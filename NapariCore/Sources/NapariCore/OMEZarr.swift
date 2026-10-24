import Foundation

/// An image read from an OME-Zarr (OME-NGFF) multiscale, at one resolution level.
public struct OMEZarrImage {
    public struct Channel: Equatable {
        public var label: String?
        public var color: RGBA?
        /// The display window (contrast limits) suggested by the file.
        public var window: ClosedRange<Float>?
    }

    public var data: NDArray<Float>
    /// Axis names in data order, e.g. ["t", "c", "z", "y", "x"].
    public var axes: [String]
    public var channelAxis: Int?
    public var channels: [Channel]
    /// Physical size of one voxel along each axis at the loaded level, if given.
    public var scale: [Double]?
    /// Index of the loaded resolution level (0 is full resolution) and how many there are.
    public var level: Int
    public var levelCount: Int
}

public enum OMEZarr {
    /// Opens the image at the root of `store`: an OME-Zarr multiscale image (NGFF 0.1–0.5),
    /// a bioformats2raw folder (whose first image is opened), or a plain Zarr array.
    ///
    /// Loads the highest-resolution level with at most `voxelBudget` voxels.
    public static func open(_ store: any ZarrStore, path: String = "", voxelBudget: Int = 64_000_000) async throws -> OMEZarrImage {
        let attributes = try await groupAttributes(store, path: path)

        guard let multiscales = attributes?["multiscales"] as? [[String: Any]], let multiscale = multiscales.first else {
            if attributes?["bioformats2raw.layout"] != nil {
                return try await open(store, path: join(path, "0"), voxelBudget: voxelBudget)
            }
            // Not an image group: try a bare array.
            let array = try await ZarrArray.open(store, path: path)
            guard array.voxelCount <= voxelBudget else { throw ZarrError.tooLarge(voxels: array.voxelCount) }
            let data = try await array.read()
            return OMEZarrImage(data: data, axes: (0 ..< data.ndim).map(String.init), channelAxis: nil, channels: [],
                                scale: nil, level: 0, levelCount: 1)
        }

        let datasets = multiscale["datasets"] as? [[String: Any]] ?? []
        guard !datasets.isEmpty else { throw ZarrError.notZarr("the multiscale has no datasets") }

        // Datasets go from full resolution to coarsest: take the first that fits the budget.
        var chosen: (index: Int, array: ZarrArray)?
        var smallest = Int.max
        for (index, dataset) in datasets.enumerated() {
            guard let datasetPath = dataset["path"] as? String else { continue }
            let array = try await ZarrArray.open(store, path: join(path, datasetPath))
            smallest = min(smallest, array.voxelCount)
            if array.voxelCount <= voxelBudget {
                chosen = (index, array)
                break
            }
        }
        guard let picked = chosen else { throw ZarrError.tooLarge(voxels: smallest) }
        let (levelIndex, array) = picked

        let data = try await array.read()
        let axes = axisNames(multiscale["axes"], ndim: data.ndim)
        let channelAxis = axes.firstIndex(of: "c")
        let omero = attributes?["omero"] as? [String: Any]
        let channels = (omero?["channels"] as? [[String: Any]] ?? []).map(channel)
        let scale = (datasets[levelIndex]["coordinateTransformations"] as? [[String: Any]])?
            .first { $0["type"] as? String == "scale" }?["scale"] as? [Double]

        return OMEZarrImage(data: data, axes: axes, channelAxis: channelAxis, channels: channels,
                            scale: scale, level: levelIndex, levelCount: datasets.count)
    }

    /// Reads a group's attributes: `.zattrs` (v2), or `zarr.json` attributes (v3, where
    /// NGFF 0.5 nests them under "ome").
    static func groupAttributes(_ store: any ZarrStore, path: String) async throws -> [String: Any]? {
        if let data = try await store.get(join(path, ".zattrs")) {
            return try jsonObject(data)
        }
        if let data = try await store.get(join(path, "zarr.json")) {
            let json = try jsonObject(data)
            guard let attributes = json["attributes"] as? [String: Any] else { return nil }
            return attributes["ome"] as? [String: Any] ?? attributes
        }
        return nil
    }

    /// Axis names from NGFF 0.4+ objects, 0.3 strings, or the 0.1/0.2 default of TCZYX.
    static func axisNames(_ value: Any?, ndim: Int) -> [String] {
        var names: [String]?
        if let objects = value as? [[String: Any]] {
            names = objects.map { $0["name"] as? String ?? "?" }
        } else if let strings = value as? [String] {
            names = strings
        }
        if let names, names.count == ndim { return names }
        return ndim <= 5 ? Array(["t", "c", "z", "y", "x"].suffix(ndim)) : (0 ..< ndim).map(String.init)
    }

    static func channel(_ json: [String: Any]) -> OMEZarrImage.Channel {
        var color: RGBA?
        if let hex = json["color"] as? String, hex.count == 6, let value = UInt32(hex, radix: 16) {
            color = RGBA(hex: value)
        }
        var window: ClosedRange<Float>?
        if let w = json["window"] as? [String: Any],
           let start = (w["start"] as? NSNumber)?.floatValue, let end = (w["end"] as? NSNumber)?.floatValue,
           start < end {
            window = start ... end
        }
        return OMEZarrImage.Channel(label: json["label"] as? String, color: color, window: window)
    }
}
