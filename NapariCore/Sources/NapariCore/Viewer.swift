import Foundation
import Observation

/// The model behind one viewer window: its layers, the current slice and the camera.
/// Mirrors `napari.Viewer`, minus the Qt window.
@Observable
public final class Viewer {
    /// Bottom to top: the last layer is drawn over the others.
    public private(set) var layers: [any Layer] = []
    public var selectedLayerID: UUID?
    public let dims = Dims()
    public let camera = Camera()

    public init() {}

    public var selectedLayer: (any Layer)? {
        layers.first { $0.id == selectedLayerID }
    }

    /// Height and width covered by all layers' displayed planes.
    public var planeExtent: (height: Int, width: Int) {
        var height = 0
        var width = 0
        for layer in layers {
            height = max(height, layer.shape[layer.ndim - 2])
            width = max(width, layer.shape[layer.ndim - 1])
        }
        return (height, width)
    }

    /// Width, height and depth (x, y, z) covered by all layers with at least three axes.
    public var volumeExtent: SIMD3<Double> {
        var extent = SIMD3<Double>(0, 0, 0)
        for layer in layers where layer.ndim >= 3 {
            let shape = layer.shape
            extent = pointwiseMax(extent, SIMD3(Double(shape[shape.count - 1]), Double(shape[shape.count - 2]),
                                                Double(shape[shape.count - 3])))
        }
        return extent
    }

    // MARK: Adding and removing layers

    @discardableResult
    public func add<L: Layer>(_ layer: L) -> L {
        layer.props.name = uniqueName(layer.props.name)
        layers.append(layer)
        selectedLayerID = layer.id
        refreshDims()
        return layer
    }

    @discardableResult
    public func addImage(
        _ data: NDArray<Float>,
        name: String = "Image",
        colormap: Colormap = .gray,
        blending: Blending = .translucent
    ) -> ImageLayer {
        add(ImageLayer(data: data, name: name, colormap: colormap, blending: blending))
    }

    /// Splits `data` along `channelAxis` into one additive image layer per channel,
    /// like `viewer.add_image(data, channel_axis=...)`.
    @discardableResult
    public func addImageChannels(_ data: NDArray<Float>, channelAxis: Int, name: String = "Image") -> [ImageLayer] {
        precondition(data.ndim >= 3 && channelAxis < data.ndim - 2, "the channel axis must not be a displayed axis")
        let channels = data.shape[channelAxis]
        var shape = data.shape
        shape.remove(at: channelAxis)
        let outer = data.shape[..<channelAxis].reduce(1, *)
        let inner = data.strides[channelAxis]
        return (0 ..< channels).map { c in
            var storage = [Float]()
            storage.reserveCapacity(outer * inner)
            for o in 0 ..< outer {
                let start = o * channels * inner + c * inner
                storage.append(contentsOf: data.storage[start ..< start + inner])
            }
            let colormap = Colormap.channelCycle[c % Colormap.channelCycle.count]
            return addImage(NDArray(shape: shape, storage: storage), name: "\(name) [\(c)]",
                            colormap: colormap, blending: .additive)
        }
    }

    /// Adds an empty labels layer the size of the selected (or first) layer.
    @discardableResult
    public func addEmptyLabels(name: String = "Labels") -> LabelsLayer? {
        guard let reference = selectedLayer ?? layers.first else { return nil }
        return add(LabelsLayer(shape: reference.shape, name: name))
    }

    /// Adds an empty points layer spanning the selected (or first) layer.
    @discardableResult
    public func addEmptyPoints(name: String = "Points") -> PointsLayer? {
        guard let reference = selectedLayer ?? layers.first else { return nil }
        return add(PointsLayer(extent: reference.shape, name: name))
    }

    /// Adds an empty shapes layer spanning the selected (or first) layer.
    @discardableResult
    public func addEmptyShapes(name: String = "Shapes") -> ShapesLayer? {
        guard let reference = selectedLayer ?? layers.first else { return nil }
        return add(ShapesLayer(extent: reference.shape, name: name))
    }

    public func removeLayer(id: UUID) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        layers.remove(at: index)
        if selectedLayerID == id {
            selectedLayerID = layers.isEmpty ? nil : layers[min(index, layers.count - 1)].id
        }
        refreshDims()
    }

    /// Reorders layers to match `ids` (bottom to top). Unknown ids are ignored and
    /// layers missing from `ids` keep their place at the end.
    public func reorderLayers(_ ids: [UUID]) {
        var remaining = layers
        var reordered: [any Layer] = []
        for id in ids {
            if let index = remaining.firstIndex(where: { $0.id == id }) {
                reordered.append(remaining.remove(at: index))
            }
        }
        layers = reordered + remaining
    }

    // MARK: Helpers

    func refreshDims() {
        let ndim = layers.map(\.ndim).max() ?? 2
        var range = Array(repeating: 1, count: ndim)
        for layer in layers {
            let offset = ndim - layer.ndim
            for (axis, size) in layer.shape.enumerated() {
                range[axis + offset] = max(range[axis + offset], size)
            }
        }
        dims.update(range: range)
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(layers.map(\.name))
        guard names.contains(base) else { return base }
        var n = 1
        while names.contains("\(base) [\(n)]") { n += 1 }
        return "\(base) [\(n)]"
    }
}
