import Foundation
import Observation

public enum Blending: String, CaseIterable, Identifiable, Sendable {
    /// Alpha-blend over the layers below.
    case translucent
    /// Add colors to the layers below; the usual choice for multichannel fluorescence.
    case additive
    /// Replace the layers below.
    case opaque

    public var id: String { rawValue }
}

/// Properties every layer has, shared so the UI can edit them without knowing the layer type.
@Observable
public final class LayerProperties {
    public var name: String
    public var visible = true
    public var opacity: Float = 1
    public var blending: Blending

    public init(name: String, opacity: Float = 1, blending: Blending) {
        self.name = name
        self.opacity = opacity
        self.blending = blending
    }
}

public protocol Layer: AnyObject {
    var id: UUID { get }
    var props: LayerProperties { get }
    /// Shape of the layer's data; the last two axes are displayed.
    var shape: [Int] { get }
    /// Incremented whenever the data changes, so renderers know to re-upload.
    var dataVersion: Int { get }
}

extension Layer {
    public var ndim: Int { shape.count }
    public var name: String { props.name }
}

public enum Interpolation: String, CaseIterable, Identifiable, Sendable {
    case nearest
    case linear

    public var id: String { rawValue }
}

/// A grayscale image or volume, shown through a colormap with adjustable contrast.
@Observable
public final class ImageLayer: Layer {
    public let id = UUID()
    public let props: LayerProperties
    public let data: NDArray<Float>
    public var colormap: Colormap
    public var contrastLimits: ClosedRange<Float>
    /// Full range of the data, the bounds for the contrast limit sliders.
    public let dataRange: ClosedRange<Float>
    public var gamma: Float = 1
    public var interpolation: Interpolation = .nearest
    public let dataVersion = 0

    public var shape: [Int] { data.shape }

    public init(
        data: NDArray<Float>,
        name: String,
        colormap: Colormap = .gray,
        contrastLimits: ClosedRange<Float>? = nil,
        blending: Blending = .translucent
    ) {
        precondition(data.ndim >= 2, "image layers need at least two dimensions")
        let range = data.finiteRange() ?? 0 ... 1
        let dataRange = range.lowerBound < range.upperBound ? range : range.lowerBound ... range.lowerBound + 1
        self.data = data
        self.props = LayerProperties(name: name, blending: blending)
        self.colormap = colormap
        self.dataRange = dataRange
        self.contrastLimits = contrastLimits ?? dataRange
    }

    public func resetContrastLimits() {
        contrastLimits = dataRange
    }
}
