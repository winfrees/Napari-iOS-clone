import Foundation
import Observation

public enum LabelsMode: String, CaseIterable, Identifiable, Sendable {
    case panZoom = "pan/zoom"
    case paint
    case erase
    case fill
    case pick

    public var id: String { rawValue }
}

/// An integer segmentation, painted by hand. Label 0 is background and transparent.
@Observable
public final class LabelsLayer: Layer {
    /// One undoable action: the pixels it touched with their values before and after.
    struct Edit {
        var offsets: [Int]
        var old: [UInt32]
        var new: [UInt32]
    }

    public let id = UUID()
    public let props: LayerProperties
    // Edited in place pixel by pixel; observers watch `dataVersion` instead.
    @ObservationIgnored public private(set) var data: NDArray<UInt32>
    public private(set) var dataVersion = 0

    public var mode: LabelsMode = .paint
    public var selectedLabel: UInt32 = 1
    /// Brush diameter in data pixels.
    public var brushSize: Double = 10
    /// Fill only the connected region (true) or every matching pixel in the plane (false).
    public var contiguousFill = true

    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []
    @ObservationIgnored private var pending: [Int: UInt32] = [:]
    @ObservationIgnored private var lastStrokePoint: SIMD2<Double>?

    public var shape: [Int] { data.shape }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public init(data: NDArray<UInt32>, name: String) {
        precondition(data.ndim >= 2, "labels layers need at least two dimensions")
        self.data = data
        self.props = LayerProperties(name: name, opacity: 0.7, blending: .translucent)
    }

    public convenience init(shape: [Int], name: String) {
        self.init(data: NDArray(shape: shape, repeating: 0), name: name)
    }

    /// Display color for a label. Mirrored by `labelColor` in Shaders.metal.
    public static func color(for label: UInt32) -> RGBA {
        guard label != 0 else { return RGBA(0, 0, 0, 0) }
        let hue = Float(label) * 0.618034
        return RGBA.hsv(hue - hue.rounded(.down), 0.75, 1)
    }

    public var largestLabel: UInt32 { data.storage.max() ?? 0 }

    // MARK: Painting

    /// Paints (or erases, in erase mode) a brush stroke through `point` on the given plane.
    /// Consecutive calls between `endStroke()`s are joined by a line and undone together.
    public func stroke(to point: SIMD2<Double>, plane leading: [Int]) {
        let value: UInt32 = mode == .erase ? 0 : selectedLabel
        let radius = max(brushSize, 1) / 2
        let start = lastStrokePoint ?? point
        let distance = ((point - start) * (point - start)).sum().squareRoot()
        let steps = max(1, Int((distance / max(radius / 2, 0.5)).rounded(.up)))
        let base = data.planeOffset(leading)
        for step in 0 ... steps {
            let t = Double(step) / Double(steps)
            dab(at: start + (point - start) * t, radius: radius, value: value, planeBase: base)
        }
        lastStrokePoint = point
        dataVersion += 1
    }

    public func endStroke() {
        lastStrokePoint = nil
        commitPending()
    }

    /// Reverts the stroke in progress without adding it to the undo history,
    /// e.g. when a painting finger turns out to be the start of a two-finger pan.
    public func cancelStroke() {
        lastStrokePoint = nil
        guard !pending.isEmpty else { return }
        for (offset, old) in pending { data.storage[offset] = old }
        pending.removeAll()
        dataVersion += 1
    }

    /// Flood-fills the region under `point` with the selected label.
    public func fill(at point: SIMD2<Double>, plane leading: [Int]) {
        guard let seed = pixel(at: point) else { return }
        let width = data.planeWidth
        let height = data.planeHeight
        let base = data.planeOffset(leading)
        let target = data.storage[base + seed.row * width + seed.col]
        let value = selectedLabel
        guard target != value else { return }

        if contiguousFill {
            var stack = [(seed.row, seed.col)]
            while let next = stack.popLast() {
                let (row, col) = next
                let offset = base + row * width + col
                guard data.storage[offset] == target else { continue }
                set(offset, value)
                if row > 0 { stack.append((row - 1, col)) }
                if row < height - 1 { stack.append((row + 1, col)) }
                if col > 0 { stack.append((row, col - 1)) }
                if col < width - 1 { stack.append((row, col + 1)) }
            }
        } else {
            for offset in base ..< base + data.planeCount where data.storage[offset] == target {
                set(offset, value)
            }
        }
        dataVersion += 1
        commitPending()
    }

    /// Selects the label under `point`.
    public func pick(at point: SIMD2<Double>, plane leading: [Int]) {
        guard let p = pixel(at: point) else { return }
        selectedLabel = data.storage[data.planeOffset(leading) + p.row * data.planeWidth + p.col]
    }

    public func value(at point: SIMD2<Double>, plane leading: [Int]) -> UInt32? {
        guard let p = pixel(at: point) else { return nil }
        return data.storage[data.planeOffset(leading) + p.row * data.planeWidth + p.col]
    }

    // MARK: Undo

    public func undo() {
        guard let edit = undoStack.popLast() else { return }
        for (offset, old) in zip(edit.offsets, edit.old) { data.storage[offset] = old }
        redoStack.append(edit)
        dataVersion += 1
    }

    public func redo() {
        guard let edit = redoStack.popLast() else { return }
        for (offset, new) in zip(edit.offsets, edit.new) { data.storage[offset] = new }
        undoStack.append(edit)
        dataVersion += 1
    }

    // MARK: Private

    private func pixel(at point: SIMD2<Double>) -> (row: Int, col: Int)? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let col = Int(point.x.rounded(.down))
        let row = Int(point.y.rounded(.down))
        guard row >= 0, row < data.planeHeight, col >= 0, col < data.planeWidth else { return nil }
        return (row, col)
    }

    private func dab(at center: SIMD2<Double>, radius: Double, value: UInt32, planeBase: Int) {
        let width = data.planeWidth
        let height = data.planeHeight
        guard center.x.isFinite, center.y.isFinite else { return }
        let rowLo = max(0, Int((center.y - radius).rounded(.down)))
        let rowHi = min(height - 1, Int((center.y + radius).rounded(.down)))
        let colLo = max(0, Int((center.x - radius).rounded(.down)))
        let colHi = min(width - 1, Int((center.x + radius).rounded(.down)))
        guard rowLo <= rowHi, colLo <= colHi else { return }
        let r2 = radius * radius
        for row in rowLo ... rowHi {
            let dy = Double(row) + 0.5 - center.y
            for col in colLo ... colHi {
                let dx = Double(col) + 0.5 - center.x
                if dx * dx + dy * dy <= r2 {
                    set(planeBase + row * width + col, value)
                }
            }
        }
        // Always paint the pixel under the brush centre, so tiny brushes still mark something.
        if let p = pixel(at: center) {
            set(planeBase + p.row * width + p.col, value)
        }
    }

    private func set(_ offset: Int, _ value: UInt32) {
        let old = data.storage[offset]
        guard old != value else { return }
        if pending[offset] == nil { pending[offset] = old }
        data.storage[offset] = value
    }

    private func commitPending() {
        guard !pending.isEmpty else { return }
        let offsets = pending.keys.sorted()
        undoStack.append(Edit(
            offsets: offsets,
            old: offsets.map { pending[$0]! },
            new: offsets.map { data.storage[$0] }
        ))
        redoStack.removeAll()
        pending.removeAll()
    }
}
