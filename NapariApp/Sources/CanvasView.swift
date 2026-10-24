import MetalKit
import NapariCore
import SwiftUI

/// The Metal canvas, wrapped for SwiftUI.
struct CanvasView: UIViewRepresentable {
    let model: AppModel

    func makeUIView(context: Context) -> CanvasMTKView {
        CanvasMTKView(model: model)
    }

    func updateUIView(_ view: CanvasMTKView, context: Context) {}
}

/// Handles input on the canvas:
/// - one finger (or a trackpad) pans, pinch zooms, scrolling zooms;
/// - in 3D, one finger orbits and two fingers pan;
/// - with a labels, points or shapes layer in an editing mode, the Pencil (and fingers,
///   unless "Pencil only" is on) edits, and panning takes two fingers;
/// - double-tapping the Pencil switches between paint and erase.
final class CanvasMTKView: MTKView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    private let model: AppModel
    private var renderer: Renderer?
    private var panGesture: UIPanGestureRecognizer!
    /// The touch currently editing, and what it is doing.
    private var activeTouch: UITouch?
    private var drag: Drag?

    private enum Editor {
        case labels(LabelsLayer)
        case points(PointsLayer)
        case shapes(ShapesLayer)
    }

    private enum Drag {
        case stroke(LabelsLayer)
        /// `added` is true when this touch created the point, so a cancelled touch removes it.
        case point(PointsLayer, index: Int, added: Bool)
        case shapeDraft(ShapesLayer)
        /// `last` is the previous touch location, so the shape follows the finger.
        case shapeMove(ShapesLayer, index: Int, last: SIMD2<Double>)
    }

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
        sampleCount = 4 // MSAA, for smooth shape edges
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // TODO: draw on demand (when the model changes) instead of continuously.
        preferredFramesPerSecond = 60
        isMultipleTouchEnabled = true

        renderer = Renderer(model: model, view: self)
        delegate = renderer

        let fingerTypes = [UITouch.TouchType.direct, .indirectPointer].map { NSNumber(value: $0.rawValue) }

        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.allowedTouchTypes = fingerTypes
        panGesture.maximumNumberOfTouches = 2
        panGesture.delegate = self
        addGestureRecognizer(panGesture)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.allowedTouchTypes = fingerTypes
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        addGestureRecognizer(scroll)

        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:))))

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var viewSize: SIMD2<Double> {
        SIMD2(Double(bounds.width), Double(bounds.height))
    }

    private func dataPoint(_ location: CGPoint) -> SIMD2<Double> {
        model.viewer.camera.dataPoint(fromScreen: SIMD2(Double(location.x), Double(location.y)), viewSize: viewSize)
    }

    /// The layer that touches edit, if any: the selected layer, when it is in an editing mode.
    private var editor: Editor? {
        guard model.viewer.dims.ndisplay == 2,
              let layer = model.viewer.selectedLayer, layer.props.visible
        else { return nil }
        if let labels = layer as? LabelsLayer, labels.mode != .panZoom {
            return .labels(labels)
        }
        if let points = layer as? PointsLayer, points.mode != .panZoom {
            return .points(points)
        }
        if let shapes = layer as? ShapesLayer, shapes.mode != .panZoom {
            return .shapes(shapes)
        }
        return nil
    }

    private func touchEdits(_ touch: UITouch) -> Bool {
        guard editor != nil else { return false }
        return touch.type == .pencil || !model.pencilOnly
    }

    // MARK: Gestures

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gesture === panGesture {
            // While fingers edit, panning needs a second finger.
            panGesture.minimumNumberOfTouches = editor != nil && !model.pencilOnly ? 2 : 1
        }
        return true
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    private var is3D: Bool { model.viewer.dims.ndisplay == 3 }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        let delta = SIMD2(Double(translation.x), Double(translation.y))
        let camera = model.viewer.camera
        if !is3D {
            camera.pan(byScreenDelta: delta)
        } else if gesture.numberOfTouches >= 2 {
            camera.pan3D += delta
        } else {
            camera.orbit(byScreenDelta: delta)
        }
        gesture.setTranslation(.zero, in: self)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        zoom(by: Double(gesture.scale), anchor: gesture.location(in: self))
        gesture.scale = 1
    }

    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        zoom(by: exp(Double(gesture.translation(in: self).y) * 0.005), anchor: gesture.location(in: self))
        gesture.setTranslation(.zero, in: self)
    }

    private func zoom(by factor: Double, anchor: CGPoint) {
        let anchor = SIMD2(Double(anchor.x), Double(anchor.y))
        if is3D {
            model.viewer.camera.zoom3D(by: factor, anchor: anchor, viewSize: viewSize)
        } else {
            model.viewer.camera.zoom(by: factor, anchor: anchor, viewSize: viewSize)
        }
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard !is3D else { return }
        model.updateStatus(at: dataPoint(gesture.location(in: self)))
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        guard let labels = model.viewer.selectedLayer as? LabelsLayer else { return }
        labels.mode = labels.mode == .erase ? .paint : .erase
    }

    // MARK: Editing

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard activeTouch == nil, let editor, let touch = touches.first(where: touchEdits) else { return }
        let point = dataPoint(touch.preciseLocation(in: self))
        model.updateStatus(at: point)
        switch editor {
        case .labels(let labels):
            let plane = model.viewer.dims.planeIndices(forLayerShape: labels.shape)
            switch labels.mode {
            case .paint, .erase:
                activeTouch = touch
                drag = .stroke(labels)
                labels.stroke(to: point, plane: plane)
            case .fill:
                labels.fill(at: point, plane: plane)
            case .pick:
                labels.pick(at: point, plane: plane)
            case .panZoom:
                break
            }
        case .points(let points):
            let plane = model.viewer.dims.planeIndices(forLayerShape: points.shape)
            switch points.mode {
            case .add:
                let index = points.add(plane.map { Double($0) } + [point.y, point.x])
                points.selection = [index]
                activeTouch = touch
                drag = .point(points, index: index, added: true)
            case .select:
                // At least 12 points on screen, so small points stay easy to hit.
                let radius = max(points.size / 2, 12 / model.viewer.camera.zoom)
                if let index = points.nearestVisible(to: point, plane: plane, within: radius) {
                    points.selection = [index]
                    activeTouch = touch
                    drag = .point(points, index: index, added: false)
                } else {
                    points.selection = []
                }
            case .panZoom:
                break
            }
        case .shapes(let shapes):
            let plane = model.viewer.dims.planeIndices(forLayerShape: shapes.shape)
            let tolerance = 12 / model.viewer.camera.zoom
            if shapes.mode == .select {
                if let index = shapes.shapeIndex(at: point, plane: plane, tolerance: tolerance) {
                    shapes.selection = [index]
                    activeTouch = touch
                    drag = .shapeMove(shapes, index: index, last: point)
                } else {
                    shapes.selection = []
                }
            } else {
                shapes.beginDraft(at: point, plane: plane, closeDistance: tolerance)
                activeTouch = touch
                drag = .shapeDraft(shapes)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let touch = activeTouch, touches.contains(touch), let drag else { return }
        let location = dataPoint(touch.preciseLocation(in: self))
        model.updateStatus(at: location)
        switch drag {
        case .stroke(let labels):
            let plane = model.viewer.dims.planeIndices(forLayerShape: labels.shape)
            // Coalesced touches give the Pencil's full 240 Hz sample rate.
            for sample in event?.coalescedTouches(for: touch) ?? [touch] {
                labels.stroke(to: dataPoint(sample.preciseLocation(in: self)), plane: plane)
            }
        case .point(let points, let index, _):
            let plane = model.viewer.dims.planeIndices(forLayerShape: points.shape)
            points.move(index, to: plane.map { Double($0) } + [location.y, location.x])
        case .shapeDraft(let shapes):
            // Paths sample every couple of screen points, regardless of zoom.
            shapes.updateDraft(to: location, minimumSpacing: 2 / model.viewer.camera.zoom)
        case .shapeMove(let shapes, let index, let last):
            shapes.move(index, by: location - last)
            self.drag = .shapeMove(shapes, index: index, last: location)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard let touch = activeTouch, touches.contains(touch) else { return }
        switch drag {
        case .stroke(let labels)?: labels.endStroke()
        case .shapeDraft(let shapes)?: shapes.endDrag()
        default: break
        }
        activeTouch = nil
        drag = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        guard let touch = activeTouch, touches.contains(touch), let drag else { return }
        // Typically a second finger arrived and this is a pan, so undo what the first finger did.
        switch drag {
        case .stroke(let labels):
            labels.cancelStroke()
        case .point(let points, let index, let added) where added:
            points.selection = [index]
            points.removeSelected()
        case .shapeDraft(let shapes):
            shapes.cancelDraftTouch()
        case .point, .shapeMove:
            break
        }
        activeTouch = nil
        self.drag = nil
    }
}
