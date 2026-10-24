import Foundation
import NapariCore
import Observation

/// App-level state around the core `Viewer`: file import/export, status text and input settings.
@Observable
final class AppModel {
    enum ImportTarget {
        case image
        case labels
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
    var exportDocument: TIFFDocument?

    func loadSampleBlobs() {
        add { $0.addImage(SampleData.blobs(), name: "blobs") }
    }

    func addEmptyLabels() {
        viewer.addEmptyLabels()
    }

    func open(_ urls: [URL], as target: ImportTarget) {
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

    func exportSelectedLabels() {
        guard let labels = viewer.selectedLayer as? LabelsLayer else { return }
        exportDocument = TIFFDocument(data: TIFFWriter.data(for: labels.data), filename: labels.name)
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
