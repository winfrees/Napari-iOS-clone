import Compression
import libzstd
import XCTest
@testable import NapariCore

final class ZarrTests: XCTestCase {
    private var root: URL!
    private var store: DirectoryStore { DirectoryStore(root: root) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Zarr v2

    func testUncompressedEdgesAndMissingChunks() async throws {
        let values = (0 ..< 35).map { UInt16($0) }
        try writeArray(path: "a", shape: [5, 7], chunks: [2, 3], values: values, separator: "/", fill: 9,
                       skip: [[1, 1]])
        let array = try await ZarrArray.open(store, path: "a").read()
        XCTAssertEqual(array.shape, [5, 7])
        for row in 0 ..< 5 {
            for col in 0 ..< 7 {
                let missing = (2 ..< 4).contains(row) && (3 ..< 6).contains(col)
                XCTAssertEqual(array[[row, col]], missing ? 9 : Float(row * 7 + col), "at \(row), \(col)")
            }
        }
    }

    func testZlibGzipZstdAndLZ4Compressors() async throws {
        let values = (0 ..< 24).map { UInt16($0 * 100) }
        let expected = values.map { Float($0) }
        try writeArray(path: "zlib", shape: [4, 6], chunks: [3, 4], values: values, compressor: ["id": "zlib"]) {
            [0x78, 0x9C] + self.deflate($0) + [0, 0, 0, 0]
        }
        try writeArray(path: "gzip", shape: [4, 6], chunks: [3, 4], values: values, compressor: ["id": "gzip"]) {
            [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3] + self.deflate($0) + Array(repeating: 0, count: 8)
        }
        try writeArray(path: "zstd", shape: [4, 6], chunks: [3, 4], values: values, compressor: ["id": "zstd"],
                       encode: zstd)
        try writeArray(path: "lz4", shape: [4, 6], chunks: [3, 4], values: values, compressor: ["id": "lz4"]) {
            le32($0.count) + self.lz4($0)
        }
        for path in ["zlib", "gzip", "zstd", "lz4"] {
            let array = try await ZarrArray.open(store, path: path).read()
            XCTAssertEqual(array.storage, expected, path)
        }
    }

    func testBloscWithShuffle() async throws {
        let values = (0 ..< 600).map { UInt16($0 % 50) }
        for (codec, name) in [(UInt8(1), "lz4"), (UInt8(4), "zstd"), (UInt8(3), "zlib")] {
            try writeArray(path: name, shape: [20, 30], chunks: [10, 30], values: values,
                           compressor: ["id": "blosc", "cname": name]) {
                self.blosc($0, typesize: 2, codec: codec)
            }
            let array = try await ZarrArray.open(store, path: name).read()
            XCTAssertEqual(array.storage, values.map { Float($0) }, name)
        }
    }

    func testBloscStoredUncompressed() throws {
        let payload: [UInt8] = [1, 2, 3, 4, 5]
        let container: [UInt8] = [2, 1, 0x02, 1] + le32(5) + le32(5) + le32(21) + payload
        XCTAssertEqual(try Blosc.decompress(container), payload)
        XCTAssertEqual(Blosc.unshuffle(Blosc.shuffle([1, 2, 3, 4, 5, 6, 7], typesize: 2), typesize: 2),
                       [1, 2, 3, 4, 5, 6, 7])
    }

    func testFloatAndBigEndian() async throws {
        let floats: [Float] = [1.5, -2.25, 3, 1e6]
        let bigEndian = floats.flatMap { value -> [UInt8] in
            withUnsafeBytes(of: value.bitPattern.bigEndian) { Array($0) }
        }
        try writeJSON("f/.zarray", ["zarr_format": 2, "shape": [2, 2], "chunks": [2, 2], "dtype": ">f4",
                                    "order": "C", "compressor": NSNull(), "fill_value": "NaN", "filters": NSNull()])
        try write("f/0.0", Data(bigEndian))
        let array = try await ZarrArray.open(store, path: "f").read()
        XCTAssertEqual(array.storage, floats)
    }

    // MARK: Zarr v3

    func testZarrV3WithZstd() async throws {
        let values = (0 ..< 12).map { UInt16($0 + 1) }
        try writeJSON("v3/zarr.json", [
            "zarr_format": 3, "node_type": "array", "shape": [3, 4], "data_type": "uint16",
            "chunk_grid": ["name": "regular", "configuration": ["chunk_shape": [2, 4]]],
            "chunk_key_encoding": ["name": "default", "configuration": ["separator": "/"]],
            "codecs": [["name": "bytes", "configuration": ["endian": "little"]],
                       ["name": "zstd", "configuration": ["level": 3]]],
            "fill_value": 0,
        ])
        for (chunkRow, rows) in [(0, 0 ..< 2), (1, 2 ..< 4)] {
            let chunk = rows.flatMap { row in (0 ..< 4).map { col in row < 3 ? values[row * 4 + col] : 0 } }
            try write("v3/c/\(chunkRow)/0", Data(zstd(bytes(chunk))))
        }
        let array = try await ZarrArray.open(store, path: "v3").read()
        XCTAssertEqual(array.storage, values.map { Float($0) })
    }

    func testShardedV3IsReportedAsUnsupported() async throws {
        try writeJSON("s/zarr.json", [
            "zarr_format": 3, "node_type": "array", "shape": [4, 4], "data_type": "uint8",
            "chunk_grid": ["name": "regular", "configuration": ["chunk_shape": [4, 4]]],
            "codecs": [["name": "sharding_indexed", "configuration": [:] as [String: Any]]], "fill_value": 0,
        ])
        do {
            _ = try await ZarrArray.open(store, path: "s")
            XCTFail("expected an error")
        } catch let error as ZarrError {
            XCTAssertEqual(error, .unsupported("sharded Zarr v3 arrays"))
        }
    }

    // MARK: OME-Zarr

    func testOMEZarrPicksLevelWithinBudgetAndReadsChannels() async throws {
        try writeJSON("img.zarr/.zattrs", [
            "multiscales": [[
                "version": "0.4",
                "axes": [["name": "c", "type": "channel"], ["name": "y", "type": "space"], ["name": "x", "type": "space"]],
                "datasets": [
                    ["path": "0", "coordinateTransformations": [["type": "scale", "scale": [1, 0.5, 0.5]]]],
                    ["path": "1", "coordinateTransformations": [["type": "scale", "scale": [1, 1, 1]]]],
                ],
            ]],
            "omero": ["channels": [
                ["label": "DAPI", "color": "0000FF", "window": ["start": 10, "end": 200, "min": 0, "max": 255]],
                ["label": "GFP", "color": "00FF00", "window": ["start": 0, "end": 50, "min": 0, "max": 255]],
            ]],
        ])
        try writeArray(path: "img.zarr/0", shape: [2, 40, 40], chunks: [1, 40, 40],
                       values: Array(repeating: 1, count: 3200))
        try writeArray(path: "img.zarr/1", shape: [2, 20, 20], chunks: [1, 20, 20],
                       values: (0 ..< 800).map { UInt16($0) })

        let image = try await OMEZarr.open(DirectoryStore(root: root.appendingPathComponent("img.zarr")),
                                           voxelBudget: 2000)
        XCTAssertEqual(image.level, 1)
        XCTAssertEqual(image.levelCount, 2)
        XCTAssertEqual(image.data.shape, [2, 20, 20])
        XCTAssertEqual(image.data[[1, 0, 0]], 400)
        XCTAssertEqual(image.axes, ["c", "y", "x"])
        XCTAssertEqual(image.channelAxis, 0)
        XCTAssertEqual(image.scale, [1, 1, 1])
        XCTAssertEqual(image.channels.map(\.label), ["DAPI", "GFP"])
        XCTAssertEqual(image.channels[0].color, RGBA(0, 0, 1))
        XCTAssertEqual(image.channels[0].window, 10 ... 200)

        do {
            _ = try await OMEZarr.open(DirectoryStore(root: root.appendingPathComponent("img.zarr")), voxelBudget: 100)
            XCTFail("expected an error")
        } catch let error as ZarrError {
            XCTAssertEqual(error, .tooLarge(voxels: 800))
        }
    }

    func testBioformats2rawLayoutAndDefaultAxes() async throws {
        try writeJSON("b.zarr/.zattrs", ["bioformats2raw.layout": 3])
        try writeJSON("b.zarr/0/.zattrs", ["multiscales": [["version": "0.2", "datasets": [["path": "0"]]]]])
        try writeArray(path: "b.zarr/0/0", shape: [1, 2, 3, 4, 5], chunks: [1, 1, 3, 4, 5],
                       values: (0 ..< 120).map { UInt16($0) })
        let image = try await OMEZarr.open(DirectoryStore(root: root.appendingPathComponent("b.zarr")))
        XCTAssertEqual(image.axes, ["t", "c", "z", "y", "x"])
        XCTAssertEqual(image.channelAxis, 1)
        XCTAssertEqual(image.data.storage.last, 119)
    }

    // MARK: Helpers

    private func write(_ key: String, _ data: Data) throws {
        let url = root.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func writeJSON(_ key: String, _ object: [String: Any]) throws {
        try write(key, JSONSerialization.data(withJSONObject: object))
    }

    /// Writes a little-endian uint16 Zarr v2 array, encoding each chunk with `encode`.
    private func writeArray(
        path: String, shape: [Int], chunks: [Int], values: [UInt16], separator: String = ".",
        compressor: [String: Any]? = nil, fill: Int = 0, skip: Set<[Int]> = [],
        encode: ([UInt8]) -> [UInt8] = { $0 }
    ) throws {
        try writeJSON(path + "/.zarray", [
            "zarr_format": 2, "shape": shape, "chunks": chunks, "dtype": "<u2", "order": "C",
            "compressor": compressor ?? NSNull(), "fill_value": fill, "filters": NSNull(),
            "dimension_separator": separator,
        ])
        let gridShape = zip(shape, chunks).map { ($0 + $1 - 1) / $1 }
        let strides = NDArray<UInt16>.rowMajorStrides(for: shape)
        let chunkStrides = NDArray<UInt16>.rowMajorStrides(for: chunks)
        for flatGrid in 0 ..< gridShape.reduce(1, *) {
            let grid = NDArray<UInt16>.rowMajorStrides(for: gridShape).enumerated().map { (flatGrid / $1) % gridShape[$0] }
            if skip.contains(grid) { continue }
            let chunk = (0 ..< chunks.reduce(1, *)).map { element -> UInt16 in
                var offset = 0
                for axis in shape.indices {
                    let index = grid[axis] * chunks[axis] + (element / chunkStrides[axis]) % chunks[axis]
                    guard index < shape[axis] else { return 0 }
                    offset += index * strides[axis]
                }
                return values[offset]
            }
            let key = grid.map(String.init).joined(separator: separator)
            try write(path + "/" + key, Data(encode(bytes(chunk))))
        }
    }

    private func bytes(_ values: [UInt16]) -> [UInt8] {
        values.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }

    private func deflate(_ input: [UInt8]) -> [UInt8] {
        appleEncode(input, COMPRESSION_ZLIB)
    }

    private func lz4(_ input: [UInt8]) -> [UInt8] {
        appleEncode(input, COMPRESSION_LZ4_RAW)
    }

    private func appleEncode(_ input: [UInt8], _ algorithm: compression_algorithm) -> [UInt8] {
        let capacity = input.count * 2 + 64
        var output = [UInt8](repeating: 0, count: capacity)
        let written = compression_encode_buffer(&output, capacity, input, input.count, nil, algorithm)
        precondition(written > 0, "compression failed")
        return Array(output[..<written])
    }

    private func zstd(_ input: [UInt8]) -> [UInt8] {
        let capacity = ZSTD_compressBound(input.count)
        var output = [UInt8](repeating: 0, count: capacity)
        let written = ZSTD_compress(&output, capacity, input, input.count, 3)
        precondition(ZSTD_isError(written) == 0, "zstd failed")
        return Array(output[..<written])
    }

    /// A single-block Blosc 1 container with byte shuffle, one compressed stream per byte position.
    private func blosc(_ input: [UInt8], typesize: Int, codec: UInt8) -> [UInt8] {
        precondition(input.count % typesize == 0)
        let shuffled = Blosc.shuffle(input, typesize: typesize)
        let splitSize = input.count / typesize
        var body: [UInt8] = []
        for j in 0 ..< typesize {
            let stream = Array(shuffled[j * splitSize ..< (j + 1) * splitSize])
            var compressed: [UInt8]
            switch codec {
            case 1: compressed = lz4(stream)
            case 3: compressed = [0x78, 0x9C] + deflate(stream) + [0, 0, 0, 0]
            default: compressed = zstd(stream)
            }
            if compressed.count >= splitSize { compressed = stream }
            body += le32(compressed.count) + compressed
        }
        let header: [UInt8] = [2, 1, 0x01 | codec << 5, UInt8(typesize)]
            + le32(input.count) + le32(input.count) + le32(16 + 4 + body.count)
        return header + le32(20) + body
    }
}

private func le32(_ value: Int) -> [UInt8] {
    (0 ..< 4).map { UInt8((value >> (8 * $0)) & 0xFF) }
}
