import Foundation
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

    // 3D: an orthographic orbit camera around the volume's centre.
    /// Rotation about the vertical axis, in radians.
    public var azimuth: Double = 0
    /// Rotation about the horizontal screen axis, in radians, within ±90°.
    public var elevation: Double = 0
    /// Screen-space offset of the volume centre from the view centre, in points.
    public var pan3D = SIMD2<Double>(0, 0)

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

    // MARK: 3D

    /// Camera axes in data (x, y, z) coordinates: `right` and `down` span the screen,
    /// `forward` points into it. With both angles zero this matches the 2D view.
    public var axes: (right: SIMD3<Double>, down: SIMD3<Double>, forward: SIMD3<Double>) {
        let (sa, ca) = (sin(azimuth), cos(azimuth))
        let (se, ce) = (sin(elevation), cos(elevation))
        return (SIMD3(ca, 0, sa), SIMD3(se * sa, ce, -se * ca), SIMD3(-ce * sa, se, ce * ca))
    }

    /// Fits a volume of `size` (x, y, z voxels) into the view at a slight angle.
    public func fit3D(size: SIMD3<Double>, viewSize: SIMD2<Double>, margin: Double = 0.9) {
        let diagonal = (size * size).sum().squareRoot()
        guard diagonal > 0, viewSize.x > 0, viewSize.y > 0 else { return }
        azimuth = -0.5
        elevation = 0.35
        pan3D = .zero
        zoom = clampZoom(min(viewSize.x, viewSize.y) / diagonal * margin)
    }

    /// Rotates by a one-finger drag: horizontal turns about the vertical axis, vertical tilts.
    public func orbit(byScreenDelta delta: SIMD2<Double>, radiansPerPoint: Double = 0.01) {
        azimuth += delta.x * radiansPerPoint
        elevation = min(max(elevation - delta.y * radiansPerPoint, -Double.pi / 2), Double.pi / 2)
    }

    /// 3D counterpart of `zoom(by:anchor:viewSize:)`, keeping the point under `anchor` fixed.
    public func zoom3D(by factor: Double, anchor: SIMD2<Double>, viewSize: SIMD2<Double>) {
        let fixed = (anchor - viewSize / 2 - pan3D) / zoom
        zoom = clampZoom(zoom * factor)
        pan3D = anchor - viewSize / 2 - fixed * zoom
    }

    private func clampZoom(_ value: Double) -> Double {
        min(max(value, Self.zoomLimits.lowerBound), Self.zoomLimits.upperBound)
    }
}
