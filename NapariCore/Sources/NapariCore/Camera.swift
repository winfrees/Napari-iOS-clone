import Observation

/// 2-D camera: maps data coordinates (x right, y down, one unit per pixel) to screen points.
///
/// Pixel (row i, column j) covers x in [j, j + 1) and y in [i, i + 1).
@Observable
public final class Camera {
    /// Data coordinate shown at the centre of the view.
    public var center = SIMD2<Double>(0, 0)
    /// Screen points per data pixel.
    public var zoom: Double = 1

    public static let zoomLimits: ClosedRange<Double> = 0.01 ... 500

    public init() {}

    public func dataPoint(fromScreen screen: SIMD2<Double>, viewSize: SIMD2<Double>) -> SIMD2<Double> {
        center + (screen - viewSize / 2) / zoom
    }

    public func screenPoint(fromData data: SIMD2<Double>, viewSize: SIMD2<Double>) -> SIMD2<Double> {
        (data - center) * zoom + viewSize / 2
    }

    /// Centers on and fits a `width` x `height` data extent into the view.
    public func fit(width: Double, height: Double, viewSize: SIMD2<Double>, margin: Double = 0.95) {
        guard width > 0, height > 0, viewSize.x > 0, viewSize.y > 0 else { return }
        center = SIMD2(width / 2, height / 2)
        zoom = clampZoom(min(viewSize.x / width, viewSize.y / height) * margin)
    }

    public func pan(byScreenDelta delta: SIMD2<Double>) {
        center -= delta / zoom
    }

    /// Scales the zoom by `factor`, keeping the data point under `anchor` fixed on screen.
    public func zoom(by factor: Double, anchor: SIMD2<Double>, viewSize: SIMD2<Double>) {
        let fixed = dataPoint(fromScreen: anchor, viewSize: viewSize)
        zoom = clampZoom(zoom * factor)
        center = fixed - (anchor - viewSize / 2) / zoom
    }

    private func clampZoom(_ value: Double) -> Double {
        min(max(value, Self.zoomLimits.lowerBound), Self.zoomLimits.upperBound)
    }
}
