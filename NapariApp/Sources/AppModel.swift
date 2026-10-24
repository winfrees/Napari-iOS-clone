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

        var contentTypes: [UTType] {
            self == .points ? [.commaSeparatedText] : [.tiff]
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

    func toggle3D() {
        viewer.dims.setNDisplay(viewer.dims.ndisplay == 3 ? 2 : 3)
        status = viewer.dims.ndisplay == 3 ? "3D: drag to rotate, two fingers to pan" : ""
        needsResetView = true
    }

    func open(_ urls: [URL], as target: ImportTarget) {
        if target == .points {
            urls.forEach(openPoints)
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

    var canExportSelectedLayer: Bool {
        viewer.selectedLayer is LabelsLayer || viewer.selectedLayer is PointsLayer
    }

    /// Labels export as a TIFF, points as a napari-style CSV.
    func exportSelectedLayer() {
        if let labels = viewer.selectedLayer as? LabelsLayer {
            exportDocument = ExportDocument(data: TIFFWriter.data(for: labels.data), filename: labels.name,
                                            contentType: .tiff)
        } else if let points = viewer.selectedLayer as? PointsLayer {
            exportDocument = ExportDocument(data: Data(points.csv().utf8), filename: points.name,
                                            contentType: .commaSeparatedText)
        }
    }

    private func openPoints(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let coordinates = try PointsLayer.parseCSV(String(contentsOf: url, encoding: .utf8))
            guard let ndim = coordinates.first?.count else {
                errorMessage = "\(url.lastPathComponent) contains no points."
                return
            }
            // Span the layer being annotated when the dimensions match, else the points themselves.
            let extent: [Int]
            if let reference = viewer.selectedLayer ?? viewer.layers.first, reference.ndim == ndim {
                extent = reference.shape
            } else {
                extent = (0 ..< ndim).map { axis in
                    max(1, Int((coordinates.map { $0[axis] }.max() ?? 0).rounded(.up)) + 1)
                }
            }
            let name = url.deletingPathExtension().lastPathComponent
            add { $0.add(PointsLayer(extent: extent, points: coordinates, name: name)) }
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

    private static func labelValue(_ value: Float) -> UInt32 {
        value.isFinite ? UInt32(min(max(value, 0), Float(UInt32.max - 255))) : 0
    }

    private func add(_ addLayer: (Viewer) -> Void) {
        let wasEmpty = viewer.layers.isEmpty
        addLayer(viewer)
        if wasEmpty { needsResetView = true }
    }
}
