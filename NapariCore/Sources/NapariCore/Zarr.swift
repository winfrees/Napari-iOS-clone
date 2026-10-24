import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Compression)
import Compression
#endif
import libzstd

public enum ZarrError: Error, LocalizedError, Equatable {
    case notZarr(String)
    case unsupported(String)
    case corrupt(String)
    case http(status: Int, key: String)
    case tooLarge(voxels: Int)

    public var errorDescription: String? {
        switch self {
        case .notZarr(let detail): return "Not a Zarr array or OME-Zarr image: \(detail)."
        case .unsupported(let what): return "Unsupported Zarr data: \(what)."
        case .corrupt(let what): return "The Zarr data is damaged: \(what)."
        case .http(let status, let key): return "The server returned HTTP \(status) for \(key)."
        case .tooLarge(let voxels): return "Even the smallest resolution level has \(voxels) voxels, too many to load."
        }
    }
}

// MARK: - Stores

/// Key-value access to a Zarr hierarchy. Returns nil for keys that don't exist
/// (missing chunks are filled with the array's fill value).
public protocol ZarrStore: Sendable {
    func get(_ key: String) async throws -> Data?
}

/// A Zarr hierarchy in a local folder, e.g. a `.zarr` directory picked in Files.
public struct DirectoryStore: ZarrStore {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func get(_ key: String) async throws -> Data? {
        let url = key.isEmpty ? root : root.appendingPathComponent(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
}

/// A Zarr hierarchy served over HTTP(S), e.g. from S3 or the IDR.
public struct HTTPStore: ZarrStore {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func get(_ key: String) async throws -> Data? {
        let url = key.isEmpty ? root : root.appendingPathComponent(key)
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        // Object stores answer 403 rather than 404 for missing keys when listing is not allowed.
        if status == 404 || status == 403 { return nil }
        guard (200 ..< 300).contains(status) else { throw ZarrError.http(status: status, key: key) }
        return data
    }
}

// MARK: - Array metadata

/// The element type of a Zarr array.
public struct ZarrDataType: Equatable, Sendable {
    /// "u" unsigned integer, "i" signed integer, "f" float, "b" boolean.
    public var kind: Character
    public var size: Int
    public var littleEndian: Bool

    /// Parses a Zarr v2 dtype such as "<u2", ">f4" or "|u1".
    init(v2 string: String) throws {
        let chars = Array(string)
        guard chars.count >= 3, "<>|".contains(chars[0]), let size = Int(String(chars[2...])),
              "uifb".contains(chars[1])
        else { throw ZarrError.unsupported("data type \(string)") }
        self.init(kind: chars[1], size: size, littleEndian: chars[0] != ">")
    }

    /// Parses a Zarr v3 data_type such as "uint16" or "float32".
    init(v3 name: String, littleEndian: Bool) throws {
        let table: [String: (Character, Int)] = [
            "bool": ("b", 1), "int8": ("i", 1), "uint8": ("u", 1), "int16": ("i", 2), "uint16": ("u", 2),
            "int32": ("i", 4), "uint32": ("u", 4), "int64": ("i", 8), "uint64": ("u", 8),
            "float32": ("f", 4), "float64": ("f", 8),
        ]
        guard let entry = table[name] else { throw ZarrError.unsupported("data type \(name)") }
        self.init(kind: entry.0, size: entry.1, littleEndian: littleEndian)
    }

    init(kind: Character, size: Int, littleEndian: Bool) {
        self.kind = kind
        self.size = size
        self.littleEndian = littleEndian
    }
}

/// Byte-to-byte codecs, applied in this order when encoding and in reverse when decoding.
public enum ZarrCodec: Equatable, Sendable {
    case blosc
    case zlib
    case gzip
    case zstd
    /// numcodecs' LZ4: a little-endian uncompressed length, then a raw LZ4 block.
    case lz4
    /// A trailing CRC32C checksum, which is stripped without being checked.
    case crc32c
}

public struct ZarrArrayMetadata: Equatable, Sendable {
    public var shape: [Int]
    public var chunks: [Int]
    public var dataType: ZarrDataType
    public var codecs: [ZarrCodec]
    public var fillValue: Double
    /// Separator between chunk indices in chunk keys.
    public var separator: String
    /// Prepended to chunk keys: "c" for Zarr v3's default encoding, empty otherwise.
    public var keyPrefix: String?

    public var chunkElementCount: Int { chunks.reduce(1, *) }

    public func chunkKey(_ grid: [Int]) -> String {
        let indices = grid.map(String.init)
        return ([keyPrefix].compactMap { $0 } + indices).joined(separator: separator)
    }

    /// Parses `.zarray` (v2) JSON.
    static func v2(_ json: [String: Any]) throws -> ZarrArrayMetadata {
        guard let shape = json["shape"] as? [Int], let chunks = json["chunks"] as? [Int], shape.count == chunks.count
        else { throw ZarrError.corrupt(".zarray has no valid shape and chunks") }
        guard let dtype = json["dtype"] as? String else {
            throw ZarrError.unsupported("structured data types")
        }
        if let order = json["order"] as? String, order != "C" {
            throw ZarrError.unsupported("Fortran-ordered chunks")
        }
        if let filters = json["filters"] as? [Any], !filters.isEmpty {
            throw ZarrError.unsupported("Zarr filters")
        }
        var codecs: [ZarrCodec] = []
        if let compressor = json["compressor"] as? [String: Any] {
            codecs = [try codec(named: compressor["id"] as? String ?? "?")]
        }
        return ZarrArrayMetadata(
            shape: shape, chunks: chunks, dataType: try ZarrDataType(v2: dtype), codecs: codecs,
            fillValue: fillValue(json["fill_value"]),
            separator: json["dimension_separator"] as? String ?? ".", keyPrefix: nil
        )
    }

    /// Parses an array's `zarr.json` (v3).
    static func v3(_ json: [String: Any]) throws -> ZarrArrayMetadata {
        guard let shape = json["shape"] as? [Int],
              let grid = json["chunk_grid"] as? [String: Any], grid["name"] as? String == "regular",
              let chunks = (grid["configuration"] as? [String: Any])?["chunk_shape"] as? [Int],
              shape.count == chunks.count
        else { throw ZarrError.unsupported("Zarr v3 arrays without a regular chunk grid") }
        guard let dataType = json["data_type"] as? String else {
            throw ZarrError.corrupt("zarr.json has no data_type")
        }

        var littleEndian = true
        var codecs: [ZarrCodec] = []
        for case let entry as [String: Any] in json["codecs"] as? [Any] ?? [] {
            let name = entry["name"] as? String ?? "?"
            let configuration = entry["configuration"] as? [String: Any] ?? [:]
            switch name {
            case "bytes", "endian":
                littleEndian = configuration["endian"] as? String != "big"
            case "sharding_indexed":
                throw ZarrError.unsupported("sharded Zarr v3 arrays")
            case "transpose":
                throw ZarrError.unsupported("transposed Zarr v3 arrays")
            default:
                codecs.append(try codec(named: name))
            }
        }

        var separator = "/"
        var prefix: String? = "c"
        if let encoding = json["chunk_key_encoding"] as? [String: Any] {
            let configured = (encoding["configuration"] as? [String: Any])?["separator"] as? String
            if encoding["name"] as? String == "v2" {
                separator = configured ?? "."
                prefix = nil
            } else {
                separator = configured ?? "/"
            }
        }
        return ZarrArrayMetadata(
            shape: shape, chunks: chunks, dataType: try ZarrDataType(v3: dataType, littleEndian: littleEndian),
            codecs: codecs, fillValue: fillValue(json["fill_value"]), separator: separator, keyPrefix: prefix
        )
    }

    private static func codec(named name: String) throws -> ZarrCodec {
        switch name {
        case "blosc": return .blosc
        case "zlib": return .zlib
        case "gzip": return .gzip
        case "zstd": return .zstd
        case "lz4": return .lz4
        case "crc32c": return .crc32c
        default: throw ZarrError.unsupported("the \(name) compressor")
        }
    }

    private static func fillValue(_ value: Any?) -> Double {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let text as String:
            switch text {
            case "NaN": return .nan
            case "Infinity": return .infinity
            case "-Infinity": return -.infinity
            default: return Double(text) ?? 0
            }
        default: return 0
        }
    }
}

// MARK: - Arrays

public struct ZarrArray: Sendable {
    public let store: any ZarrStore
    public let path: String
    public let metadata: ZarrArrayMetadata

    /// Opens the array at `path` (empty for the store root), reading `.zarray` or `zarr.json`.
    public static func open(_ store: any ZarrStore, path: String = "") async throws -> ZarrArray {
        if let data = try await store.get(join(path, ".zarray")) {
            return ZarrArray(store: store, path: path, metadata: try .v2(try jsonObject(data)))
        }
        if let data = try await store.get(join(path, "zarr.json")) {
            let json = try jsonObject(data)
            guard json["node_type"] as? String == "array" else {
                throw ZarrError.notZarr("\(path.isEmpty ? "the root" : path) is a group, not an array")
            }
            return ZarrArray(store: store, path: path, metadata: try .v3(json))
        }
        throw ZarrError.notZarr("no .zarray or zarr.json at \(path.isEmpty ? "the root" : path)")
    }

    public var voxelCount: Int { metadata.shape.reduce(1, *) }

    /// Reads the whole array as Float32, fetching up to `concurrency` chunks at a time.
    public func read(concurrency: Int = 8) async throws -> NDArray<Float> {
        let meta = metadata
        let shape = meta.shape
        guard !shape.isEmpty, shape.allSatisfy({ $0 > 0 }) else { throw ZarrError.unsupported("empty arrays") }
        var storage = [Float](repeating: Float(meta.fillValue), count: voxelCount)
        let strides = NDArray<Float>.rowMajorStrides(for: shape)
        let gridShape = zip(shape, meta.chunks).map { ($0 + $1 - 1) / $1 }
        let gridCount = gridShape.reduce(1, *)
        let gridStrides = NDArray<Float>.rowMajorStrides(for: gridShape)
        let store = self.store
        let path = self.path

        try await withThrowingTaskGroup(of: (grid: [Int], values: [Float]?).self) { group in
            var next = 0
            func enqueue() {
                guard next < gridCount else { return }
                let flat = next
                next += 1
                let grid = gridStrides.indices.map { (flat / gridStrides[$0]) % gridShape[$0] }
                group.addTask {
                    guard let data = try await store.get(join(path, meta.chunkKey(grid))) else { return (grid, nil) }
                    return (grid, try ZarrChunkDecoder.decode(data, metadata: meta))
                }
            }
            for _ in 0 ..< max(1, concurrency) { enqueue() }
            while let result = try await group.next() {
                if let values = result.values {
                    ZarrArray.copy(chunk: values, grid: result.grid, chunks: meta.chunks, into: &storage,
                                   shape: shape, strides: strides)
                }
                enqueue()
            }
        }
        return NDArray(shape: shape, storage: storage)
    }

    /// Copies a decoded chunk into the full array, clipping chunks that overhang the edges.
    static func copy(chunk values: [Float], grid: [Int], chunks: [Int], into storage: inout [Float],
                     shape: [Int], strides: [Int]) {
        let n = shape.count
        let origin = zip(grid, chunks).map(*)
        let extent = (0 ..< n).map { min(chunks[$0], shape[$0] - origin[$0]) }
        guard extent.allSatisfy({ $0 > 0 }) else { return }
        let chunkStrides = NDArray<Float>.rowMajorStrides(for: chunks)
        let rowLength = extent[n - 1]
        var index = Array(repeating: 0, count: n - 1) // position within the chunk, all axes but the last
        while true {
            var source = 0
            var destination = origin[n - 1]
            for axis in 0 ..< n - 1 {
                source += index[axis] * chunkStrides[axis]
                destination += (origin[axis] + index[axis]) * strides[axis]
            }
            storage.replaceSubrange(destination ..< destination + rowLength, with: values[source ..< source + rowLength])
            // Advance the odometer over the valid region.
            var axis = n - 2
            while axis >= 0 {
                index[axis] += 1
                if index[axis] < extent[axis] { break }
                index[axis] = 0
                axis -= 1
            }
            if axis < 0 { return }
        }
    }
}

func join(_ path: String, _ key: String) -> String {
    path.isEmpty ? key : path + "/" + key
}

func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ZarrError.corrupt("invalid JSON metadata")
    }
    return json
}

// MARK: - Chunk decoding

enum ZarrChunkDecoder {
    static func decode(_ data: Data, metadata: ZarrArrayMetadata) throws -> [Float] {
        let count = metadata.chunkElementCount
        let byteCount = count * metadata.dataType.size
        var bytes = [UInt8](data)
        for codec in metadata.codecs.reversed() {
            bytes = try decode(bytes, codec: codec, expectedSize: byteCount)
        }
        guard bytes.count >= byteCount else {
            throw ZarrError.corrupt("chunk has \(bytes.count) bytes, expected \(byteCount)")
        }
        return try convert(bytes, count: count, type: metadata.dataType)
    }

    static func decode(_ bytes: [UInt8], codec: ZarrCodec, expectedSize: Int) throws -> [UInt8] {
        switch codec {
        case .blosc:
            return try Blosc.decompress(bytes)
        case .zlib:
            // zlib = 2-byte header + raw deflate + Adler-32.
            guard bytes.count > 6 else { throw ZarrError.corrupt("truncated zlib stream") }
            return try inflate(bytes[2...], capacity: expectedSize)
        case .gzip:
            let start = try gzipPayloadStart(bytes)
            return try inflate(bytes[start...], capacity: expectedSize)
        case .zstd:
            return try zstdDecompress(bytes[...], capacity: expectedSize)
        case .lz4:
            guard bytes.count >= 4 else { throw ZarrError.corrupt("truncated LZ4 chunk") }
            let size = Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
            return try lz4Decompress(bytes[4...], size: size)
        case .crc32c:
            guard bytes.count >= 4 else { throw ZarrError.corrupt("truncated checksum") }
            return Array(bytes.dropLast(4))
        }
    }

    /// Skips a gzip member header (RFC 1952) and returns where the deflate data starts.
    static func gzipPayloadStart(_ bytes: [UInt8]) throws -> Int {
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else {
            throw ZarrError.corrupt("invalid gzip header")
        }
        let flags = bytes[3]
        var position = 10
        if flags & 0x04 != 0 { position += 2 + (Int(bytes[position]) | Int(bytes[position + 1]) << 8) }
        if flags & 0x08 != 0 { while position < bytes.count, bytes[position] != 0 { position += 1 }; position += 1 }
        if flags & 0x10 != 0 { while position < bytes.count, bytes[position] != 0 { position += 1 }; position += 1 }
        if flags & 0x02 != 0 { position += 2 }
        guard position < bytes.count else { throw ZarrError.corrupt("invalid gzip header") }
        return position
    }

    static func convert(_ bytes: [UInt8], count: Int, type: ZarrDataType) throws -> [Float] {
        let le = type.littleEndian
        return try bytes.withUnsafeBytes { raw -> [Float] in
            func load<T: FixedWidthInteger>(_: T.Type, _ i: Int) -> T {
                let value = raw.loadUnaligned(fromByteOffset: i * MemoryLayout<T>.size, as: T.self)
                return le ? T(littleEndian: value) : T(bigEndian: value)
            }
            switch (type.kind, type.size) {
            case ("u", 1), ("b", 1): return (0 ..< count).map { Float(raw[$0]) }
            case ("i", 1): return (0 ..< count).map { Float(Int8(bitPattern: raw[$0])) }
            case ("u", 2): return (0 ..< count).map { Float(load(UInt16.self, $0)) }
            case ("i", 2): return (0 ..< count).map { Float(load(Int16.self, $0)) }
            case ("u", 4): return (0 ..< count).map { Float(load(UInt32.self, $0)) }
            case ("i", 4): return (0 ..< count).map { Float(load(Int32.self, $0)) }
            case ("u", 8): return (0 ..< count).map { Float(load(UInt64.self, $0)) }
            case ("i", 8): return (0 ..< count).map { Float(load(Int64.self, $0)) }
            case ("f", 4): return (0 ..< count).map { Float(bitPattern: load(UInt32.self, $0)) }
            case ("f", 8): return (0 ..< count).map { Float(Double(bitPattern: load(UInt64.self, $0))) }
            default: throw ZarrError.unsupported("\(type.size)-byte \(type.kind) data")
            }
        }
    }
}

// MARK: - Compression primitives

func zstdDecompress(_ src: ArraySlice<UInt8>, capacity: Int) throws -> [UInt8] {
    guard !src.isEmpty else { throw ZarrError.corrupt("empty zstd frame") }
    return try src.withUnsafeBytes { input -> [UInt8] in
        let declared = ZSTD_getFrameContentSize(input.baseAddress, input.count)
        // UInt64.max is "unknown", UInt64.max - 1 is "error".
        let size = declared < UInt64.max - 1 ? Int(declared) : capacity
        var output = [UInt8](repeating: 0, count: max(size, 1))
        let written = output.withUnsafeMutableBytes { out in
            ZSTD_decompress(out.baseAddress, out.count, input.baseAddress, input.count)
        }
        guard ZSTD_isError(written) == 0 else {
            throw ZarrError.corrupt("zstd: \(String(cString: ZSTD_getErrorName(written)))")
        }
        return Array(output[..<written])
    }
}

#if canImport(Compression)
private func appleDecode(_ src: ArraySlice<UInt8>, algorithm: compression_algorithm, capacity: Int) throws -> [UInt8] {
    guard !src.isEmpty, capacity > 0 else { throw ZarrError.corrupt("empty compressed data") }
    var output = [UInt8](repeating: 0, count: capacity)
    let written = src.withUnsafeBufferPointer { input in
        output.withUnsafeMutableBufferPointer { out in
            compression_decode_buffer(out.baseAddress!, out.count, input.baseAddress!, input.count, nil, algorithm)
        }
    }
    guard written > 0 else { throw ZarrError.corrupt("could not decompress chunk") }
    return Array(output[..<written])
}

/// Raw DEFLATE (no zlib or gzip wrapper).
func inflate(_ src: ArraySlice<UInt8>, capacity: Int) throws -> [UInt8] {
    try appleDecode(src, algorithm: COMPRESSION_ZLIB, capacity: capacity)
}

/// A raw LZ4 block of known decompressed size.
func lz4Decompress(_ src: ArraySlice<UInt8>, size: Int) throws -> [UInt8] {
    try appleDecode(src, algorithm: COMPRESSION_LZ4_RAW, capacity: size)
}
#else
func inflate(_ src: ArraySlice<UInt8>, capacity: Int) throws -> [UInt8] {
    throw ZarrError.unsupported("zlib on this platform")
}

func lz4Decompress(_ src: ArraySlice<UInt8>, size: Int) throws -> [UInt8] {
    throw ZarrError.unsupported("LZ4 on this platform")
}
#endif

/// Decoder for Blosc 1 containers, the default Zarr compressor.
enum Blosc {
    static func decompress(_ src: [UInt8]) throws -> [UInt8] {
        guard src.count >= 16 else { throw ZarrError.corrupt("truncated Blosc header") }
        func u32(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 4 <= src.count else { throw ZarrError.corrupt("truncated Blosc data") }
            return Int(UInt32(src[offset]) | UInt32(src[offset + 1]) << 8
                | UInt32(src[offset + 2]) << 16 | UInt32(src[offset + 3]) << 24)
        }
        let flags = src[2]
        let typesize = max(1, Int(src[3]))
        let nbytes = try u32(4)
        let blocksize = try u32(8)
        guard nbytes > 0 else { return [] }

        // Stored uncompressed.
        if flags & 0x02 != 0 {
            guard src.count >= 16 + nbytes else { throw ZarrError.corrupt("truncated Blosc data") }
            return Array(src[16 ..< 16 + nbytes])
        }
        if flags & 0x04 != 0 { throw ZarrError.unsupported("bit-shuffled Blosc data") }
        guard blocksize > 0 else { throw ZarrError.corrupt("Blosc block size is zero") }

        let compressor = (flags >> 5) & 0x07
        let shuffled = flags & 0x01 != 0 && typesize > 1
        let dontSplit = flags & 0x10 != 0
        let blockCount = (nbytes + blocksize - 1) / blocksize
        var output = [UInt8](repeating: 0, count: nbytes)

        for block in 0 ..< blockCount {
            let start = block * blocksize
            let size = min(blocksize, nbytes - start)
            let leftover = size < blocksize
            let splits = !dontSplit && !leftover ? typesize : 1
            let splitSize = size / splits
            var decoded: [UInt8] = []
            decoded.reserveCapacity(size)
            var position = try u32(16 + 4 * block)
            for _ in 0 ..< splits {
                let rawSize = try u32(position)
                let compressedSize = Int(Int32(truncatingIfNeeded: rawSize))
                position += 4
                guard compressedSize > 0, position + compressedSize <= src.count else {
                    throw ZarrError.corrupt("invalid Blosc stream")
                }
                let stream = src[position ..< position + compressedSize]
                if compressedSize == splitSize {
                    decoded += stream // stored
                } else {
                    decoded += try decodeStream(stream, compressor: compressor, size: splitSize)
                }
                position += compressedSize
            }
            guard decoded.count == size else { throw ZarrError.corrupt("Blosc block has the wrong size") }
            if shuffled { decoded = unshuffle(decoded, typesize: typesize) }
            output.replaceSubrange(start ..< start + size, with: decoded)
        }
        return output
    }

    private static func decodeStream(_ stream: ArraySlice<UInt8>, compressor: UInt8, size: Int) throws -> [UInt8] {
        switch compressor {
        case 1: return try lz4Decompress(stream, size: size)
        case 3:
            guard stream.count > 2 else { throw ZarrError.corrupt("truncated zlib stream") }
            return try inflate(stream.dropFirst(2), capacity: size)
        case 4: return try zstdDecompress(stream, capacity: size)
        case 0: throw ZarrError.unsupported("Blosc's blosclz codec (lz4, zlib and zstd are supported)")
        case 2: throw ZarrError.unsupported("Blosc's snappy codec (lz4, zlib and zstd are supported)")
        default: throw ZarrError.unsupported("Blosc codec \(compressor)")
        }
    }

    /// Undoes Blosc's byte shuffle: byte j of every element is stored together.
    static func unshuffle(_ bytes: [UInt8], typesize: Int) -> [UInt8] {
        let elements = bytes.count / typesize
        var output = bytes // keeps any trailing bytes that were not shuffled
        for i in 0 ..< elements {
            for j in 0 ..< typesize {
                output[i * typesize + j] = bytes[j * elements + i]
            }
        }
        return output
    }

    static func shuffle(_ bytes: [UInt8], typesize: Int) -> [UInt8] {
        let elements = bytes.count / typesize
        var output = bytes
        for i in 0 ..< elements {
            for j in 0 ..< typesize {
                output[j * elements + i] = bytes[i * typesize + j]
            }
        }
        return output
    }
}
