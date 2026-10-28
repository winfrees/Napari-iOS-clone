import Observation

/// Which slice of the data is shown: one index per non-displayed axis.
///
/// As in napari, the viewer's dimensionality is the largest layer's, and layers
/// with fewer axes are aligned to the right (their last axes match the viewer's).
@Observable
public final class Dims {
    public private(set) var ndim: Int = 2
    /// Number of steps along each axis.
    public private(set) var range: [Int] = [1, 1]
    /// Current index along each axis. Entries for the displayed axes are unused.
    public private(set) var point: [Int] = [0, 0]
    public private(set) var axisLabels: [String] = ["0", "1"]
    /// Number of displayed axes: 2 for a plane, 3 for a volume. Always the last axes.
    public private(set) var ndisplay = 2

    public init() {}

    /// Axes that get a slider: everything except the displayed axes,
    /// skipping axes with a single step.
    public var sliderAxes: [Int] {
        (0 ..< max(0, ndim - ndisplay)).filter { range[$0] > 1 }
    }

    /// 3D needs at least three axes; requests for it are ignored otherwise.
    public func setNDisplay(_ value: Int) {
        ndisplay = value == 3 && ndim >= 3 ? 3 : 2
    }

    public func update(range newRange: [Int]) {
        let newNdim = max(2, newRange.count)
        let padded = Array(repeating: 1, count: newNdim - newRange.count) + newRange
        // Keep the current position on axes that still exist, aligned from the right.
        var newPoint = Array(repeating: 0, count: newNdim)
        for k in 0 ..< min(ndim, newNdim) {
            let old = point[ndim - 1 - k]
            newPoint[newNdim - 1 - k] = min(max(old, 0), padded[newNdim - 1 - k] - 1)
        }
        ndim = newNdim
        range = padded
        point = newPoint
        axisLabels = (0 ..< newNdim).map(String.init)
        if ndim < 3 { ndisplay = 2 }
    }

    public func setPoint(axis: Int, to value: Int) {
        guard point.indices.contains(axis) else { return }
        point[axis] = min(max(value, 0), range[axis] - 1)
    }

    /// The leading indices selecting the visible plane of a layer with the given shape.
    public func planeIndices(forLayerShape shape: [Int]) -> [Int] {
        leadingIndices(forLayerShape: shape, displayed: 2)
    }

    /// The leading indices selecting the visible volume of a layer with at least three axes.
    public func volumeIndices(forLayerShape shape: [Int]) -> [Int] {
        leadingIndices(forLayerShape: shape, displayed: 3)
    }

    private func leadingIndices(forLayerShape shape: [Int], displayed: Int) -> [Int] {
        let offset = ndim - shape.count
        return (0 ..< max(0, shape.count - displayed)).map { axis in
            let viewerAxis = axis + offset
            let value = viewerAxis >= 0 && viewerAxis < point.count ? point[viewerAxis] : 0
            return min(max(value, 0), shape[axis] - 1)
        }
    }
}
