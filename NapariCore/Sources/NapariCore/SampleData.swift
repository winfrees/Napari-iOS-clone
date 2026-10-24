import Foundation

/// Synthetic data for trying the viewer without any files, like napari's sample data menu.
public enum SampleData {
    /// A volume of Gaussian blobs of varying size and brightness.
    public static func blobs(shape: [Int] = [32, 192, 192], count: Int = 40, seed: UInt64 = 1) -> NDArray<Float> {
        precondition(shape.count == 3, "blobs are generated as a (z, y, x) volume")
        var rng = SplitMix64(seed: seed)
        var volume = NDArray<Float>(shape: shape, repeating: 0)
        let (depth, height, width) = (shape[0], shape[1], shape[2])
        for _ in 0 ..< count {
            let cz = rng.nextDouble() * Double(depth)
            let cy = rng.nextDouble() * Double(height)
            let cx = rng.nextDouble() * Double(width)
            let sigma = 2 + rng.nextDouble() * Double(min(height, width)) / 24
            let sigmaZ = sigma * Double(depth) / Double(min(height, width)) * 2
            let amplitude = Float(0.4 + rng.nextDouble() * 0.6)
            // Only evaluate within three sigma of the centre.
            let zs = max(0, Int(cz - 3 * sigmaZ)) ..< min(depth, Int(cz + 3 * sigmaZ) + 1)
            let ys = max(0, Int(cy - 3 * sigma)) ..< min(height, Int(cy + 3 * sigma) + 1)
            let xs = max(0, Int(cx - 3 * sigma)) ..< min(width, Int(cx + 3 * sigma) + 1)
            for z in zs {
                let dz = (Double(z) - cz) / sigmaZ
                for y in ys {
                    let dy = (Double(y) - cy) / sigma
                    let rowStart = (z * height + y) * width
                    for x in xs {
                        let dx = (Double(x) - cx) / sigma
                        let value = Float(exp(-0.5 * (dx * dx + dy * dy + dz * dz)))
                        volume.storage[rowStart + x] += amplitude * value
                    }
                }
            }
        }
        // Add a little deterministic noise so the contrast controls have something to do.
        for i in volume.storage.indices {
            volume.storage[i] += Float(rng.nextDouble()) * 0.05
        }
        return volume
    }
}

/// Small deterministic random number generator, so sample data is identical on every run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextDouble() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
