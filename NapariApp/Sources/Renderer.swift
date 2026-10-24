import MetalKit
import NapariCore
import os
import simd

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

/// Must match `PointInstance` in Shaders.metal.
struct PointInstance {
    var center: SIMD2<Float>
    var size: Float
    var borderWidth: Float
    var face: SIMD4<Float>
    var border: SIMD4<Float>
}

extension RGBA {
    var vector: SIMD4<Float> { SIMD4(r, g, b, a) }
}

/// Must match `VolumeUniforms` in Shaders.metal.
struct VolumeUniforms {
    var cameraToWorld: simd_float4x4
    var volumeSize: SIMD4<Float>
    var viewSize: SIMD2<Float>
    var pan: SIMD2<Float>
    var zoom: Float
    var climLow: Float
    var climHigh: Float
    var gamma: Float
    var opacity: Float
    var mode: UInt32
}

/// Draws every visible layer, bottom to top.
///
/// In 2D each layer is one textured quad of its current plane. In 3D each image layer
/// with at least three axes is ray-cast from a 3D texture across the whole view.
/// Textures are re-uploaded only when the slice or the layer's data changes.
final class Renderer: NSObject, MTKViewDelegate {
    /// Which part of a layer's data a texture holds.
    private struct TextureKey: Equatable {
        var leading: [Int]
        var version: Int
    }

    private struct CachedTexture {
        var texture: MTLTexture
        var key: TextureKey
    }

    private let model: AppModel
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let imagePipelines: [Blending: MTLRenderPipelineState]
    private let labelsPipelines: [Blending: MTLRenderPipelineState]
    private let volumePipelines: [Blending: MTLRenderPipelineState]
    private let pointsPipelines: [Blending: MTLRenderPipelineState]
    private let nearestSampler: MTLSamplerState
    private let linearSampler: MTLSamplerState
    private var planes: [UUID: CachedTexture] = [:]
    private var volumes: [UUID: CachedTexture] = [:]
    private var luts: [UUID: (colormap: Colormap, texture: MTLTexture)] = [:]
    private let log = Logger(subsystem: "org.napari.ios", category: "Renderer")

    init?(model: AppModel, view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary()
        else { return nil }
        self.model = model
        self.device = device
        self.queue = queue

        func pipelines(vertex: String, fragment: String) -> [Blending: MTLRenderPipelineState] {
            var result: [Blending: MTLRenderPipelineState] = [:]
            for blending in Blending.allCases {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: vertex)
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
        imagePipelines = pipelines(vertex: "quad_vertex", fragment: "image_fragment")
        labelsPipelines = pipelines(vertex: "quad_vertex", fragment: "labels_fragment")
        volumePipelines = pipelines(vertex: "fullscreen_vertex", fragment: "volume_fragment")
        pointsPipelines = pipelines(vertex: "points_vertex", fragment: "points_fragment")
        guard [imagePipelines, labelsPipelines, volumePipelines, pointsPipelines].allSatisfy({ $0.count == Blending.allCases.count })
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
        let is3D = viewer.dims.ndisplay == 3

        if model.needsResetView, !viewer.layers.isEmpty {
            if is3D {
                viewer.camera.fit3D(size: viewer.volumeExtent, viewSize: viewSize)
            } else {
                let extent = viewer.planeExtent
                viewer.camera.fit(width: Double(extent.width), height: Double(extent.height), viewSize: viewSize)
            }
            model.needsResetView = false
        }

        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        let liveIDs = Set(viewer.layers.map(\.id))
        planes = planes.filter { liveIDs.contains($0.key) }
        volumes = volumes.filter { liveIDs.contains($0.key) }
        luts = luts.filter { liveIDs.contains($0.key) }

        if is3D {
            drawVolumes(viewer, viewSize: viewSize, encoder: encoder)
        } else {
            drawPlanes(viewer, viewSize: viewSize, encoder: encoder)
        }

        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    // MARK: 2D

    private func drawPlanes(_ viewer: Viewer, viewSize: SIMD2<Double>, encoder: MTLRenderCommandEncoder) {
        // Data (x, y) -> clip space, with y pointing down on screen.
        let camera = viewer.camera
        let scale = SIMD2(2 * camera.zoom / viewSize.x, -2 * camera.zoom / viewSize.y)
        let offset = -camera.center * scale

        for layer in viewer.layers where layer.props.visible && layer.props.opacity > 0 {
            let leading = viewer.dims.planeIndices(forLayerShape: layer.shape)
            var uniforms = LayerUniforms(
                scale: SIMD2<Float>(scale),
                offset: SIMD2<Float>(offset),
                size: SIMD2(Float(layer.shape[layer.ndim - 1]), Float(layer.shape[layer.ndim - 2])),
                opacity: layer.props.opacity
            )

            if let image = layer as? ImageLayer {
                guard let plane = planeTexture(for: image, data: image.data, format: .r32Float, leading: leading),
                      let lut = lut(for: image),
                      let pipeline = imagePipelines[image.props.blending]
                else { continue }
                uniforms.climLow = image.contrastLimits.lowerBound
                uniforms.climHigh = image.contrastLimits.upperBound
                uniforms.gamma = image.gamma
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(plane, index: 0)
                encoder.setFragmentTexture(lut, index: 1)
                encoder.setFragmentSamplerState(image.interpolation == .linear ? linearSampler : nearestSampler, index: 0)
            } else if let labels = layer as? LabelsLayer {
                guard let plane = planeTexture(for: labels, data: labels.data, format: .r32Uint, leading: leading),
                      let pipeline = labelsPipelines[labels.props.blending]
                else { continue }
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(plane, index: 0)
            } else if let points = layer as? PointsLayer {
                drawPoints(points, leading: leading, uniforms: &uniforms, encoder: encoder)
                continue
            } else {
                continue
            }
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    private func drawPoints(_ points: PointsLayer, leading: [Int], uniforms: inout LayerUniforms,
                            encoder: MTLRenderCommandEncoder) {
        let visible = points.visibleIndices(plane: leading)
        guard !visible.isEmpty, let pipeline = pointsPipelines[points.props.blending] else { return }
        let selectedBorder = SIMD4<Float>(0.2, 0.8, 1, 1)
        var instances = visible.map { index -> PointInstance in
            let p = points.points[index]
            let selected = points.selection.contains(index)
            return PointInstance(
                center: SIMD2(Float(p[p.count - 1]), Float(p[p.count - 2])),
                size: Float(points.size),
                borderWidth: selected ? 0.35 : 0.15,
                face: points.faceColor.vector,
                border: selected ? selectedBorder : points.borderColor.vector
            )
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        let length = MemoryLayout<PointInstance>.stride * instances.count
        if length <= 4096 {
            encoder.setVertexBytes(&instances, length: length, index: 1)
        } else {
            guard let buffer = device.makeBuffer(bytes: &instances, length: length) else { return }
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
    }

    // MARK: 3D

    // TODO: render labels layers in 3D too (nearest-sampled, first-hit compositing).
    private func drawVolumes(_ viewer: Viewer, viewSize: SIMD2<Double>, encoder: MTLRenderCommandEncoder) {
        let camera = viewer.camera
        let center = viewer.volumeExtent / 2
        let (right, down, forward) = camera.axes
        func column(_ v: SIMD3<Double>, _ w: Float) -> SIMD4<Float> {
            SIMD4(Float(v.x), Float(v.y), Float(v.z), w)
        }
        let cameraToWorld = simd_float4x4(columns: (column(right, 0), column(down, 0), column(forward, 0), column(center, 1)))

        for layer in viewer.layers where layer.props.visible && layer.props.opacity > 0 && layer.ndim >= 3 {
            guard let image = layer as? ImageLayer,
                  let volume = volumeTexture(for: image, leading: viewer.dims.volumeIndices(forLayerShape: image.shape)),
                  let lut = lut(for: image),
                  let pipeline = volumePipelines[image.props.blending]
            else { continue }

            // The texture stores the data range as 0...1, so normalise the contrast limits the same way.
            let low = image.dataRange.lowerBound
            let span = image.dataRange.upperBound - low
            var uniforms = VolumeUniforms(
                cameraToWorld: cameraToWorld,
                volumeSize: SIMD4(Float(volume.width), Float(volume.height), Float(volume.depth), 0),
                viewSize: SIMD2<Float>(viewSize),
                pan: SIMD2<Float>(camera.pan3D),
                zoom: Float(camera.zoom),
                climLow: (image.contrastLimits.lowerBound - low) / span,
                climHigh: (image.contrastLimits.upperBound - low) / span,
                gamma: image.gamma,
                opacity: image.props.opacity,
                mode: Self.shaderMode(image.rendering)
            )
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(volume, index: 0)
            encoder.setFragmentTexture(lut, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VolumeUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    private static func shaderMode(_ rendering: VolumeRendering) -> UInt32 {
        switch rendering {
        case .mip: return 0
        case .minip: return 1
        case .average: return 2
        }
    }

    // MARK: Textures

    private func lut(for image: ImageLayer) -> MTLTexture? {
        if let cached = luts[image.id], cached.colormap == image.colormap {
            return cached.texture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 256, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        image.colormap.lutBytes(size: 256).withUnsafeBytes { buffer in
            texture.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0,
                            withBytes: buffer.baseAddress!, bytesPerRow: 256 * 4)
        }
        luts[image.id] = (image.colormap, texture)
        return texture
    }

    /// Returns the layer's plane texture, (re)creating or re-uploading it when the slice or data changed.
    private func planeTexture<Element>(
        for layer: any Layer, data: NDArray<Element>, format: MTLPixelFormat, leading: [Int]
    ) -> MTLTexture? {
        let key = TextureKey(leading: leading, version: layer.dataVersion)
        if let cached = planes[layer.id], cached.key == key {
            return cached.texture
        }
        let width = data.planeWidth
        let height = data.planeHeight
        // TODO: tile planes larger than the GPU's maximum texture size (16384 on current iPads).
        guard width <= 16384, height <= 16384 else {
            log.error("Plane \(width)x\(height) of \(layer.name, privacy: .public) is too large to display")
            return nil
        }

        var candidate = planes[layer.id]?.texture
        if candidate == nil || candidate!.width != width || candidate!.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = .shaderRead
            candidate = device.makeTexture(descriptor: descriptor)
        }
        guard let texture = candidate else { return nil }
        // TODO: while painting, upload only the region that changed rather than the whole plane.
        data.plane(at: leading).withUnsafeBytes { buffer in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: buffer.baseAddress!, bytesPerRow: width * MemoryLayout<Element>.stride)
        }
        planes[layer.id] = CachedTexture(texture: texture, key: key)
        return texture
    }

    /// Returns the layer's current volume as a 16-bit normalised 3D texture, which every
    /// iOS GPU can filter linearly. Values are scaled so the layer's data range maps to 0...1.
    private func volumeTexture(for image: ImageLayer, leading: [Int]) -> MTLTexture? {
        let key = TextureKey(leading: leading, version: image.dataVersion)
        if let cached = volumes[image.id], cached.key == key {
            return cached.texture
        }
        guard let shape = image.data.volumeShape else { return nil }
        let (depth, height, width) = shape
        // TODO: downsample volumes larger than the 3D texture limit instead of skipping them.
        guard width <= 2048, height <= 2048, depth <= 2048 else {
            log.error("Volume \(width)x\(height)x\(depth) of \(image.name, privacy: .public) is too large for 3D")
            return nil
        }

        let low = image.dataRange.lowerBound
        let scale = 65535 / (image.dataRange.upperBound - low)
        let normalized = image.data.volume(at: leading).map { value -> UInt16 in
            let scaled = (value - low) * scale
            return scaled.isNaN ? 0 : UInt16(min(max(scaled, 0), 65535).rounded())
        }

        var candidate = volumes[image.id]?.texture
        if candidate == nil || candidate!.width != width || candidate!.height != height || candidate!.depth != depth {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type3D
            descriptor.pixelFormat = .r16Unorm
            descriptor.width = width
            descriptor.height = height
            descriptor.depth = depth
            descriptor.usage = .shaderRead
            candidate = device.makeTexture(descriptor: descriptor)
        }
        guard let texture = candidate else { return nil }
        normalized.withUnsafeBytes { buffer in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, width, height, depth), mipmapLevel: 0, slice: 0,
                            withBytes: buffer.baseAddress!, bytesPerRow: width * 2, bytesPerImage: width * height * 2)
        }
        volumes[image.id] = CachedTexture(texture: texture, key: key)
        return texture
    }
}
