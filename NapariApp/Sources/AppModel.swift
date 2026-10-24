import Foundation
import NapariCore
import Observation
import UniformTypeIdentifiers

/// App-level state around the core `Viewer`: file import/export, status text and input settings.
@Observable
final class AppModel {
    enum ImportTarget {
        case image
        case labels
        case points
        case shapes
        case zarr

        var contentTypes: [UTType] {
            switch self {
            case .image, .labels: return [.tiff]
            case .points, .shapes: return [.commaSeparatedText]
            case .zarr: return [.folder]
            }
        }
    }

    let viewer = Viewer()
    /// Fit the camera to the data on the next frame (set when the first layer arrives).
    var needsResetView = true
    /// Only the Apple Pencil paints; fingers always pan and zoom.
    var pencilOnly = false
    /// Coordinates and value under the pointer, like napari's status bar.
    var status = ""
    var errorMessage: String?
    var isLoading = false

    var importTarget: ImportTarget?
    var isShowingURLPrompt = false
    var urlText = ""
    var exportDocument: ExportDocument?

    func loadSampleBlobs() {
        add { $0.addImage(SampleData.blobs(), name: "blobs") }
    }

    func addEmptyLabels() {
        viewer.addEmptyLabels()
    }

    func addEmptyPoints() {
        viewer.addEmptyPoints()
    }

    func addEmptyShapes() {
        viewer.addEmptyShapes()
    }

    func toggle3D() {
        viewer.dims.setNDisplay(viewer.dims.ndisplay == 3 ? 2 : 3)
        status = viewer.dims.ndisplay == 3 ? "3D: drag to rotate, two fingers to pan" : ""
        needsResetView = true
    }

    func open(_ urls: [URL], as target: ImportTarget) {
        if target == .points || target == .shapes {
            for url in urls { openCSV(url, as: target) }
            return
        }
        if target == .zarr {
            for url in urls {
                openZarr(DirectoryStore(root: url), name: url.deletingPathExtension().lastPathComponent, scopedURL: url)
            }
            return
        }
        isLoading = true
        Task { @MainActor [self] in
            for url in urls {
                let name = url.deletingPathExtension().lastPathComponent
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                        return try TIFFReader.read(contentsOf: url)
                    }.value
                    if target == .labels {
                        let labels = LabelsLayer(data: data.map(Self.labelValue), name: name)
                        add { $0.add(labels) }
                    } else {
                        add { $0.addImage(data, name: name) }
                    }
                } catch {
                    errorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            isLoading = false
        }
    }

    func openZarrURL() {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme == "https" || url.scheme == "http" else {
            errorMessage = "Enter an http:// or https:// URL of an OME-Zarr image."
            return
        }
        openZarr(HTTPStore(root: url), name: url.deletingPathExtension().lastPathComponent)
    }

    /// Loads an OME-Zarr image in the background. `scopedURL` is a folder picked in Files,
    /// which needs security-scoped access for as long as chunks are being read.
    func openZarr(_ store: any ZarrStore, name: String, scopedURL: URL? = nil) {
        isLoading = true
        Task { @MainActor [self] in
            defer { isLoading = false }
            do {
                let image = try await Task.detached(priority: .userInitiated) {
                    let accessing = scopedURL?.startAccessingSecurityScopedResource() ?? false
                    defer { if accessing { scopedURL?.stopAccessingSecurityScopedResource() } }
                    return try await OMEZarr.open(store)
                }.value
                addOMEZarr(image, name: name)
            } catch {
                errorMessage = "Could not open \(name): \(error.localizedDescription)"
            }
        }
    }

    /// One additive layer per channel, colored and windowed from the file's omero metadata.
    private func addOMEZarr(_ image: OMEZarrImage, name: String) {
        add { viewer in
            guard let channelAxis = image.channelAxis, channelAxis < image.data.ndim - 2 else {
                viewer.addImage(image.data, name: name)
                return
            }
            let layers = viewer.addImageChannels(image.data, channelAxis: channelAxis, name: name)
            for (layer, channel) in zip(layers, image.channels) {
                if let label = channel.label, !label.isEmpty {
                    layer.props.name = label
                }
                if let color = channel.color {
                    layer.colormap = Colormap.ramp(channel.label ?? "channel", color)
                }
                if let window = channel.window {
                    let low = max(window.lowerBound, layer.dataRange.lowerBound)
                    let high = min(window.upperBound, layer.dataRange.upperBound)
                    if low < high { layer.contrastLimits = low ... high }
                }
            }
        }
        if image.level > 0 {
            status = "Loaded resolution level \(image.level) of \(image.levelCount) to fit in memory"
        }
    }

    var canExportSelectedLayer: Bool {
        viewer.selectedLayer is LabelsLayer || viewer.selectedLayer is PointsLayer
            || viewer.selectedLayer is ShapesLayer
    }

    /// Labels export as a TIFF, points and shapes as napari-style CSVs.
    func exportSelectedLayer() {
        if let labels = viewer.selectedLayer as? LabelsLayer {
            exportDocument = ExportDocument(data: TIFFWriter.data(for: labels.data), filename: labels.name,
                                            contentType: .tiff)
        } else if let points = viewer.selectedLayer as? PointsLayer {
            exportDocument = ExportDocument(data: Data(points.csv().utf8), filename: points.name,
                                            contentType: .commaSeparatedText)
        } else if let shapes = viewer.selectedLayer as? ShapesLayer {
            exportDocument = ExportDocument(data: Data(shapes.csv().utf8), filename: shapes.name,
                                            contentType: .commaSeparatedText)
        }
    }

    /// Reads a napari points or shapes CSV into a new layer.
    private func openCSV(_ url: URL, as target: ImportTarget) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let name = url.deletingPathExtension().lastPathComponent
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            // Every coordinate, in (…, y, x) order, to size the layer.
            let coordinates: [[Double]]
            var shapes: [VectorShape] = []
            if target == .shapes {
                shapes = try ShapesLayer.parseCSV(text)
                coordinates = shapes.flatMap { shape in shape.vertices.map { shape.leading + [$0.y, $0.x] } }
            } else {
                coordinates = try PointsLayer.parseCSV(text)
            }
            guard let ndim = coordinates.first?.count else {
                errorMessage = "\(url.lastPathComponent) contains no data."
                return
            }
            let extent = layerExtent(ndim: ndim, coordinates: coordinates)
            if target == .shapes {
                add { $0.add(ShapesLayer(extent: extent, shapes: shapes, name: name)) }
            } else {
                add { $0.add(PointsLayer(extent: extent, points: coordinates, name: name)) }
            }
        } catch {
            errorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func updateStatus(at point: SIMD2<Double>) {
        guard let layer = viewer.selectedLayer ?? viewer.layers.last else {
            status = ""
            return
        }
        let leading = viewer.dims.planeIndices(forLayerShape: layer.shape)
        let row = Int(point.y.rounded(.down))
        let col = Int(point.x.rounded(.down))
        let position = (leading + [row, col]).map(String.init).joined(separator: ", ")
        var text = "\(layer.name) [\(position)]"
        let height = layer.shape[layer.ndim - 2]
        let width = layer.shape[layer.ndim - 1]
        if (0 ..< height).contains(row), (0 ..< width).contains(col) {
            if let image = layer as? ImageLayer {
                let value = image.data.storage[image.data.planeOffset(leading) + row * width + col]
                text += ": " + String(format: "%.4g", value)
            } else if let labels = layer as? LabelsLayer,
                      let value = labels.value(at: point, plane: leading) {
                text += ": \(value)"
            }
        }
        status = text
    }

    /// The extent for imported annotations: the layer being annotated when the dimensions
    /// match, else just large enough for the coordinates.
    private func layerExtent(ndim: Int, coordinates: [[Double]]) -> [Int] {
        if let reference = viewer.selectedLayer ?? viewer.layers.first, reference.ndim == ndim {
            return reference.shape
        }
        return (0 ..< ndim).map { axis in
            max(1, Int((coordinates.map { $0[axis] }.max() ?? 0).rounded(.up)) + 1)
        }
    }

    private static func labelValue(_ value: Float) -> UInt32 {
        value.isFinite ? UInt32(min(max(value, 0), Float(UInt32.max - 255))) : 0
    }

    private func add(_ addLayer: (Viewer) -> Void) {
        let wasEmpty = viewer.layers.isEmpty
        addLayer(viewer)
        if wasEmpty { needsResetView = true }
    }
}
