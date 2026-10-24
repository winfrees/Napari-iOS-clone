import MetalKit
import NapariCore
import os

/// Must match `LayerUniforms` in Shaders.metal.
struct LayerUniforms {
    var scale: SIMD2<Float>
    var offset: SIMD2<Float>
    var size: SIMD2<Float>
    var climLow: Float = 0
    var climHigh: Float = 1
    var gamma: Float = 1
    var opacity: Float = 1
}

/// Draws the visible plane of every layer, bottom to top, as one textured quad each.
///
/// Each layer's current plane lives in a texture that is re-uploaded only when the
/// slice or the layer's data changes. Colormaps are 256-entry lookup textures.
final class Renderer: NSObject, MTKViewDelegate {
    private struct Slice: Equatable {
        var leading: [Int]
        var version: Int
    }

    private struct LayerTextures {
        var plane: MTLTexture
        var slice: Slice
        var lut: MTLTexture?
        var colormap: Colormap?
    }

    private let model: AppModel
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let imagePipelines: [Blending: MTLRenderPipelineState]
    private let labelsPipelines: [Blending: MTLRenderPipelineState]
    private let nearestSampler: MTLSamplerState
    private let linearSampler: MTLSamplerState
    private var textures: [UUID: LayerTextures] = [:]
    private let log = Logger(subsystem: "org.napari.ios", category: "Renderer")

    init?(model: AppModel, view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary()
        else { return nil }
        self.model = model
        self.device = device
        self.queue = queue

        func pipelines(fragment: String) -> [Blending: MTLRenderPipelineState] {
            var result: [Blending: MTLRenderPipelineState] = [:]
            for blending in Blending.allCases {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "quad_vertex")
                descriptor.fragmentFunction = library.makeFunction(name: fragment)
                let attachment = descriptor.colorAttachments[0]!
                attachment.pixelFormat = view.colorPixelFormat
                // Shaders output premultiplied alpha.
                switch blending {
                case .translucent:
                    attachment.isBlendingEnabled = true
                    attachment.sourceRGBBlendFactor = .one
                    attachment.sourceAlphaBlendFactor = .one
                    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                case .additive:
                    attachment.isBlendingEnabled = true
                    attachment.sourceRGBBlendFactor = .one
                    attachment.sourceAlphaBlendFactor = .one
                    attachment.destinationRGBBlendFactor = .one
                    attachment.destinationAlphaBlendFactor = .one
                case .opaque:
                    attachment.isBlendingEnabled = false
                }
                result[blending] = try? device.makeRenderPipelineState(descriptor: descriptor)
            }
            return result
        }
        imagePipelines = pipelines(fragment: "image_fragment")
        labelsPipelines = pipelines(fragment: "labels_fragment")
        guard imagePipelines.count == Blending.allCases.count,
              labelsPipelines.count == Blending.allCases.count
        else { return nil }

        func sampler(_ filter: MTLSamplerMinMagFilter) -> MTLSamplerState? {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = filter
            descriptor.magFilter = filter
            descriptor.sAddressMode = .clampToEdge
            descriptor.tAddressMode = .clampToEdge
            return device.makeSamplerState(descriptor: descriptor)
        }
        guard let nearest = sampler(.nearest), let linear = sampler(.linear) else { return nil }
        nearestSampler = nearest
        // Not every iOS GPU can filter 32-bit float textures; fall back to nearest there.
        linearSampler = device.supports32BitFloatFiltering ? linear : nearest
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let viewer = model.viewer
        let viewSize = SIMD2<Double>(Double(view.bounds.width), Double(view.bounds.height))
        guard viewSize.x > 0, viewSize.y > 0 else { return }

        if model.needsResetView, !viewer.layers.isEmpty {
            let extent = viewer.planeExtent
            viewer.camera.fit(width: Double(extent.width), height: Double(extent.height), viewSize: viewSize)
            model.needsResetView = false
        }

        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        // Data (x, y) -> clip space, with y pointing down on screen.
        let camera = viewer.camera
        let scale = SIMD2(2 * camera.zoom / viewSize.x, -2 * camera.zoom / viewSize.y)
        let offset = -camera.center * scale

        let liveIDs = Set(viewer.layers.map(\.id))
        textures = textures.filter { liveIDs.contains($0.key) }

        for layer in viewer.layers where layer.props.visible && layer.props.opacity > 0 {
            let leading = viewer.dims.planeIndices(forLayerShape: layer.shape)
            var uniforms = LayerUniforms(
                scale: SIMD2<Float>(scale),
                offset: SIMD2<Float>(offset),
                size: SIMD2(Float(layer.shape[layer.ndim - 1]), Float(layer.shape[layer.ndim - 2])),
                opacity: layer.props.opacity
            )

            if let image = layer as? ImageLayer {
                guard let entry = prepare(image, leading: leading),
                      let pipeline = imagePipelines[image.props.blending]
                else { continue }
                uniforms.climLow = image.contrastLimits.lowerBound
                uniforms.climHigh = image.contrastLimits.upperBound
                uniforms.gamma = image.gamma
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(entry.plane, index: 0)
                encoder.setFragmentTexture(entry.lut, index: 1)
                encoder.setFragmentSamplerState(image.interpolation == .linear ? linearSampler : nearestSampler, index: 0)
            } else if let labels = layer as? LabelsLayer {
                guard let entry = prepare(labels, leading: leading),
                      let pipeline = labelsPipelines[labels.props.blending]
                else { continue }
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(entry.plane, index: 0)
            } else {
                continue
            }
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    // MARK: Textures

    private func prepare(_ image: ImageLayer, leading: [Int]) -> LayerTextures? {
        guard var entry = planeTexture(for: image, data: image.data, format: .r32Float, leading: leading) else {
            return nil
        }
        if entry.colormap != image.colormap || entry.lut == nil {
            let bytes = image.colormap.lutBytes(size: 256)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: 256, height: 1, mipmapped: false)
            descriptor.usage = .shaderRead
            guard let lut = device.makeTexture(descriptor: descriptor) else { return nil }
            bytes.withUnsafeBytes { buffer in
                lut.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0,
                            withBytes: buffer.baseAddress!, bytesPerRow: 256 * 4)
            }
            entry.lut = lut
            entry.colormap = image.colormap
            textures[image.id] = entry
        }
        return entry
    }

    private func prepare(_ labels: LabelsLayer, leading: [Int]) -> LayerTextures? {
        planeTexture(for: labels, data: labels.data, format: .r32Uint, leading: leading)
    }

    /// Returns the layer's plane texture, (re)creating or re-uploading it when the slice or data changed.
    private func planeTexture<Element>(
        for layer: any Layer, data: NDArray<Element>, format: MTLPixelFormat, leading: [Int]
    ) -> LayerTextures? {
        let slice = Slice(leading: leading, version: layer.dataVersion)
        if let entry = textures[layer.id], entry.slice == slice {
            return entry
        }
        let width = data.planeWidth
        let height = data.planeHeight
        // TODO: tile planes larger than the GPU's maximum texture size (16384 on current iPads).
        guard width <= 16384, height <= 16384 else {
            log.error("Plane \(width)x\(height) of \(layer.name, privacy: .public) is too large to display")
            return nil
        }

        var entry = textures[layer.id]
        if entry == nil || entry!.plane.width != width || entry!.plane.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            entry = LayerTextures(plane: texture, slice: slice, lut: entry?.lut, colormap: entry?.colormap)
        }
        // TODO: while painting, upload only the region that changed rather than the whole plane.
        data.plane(at: leading).withUnsafeBytes { buffer in
            entry!.plane.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                 withBytes: buffer.baseAddress!, bytesPerRow: width * MemoryLayout<Element>.stride)
        }
        entry!.slice = slice
        textures[layer.id] = entry
        return entry
    }
}
