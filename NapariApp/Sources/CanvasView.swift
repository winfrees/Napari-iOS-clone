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
/// - with a labels layer in a painting mode, the Pencil (and fingers, unless "Pencil only"
///   is on) paints, fills or picks, and panning takes two fingers;
/// - double-tapping the Pencil switches between paint and erase.
final class CanvasMTKView: MTKView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    private let model: AppModel
    private var renderer: Renderer?
    private var panGesture: UIPanGestureRecognizer!
    private var strokeTouch: UITouch?

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
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

    /// The labels layer that touches edit, if any.
    private var paintingLayer: LabelsLayer? {
        guard let labels = model.viewer.selectedLayer as? LabelsLayer,
              labels.mode != .panZoom, labels.props.visible
        else { return nil }
        return labels
    }

    private func touchPaints(_ touch: UITouch) -> Bool {
        guard paintingLayer != nil else { return false }
        return touch.type == .pencil || !model.pencilOnly
    }

    // MARK: Gestures

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gesture === panGesture {
            // While fingers paint, panning needs a second finger.
            panGesture.minimumNumberOfTouches = paintingLayer != nil && !model.pencilOnly ? 2 : 1
        }
        return true
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        model.viewer.camera.pan(byScreenDelta: SIMD2(Double(translation.x), Double(translation.y)))
        gesture.setTranslation(.zero, in: self)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        let anchor = gesture.location(in: self)
        model.viewer.camera.zoom(by: Double(gesture.scale), anchor: SIMD2(Double(anchor.x), Double(anchor.y)),
                                 viewSize: viewSize)
        gesture.scale = 1
    }

    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        let dy = Double(gesture.translation(in: self).y)
        let anchor = gesture.location(in: self)
        model.viewer.camera.zoom(by: exp(dy * 0.005), anchor: SIMD2(Double(anchor.x), Double(anchor.y)),
                                 viewSize: viewSize)
        gesture.setTranslation(.zero, in: self)
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        model.updateStatus(at: dataPoint(gesture.location(in: self)))
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        guard let labels = model.viewer.selectedLayer as? LabelsLayer else { return }
        labels.mode = labels.mode == .erase ? .paint : .erase
    }

    // MARK: Painting

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard strokeTouch == nil, let labels = paintingLayer,
              let touch = touches.first(where: touchPaints)
        else { return }
        let point = dataPoint(touch.preciseLocation(in: self))
        let plane = model.viewer.dims.planeIndices(forLayerShape: labels.shape)
        model.updateStatus(at: point)
        switch labels.mode {
        case .paint, .erase:
            strokeTouch = touch
            labels.stroke(to: point, plane: plane)
        case .fill:
            labels.fill(at: point, plane: plane)
        case .pick:
            labels.pick(at: point, plane: plane)
        case .panZoom:
            break
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let touch = strokeTouch, touches.contains(touch), let labels = paintingLayer else { return }
        let plane = model.viewer.dims.planeIndices(forLayerShape: labels.shape)
        // Coalesced touches give the Pencil's full 240 Hz sample rate.
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            labels.stroke(to: dataPoint(sample.preciseLocation(in: self)), plane: plane)
        }
        model.updateStatus(at: dataPoint(touch.preciseLocation(in: self)))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard let touch = strokeTouch, touches.contains(touch) else { return }
        strokeTouch = nil
        (model.viewer.selectedLayer as? LabelsLayer)?.endStroke()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        guard let touch = strokeTouch, touches.contains(touch) else { return }
        strokeTouch = nil
        // Typically a second finger arrived and this is a pan, not a stroke.
        (model.viewer.selectedLayer as? LabelsLayer)?.cancelStroke()
    }
}
