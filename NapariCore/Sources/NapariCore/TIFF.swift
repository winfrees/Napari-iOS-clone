import Foundation

public enum TIFFError: Error, LocalizedError, Equatable {
    case notATIFF
    case unsupported(String)
    case corrupt(String)

    public var errorDescription: String? {
        switch self {
        case .notATIFF: return "The file is not a TIFF."
        case .unsupported(let what): return "Unsupported TIFF: \(what)."
        case .corrupt(let what): return "The TIFF file is damaged: \(what)."
        }
    }
}

/// Reads grayscale TIFF stacks: uncompressed or PackBits, 8/16/32-bit integer or
/// 32/64-bit float samples, one IFD per plane.
///
/// The result's shape comes from, in order: a tifffile `{"shape": [...]}` description,
/// ImageJ hyperstack metadata (frames, slices, channels), or the page count.
/// Values are converted to Float32, which is exact for integers up to 2^24.
public enum TIFFReader {
    public static func read(contentsOf url: URL) throws -> NDArray<Float> {
        try read(Data(contentsOf: url))
    }

    public static func read(_ data: Data) throws -> NDArray<Float> {
        let bytes = ByteReader(bytes: [UInt8](data))
        guard bytes.count >= 8 else { throw TIFFError.notATIFF }
        switch (bytes.raw[0], bytes.raw[1]) {
        case (0x49, 0x49): bytes.littleEndian = true
        case (0x4D, 0x4D): bytes.littleEndian = false
        default: throw TIFFError.notATIFF
        }
        switch try bytes.u16(2) {
        case 42: break
        case 43: throw TIFFError.unsupported("BigTIFF")
        default: throw TIFFError.notATIFF
        }

        var pages: [Page] = []
        var visited = Set<Int>()
        var ifdOffset = Int(try bytes.u32(4))
        while ifdOffset != 0, visited.insert(ifdOffset).inserted {
            let page = try Page(bytes: bytes, at: ifdOffset)
            // Stop at the first page that does not match: it starts a different series.
            if let first = pages.first, !page.matches(first) { break }
            pages.append(page)
            ifdOffset = page.nextIFD
        }
        guard let first = pages.first else { throw TIFFError.corrupt("no image directories") }

        let planeCount = first.width * first.height
        var storage = [Float](repeating: 0, count: planeCount * pages.count)
        for (index, page) in pages.enumerated() {
            let raw = try page.decodedBytes(from: bytes)
            try page.convert(raw, littleEndian: bytes.littleEndian, into: &storage, at: index * planeCount)
        }
        let shape = inferShape(description: first.description, pageCount: pages.count,
                               height: first.height, width: first.width)
        return NDArray(shape: shape, storage: storage)
    }

    static func inferShape(description: String?, pageCount: Int, height: Int, width: Int) -> [Int] {
        let total = pageCount * height * width
        if let description, description.hasPrefix("{"),
           let json = try? JSONSerialization.jsonObject(with: Data(description.utf8)) as? [String: Any],
           let shape = json["shape"] as? [Int], shape.count >= 2, shape.allSatisfy({ $0 > 0 }),
           shape.reduce(1, *) == total, Array(shape.suffix(2)) == [height, width] {
            return shape
        }
        if let description, description.hasPrefix("ImageJ=") {
            var fields: [String: Int] = [:]
            for line in description.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2, let value = Int(parts[1]) { fields[String(parts[0])] = value }
            }
            // ImageJ stores planes channel-fastest, i.e. (frames, slices, channels, y, x).
            let leading = [fields["frames"] ?? 1, fields["slices"] ?? 1, fields["channels"] ?? 1]
            if leading.reduce(1, *) == pageCount {
                return leading.filter { $0 > 1 } + [height, width]
            }
        }
        return pageCount > 1 ? [pageCount, height, width] : [height, width]
    }
}

/// Writes N-D arrays as little-endian, uncompressed multi-page TIFFs, with a tifffile
/// shape description so napari (via tifffile) reads back the original shape.
public enum TIFFWriter {
    public static func data(for array: NDArray<UInt32>) -> Data {
        write(shape: array.shape, bitsPerSample: 32, sampleFormat: 1,
              payload: array.storage.map { $0.littleEndian })
    }

    public static func data(for array: NDArray<UInt16>) -> Data {
        write(shape: array.shape, bitsPerSample: 16, sampleFormat: 1,
              payload: array.storage.map { $0.littleEndian })
    }

    public static func data(for array: NDArray<Float>) -> Data {
        write(shape: array.shape, bitsPerSample: 32, sampleFormat: 3,
              payload: array.storage.map { $0.bitPattern.littleEndian })
    }

    private static func write<T>(shape: [Int], bitsPerSample: Int, sampleFormat: Int, payload: [T]) -> Data {
        let height = shape.count >= 2 ? shape[shape.count - 2] : 1
        let width = shape[shape.count - 1]
        let pageCount = shape.dropLast(2).reduce(1, *)
        let pageBytes = width * height * bitsPerSample / 8
        let description = "{\"shape\": [\(shape.map(String.init).joined(separator: ", "))]}"
        let descriptionBytes = Array(description.utf8) + [0]
        precondition(pageCount * pageBytes < Int(UInt32.max) - 1_000_000, "classic TIFF is limited to 4 GB")

        var out = ByteWriter()
        out.bytes += [0x49, 0x49]
        out.u16(42)
        out.u32(0) // first IFD offset, patched below

        let descriptionOffset = out.count
        out.bytes += descriptionBytes
        out.padToEven()

        let dataOffset = out.count
        payload.withUnsafeBytes { out.bytes += $0 }
        out.padToEven()

        let firstIFD = out.count
        out.patchU32(at: 4, UInt32(firstIFD))
        for page in 0 ..< pageCount {
            var entries: [(tag: UInt16, type: UInt16, count: UInt32, value: UInt32)] = [
                (256, 4, 1, UInt32(width)),
                (257, 4, 1, UInt32(height)),
                (258, 3, 1, UInt32(bitsPerSample)),
                (259, 3, 1, 1), // no compression
                (262, 3, 1, 1), // BlackIsZero
                (273, 4, 1, UInt32(dataOffset + page * pageBytes)),
                (277, 3, 1, 1),
                (278, 4, 1, UInt32(height)),
                (279, 4, 1, UInt32(pageBytes)),
                (339, 3, 1, UInt32(sampleFormat)),
            ]
            if page == 0 {
                entries.insert((270, 2, UInt32(descriptionBytes.count), UInt32(descriptionOffset)), at: 5)
            }
            out.u16(UInt16(entries.count))
            for entry in entries {
                out.u16(entry.tag)
                out.u16(entry.type)
                out.u32(entry.count)
                if entry.type == 3 {
                    out.u16(UInt16(entry.value))
                    out.u16(0)
                } else {
                    out.u32(entry.value)
                }
            }
            out.u32(page == pageCount - 1 ? 0 : UInt32(out.count + 4))
        }
        return Data(out.bytes)
    }
}

// MARK: - Parsing

private final class ByteReader {
    let raw: [UInt8]
    var littleEndian = true

    init(bytes: [UInt8]) {
        raw = bytes
    }

    var count: Int { raw.count }

    func check(_ offset: Int, _ length: Int) throws {
        guard offset >= 0, length >= 0, offset + length <= raw.count else {
            throw TIFFError.corrupt("read past the end of the file")
        }
    }

    func u16(_ offset: Int) throws -> UInt16 {
        try check(offset, 2)
        let a = UInt16(raw[offset]), b = UInt16(raw[offset + 1])
        return littleEndian ? a | b << 8 : a << 8 | b
    }

    func u32(_ offset: Int) throws -> UInt32 {
        try check(offset, 4)
        let lo = UInt32(try u16(offset)), hi = UInt32(try u16(offset + 2))
        return littleEndian ? lo | hi << 16 : lo << 16 | hi
    }
}

private struct Page {
    var width = 0
    var height = 0
    var bitsPerSample = 1
    var sampleFormat = 1
    var compression = 1
    var samplesPerPixel = 1
    var stripOffsets: [Int] = []
    var stripByteCounts: [Int] = []
    var description: String?
    var nextIFD = 0

    init(bytes: ByteReader, at offset: Int) throws {
        let entryCount = Int(try bytes.u16(offset))
        var isTiled = false
        for i in 0 ..< entryCount {
            let entry = offset + 2 + i * 12
            let tag = try bytes.u16(entry)
            let type = try bytes.u16(entry + 2)
            let count = Int(try bytes.u32(entry + 4))
            let size: Int
            switch type {
            case 1, 2, 6, 7: size = 1
            case 3, 8: size = 2
            case 4, 9, 11: size = 4
            case 5, 10, 12: size = 8
            default: continue // unknown type: skip the entry, as the spec says
            }
            let valuePosition = count * size <= 4 ? entry + 8 : Int(try bytes.u32(entry + 8))
            try bytes.check(valuePosition, count * size)

            func integers() throws -> [Int] {
                switch type {
                case 1, 7: return (0 ..< count).map { Int(bytes.raw[valuePosition + $0]) }
                case 3: return try (0 ..< count).map { Int(try bytes.u16(valuePosition + 2 * $0)) }
                case 4: return try (0 ..< count).map { Int(try bytes.u32(valuePosition + 4 * $0)) }
                default: throw TIFFError.unsupported("tag \(tag) has value type \(type)")
                }
            }

            switch tag {
            case 256: width = try integers().first ?? 0
            case 257: height = try integers().first ?? 0
            case 258: bitsPerSample = try integers().first ?? 1
            case 259: compression = try integers().first ?? 1
            case 270:
                let text = bytes.raw[valuePosition ..< valuePosition + count].prefix { $0 != 0 }
                description = String(decoding: text, as: UTF8.self)
            case 273: stripOffsets = try integers()
            case 277: samplesPerPixel = try integers().first ?? 1
            case 279: stripByteCounts = try integers()
            case 322, 323, 324, 325: isTiled = true
            case 339: sampleFormat = try integers().first ?? 1
            default: break
            }
        }
        nextIFD = Int(try bytes.u32(offset + 2 + entryCount * 12))

        guard width > 0, height > 0 else { throw TIFFError.corrupt("missing image size") }
        if isTiled { throw TIFFError.unsupported("tiled images") }
        if samplesPerPixel != 1 { throw TIFFError.unsupported("\(samplesPerPixel) samples per pixel (RGB)") }
        guard [1, 32773].contains(compression) else {
            throw TIFFError.unsupported("compression scheme \(compression)")
        }
        guard !stripOffsets.isEmpty, stripOffsets.count == stripByteCounts.count else {
            throw TIFFError.corrupt("missing strip offsets")
        }
    }

    func matches(_ other: Page) -> Bool {
        width == other.width && height == other.height && bitsPerSample == other.bitsPerSample
            && sampleFormat == other.sampleFormat
    }

    var expectedByteCount: Int { width * height * bitsPerSample / 8 }

    func decodedBytes(from bytes: ByteReader) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(expectedByteCount)
        for (offset, length) in zip(stripOffsets, stripByteCounts) {
            try bytes.check(offset, length)
            let strip = bytes.raw[offset ..< offset + length]
            if compression == 1 {
                out += strip
            } else {
                try Page.unpackBits(strip, into: &out)
            }
        }
        guard out.count >= expectedByteCount else { throw TIFFError.corrupt("image data is truncated") }
        return out
    }

    static func unpackBits(_ input: ArraySlice<UInt8>, into out: inout [UInt8]) throws {
        var i = input.startIndex
        while i < input.endIndex {
            let n = Int(Int8(bitPattern: input[i]))
            i += 1
            if n >= 0 {
                guard i + n + 1 <= input.endIndex else { throw TIFFError.corrupt("PackBits run overflows") }
                out += input[i ..< i + n + 1]
                i += n + 1
            } else if n != -128 {
                guard i < input.endIndex else { throw TIFFError.corrupt("PackBits run overflows") }
                out += repeatElement(input[i], count: 1 - n)
                i += 1
            }
        }
    }

    func convert(_ raw: [UInt8], littleEndian le: Bool, into storage: inout [Float], at base: Int) throws {
        let n = width * height
        func u16(_ o: Int) -> UInt16 {
            le ? UInt16(raw[o]) | UInt16(raw[o + 1]) << 8 : UInt16(raw[o]) << 8 | UInt16(raw[o + 1])
        }
        func u32(_ o: Int) -> UInt32 {
            le ? UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 : UInt32(u16(o)) << 16 | UInt32(u16(o + 2))
        }
        func u64(_ o: Int) -> UInt64 {
            le ? UInt64(u32(o)) | UInt64(u32(o + 4)) << 32 : UInt64(u32(o)) << 32 | UInt64(u32(o + 4))
        }
        switch (bitsPerSample, sampleFormat) {
        case (8, 1): for i in 0 ..< n { storage[base + i] = Float(raw[i]) }
        case (8, 2): for i in 0 ..< n { storage[base + i] = Float(Int8(bitPattern: raw[i])) }
        case (16, 1): for i in 0 ..< n { storage[base + i] = Float(u16(2 * i)) }
        case (16, 2): for i in 0 ..< n { storage[base + i] = Float(Int16(bitPattern: u16(2 * i))) }
        case (32, 1): for i in 0 ..< n { storage[base + i] = Float(u32(4 * i)) }
        case (32, 2): for i in 0 ..< n { storage[base + i] = Float(Int32(bitPattern: u32(4 * i))) }
        case (32, 3): for i in 0 ..< n { storage[base + i] = Float(bitPattern: u32(4 * i)) }
        case (64, 3): for i in 0 ..< n { storage[base + i] = Float(Double(bitPattern: u64(8 * i))) }
        default:
            throw TIFFError.unsupported("\(bitsPerSample)-bit samples in format \(sampleFormat)")
        }
    }
}

private struct ByteWriter {
    var bytes: [UInt8] = []

    var count: Int { bytes.count }

    mutating func u16(_ value: UInt16) {
        bytes += [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    mutating func u32(_ value: UInt32) {
        u16(UInt16(value & 0xFFFF))
        u16(UInt16(value >> 16))
    }

    mutating func patchU32(at offset: Int, _ value: UInt32) {
        for i in 0 ..< 4 { bytes[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
    }

    mutating func padToEven() {
        if bytes.count % 2 == 1 { bytes.append(0) }
    }
}
