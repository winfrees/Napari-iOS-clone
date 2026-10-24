public struct RGBA: Hashable, Sendable {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public init(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Creates an opaque color from a 0xRRGGBB literal.
    public init(hex: UInt32) {
        self.init(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255)
    }

    public static func lerp(_ a: RGBA, _ b: RGBA, _ t: Float) -> RGBA {
        RGBA(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
    }

    /// HSV to RGB with all components in 0...1. Mirrored by `hsv2rgb` in Shaders.metal.
    public static func hsv(_ h: Float, _ s: Float, _ v: Float, alpha: Float = 1) -> RGBA {
        let h6 = (h - h.rounded(.down)) * 6
        let i = Int(h6.rounded(.down)) % 6
        let f = h6 - h6.rounded(.down)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch i {
        case 0: return RGBA(v, t, p, alpha)
        case 1: return RGBA(q, v, p, alpha)
        case 2: return RGBA(p, v, t, alpha)
        case 3: return RGBA(p, q, v, alpha)
        case 4: return RGBA(t, p, v, alpha)
        default: return RGBA(v, p, q, alpha)
        }
    }
}

/// A piecewise-linear colormap, sampled into a lookup table for rendering.
public struct Colormap: Hashable, Identifiable, Sendable {
    public struct ControlPoint: Hashable, Sendable {
        public var position: Float
        public var color: RGBA

        public init(_ position: Float, _ color: RGBA) {
            self.position = position
            self.color = color
        }
    }

    public let name: String
    public let controls: [ControlPoint]

    public var id: String { name }

    public init(name: String, controls: [ControlPoint]) {
        precondition(controls.count >= 2, "a colormap needs at least two control points")
        self.name = name
        self.controls = controls.sorted { $0.position < $1.position }
    }

    /// Evenly spaced hex colors from 0 to 1.
    public init(name: String, hexStops: [UInt32]) {
        let last = Float(hexStops.count - 1)
        self.init(name: name, controls: hexStops.enumerated().map { ControlPoint(Float($0.offset) / last, RGBA(hex: $0.element)) })
    }

    /// Black to `color`, like napari's single-channel colormaps.
    public static func ramp(_ name: String, _ color: RGBA) -> Colormap {
        Colormap(name: name, controls: [ControlPoint(0, RGBA(0, 0, 0)), ControlPoint(1, color)])
    }

    public func color(at t: Float) -> RGBA {
        let t = min(max(t, 0), 1)
        if t <= controls[0].position { return controls[0].color }
        for (lo, hi) in zip(controls, controls.dropFirst()) where t <= hi.position {
            let span = hi.position - lo.position
            return span > 0 ? RGBA.lerp(lo.color, hi.color, (t - lo.position) / span) : hi.color
        }
        return controls[controls.count - 1].color
    }

    /// RGBA8 lookup table, `size` entries of 4 bytes each.
    public func lutBytes(size: Int = 256) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(size * 4)
        for i in 0..<size {
            let c = color(at: Float(i) / Float(size - 1))
            for component in [c.r, c.g, c.b, c.a] {
                bytes.append(UInt8((min(max(component, 0), 1) * 255).rounded()))
            }
        }
        return bytes
    }

    public static let gray = ramp("gray", RGBA(1, 1, 1))
    public static let red = ramp("red", RGBA(1, 0, 0))
    public static let green = ramp("green", RGBA(0, 1, 0))
    public static let blue = ramp("blue", RGBA(0, 0, 1))
    public static let cyan = ramp("cyan", RGBA(0, 1, 1))
    public static let magenta = ramp("magenta", RGBA(1, 0, 1))
    public static let yellow = ramp("yellow", RGBA(1, 1, 0))
    public static let viridis = Colormap(name: "viridis", hexStops: [
        0x440154, 0x472D7B, 0x3B528B, 0x2C728E, 0x21918C, 0x28AE80, 0x5EC962, 0xADDC30, 0xFDE725,
    ])
    public static let magma = Colormap(name: "magma", hexStops: [
        0x000004, 0x1C1044, 0x4F127B, 0x812581, 0xB5367A, 0xE55964, 0xFB8761, 0xFEC287, 0xFCFDBF,
    ])
    public static let inferno = Colormap(name: "inferno", hexStops: [
        0x000004, 0x1F0C48, 0x550F6D, 0x88226A, 0xBA3655, 0xE35933, 0xF98E09, 0xF8C932, 0xFCFFA4,
    ])

    public static let builtins: [Colormap] = [
        .gray, .viridis, .magma, .inferno, .red, .green, .blue, .cyan, .magenta, .yellow,
    ]

    /// Colormaps cycled through when several images are added, like napari's channel_axis.
    public static let channelCycle: [Colormap] = [.magenta, .green, .cyan, .yellow, .red, .blue]
}
