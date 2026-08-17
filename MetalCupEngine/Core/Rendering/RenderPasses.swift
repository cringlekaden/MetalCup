/// RenderPasses.swift
/// Render graph pass implementations and helpers.
/// Created by Kaden Cringle

import MetalKit

struct RenderPassBuilder {
    static func color(texture: MTLTexture?, level: Int = 0, clearColor: MTLClearColor = ClearColor.Black) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor
        pass.colorAttachments[0].level = level
        return pass
    }

    static func colorLoad(texture: MTLTexture?, level: Int = 0) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].level = level
        return pass
    }

    static func depth(texture: MTLTexture?, clearDepth: Double = 1.0) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = texture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = clearDepth
        return pass
    }

    static func colorDepth(color texture: MTLTexture?, depth: MTLTexture?, depthLoadAction: MTLLoadAction = .clear) -> MTLRenderPassDescriptor {
        let pass = RenderPassBuilder.color(texture: texture)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = depthLoadAction
        pass.depthAttachment.storeAction = .store
        return pass
    }
}

struct RenderPassHelpers {
    static func setViewport(_ encoder: MTLRenderCommandEncoder, _ size: SIMD2<Float>) {
        encoder.setViewport(MTLViewport(
            originX: 0,
            originY: 0,
            width: Double(size.x),
            height: Double(size.y),
            znear: 0,
            zfar: 1
        ))
    }

    static func textureSize(_ texture: MTLTexture) -> SIMD2<Float> {
        SIMD2<Float>(Float(texture.width), Float(texture.height))
    }

    static func mipSize(for texture: MTLTexture, mip: Int = 0) -> SIMD2<Float> {
        let width = max(1, texture.width >> mip)
        let height = max(1, texture.height >> mip)
        return SIMD2<Float>(Float(width), Float(height))
    }

    static func withRenderPass(_ pass: RenderPassType, frameContext: RendererFrameContext, _ body: () -> Void) {
        let previous = frameContext.currentRenderPass()
        frameContext.setCurrentRenderPass(pass)
        body()
        frameContext.setCurrentRenderPass(previous)
    }

    static func shouldRenderEditorOverlays(_ frameContext: RendererFrameContext, fallback sceneView: SceneView) -> Bool {
        let contextFlag = frameContext.viewContext().showEditorOverlays
        return contextFlag || sceneView.isEditorView
    }
}

struct CanonicalScreenSpaceTextures {
    // Canonical screen-space surfaces used by fullscreen/post passes.
    // sceneColor is the resolved HDR scene color, sceneColorFogged is the optional
    // fogged variant, and finalColor is the final composite target.
    let sceneColor: MTLTexture?
    let sceneColorFogged: MTLTexture?
    let sceneDepth: MTLTexture?
    let sceneNormals: MTLTexture?
    let ssaoDepth: MTLTexture?
    let ssaoNormals: MTLTexture?
    let ssaoRaw: MTLTexture?
    let ssaoFiltered: MTLTexture?
    let ssaoPing: MTLTexture?
    let sceneColorMSAA: MTLTexture?
    let sceneDepthMSAA: MTLTexture?
    let finalColor: MTLTexture?

    init(registry: RenderResourceRegistry) {
        sceneColor = registry.namedTexture(RenderNamedResourceKey.sceneColor)
        sceneColorFogged = registry.namedTexture(RenderNamedResourceKey.sceneColorFogged)
        sceneDepth = registry.namedTexture(RenderNamedResourceKey.sceneDepth)
        sceneNormals = registry.namedTexture(RenderNamedResourceKey.sceneNormals)
        ssaoDepth = registry.namedTexture(RenderNamedResourceKey.ssaoDepth)
        ssaoNormals = registry.namedTexture(RenderNamedResourceKey.ssaoNormals)
        ssaoRaw = registry.namedTexture(RenderNamedResourceKey.ssaoRaw)
        ssaoFiltered = registry.namedTexture(RenderNamedResourceKey.ssaoFiltered)
        ssaoPing = registry.namedTexture(RenderNamedResourceKey.ssaoPing)
        sceneColorMSAA = registry.namedTexture(RenderNamedResourceKey.sceneColorMSAA)
        sceneDepthMSAA = registry.namedTexture(RenderNamedResourceKey.sceneDepthMSAA)
        finalColor = registry.namedTexture(RenderNamedResourceKey.postFinalColor)
    }

    func postSceneColorChain(heightFogEnabled: Bool) -> PostSceneColorChain {
        PostSceneColorChain(
            baseSceneColor: sceneColor,
            foggedSceneColor: sceneColorFogged,
            heightFogEnabled: heightFogEnabled
        )
    }
}

enum PostSceneColorSource {
    case baseSceneColor
    case foggedSceneColor
}

struct PostSceneColorChain {
    let baseSceneColor: MTLTexture?
    let foggedSceneColor: MTLTexture?
    let activeSource: PostSceneColorSource

    init(baseSceneColor: MTLTexture?,
         foggedSceneColor: MTLTexture?,
         heightFogEnabled: Bool) {
        self.baseSceneColor = baseSceneColor
        self.foggedSceneColor = foggedSceneColor
        if heightFogEnabled, foggedSceneColor != nil {
            activeSource = .foggedSceneColor
        } else {
            activeSource = .baseSceneColor
        }
    }

    var activeSceneColor: MTLTexture? {
        switch activeSource {
        case .baseSceneColor:
            return baseSceneColor
        case .foggedSceneColor:
            return foggedSceneColor
        }
    }
}

struct FullscreenTarget {
    let texture: MTLTexture
    let mipLevel: Int
    let loadAction: MTLLoadAction
    let clearColor: MTLClearColor

    init(texture: MTLTexture,
         mipLevel: Int = 0,
         loadAction: MTLLoadAction = .clear,
         clearColor: MTLClearColor = ClearColor.Black) {
        self.texture = texture
        self.mipLevel = mipLevel
        self.loadAction = loadAction
        self.clearColor = clearColor
    }

    var size: SIMD2<Float> {
        RenderPassHelpers.mipSize(for: texture, mip: mipLevel)
    }

    func renderPassDescriptor() -> MTLRenderPassDescriptor {
        switch loadAction {
        case .load:
            return RenderPassBuilder.colorLoad(texture: texture, level: mipLevel)
        default:
            return RenderPassBuilder.color(texture: texture, level: mipLevel, clearColor: clearColor)
        }
    }
}

#if DEBUG
@inline(__always)
private func assertForwardPlusLightsAreLocalOnly(_ lights: [LightData], context: StaticString) {
    MC_ASSERT(lights.allSatisfy { $0.type != 2 },
              "Forward+ \(context) received directional lights. Directionals must be evaluated outside Forward+.")
}
#endif

struct PostProcessInputs {
    var sampler: SamplerStateType?
    var source: MTLTexture?
    var bloom: MTLTexture?
    var outlineMask: MTLTexture?
    var sceneDepth: MTLTexture?
    var sceneNormals: MTLTexture?
    var aoNormals: MTLTexture?
    var ssaoRaw: MTLTexture?
    var ssaoFiltered: MTLTexture?
    var environmentIrradiance: MTLTexture?
    var grid: MTLTexture?
    var worldDebug: MTLTexture?
    var settings: RendererSettings?
    var viewExposure: ExposureOutputUniforms?

    init(sampler: SamplerStateType? = nil,
         source: MTLTexture? = nil,
         bloom: MTLTexture? = nil,
         outlineMask: MTLTexture? = nil,
         sceneDepth: MTLTexture? = nil,
         sceneNormals: MTLTexture? = nil,
         aoNormals: MTLTexture? = nil,
         ssaoRaw: MTLTexture? = nil,
         ssaoFiltered: MTLTexture? = nil,
         environmentIrradiance: MTLTexture? = nil,
         grid: MTLTexture? = nil,
         worldDebug: MTLTexture? = nil,
         settings: RendererSettings? = nil,
         viewExposure: ExposureOutputUniforms? = nil) {
        self.sampler = sampler
        self.source = source
        self.bloom = bloom
        self.outlineMask = outlineMask
        self.sceneDepth = sceneDepth
        self.sceneNormals = sceneNormals
        self.aoNormals = aoNormals
        self.ssaoRaw = ssaoRaw
        self.ssaoFiltered = ssaoFiltered
        self.environmentIrradiance = environmentIrradiance
        self.grid = grid
        self.worldDebug = worldDebug
        self.settings = settings
        self.viewExposure = viewExposure
    }

    init(canonical surfaces: CanonicalScreenSpaceTextures,
         sampler: SamplerStateType? = nil,
         source: MTLTexture? = nil,
         bloom: MTLTexture? = nil,
         outlineMask: MTLTexture? = nil,
         useSceneDepth: Bool = false,
         useSceneNormals: Bool = false,
         useSSAO: Bool = false,
         grid: MTLTexture? = nil,
         worldDebug: MTLTexture? = nil,
         settings: RendererSettings? = nil,
         viewExposure: ExposureOutputUniforms? = nil) {
        self.init(
            sampler: sampler,
            source: source ?? surfaces.sceneColor,
            bloom: bloom,
            outlineMask: outlineMask,
            sceneDepth: useSceneDepth ? surfaces.sceneDepth : nil,
            sceneNormals: useSceneNormals ? surfaces.sceneNormals : nil,
            aoNormals: useSSAO ? surfaces.ssaoNormals : nil,
            ssaoRaw: useSSAO ? surfaces.ssaoRaw : nil,
            ssaoFiltered: useSSAO ? surfaces.ssaoFiltered : nil,
            grid: grid,
            worldDebug: worldDebug,
            settings: settings,
            viewExposure: viewExposure
        )
    }

    func bind(into encoder: MTLRenderCommandEncoder,
              frameContext: RendererFrameContext,
              graphics: Graphics) {
        let fallback = frameContext.engineContext().fallbackTextures
        if let sampler {
            encoder.setFragmentSamplerState(graphics.samplerStates[sampler], index: FragmentSamplerIndex.linearClamp)
        }
        if let source {
            encoder.setFragmentTexture(source, index: PostProcessTextureIndex.source)
        } else {
            encoder.setFragmentTexture(fallback.blackRGBA, index: PostProcessTextureIndex.source)
        }
        encoder.setFragmentTexture(bloom ?? fallback.blackRGBA, index: PostProcessTextureIndex.bloom)
        // Optional editor/composite overlays must fall back to transparent black.
        // Using opaque black here darkens the frame whenever a view intentionally omits an overlay texture.
        encoder.setFragmentTexture(outlineMask ?? fallback.transparentBlackRGBA, index: PostProcessTextureIndex.outlineMask)
        encoder.setFragmentTexture(sceneDepth ?? fallback.depth1x1, index: PostProcessTextureIndex.depth)
        encoder.setFragmentTexture(grid ?? fallback.transparentBlackRGBA, index: PostProcessTextureIndex.grid)
        encoder.setFragmentTexture(worldDebug ?? fallback.transparentBlackRGBA, index: PostProcessTextureIndex.worldDebug)
        encoder.setFragmentTexture(sceneNormals ?? fallback.blackRGBA, index: PostProcessTextureIndex.normals)
        encoder.setFragmentTexture(aoNormals ?? fallback.blackRGBA, index: PostProcessTextureIndex.aoNormals)
        encoder.setFragmentTexture(ssaoRaw ?? fallback.blackRGBA, index: PostProcessTextureIndex.ssaoRaw)
        encoder.setFragmentTexture(ssaoFiltered ?? fallback.blackRGBA, index: PostProcessTextureIndex.ssaoFiltered)
        if let environmentIrradiance {
            encoder.setFragmentTexture(environmentIrradiance, index: FragmentTextureIndex.irradiance)
        }
        let resolvedSettings = settings ?? frameContext.rendererSettings()
        let settingsBuffer = frameContext.uploadRendererSettings(resolvedSettings)
        encoder.setFragmentBuffer(settingsBuffer.buffer, offset: settingsBuffer.offset, index: FragmentBufferIndex.rendererSettings)
        let sceneConstants = frameContext.renderFrameSnapshot()?.sceneConstants ?? SceneConstants()
        let sceneConstantsBuffer = frameContext.uploadSceneConstants(sceneConstants)
        encoder.setFragmentBuffer(sceneConstantsBuffer, offset: 0, index: FragmentBufferIndex.postProcessSceneConstants)
        if let exposureBuffer = frameContext.exposureFrameResources()?.outputBuffer {
            encoder.setFragmentBuffer(exposureBuffer, offset: 0, index: FragmentBufferIndex.viewExposure)
        } else {
            var resolvedExposure = viewExposure ?? ExposureOutputUniforms()
            encoder.setFragmentBytes(&resolvedExposure, length: ExposureOutputUniforms.stride, index: FragmentBufferIndex.viewExposure)
        }
        var debugFlags = PostProcessDebugFlags()
        debugFlags.hasSceneNormals = (sceneNormals != nil) ? 1 : 0
        debugFlags.hasSSAO = (ssaoRaw != nil || ssaoFiltered != nil) ? 1 : 0
        debugFlags.hasAONormals = (aoNormals != nil) ? 1 : 0
        encoder.setFragmentBytes(&debugFlags, length: PostProcessDebugFlags.stride, index: FragmentBufferIndex.postProcessDebugFlags)
    }
}

struct FinalCompositeInputs {
    let surfaces: CanonicalScreenSpaceTextures
    let sceneColor: MTLTexture
    let bloom: MTLTexture
    let outlineMask: MTLTexture?
    let grid: MTLTexture?
    let worldDebug: MTLTexture?
    let includeSceneDepth: Bool
    let includeSceneNormals: Bool
    let includeSSAO: Bool
    let settings: RendererSettings

    func postProcessInputs() -> PostProcessInputs {
        PostProcessInputs(
            canonical: surfaces,
            sampler: .LinearClampToZero,
            source: sceneColor,
            bloom: bloom,
            outlineMask: outlineMask,
            useSceneDepth: includeSceneDepth,
            useSceneNormals: includeSceneNormals,
            useSSAO: includeSSAO,
            grid: grid,
            worldDebug: worldDebug,
            settings: settings
        )
    }
}

struct FullscreenPass {
    var pipeline: RenderPipelineStateType
    var label: String
    var inputs: PostProcessInputs

    func encode(into encoder: MTLRenderCommandEncoder, quad: MCMesh, frameContext: RendererFrameContext, graphics: Graphics) {
        encoder.setRenderPipelineState(graphics.renderPipelineStates[pipeline])
        encoder.label = label
        encoder.pushDebugGroup(label)
        encoder.setCullMode(.none)
        inputs.bind(into: encoder, frameContext: frameContext, graphics: graphics)
        quad.drawPrimitives(encoder, frameContext: frameContext)
        encoder.popDebugGroup()
    }

    @discardableResult
    func encode(frame: RenderGraphFrame,
                target: FullscreenTarget,
                beforeEncoding: ((MTLRenderCommandEncoder) -> Void)? = nil,
                afterEncoding: ((MTLRenderCommandEncoder) -> Void)? = nil) -> Bool {
        guard let quad = frame.engineContext.assets.mesh(handle: BuiltinAssets.fullscreenQuadMesh),
              let encoder = frame.commandBuffer.makeRenderCommandEncoder(descriptor: target.renderPassDescriptor()) else {
            return false
        }
        RenderPassHelpers.setViewport(encoder, target.size)
        beforeEncoding?(encoder)
        encode(into: encoder,
               quad: quad,
               frameContext: frame.frameContext,
               graphics: frame.engineContext.graphics)
        afterEncoding?(encoder)
        encoder.endEncoding()
        return true
    }
}

final class ShadowPass: RenderGraphPass {
    let name = "ShadowPass"
    let outputs: [RenderPassResourceUsage] = [
        .namedTexture("shadow.map"),
        .buffer("shadow.constants")
    ]

    func execute(frame: RenderGraphFrame) {
        frame.renderer.shadowRenderer.render(frame: frame)
    }
}

final class DepthPrepassPass: RenderGraphPass {
    let name = "DepthPrepassPass"
    let allowedDoubleWriteOutputs: Set<RenderResourceHandle> = [
        .namedTexture(RenderNamedResourceKey.sceneDepth),
        .namedTexture(RenderNamedResourceKey.forwardPlusCullingDepth)
    ]
    let outputs: [RenderPassResourceUsage] = [
        .namedTexture(RenderNamedResourceKey.sceneDepth),
        .namedTexture(RenderNamedResourceKey.forwardPlusCullingDepth, requiredUsage: .shaderRead)
    ]

    func execute(frame: RenderGraphFrame) {
        guard let depth = frame.resourceRegistry.namedTexture(RenderNamedResourceKey.sceneDepth) else { return }
        let frameIndex = frame.frameContext.currentFrameIndex()
        let pass = RenderPassBuilder.depth(texture: depth)
        guard let encoder = frame.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Depth Prepass"
        encoder.pushDebugGroup("Depth Prepass")
        frame.profiler.sampleGpuPassBegin(.depthPrepass, encoder: encoder, frameIndex: frameIndex)
        RenderPassHelpers.setViewport(encoder, RenderPassHelpers.textureSize(depth))
        RenderPassHelpers.withRenderPass(.depthPrepass, frameContext: frame.frameContext) {
            frame.delegate?.renderScene(into: encoder, frameContext: frame.frameContext)
        }
        encoder.popDebugGroup()
        encoder.endEncoding()
        frame.profiler.sampleGpuPassEnd(.depthPrepass, encoder: encoder, frameIndex: frameIndex)
    }
}

final class CullingDepthFallbackPass: RenderGraphPass {
    let name = "CullingDepthFallbackPass"
    let allowedDoubleWriteOutputs: Set<RenderResourceHandle> = [
        .namedTexture(RenderNamedResourceKey.sceneDepth),
        .namedTexture(RenderNamedResourceKey.forwardPlusCullingDepth)
    ]
    let outputs: [RenderPassResourceUsage] = [
        .namedTexture(RenderNamedResourceKey.sceneDepth),
        .namedTexture(RenderNamedResourceKey.forwardPlusCullingDepth, requiredUsage: .shaderRead)
    ]

    func execute(frame: RenderGraphFrame) {
        guard let depth = frame.resourceRegistry.namedTexture(RenderNamedResourceKey.sceneDepth) else { return }
        let pass = RenderPassBuilder.depth(texture: depth)
        guard let encoder = frame.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Culling Depth Fallback"
        encoder.pushDebugGroup("Culling Depth Fallback")
        RenderPassHelpers.setViewport(encoder, RenderPassHelpers.textureSize(depth))
        RenderPassHelpers.withRenderPass(.depthPrepass, frameContext: frame.frameContext) {
            frame.delegate?.renderScene(into: encoder, frameContext: frame.frameContext)
        }
        encoder.popDebugGroup()
        encoder.endEncoding()
    }
}

final class SceneNormalsPass: RenderGraphPass {
    let name = "SceneNormalsPass"
    let inputs: [RenderPassResourceUsage] = [
        .namedTexture(RenderNamedResourceKey.sceneDepth)
    ]
    let outputs: [RenderPassResourceUsage] = [
        .namedTexture(RenderNamedResourceKey.sceneNormals, expectedFormat: .rg16Float)
    ]

    func execute(frame: RenderGraphFrame) {
        guard let sceneNormals = frame.resourceRegistry.namedTexture(RenderNamedResourceKey.sceneNormals),
              let sceneDepth = frame.resourceRegistry.namedTexture(RenderNamedResourceKey.sceneDepth) else {
            return
        }

        let pass = RenderPassBuilder.colorDepth(
            color: sceneNormals,
            depth: sceneDepth,
            depthLoadAction: .load
        )
        guard let encoder = frame.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Scene Normals Pass"
        encoder.pushDebugGroup("Scene Normals Pass")
        RenderPassHelpers.setViewport(encoder, RenderPassHelpers.textureSize(sceneNormals))
        RenderPassHelpers.withRenderPass(.normal, frameContext: frame.frameContext) {
            frame.delegate?.renderScene(into: encoder, frameContext: frame.frameContext)
        }
        encoder.popDebugGroup()
        encoder.endEncoding()
    }
}

final class AONormalsPass: RenderGraphPass {
    let name = "AONormalsPass"
    let outputs: [RenderPassResourceUsage] = [
        .namedTexture(RenderNamedResourceKey.ssaoDepth),
        .namedTexture(RenderNamedResourceKey.ssaoNormals, expectedFormat: .rg16Float)
    ]

    func execute(frame: RenderGraphFrame) {
        guard let ssaoNormals = frame.resourceRegistry.namedTexture(RenderNamedResourceKey.ssaoNormals),
              let ssaoDepth = frame.resourceRegistry.namedTexture(RenderNamedResourceKey.ssaoDepth) else {
            return
        }

        // AO depth and normals are rasterized together into a single-sample pair. They remain
        // coherent with each other regardless of the main scene's MSAA sample count.
        let pass = RenderPassBuilder.colorDepth(
            color: ssaoNormals,
            depth: ssaoDepth,
            depthLoadAction: .clear
        )
        pass.depthAttachment.clearDepth = 1.0
        guard let encoder = frame.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "AO Normals Pass"
        encoder.pushDebugGroup("AO Normals Pass")
        RenderPassHelpers.setViewport(encoder, RenderPassHelpers.textureSize(ssaoNormals))
        RenderPassHelpers.withRenderPass(.ssaoNormal, frameContext: frame.frameContext) {
            frame.delegate?.renderScene(into: encoder, frameContext: frame.frameContext)
        }
        encoder.popDebugGroup()
        encoder.endEncoding()
    }
}

final class ForwardPlusTileBinPass: RenderGraphPass {
    let name = "ForwardPlusTileBinPass"
    let allowedDoubleWriteOutputs: Set<RenderResourceHandle> = [
        .buffer(RenderBufferHandle(key: RenderNamedResourceKey.forwardPlusLightGrid)),
        .buffer(RenderBufferHandle(key: RenderNamedResourceKey.forwardPlusLightIndexList)),
        .buffer(RenderBufferHandle(key: RenderNamedResourceKey.forwardPlusLightIndexCount))
    ]
    let inputs: [RenderPassResourceUsage] = []
    let outputs: [RenderPassResourceUsage] = [
        .buffer(RenderNamedResourceKey.forwardPlusTileLightGrid, requiredUsage: [.computeWrite]),
        .buffer(RenderNamedResourceKey.forwardPlusTileLightIndexList, requiredUsage: [.computeWrite]),
        .buffer(RenderNamedResourceKey.forwardPlusTileLightIndexCount, requiredUsage: [.computeWrite]),
        .buffer(RenderNamedResourceKey.forwardPlusActiveTileList, requiredUsage: [.computeWrite]),
        .buffer(RenderNamedResourceKey.forwardPlusActiveTileCount, requiredUsage: [.computeWrite]),
        .buffer(RenderNamedResourceKey.forwardPlusActiveDispatchArgs, requiredUsage: [.computeWrite]),
        .buffer(RenderNamedResourceKey.forwardPlusTileParams, requiredUsage: [.computeWrite]),
        .buffer(RenderNamedResourceKey.forwardPlusLightGrid, requiredUsage: [.computeWrite]),
        .buffer(RenderNamedResourceKey.forwardPlusLightIndexList, requiredUsage: [.computeWrite]),
        .buffer(RenderNamedResourceKey.forwardPlusLightIndexCount, requiredUsage: [.computeWrite]),
        .buffer(RenderNamedResourceKey.forwardPlusClusterParams, requiredUsage: [.computeWrite]),
        .buffer(RenderNamedResourceKey.forwardPlusStats, requiredUsage: [.computeWrite])
    ]
    private let tileSize = SIMD2<UInt32>(ForwardPlusConfig.tileSizeX, ForwardPlusConfig.tileSizeY)
    private let maxLightsPerTile: UInt32 = ForwardPlusConfig.maxLightsPerTile
    private let maxLightsPerCluster: UInt32 = ForwardPlusConfig.maxLightsPerCluster
    private var computePipeline: MTLComputePipelineState?
    private var clearPipeline: MTLComputePipelineState?
    private var activeTileBuildPipeline: MTLComputePipelineState?
    private var sparseDispatchPrepPipeline: MTLComputePipelineState?

    func execute(frame: RenderGraphFrame) {
#if DEBUG
        MC_ASSERT(ForwardPlusTileParams.stride == ForwardPlusTileParams.expectedMetalStride,
                  "ForwardPlusTileParams ABI mismatch: expected stride \(ForwardPlusTileParams.expectedMetalStride), got \(ForwardPlusTileParams.stride).")
        MC_ASSERT(MemoryLayout<ForwardPlusTileParams>.alignment == ForwardPlusTileParams.expectedMetalAlignment,
                  "ForwardPlusTileParams ABI mismatch: expected alignment \(ForwardPlusTileParams.expectedMetalAlignment), got \(MemoryLayout<ForwardPlusTileParams>.alignment).")
        MC_ASSERT(ForwardPlusTileIndexHeader.stride == ForwardPlusTileIndexHeader.expectedMetalStride,
                  "ForwardPlusTileIndexHeader ABI mismatch: expected stride \(ForwardPlusTileIndexHeader.expectedMetalStride), got \(ForwardPlusTileIndexHeader.stride).")
        MC_ASSERT(MemoryLayout<ForwardPlusTileIndexHeader>.alignment == ForwardPlusTileIndexHeader.expectedMetalAlignment,
                  "ForwardPlusTileIndexHeader ABI mismatch: expected alignment \(ForwardPlusTileIndexHeader.expectedMetalAlignment), got \(MemoryLayout<ForwardPlusTileIndexHeader>.alignment).")
#endif
        guard let baseDepth = frame.resourceRegistry.namedTexture(RenderNamedResourceKey.sceneDepth) else {
#if DEBUG
            fatalError("ForwardPlusTileBinPass requires scene.depth render target.")
#else
            return
#endif
        }

        let viewport = SIMD2<UInt32>(UInt32(max(baseDepth.width, 1)), UInt32(max(baseDepth.height, 1)))
        let tileCount = SIMD2<UInt32>(
            max(1, (viewport.x + tileSize.x - 1) / tileSize.x),
            max(1, (viewport.y + tileSize.y - 1) / tileSize.y)
        )
        let totalTileCountU32 = max(tileCount.x * tileCount.y, 1)
        let totalTileCount = Int(totalTileCountU32)
        let gridByteCount = max(totalTileCount * MemoryLayout<SIMD2<UInt32>>.stride, MemoryLayout<SIMD2<UInt32>>.stride)
        let indexCapacity64 = UInt64(max(totalTileCount, 1)) * UInt64(maxLightsPerTile)
        let indexCapacity = Int(min(indexCapacity64, UInt64(Int.max / MemoryLayout<UInt32>.stride)))
        let indexCapacityU32 = UInt32(min(indexCapacity, Int(UInt32.max)))
        let indexListByteCount = max(indexCapacity * MemoryLayout<UInt32>.stride, MemoryLayout<UInt32>.stride)
        let clusterCount = SIMD3<UInt32>(tileCount.x, tileCount.y, max(1, ForwardPlusConfig.zSliceCount))
        let totalClusterCountU32 = max(clusterCount.x * clusterCount.y * clusterCount.z, 1)
        let totalClusterCount = Int(totalClusterCountU32)
        let clusterGridByteCount = max(totalClusterCount * MemoryLayout<SIMD2<UInt32>>.stride, MemoryLayout<SIMD2<UInt32>>.stride)
        let clusterIndexCapacity64 = UInt64(max(totalClusterCount, 1)) * UInt64(maxLightsPerCluster)
        let clusterIndexCapacity = Int(min(clusterIndexCapacity64, UInt64(Int.max / MemoryLayout<UInt32>.stride)))
        let clusterIndexListByteCount = max(clusterIndexCapacity * MemoryLayout<UInt32>.stride, MemoryLayout<UInt32>.stride)
        let frameIndex = frame.frameInFlightIndex
        let viewSignature = frame.viewSignature
        let settingsRevision = frame.settingsRevision
        let tileGridSignature = makeSizeSignature(byteCount: gridByteCount, viewport: viewport, tileCount: tileCount, clusterCount: clusterCount)
        let tileIndexSignature = makeSizeSignature(byteCount: indexListByteCount, viewport: viewport, tileCount: tileCount, clusterCount: clusterCount)
        let clusterGridSignature = makeSizeSignature(byteCount: clusterGridByteCount, viewport: viewport, tileCount: tileCount, clusterCount: clusterCount)
        let clusterIndexSignature = makeSizeSignature(byteCount: clusterIndexListByteCount, viewport: viewport, tileCount: tileCount, clusterCount: clusterCount)
        let activeTileListByteCount = max(totalTileCount * MemoryLayout<UInt32>.stride, MemoryLayout<UInt32>.stride)
        let activeTileListSignature = makeSizeSignature(byteCount: activeTileListByteCount, viewport: viewport, tileCount: tileCount, clusterCount: clusterCount)
        let activeTileCountSignature = makeSizeSignature(byteCount: MemoryLayout<UInt32>.stride, viewport: viewport, tileCount: tileCount, clusterCount: clusterCount) ^ 0xE5
        let activeDispatchArgsByteCount = max(MemoryLayout<SIMD3<UInt32>>.stride, MemoryLayout<UInt32>.stride)
        let activeDispatchArgsSignature = makeSizeSignature(byteCount: activeDispatchArgsByteCount, viewport: viewport, tileCount: tileCount, clusterCount: clusterCount) ^ 0xF6
        let headerSignature = makeSizeSignature(byteCount: ForwardPlusIndexHeader.stride, viewport: viewport, tileCount: tileCount, clusterCount: clusterCount)
        let paramsSignature = makeSizeSignature(byteCount: ForwardPlusClusterParams.stride, viewport: viewport, tileCount: tileCount, clusterCount: clusterCount)

        guard let tileGridBuffer = frame.resources.transientBuffer(
            resourceName: RenderNamedResourceKey.forwardPlusTileLightGrid,
            frameInFlightIndex: frameIndex,
            viewSignature: viewSignature,
            sizeSignature: tileGridSignature,
            settingsRevision: settingsRevision,
            minLength: gridByteCount,
            storageMode: .private,
            label: "ForwardPlus.TileLightGrid.F\(frameIndex).V\(viewSignature)"
        ),
              let tileIndexListBuffer = frame.resources.transientBuffer(
                resourceName: RenderNamedResourceKey.forwardPlusTileLightIndexList,
                frameInFlightIndex: frameIndex,
                viewSignature: viewSignature,
                sizeSignature: tileIndexSignature,
                settingsRevision: settingsRevision,
                minLength: indexListByteCount,
                storageMode: .private,
                label: "ForwardPlus.TileLightIndexList.F\(frameIndex).V\(viewSignature)"
              ),
              let tileIndexHeaderBuffer = frame.resources.transientBuffer(
                resourceName: RenderNamedResourceKey.forwardPlusTileLightIndexCount,
                frameInFlightIndex: frameIndex,
                viewSignature: viewSignature,
                sizeSignature: headerSignature ^ 0xA1,
                settingsRevision: settingsRevision,
                minLength: ForwardPlusTileIndexHeader.stride,
                storageMode: .private,
                label: "ForwardPlus.TileLightIndexHeader.F\(frameIndex).V\(viewSignature)"
              ),
              let activeTileListBuffer = frame.resources.transientBuffer(
                resourceName: RenderNamedResourceKey.forwardPlusActiveTileList,
                frameInFlightIndex: frameIndex,
                viewSignature: viewSignature,
                sizeSignature: activeTileListSignature,
                settingsRevision: settingsRevision,
                minLength: activeTileListByteCount,
                storageMode: .private,
                label: "ForwardPlus.ActiveTileList.F\(frameIndex).V\(viewSignature)"
              ),
              let activeTileCountBuffer = frame.resources.transientBuffer(
                resourceName: RenderNamedResourceKey.forwardPlusActiveTileCount,
                frameInFlightIndex: frameIndex,
                viewSignature: viewSignature,
                sizeSignature: activeTileCountSignature,
                settingsRevision: settingsRevision,
                minLength: MemoryLayout<UInt32>.stride,
                storageMode: .private,
                label: "ForwardPlus.ActiveTileCount.F\(frameIndex).V\(viewSignature)"
              ),
              let activeDispatchArgsBuffer = frame.resources.transientBuffer(
                resourceName: RenderNamedResourceKey.forwardPlusActiveDispatchArgs,
                frameInFlightIndex: frameIndex,
                viewSignature: viewSignature,
                sizeSignature: activeDispatchArgsSignature,
                settingsRevision: settingsRevision,
                minLength: activeDispatchArgsByteCount,
                storageMode: .private,
                label: "ForwardPlus.ActiveDispatchArgs.F\(frameIndex).V\(viewSignature)"
              ),
              let tileParamsBuffer = frame.resources.transientBuffer(
                resourceName: RenderNamedResourceKey.forwardPlusTileParams,
                frameInFlightIndex: frameIndex,
                viewSignature: viewSignature,
                sizeSignature: paramsSignature ^ 0xB2,
                settingsRevision: settingsRevision,
                minLength: ForwardPlusTileParams.stride,
                storageMode: .private,
                label: "ForwardPlus.TileParams.F\(frameIndex).V\(viewSignature)"
              ),
              let clusterGridBuffer = frame.resources.transientBuffer(
                resourceName: RenderNamedResourceKey.forwardPlusLightGrid,
                frameInFlightIndex: frameIndex,
                viewSignature: viewSignature,
                sizeSignature: clusterGridSignature,
                settingsRevision: settingsRevision,
                minLength: clusterGridByteCount,
                storageMode: .private,
                label: "ForwardPlus.LightGrid.F\(frameIndex).V\(viewSignature)"
              ),
              let clusterIndexListBuffer = frame.resources.transientBuffer(
                resourceName: RenderNamedResourceKey.forwardPlusLightIndexList,
                frameInFlightIndex: frameIndex,
                viewSignature: viewSignature,
                sizeSignature: clusterIndexSignature,
                settingsRevision: settingsRevision,
                minLength: clusterIndexListByteCount,
                storageMode: .private,
                label: "ForwardPlus.LightIndexList.F\(frameIndex).V\(viewSignature)"
              ),
              let clusterIndexHeaderBuffer = frame.resources.transientBuffer(
                resourceName: RenderNamedResourceKey.forwardPlusLightIndexCount,
                frameInFlightIndex: frameIndex,
                viewSignature: viewSignature,
                sizeSignature: headerSignature ^ 0xC3,
                settingsRevision: settingsRevision,
                minLength: ForwardPlusIndexHeader.stride,
                storageMode: .private,
                label: "ForwardPlus.LightIndexHeader.F\(frameIndex).V\(viewSignature)"
              ),
              let clusterParamsBuffer = frame.resources.transientBuffer(
                resourceName: RenderNamedResourceKey.forwardPlusClusterParams,
                frameInFlightIndex: frameIndex,
                viewSignature: viewSignature,
                sizeSignature: paramsSignature ^ 0xD4,
                settingsRevision: settingsRevision,
                minLength: ForwardPlusClusterParams.stride,
                storageMode: .private,
                label: "ForwardPlus.ClusterParams.F\(frameIndex).V\(viewSignature)"
              ),
              let statsBuffer = frame.resources.transientBuffer(
                resourceName: RenderNamedResourceKey.forwardPlusStats,
                frameInFlightIndex: frameIndex,
                viewSignature: viewSignature,
                sizeSignature: makeSizeSignature(byteCount: ForwardPlusStats.stride, viewport: viewport, tileCount: tileCount, clusterCount: clusterCount),
                settingsRevision: settingsRevision,
                minLength: ForwardPlusStats.stride,
                storageMode: .shared,
                label: "ForwardPlus.Stats.F\(frameIndex).V\(viewSignature)"
              ) else {
            return
        }

        let projectionMatrix = frame.sceneSnapshot?.sceneConstants.projectionMatrix ?? matrix_identity_float4x4
        let derivedNearFar = deriveNearFarPlanes(from: projectionMatrix)
        let nearPlane = max(derivedNearFar?.near ?? 0.1, 0.01)
        let farPlane = max(derivedNearFar?.far ?? 1000.0, nearPlane + 0.01)
        let depthSpan = max(farPlane - nearPlane, 0.0001)
        let logDepthPow = exp2(Float(clusterCount.z))
        let logDepthScale = (logDepthPow - 1.0) / depthSpan
        let logDepthBias = 1.0 - nearPlane * logDepthScale
        var clearUniforms = ForwardPlusClearUniforms()
        clearUniforms.abiVersion = ForwardPlusConfig.abiVersion
        clearUniforms.tileCountX = tileCount.x
        clearUniforms.tileCountY = tileCount.y
        clearUniforms.maxLightsPerTile = maxLightsPerTile
        clearUniforms.tileSizeX = tileSize.x
        clearUniforms.tileSizeY = tileSize.y
        clearUniforms.viewportWidth = viewport.x
        clearUniforms.viewportHeight = viewport.y
        clearUniforms.clusterCountX = clusterCount.x
        clearUniforms.clusterCountY = clusterCount.y
        clearUniforms.clusterCountZ = clusterCount.z
        clearUniforms.maxLightsPerCluster = maxLightsPerCluster
        clearUniforms.nearPlane = nearPlane
        clearUniforms.farPlane = farPlane
        clearUniforms.logDepthScale = max(logDepthScale, 1e-6)
        clearUniforms.logDepthBias = logDepthBias
        runComputeClear(frame: frame,
                        totalTileCount: totalTileCountU32,
                        totalClusterCount: totalClusterCountU32,
                        clearUniforms: clearUniforms,
                        tileParamsBuffer: tileParamsBuffer,
                        tileIndexHeaderBuffer: tileIndexHeaderBuffer,
                        tileGridBuffer: tileGridBuffer,
                        activeTileCountBuffer: activeTileCountBuffer,
                        clusterParamsBuffer: clusterParamsBuffer,
                        clusterIndexHeaderBuffer: clusterIndexHeaderBuffer,
                        clusterGridBuffer: clusterGridBuffer,
                        sparseDispatchBuffer: activeDispatchArgsBuffer,
                        statsBuffer: statsBuffer)
        runComputeTileBinning(frame: frame,
                              tileCount: tileCount,
                              viewport: viewport,
                              indexCapacity: indexCapacityU32,
                              tileParamsBuffer: tileParamsBuffer,
                              tileGridBuffer: tileGridBuffer,
                              tileIndexListBuffer: tileIndexListBuffer,
                              tileIndexHeaderBuffer: tileIndexHeaderBuffer,
                              statsBuffer: statsBuffer)
        runComputeBuildActiveTiles(frame: frame,
                                   tileCount: tileCount,
                                   tileParamsBuffer: tileParamsBuffer,
                                   tileGridBuffer: tileGridBuffer,
                                   activeTileListBuffer: activeTileListBuffer,
                                   activeTileCountBuffer: activeTileCountBuffer,
                                   clusterParamsBuffer: clusterParamsBuffer,
                                   sparseDispatchBuffer: activeDispatchArgsBuffer,
                                   statsBuffer: statsBuffer)

        frame.resourceRegistry.registerBuffer(
            RenderNamedResourceKey.forwardPlusTileLightGrid,
            buffer: tileGridBuffer,
            lifetime: .transientPerFrame,
            usage: [.computeWrite]
        )
        frame.resourceRegistry.registerBuffer(
            RenderNamedResourceKey.forwardPlusTileLightIndexList,
            buffer: tileIndexListBuffer,
            lifetime: .transientPerFrame,
            usage: [.computeWrite]
        )
        frame.resourceRegistry.registerBuffer(
            RenderNamedResourceKey.forwardPlusTileLightIndexCount,
            buffer: tileIndexHeaderBuffer,
            lifetime: .transientPerFrame,
            usage: [.computeWrite]
        )
        frame.resourceRegistry.registerBuffer(
            RenderNamedResourceKey.forwardPlusActiveTileList,
            buffer: activeTileListBuffer,
            lifetime: .transientPerFrame,
            usage: [.computeWrite]
        )
        frame.resourceRegistry.registerBuffer(
            RenderNamedResourceKey.forwardPlusActiveTileCount,
            buffer: activeTileCountBuffer,
            lifetime: .transientPerFrame,
            usage: [.computeWrite]
        )
        frame.resourceRegistry.registerBuffer(
            RenderNamedResourceKey.forwardPlusActiveDispatchArgs,
            buffer: activeDispatchArgsBuffer,
            lifetime: .transientPerFrame,
            usage: [.computeWrite]
        )
        frame.resourceRegistry.registerBuffer(
            RenderNamedResourceKey.forwardPlusTileParams,
            buffer: tileParamsBuffer,
            lifetime: .transientPerFrame,
            usage: [.computeWrite]
        )
        frame.resourceRegistry.registerBuffer(
            RenderNamedResourceKey.forwardPlusLightGrid,
            buffer: clusterGridBuffer,
            lifetime: .transientPerFrame,
            usage: [.computeWrite]
        )
        frame.resourceRegistry.registerBuffer(
            RenderNamedResourceKey.forwardPlusLightIndexList,
            buffer: clusterIndexListBuffer,
            lifetime: .transientPerFrame,
            usage: [.computeWrite]
        )
        frame.resourceRegistry.registerBuffer(
            RenderNamedResourceKey.forwardPlusLightIndexCount,
            buffer: clusterIndexHeaderBuffer,
            lifetime: .transientPerFrame,
            usage: [.computeWrite]
        )
        frame.resourceRegistry.registerBuffer(
            RenderNamedResourceKey.forwardPlusClusterParams,
            buffer: clusterParamsBuffer,
            lifetime: .transientPerFrame,
            usage: [.computeWrite]
        )
        frame.resourceRegistry.registerBuffer(
            RenderNamedResourceKey.forwardPlusStats,
            buffer: statsBuffer,
            lifetime: .transientPerFrame,
            usage: [.computeWrite]
        )
#if DEBUG
        MC_ASSERT(tileGridBuffer.storageMode == .private && tileIndexListBuffer.storageMode == .private
                    && tileIndexHeaderBuffer.storageMode == .private
                    && activeTileListBuffer.storageMode == .private
                    && activeTileCountBuffer.storageMode == .private
                    && activeDispatchArgsBuffer.storageMode == .private
                    && tileParamsBuffer.storageMode == .private,
                  "Forward+ tile resources must use private storage.")
        MC_ASSERT(clusterGridBuffer.storageMode == .private && clusterIndexListBuffer.storageMode == .private
                    && clusterIndexHeaderBuffer.storageMode == .private && clusterParamsBuffer.storageMode == .private,
                  "Forward+ cluster resources must use private storage.")
        MC_ASSERT(statsBuffer.storageMode == .shared, "Forward+ stats buffer must use shared storage.")
#endif
        frame.frameContext.diagnostics.setForwardPlusStatsReadbackBuffer(statsBuffer)
    }

    private func deriveNearFarPlanes(from projection: matrix_float4x4) -> (near: Float, far: Float)? {
        let m22 = projection.columns.2.z
        let m32 = projection.columns.3.z
        guard m22.isFinite, m32.isFinite else { return nil }

        let isPerspective = abs(projection.columns.2.w + 1.0) < 0.01 && abs(projection.columns.3.w) < 0.01
        if isPerspective {
            guard abs(m22) > 1e-6, abs(m22 + 1.0) > 1e-6 else { return nil }
            var near = m32 / m22
            var far = m32 / (m22 + 1.0)
            if near > far { swap(&near, &far) }
            near = max(0.01, near)
            far = max(near + 0.01, far)
            return (near, far)
        }

        guard abs(m22) > 1e-6 else { return nil }
        var near = m32 / m22
        var far = near - 1.0 / m22
        if near > far { swap(&near, &far) }
        near = max(0.01, near)
        far = max(near + 0.01, far)
        return (near, far)
    }

    private func runComputeClear(frame: RenderGraphFrame,
                                 totalTileCount: UInt32,
                                 totalClusterCount: UInt32,
                                 clearUniforms: ForwardPlusClearUniforms,
                                 tileParamsBuffer: MTLBuffer,
                                 tileIndexHeaderBuffer: MTLBuffer,
                                 tileGridBuffer: MTLBuffer,
                                 activeTileCountBuffer: MTLBuffer,
                                 clusterParamsBuffer: MTLBuffer,
                                 clusterIndexHeaderBuffer: MTLBuffer,
                                 clusterGridBuffer: MTLBuffer,
                                 sparseDispatchBuffer: MTLBuffer,
                                 statsBuffer: MTLBuffer) {
        guard let pipeline = resolveClearPipeline(frame: frame) else { return }
        guard let encoder = frame.commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "Forward+ Clear"
        encoder.pushDebugGroup("Forward+ Clear")
        encoder.setComputePipelineState(pipeline)
        var uniforms = clearUniforms
        encoder.setBytes(&uniforms, length: ForwardPlusClearUniforms.stride, index: ShaderBindings.ComputeBuffer.clearUniforms)
        encoder.setBuffer(tileParamsBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.tileParams)
        encoder.setBuffer(tileIndexHeaderBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.tileLightIndexCount)
        encoder.setBuffer(clusterIndexHeaderBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.indexHeader)
        encoder.setBuffer(clusterParamsBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.clusterParams)
        encoder.setBuffer(tileGridBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.tileLightGrid)
        encoder.setBuffer(clusterGridBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.lightGrid)
        encoder.setBuffer(activeTileCountBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.activeTileCount)
        encoder.setBuffer(sparseDispatchBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.dispatchThreadgroups)
        encoder.setBuffer(statsBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.forwardPlusStats)

        let threadWidth = min(64, pipeline.maxTotalThreadsPerThreadgroup)
        let threadsPerThreadgroup = MTLSize(width: max(threadWidth, 1), height: 1, depth: 1)
        let maxThreads = max(totalTileCount, totalClusterCount)
        let threadsPerGrid = MTLSize(width: Int(max(maxThreads, 1)), height: 1, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.popDebugGroup()
        encoder.endEncoding()
    }

    private func runComputeTileBinning(frame: RenderGraphFrame,
                                       tileCount: SIMD2<UInt32>,
                                       viewport: SIMD2<UInt32>,
                                       indexCapacity: UInt32,
                                       tileParamsBuffer: MTLBuffer,
                                       tileGridBuffer: MTLBuffer,
                                       tileIndexListBuffer: MTLBuffer,
                                       tileIndexHeaderBuffer: MTLBuffer,
                                       statsBuffer: MTLBuffer) {
        guard let pipeline = resolvePipeline(frame: frame) else { return }
        let snapshotLights = frame.sceneSnapshot?.localLights ?? []
#if DEBUG
        assertForwardPlusLightsAreLocalOnly(snapshotLights, context: "tile binning")
#endif
        let cullLights = snapshotLights.map { light in
            var out = ForwardPlusCullLight()
            out.positionAndRange = SIMD4<Float>(light.position, max(light.range, 0.0))
            out.directionAndType = SIMD4<Float>(light.direction, Float(light.type))
            out.colorAndIntensity = SIMD4<Float>(light.color, max(light.brightness, 0.0))
            out.spotParams = SIMD4<Float>(light.innerConeCos, light.outerConeCos, 0.0, 0.0)
            return out
        }
        guard !cullLights.isEmpty else { return }
        let lightBufferLength = max(ForwardPlusCullLight.stride(cullLights.count), ForwardPlusCullLight.stride)
        guard let lightBuffer = frame.engineContext.device.makeBuffer(length: lightBufferLength, options: [.storageModeShared]),
              let uniformsBuffer = frame.engineContext.device.makeBuffer(length: ForwardPlusCullUniforms.stride, options: [.storageModeShared]) else {
            return
        }
        lightBuffer.label = "ForwardPlus.TileBinLights"
        uniformsBuffer.label = "ForwardPlus.TileBinUniforms"
        cullLights.withUnsafeBytes { bytes in
            lightBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }

        var uniforms = ForwardPlusCullUniforms()
        if let snapshot = frame.sceneSnapshot {
            uniforms.viewMatrix = snapshot.sceneConstants.viewMatrix
            uniforms.projectionMatrix = snapshot.sceneConstants.projectionMatrix
        }
        uniforms.params0 = SIMD4<UInt32>(viewport.x, viewport.y, UInt32(cullLights.count), maxLightsPerTile)
        uniforms.params1 = SIMD4<UInt32>(tileCount.x, tileCount.y, 1, indexCapacity)
        withUnsafeBytes(of: &uniforms) { bytes in
            uniformsBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: ForwardPlusCullUniforms.stride)
        }

        guard let encoder = frame.commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "Forward+ Tile Binning"
        encoder.pushDebugGroup("Forward+ Tile Binning")
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(lightBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.cullLights)
        encoder.setBuffer(uniformsBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.cullUniforms)
        encoder.setBuffer(tileParamsBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.tileParams)
        encoder.setBuffer(tileGridBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.tileLightGrid)
        encoder.setBuffer(tileIndexListBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.tileLightIndexList)
        encoder.setBuffer(tileIndexHeaderBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.tileLightIndexCount)
        encoder.setBuffer(statsBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.forwardPlusStats)

        let threadWidth = min(64, pipeline.maxTotalThreadsPerThreadgroup)
        let threadsPerThreadgroup = MTLSize(width: max(threadWidth, 1), height: 1, depth: 1)
        let threadsPerGrid = MTLSize(width: cullLights.count, height: 1, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.popDebugGroup()
        encoder.endEncoding()
    }

    private func runComputeBuildActiveTiles(frame: RenderGraphFrame,
                                            tileCount: SIMD2<UInt32>,
                                            tileParamsBuffer: MTLBuffer,
                                            tileGridBuffer: MTLBuffer,
                                            activeTileListBuffer: MTLBuffer,
                                            activeTileCountBuffer: MTLBuffer,
                                            clusterParamsBuffer: MTLBuffer,
                                            sparseDispatchBuffer: MTLBuffer,
                                            statsBuffer: MTLBuffer) {
        guard let buildPipeline = resolveActiveTileBuildPipeline(frame: frame),
              let preparePipeline = resolveSparseDispatchPrepPipeline(frame: frame) else { return }

        let totalTileCount = max(tileCount.x * tileCount.y, 1)
        if let encoder = frame.commandBuffer.makeComputeCommandEncoder() {
            encoder.label = "Forward+ Build Active Tiles"
            encoder.pushDebugGroup("Forward+ Build Active Tiles")
            encoder.setComputePipelineState(buildPipeline)
            encoder.setBuffer(tileParamsBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.tileParams)
            encoder.setBuffer(tileGridBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.tileLightGrid)
            encoder.setBuffer(activeTileListBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.activeTileList)
            encoder.setBuffer(activeTileCountBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.activeTileCount)

            let threadWidth = min(64, buildPipeline.maxTotalThreadsPerThreadgroup)
            let threadsPerThreadgroup = MTLSize(width: max(threadWidth, 1), height: 1, depth: 1)
            let threadsPerGrid = MTLSize(width: Int(totalTileCount), height: 1, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
            encoder.popDebugGroup()
            encoder.endEncoding()
        }

        if let encoder = frame.commandBuffer.makeComputeCommandEncoder() {
            encoder.label = "Forward+ Prepare Sparse Dispatch"
            encoder.pushDebugGroup("Forward+ Prepare Sparse Dispatch")
            encoder.setComputePipelineState(preparePipeline)
            encoder.setBuffer(clusterParamsBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.clusterParams)
            encoder.setBuffer(activeTileCountBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.activeTileCount)
            encoder.setBuffer(sparseDispatchBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.dispatchThreadgroups)
            encoder.setBuffer(statsBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.forwardPlusStats)
            encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            encoder.popDebugGroup()
            encoder.endEncoding()
        }
    }

    private func makeSizeSignature(byteCount: Int,
                                   viewport: SIMD2<UInt32>,
                                   tileCount: SIMD2<UInt32>,
                                   clusterCount: SIMD3<UInt32>) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(ForwardPlusConfig.configVersion)
        hasher.combine(ForwardPlusConfig.abiVersion)
        hasher.combine(byteCount)
        hasher.combine(viewport.x)
        hasher.combine(viewport.y)
        hasher.combine(tileCount.x)
        hasher.combine(tileCount.y)
        hasher.combine(clusterCount.x)
        hasher.combine(clusterCount.y)
        hasher.combine(clusterCount.z)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    private func resolvePipeline(frame: RenderGraphFrame) -> MTLComputePipelineState? {
        if let computePipeline { return computePipeline }
        guard let fn = frame.engineContext.resources.resolveFunction(
            "kernel_forward_plus_tile_bin",
            device: frame.engineContext.device,
            fallbackLibrary: frame.engineContext.defaultLibrary
        ) else {
            frame.engineContext.log.logWarning("Forward+ compute function 'kernel_forward_plus_tile_bin' not found; skipping tile binning.", category: .renderer)
            return nil
        }
        do {
            let pipeline = try frame.engineContext.device.makeComputePipelineState(function: fn)
            computePipeline = pipeline
            return pipeline
        } catch {
            frame.engineContext.log.logWarning("Failed to create Forward+ tile bin compute pipeline: \(error)", category: .renderer)
            return nil
        }
    }

    private func resolveClearPipeline(frame: RenderGraphFrame) -> MTLComputePipelineState? {
        if let clearPipeline { return clearPipeline }
        guard let fn = frame.engineContext.resources.resolveFunction(
            "kernel_forward_plus_clear",
            device: frame.engineContext.device,
            fallbackLibrary: frame.engineContext.defaultLibrary
        ) else {
            frame.engineContext.log.logWarning("Forward+ compute function 'kernel_forward_plus_clear' not found; skipping Forward+ clear.", category: .renderer)
            return nil
        }
        do {
            let pipeline = try frame.engineContext.device.makeComputePipelineState(function: fn)
            clearPipeline = pipeline
            return pipeline
        } catch {
            frame.engineContext.log.logWarning("Failed to create Forward+ clear compute pipeline: \(error)", category: .renderer)
            return nil
        }
    }

    private func resolveActiveTileBuildPipeline(frame: RenderGraphFrame) -> MTLComputePipelineState? {
        if let activeTileBuildPipeline { return activeTileBuildPipeline }
        guard let fn = frame.engineContext.resources.resolveFunction(
            "kernel_forward_plus_build_active_tiles",
            device: frame.engineContext.device,
            fallbackLibrary: frame.engineContext.defaultLibrary
        ) else {
            frame.engineContext.log.logWarning("Forward+ compute function 'kernel_forward_plus_build_active_tiles' not found; sparse dispatch disabled.", category: .renderer)
            return nil
        }
        do {
            let pipeline = try frame.engineContext.device.makeComputePipelineState(function: fn)
            activeTileBuildPipeline = pipeline
            return pipeline
        } catch {
            frame.engineContext.log.logWarning("Failed to create Forward+ active tile build pipeline: \(error)", category: .renderer)
            return nil
        }
    }

    private func resolveSparseDispatchPrepPipeline(frame: RenderGraphFrame) -> MTLComputePipelineState? {
        if let sparseDispatchPrepPipeline { return sparseDispatchPrepPipeline }
        guard let fn = frame.engineContext.resources.resolveFunction(
            "kernel_forward_plus_prepare_sparse_dispatch",
            device: frame.engineContext.device,
            fallbackLibrary: frame.engineContext.defaultLibrary
        ) else {
            frame.engineContext.log.logWarning("Forward+ compute function 'kernel_forward_plus_prepare_sparse_dispatch' not found; sparse dispatch disabled.", category: .renderer)
            return nil
        }
        do {
            let pipeline = try frame.engineContext.device.makeComputePipelineState(function: fn)
            sparseDispatchPrepPipeline = pipeline
            return pipeline
        } catch {
            frame.engineContext.log.logWarning("Failed to create Forward+ sparse dispatch prep pipeline: \(error)", category: .renderer)
            return nil
        }
    }
}

final class LightCullingPass: RenderGraphPass {
    let name = "LightCullingPass"
    let inputs: [RenderPassResourceUsage] = [
        .namedTexture(RenderNamedResourceKey.forwardPlusCullingDepth, requiredUsage: .shaderRead),
        .buffer(RenderNamedResourceKey.forwardPlusTileLightGrid),
        .buffer(RenderNamedResourceKey.forwardPlusTileLightIndexList),
        .buffer(RenderNamedResourceKey.forwardPlusTileLightIndexCount),
        .buffer(RenderNamedResourceKey.forwardPlusActiveTileList),
        .buffer(RenderNamedResourceKey.forwardPlusActiveTileCount),
        .buffer(RenderNamedResourceKey.forwardPlusActiveDispatchArgs),
        .buffer(RenderNamedResourceKey.forwardPlusTileParams),
        .buffer(RenderNamedResourceKey.forwardPlusLightGrid),
        .buffer(RenderNamedResourceKey.forwardPlusLightIndexList),
        .buffer(RenderNamedResourceKey.forwardPlusLightIndexCount),
        .buffer(RenderNamedResourceKey.forwardPlusClusterParams),
        .buffer(RenderNamedResourceKey.forwardPlusStats)
    ]
    let outputs: [RenderPassResourceUsage] = [
        .buffer(RenderNamedResourceKey.forwardPlusLightGrid, requiredUsage: [.computeWrite]),
        .buffer(RenderNamedResourceKey.forwardPlusLightIndexList, requiredUsage: [.computeWrite]),
        .buffer(RenderNamedResourceKey.forwardPlusLightIndexCount, requiredUsage: [.computeWrite])
    ]
    private let maxLightsPerCluster: UInt32 = ForwardPlusConfig.maxLightsPerCluster
    private var computePipeline: MTLComputePipelineState?

    func execute(frame: RenderGraphFrame) {
        guard let tileParamsBuffer = frame.resourceRegistry.buffer(RenderNamedResourceKey.forwardPlusTileParams),
              let tileGridBuffer = frame.resourceRegistry.buffer(RenderNamedResourceKey.forwardPlusTileLightGrid),
              let tileIndexListBuffer = frame.resourceRegistry.buffer(RenderNamedResourceKey.forwardPlusTileLightIndexList),
              let tileIndexHeaderBuffer = frame.resourceRegistry.buffer(RenderNamedResourceKey.forwardPlusTileLightIndexCount),
              let activeTileListBuffer = frame.resourceRegistry.buffer(RenderNamedResourceKey.forwardPlusActiveTileList),
              let activeTileCountBuffer = frame.resourceRegistry.buffer(RenderNamedResourceKey.forwardPlusActiveTileCount),
              let activeDispatchArgsBuffer = frame.resourceRegistry.buffer(RenderNamedResourceKey.forwardPlusActiveDispatchArgs),
              let clusterGridBuffer = frame.resourceRegistry.buffer(RenderNamedResourceKey.forwardPlusLightGrid),
              let clusterIndexListBuffer = frame.resourceRegistry.buffer(RenderNamedResourceKey.forwardPlusLightIndexList),
              let clusterIndexHeaderBuffer = frame.resourceRegistry.buffer(RenderNamedResourceKey.forwardPlusLightIndexCount),
              let clusterParamsBuffer = frame.resourceRegistry.buffer(RenderNamedResourceKey.forwardPlusClusterParams),
              let statsBuffer = frame.resourceRegistry.buffer(RenderNamedResourceKey.forwardPlusStats) else {
#if DEBUG
            fatalError("LightCullingPass requires Forward+ tile bin resources before clustered culling.")
#else
            return
#endif
        }
#if DEBUG
        MC_ASSERT(tileParamsBuffer.storageMode == .private
                    && tileGridBuffer.storageMode == .private
                    && tileIndexListBuffer.storageMode == .private
                    && tileIndexHeaderBuffer.storageMode == .private
                    && activeTileListBuffer.storageMode == .private
                    && activeTileCountBuffer.storageMode == .private
                    && activeDispatchArgsBuffer.storageMode == .private
                    && clusterGridBuffer.storageMode == .private
                    && clusterIndexListBuffer.storageMode == .private
                    && clusterIndexHeaderBuffer.storageMode == .private
                    && clusterParamsBuffer.storageMode == .private,
                  "Forward+ culling buffers must be private.")
        MC_ASSERT(statsBuffer.storageMode == .shared, "Forward+ stats buffer must be shared.")
#endif

        let drawableWidth = UInt32(max(Int(frame.view.drawableSize.width), 1))
        let drawableHeight = UInt32(max(Int(frame.view.drawableSize.height), 1))
        let viewport = SIMD2<UInt32>(drawableWidth, drawableHeight)
        let clusterCount = SIMD3<UInt32>(
            max((viewport.x + ForwardPlusConfig.tileSizeX - 1) / ForwardPlusConfig.tileSizeX, 1),
            max((viewport.y + ForwardPlusConfig.tileSizeY - 1) / ForwardPlusConfig.tileSizeY, 1),
            max(1, ForwardPlusConfig.zSliceCount)
        )
        let totalClusterCount = max(clusterCount.x * clusterCount.y * clusterCount.z, 1)
        let indexCapacity = max(totalClusterCount * maxLightsPerCluster, 1)
        runComputeCulling(frame: frame,
                          clusterCount: clusterCount,
                          viewport: viewport,
                          indexCapacity: indexCapacity,
                          clusterParamsBuffer: clusterParamsBuffer,
                          indexHeaderBuffer: clusterIndexHeaderBuffer,
                          gridBuffer: clusterGridBuffer,
                          indexListBuffer: clusterIndexListBuffer,
                          tileParamsBuffer: tileParamsBuffer,
                          tileGridBuffer: tileGridBuffer,
                          tileIndexListBuffer: tileIndexListBuffer,
                          tileIndexHeaderBuffer: tileIndexHeaderBuffer,
                          activeTileListBuffer: activeTileListBuffer,
                          activeTileCountBuffer: activeTileCountBuffer,
                          activeDispatchArgsBuffer: activeDispatchArgsBuffer,
                          statsBuffer: statsBuffer)
    }

    private func runComputeCulling(frame: RenderGraphFrame,
                                   clusterCount: SIMD3<UInt32>,
                                   viewport: SIMD2<UInt32>,
                                   indexCapacity: UInt32,
                                   clusterParamsBuffer: MTLBuffer,
                                   indexHeaderBuffer: MTLBuffer,
                                   gridBuffer: MTLBuffer,
                                   indexListBuffer: MTLBuffer,
                                   tileParamsBuffer: MTLBuffer,
                                   tileGridBuffer: MTLBuffer,
                                   tileIndexListBuffer: MTLBuffer,
                                   tileIndexHeaderBuffer: MTLBuffer,
                                   activeTileListBuffer: MTLBuffer,
                                   activeTileCountBuffer: MTLBuffer,
                                   activeDispatchArgsBuffer: MTLBuffer,
                                   statsBuffer: MTLBuffer) {
        guard let pipeline = resolvePipeline(frame: frame) else { return }
        let snapshotLights = frame.sceneSnapshot?.localLights ?? []
#if DEBUG
        assertForwardPlusLightsAreLocalOnly(snapshotLights, context: "cluster culling")
#endif
        let cullLights = snapshotLights.map { light in
            var out = ForwardPlusCullLight()
            out.positionAndRange = SIMD4<Float>(light.position, max(light.range, 0.0))
            out.directionAndType = SIMD4<Float>(light.direction, Float(light.type))
            out.colorAndIntensity = SIMD4<Float>(light.color, max(light.brightness, 0.0))
            out.spotParams = SIMD4<Float>(light.innerConeCos, light.outerConeCos, 0.0, 0.0)
            return out
        }
        let lightBufferLength = max(ForwardPlusCullLight.stride(cullLights.count), ForwardPlusCullLight.stride)
        guard let lightBuffer = frame.engineContext.device.makeBuffer(length: lightBufferLength, options: [.storageModeShared]),
              let uniformsBuffer = frame.engineContext.device.makeBuffer(length: ForwardPlusCullUniforms.stride, options: [.storageModeShared]) else {
            return
        }
        lightBuffer.label = "ForwardPlus.CullLights"
        uniformsBuffer.label = "ForwardPlus.CullUniforms"
        if !cullLights.isEmpty {
            cullLights.withUnsafeBytes { bytes in
                lightBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
        }

        var uniforms = ForwardPlusCullUniforms()
        if let snapshot = frame.sceneSnapshot {
            uniforms.viewMatrix = snapshot.sceneConstants.viewMatrix
            uniforms.projectionMatrix = snapshot.sceneConstants.projectionMatrix
        }
        uniforms.params0 = SIMD4<UInt32>(viewport.x, viewport.y, UInt32(cullLights.count), maxLightsPerCluster)
        uniforms.params1 = SIMD4<UInt32>(clusterCount.x, clusterCount.y, clusterCount.z, indexCapacity)
#if DEBUG
        MC_ASSERT(uniforms.viewMatrix.columns.0.x.isFinite &&
                  uniforms.projectionMatrix.columns.0.x.isFinite,
                  "Forward+ cull uniforms contain invalid matrix values.")
#endif
        withUnsafeBytes(of: &uniforms) { bytes in
            uniformsBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: ForwardPlusCullUniforms.stride)
        }

        guard let encoder = frame.commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "Forward+ Light Culling"
        encoder.pushDebugGroup("Forward+ Light Culling")
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(lightBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.cullLights)
        encoder.setBuffer(clusterParamsBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.clusterParams)
        encoder.setBuffer(indexHeaderBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.indexHeader)
        encoder.setBuffer(uniformsBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.cullUniforms)
        encoder.setBuffer(gridBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.lightGrid)
        encoder.setBuffer(indexListBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.lightIndexList)
        encoder.setBuffer(tileParamsBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.tileParams)
        encoder.setBuffer(tileGridBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.tileLightGrid)
        encoder.setBuffer(tileIndexListBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.tileLightIndexList)
        encoder.setBuffer(tileIndexHeaderBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.tileLightIndexCount)
        encoder.setBuffer(activeTileListBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.activeTileList)
        encoder.setBuffer(activeTileCountBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.activeTileCount)
        encoder.setBuffer(statsBuffer, offset: 0, index: ShaderBindings.ComputeBuffer.forwardPlusStats)

        let threadsPerThreadgroup = MTLSize(width: 64, height: 1, depth: 1)
#if DEBUG
        MC_ASSERT(pipeline.maxTotalThreadsPerThreadgroup >= 64,
                  "Forward+ cull pipeline must support 64 threads per threadgroup.")
#endif
        encoder.dispatchThreadgroups(indirectBuffer: activeDispatchArgsBuffer,
                                     indirectBufferOffset: 0,
                                     threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.popDebugGroup()
        encoder.endEncoding()

    }

    private func resolvePipeline(frame: RenderGraphFrame) -> MTLComputePipelineState? {
        if let computePipeline { return computePipeline }
        guard let fn = frame.engineContext.resources.resolveFunction(
            "kernel_forward_plus_cull",
            device: frame.engineContext.device,
            fallbackLibrary: frame.engineContext.defaultLibrary
        ) else {
            frame.engineContext.log.logWarning("Forward+ compute function 'kernel_forward_plus_cull' not found; using empty culling output.", category: .renderer)
            return nil
        }
        do {
            let pipeline = try frame.engineContext.device.makeComputePipelineState(function: fn)
            computePipeline = pipeline
            return pipeline
        } catch {
            frame.engineContext.log.logWarning("Failed to create Forward+ compute pipeline: \(error)", category: .renderer)
            return nil
        }
    }
}

final class OpaqueScenePass: RenderGraphPass {
    let name = "OpaqueScenePass"
    let allowedDoubleWriteOutputs: Set<RenderResourceHandle> = [
        .namedTexture(RenderNamedResourceKey.sceneColorMSAA),
        .namedTexture(RenderNamedResourceKey.sceneDepthMSAA)
    ]
    let inputs: [RenderPassResourceUsage] = [
        .namedTexture(RenderNamedResourceKey.sceneDepth),
        .namedTexture(RenderNamedResourceKey.sceneNormals),
        .namedTexture(RenderNamedResourceKey.sceneColorMSAA),
        .namedTexture(RenderNamedResourceKey.sceneDepthMSAA),
        .buffer(RenderNamedResourceKey.forwardPlusLightGrid),
        .buffer(RenderNamedResourceKey.forwardPlusLightIndexList),
        .buffer(RenderNamedResourceKey.forwardPlusLightIndexCount),
        .buffer(RenderNamedResourceKey.forwardPlusClusterParams),
        .buffer(RenderNamedResourceKey.forwardPlusTileLightGrid),
        .buffer(RenderNamedResourceKey.forwardPlusTileParams)
    ]
    let outputs: [RenderPassResourceUsage] = [
        .namedTexture(RenderNamedResourceKey.sceneColorMSAA),
        .namedTexture(RenderNamedResourceKey.sceneDepthMSAA)
    ]

    func execute(frame: RenderGraphFrame) {
        let sceneStart = CACurrentMediaTime()
        guard
            let sceneColorMSAA = frame.resourceRegistry.namedTexture(RenderNamedResourceKey.sceneColorMSAA),
            let sceneDepthMSAA = frame.resourceRegistry.namedTexture(RenderNamedResourceKey.sceneDepthMSAA)
        else { return }
        let frameIndex = frame.frameContext.currentFrameIndex()
        let pass = MTLRenderPassDescriptor()
        // Single-sample baseDepth remains the authoritative shader-readable depth source.
        // The MSAA depth target exists only to keep opaque + transparent scene rasterization coherent.
        pass.colorAttachments[0].texture = sceneColorMSAA
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = ClearColor.Black
        pass.depthAttachment.texture = sceneDepthMSAA
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 1.0
        guard let encoder = frame.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Opaque Scene Pass"
        encoder.pushDebugGroup("Opaque Scene Pass")
        frame.profiler.sampleGpuPassBegin(.scene, encoder: encoder, frameIndex: frameIndex)
        RenderPassHelpers.setViewport(encoder, RenderPassHelpers.textureSize(sceneColorMSAA))
        RenderPassHelpers.withRenderPass(.main, frameContext: frame.frameContext) {
            frame.delegate?.renderScene(into: encoder, frameContext: frame.frameContext)
        }
        encoder.popDebugGroup()
        encoder.endEncoding()
        frame.profiler.sampleGpuPassEnd(.scene, encoder: encoder, frameIndex: frameIndex)
        frame.profiler.record(.scene, seconds: CACurrentMediaTime() - sceneStart)
    }
}

final class TransparentScenePass: RenderGraphPass {
    let name = "TransparentScenePass"
    let inputs: [RenderPassResourceUsage] = [
        .namedTexture(RenderNamedResourceKey.sceneColor),
        .namedTexture(RenderNamedResourceKey.sceneColorMSAA),
        .namedTexture(RenderNamedResourceKey.sceneDepthMSAA),
        .buffer(RenderNamedResourceKey.forwardPlusLightGrid),
        .buffer(RenderNamedResourceKey.forwardPlusLightIndexList),
        .buffer(RenderNamedResourceKey.forwardPlusLightIndexCount),
        .buffer(RenderNamedResourceKey.forwardPlusClusterParams),
        .buffer(RenderNamedResourceKey.forwardPlusTileLightGrid),
        .buffer(RenderNamedResourceKey.forwardPlusTileParams)
    ]
    let outputs: [RenderPassResourceUsage] = [
        .namedTexture(RenderNamedResourceKey.sceneColorMSAA),
        .namedTexture(RenderNamedResourceKey.sceneDepthMSAA),
        .namedTexture(RenderNamedResourceKey.sceneColor)
    ]

    func execute(frame: RenderGraphFrame) {
        guard
            let baseColor = frame.resourceRegistry.namedTexture(RenderNamedResourceKey.sceneColor),
            let sceneColorMSAA = frame.resourceRegistry.namedTexture(RenderNamedResourceKey.sceneColorMSAA),
            let sceneDepthMSAA = frame.resourceRegistry.namedTexture(RenderNamedResourceKey.sceneDepthMSAA)
        else { return }

        let pass = MTLRenderPassDescriptor()
        // Resolve scene color once after transparency so post continues from a single-sample HDR scene buffer.
        pass.colorAttachments[0].texture = sceneColorMSAA
        pass.colorAttachments[0].loadAction = .load
        if sceneColorMSAA.sampleCount > 1 {
            pass.colorAttachments[0].resolveTexture = baseColor
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].storeAction = .store
        }
        pass.depthAttachment.texture = sceneDepthMSAA
        pass.depthAttachment.loadAction = .load
        pass.depthAttachment.storeAction = .store

        guard let encoder = frame.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Transparent Scene Pass"
        encoder.pushDebugGroup("Transparent Scene Pass")
        RenderPassHelpers.setViewport(encoder, RenderPassHelpers.textureSize(sceneColorMSAA))
        RenderPassHelpers.withRenderPass(.transparent, frameContext: frame.frameContext) {
            frame.delegate?.renderScene(into: encoder, frameContext: frame.frameContext)
        }
        encoder.popDebugGroup()
        encoder.endEncoding()

        if sceneColorMSAA.sampleCount <= 1 {
            guard let blit = frame.commandBuffer.makeBlitCommandEncoder() else { return }
            blit.label = "Scene Color Copy"
            blit.copy(
                from: sceneColorMSAA,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: sceneColorMSAA.width, height: sceneColorMSAA.height, depth: 1),
                to: baseColor,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
        }
    }
}

final class SAOEvaluatePass: RenderGraphPass {
    let name = "SAOEvaluatePass"
    let inputs: [RenderPassResourceUsage] = [
        .namedTexture(RenderNamedResourceKey.ssaoDepth),
        .namedTexture(RenderNamedResourceKey.ssaoNormals)
    ]
    let outputs: [RenderPassResourceUsage] = [
        .namedTexture(RenderNamedResourceKey.ssaoRaw, expectedFormat: .rgba16Float)
    ]

    func execute(frame: RenderGraphFrame) {
        let surfaces = CanonicalScreenSpaceTextures(registry: frame.resourceRegistry)
        guard
            frame.renderPlan.ssaoEnabled,
            let sceneDepth = surfaces.ssaoDepth,
            let sceneNormals = surfaces.ssaoNormals,
            let ssaoRaw = surfaces.ssaoRaw
        else { return }

        // AO targets store visibility, so the neutral clear value is white.
        let target = FullscreenTarget(texture: ssaoRaw, clearColor: MTLClearColorMake(1.0, 1.0, 1.0, 1.0))
        let pass = FullscreenPass(
            pipeline: .SAOEvaluate,
            label: "SAO Evaluate",
            inputs: PostProcessInputs(
                sampler: .Nearest,
                sceneDepth: sceneDepth,
                sceneNormals: sceneNormals,
                settings: frame.frameContext.rendererSettings()
            )
        )
        _ = pass.encode(frame: frame, target: target)
    }
}

final class AOBlurPass: RenderGraphPass {
    let name = "AOBlurPass"
    let inputs: [RenderPassResourceUsage] = [
        .namedTexture(RenderNamedResourceKey.ssaoRaw, expectedFormat: .rgba16Float),
        .namedTexture(RenderNamedResourceKey.ssaoDepth),
        .namedTexture(RenderNamedResourceKey.ssaoNormals)
    ]
    let outputs: [RenderPassResourceUsage] = [
        .namedTexture(RenderNamedResourceKey.ssaoFiltered, expectedFormat: .r16Float),
        .namedTexture(RenderNamedResourceKey.ssaoPing, expectedFormat: .r16Float)
    ]

    func execute(frame: RenderGraphFrame) {
        let surfaces = CanonicalScreenSpaceTextures(registry: frame.resourceRegistry)
        guard
            frame.renderPlan.ssaoEnabled,
            let ssaoRaw = surfaces.ssaoRaw,
            let ssaoFiltered = surfaces.ssaoFiltered,
            let ssaoPing = surfaces.ssaoPing,
            let sceneDepth = surfaces.ssaoDepth,
            let aoNormals = surfaces.ssaoNormals,
            let quadMesh = frame.engineContext.assets.mesh(handle: BuiltinAssets.fullscreenQuadMesh)
        else { return }

        // Blur preserves AO visibility semantics through ping/pong.
        let horizontalTarget = FullscreenTarget(texture: ssaoPing, clearColor: MTLClearColorMake(1.0, 1.0, 1.0, 1.0))
        guard let horizontalEncoder = frame.commandBuffer.makeRenderCommandEncoder(descriptor: horizontalTarget.renderPassDescriptor()) else { return }
        RenderPassHelpers.setViewport(horizontalEncoder, horizontalTarget.size)
        let horizontalPass = FullscreenPass(
            pipeline: .AOBlurH,
            label: "AO Blur Horizontal",
            inputs: PostProcessInputs(
                sampler: .LinearClampToZero,
                source: ssaoRaw,
                sceneDepth: sceneDepth,
                sceneNormals: aoNormals,
                settings: frame.frameContext.rendererSettings()
            )
        )
        horizontalPass.encode(into: horizontalEncoder, quad: quadMesh, frameContext: frame.frameContext, graphics: frame.engineContext.graphics)
        horizontalEncoder.endEncoding()

        let verticalTarget = FullscreenTarget(texture: ssaoFiltered, clearColor: MTLClearColorMake(1.0, 1.0, 1.0, 1.0))
        guard let verticalEncoder = frame.commandBuffer.makeRenderCommandEncoder(descriptor: verticalTarget.renderPassDescriptor()) else { return }
        RenderPassHelpers.setViewport(verticalEncoder, verticalTarget.size)
        let verticalPass = FullscreenPass(
            pipeline: .AOBlurV,
            label: "AO Blur Vertical",
            inputs: PostProcessInputs(
                sampler: .LinearClampToZero,
                source: ssaoPing,
                sceneDepth: sceneDepth,
                sceneNormals: aoNormals,
                settings: frame.frameContext.rendererSettings()
            )
        )
        verticalPass.encode(into: verticalEncoder, quad: quadMesh, frameContext: frame.frameContext, graphics: frame.engineContext.graphics)
        verticalEncoder.endEncoding()
    }
}

final class PickingPass: RenderGraphPass {
    let name = "PickingPass"
    let outputs: [RenderPassResourceUsage] = [
        .texture(.pickId, expectedFormat: .r32Uint),
        .texture(.pickDepth)
    ]

    func execute(frame: RenderGraphFrame) {
        guard
            let pickId = frame.resourceRegistry.texture(.pickId),
            let pickDepth = frame.resourceRegistry.texture(.pickDepth)
        else { return }
        let request = frame.engineContext.pickingSystem.consumeRequest()

        let frameIndex = frame.frameContext.currentFrameIndex()
        let pass = RenderPassBuilder.color(texture: pickId, clearColor: MTLClearColorMake(0, 0, 0, 0))
        pass.depthAttachment.texture = pickDepth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 1.0

        guard let encoder = frame.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Picking Pass"
        encoder.pushDebugGroup("Picking Pass")
        frame.profiler.sampleGpuPassBegin(.picking, encoder: encoder, frameIndex: frameIndex)
        RenderPassHelpers.setViewport(encoder, RenderPassHelpers.textureSize(pickId))
        RenderPassHelpers.withRenderPass(.picking, frameContext: frame.frameContext) {
            frame.delegate?.renderScene(into: encoder, frameContext: frame.frameContext)
        }
        encoder.popDebugGroup()
        encoder.endEncoding()
        frame.profiler.sampleGpuPassEnd(.picking, encoder: encoder, frameIndex: frameIndex)

        if let request, let readbackBuffer = frame.frameContext.pickReadbackBuffer() {
            frame.engineContext.pickingSystem.enqueueReadback(
                request: request,
                pickTexture: pickId,
                readbackBuffer: readbackBuffer,
                commandBuffer: frame.commandBuffer
            ) { pickedId, mask in
                frame.delegate?.handlePickResult(PickResult(pickedId: pickedId, mask: mask))
            }
        }
    }
}

final class GridOverlayPass: RenderGraphPass {
    let name = "GridOverlayPass"
    let allowedDoubleWriteOutputs: Set<RenderResourceHandle> = [
        .texture(RenderTextureHandle(key: .gridColor))
    ]
    let inputs: [RenderPassResourceUsage] = [
        .namedTexture(RenderNamedResourceKey.sceneDepth)
    ]
    let outputs: [RenderPassResourceUsage] = [
        .texture(.gridColor)
    ]

    func execute(frame: RenderGraphFrame) {
        guard let grid = frame.resourceRegistry.texture(.gridColor) else { return }
        let frameIndex = frame.frameContext.currentFrameIndex()
        let pass = RenderPassBuilder.color(texture: grid, clearColor: MTLClearColorMake(0, 0, 0, 0))
        guard let encoder = frame.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Grid Overlay"
        encoder.pushDebugGroup("Grid Overlay")
        defer {
            encoder.popDebugGroup()
            encoder.endEncoding()
            frame.profiler.sampleGpuPassEnd(.grid, encoder: encoder, frameIndex: frameIndex)
        }

        frame.profiler.sampleGpuPassBegin(.grid, encoder: encoder, frameIndex: frameIndex)
        guard
            let quadMesh = frame.engineContext.assets.mesh(handle: BuiltinAssets.fullscreenQuadMesh),
            var params = frame.engineContext.debugDraw.gridParams()
        else { return }

        RenderPassHelpers.setViewport(encoder, RenderPassHelpers.textureSize(grid))
        encoder.setRenderPipelineState(frame.engineContext.graphics.renderPipelineStates[.GridOverlay])
        encoder.setCullMode(.none)
        let depthTexture = frame.resourceRegistry.namedTexture(RenderNamedResourceKey.sceneDepth) ?? frame.engineContext.fallbackTextures.depth1x1
        encoder.setFragmentSamplerState(frame.engineContext.graphics.samplerStates[.LinearClampToZero], index: FragmentSamplerIndex.linearClamp)
        encoder.setFragmentTexture(depthTexture, index: PostProcessTextureIndex.depth)
        encoder.setFragmentBytes(&params, length: GridParams.stride, index: FragmentBufferIndex.gridParams)
        let settingsBuffer = frame.frameContext.uploadRendererSettings(frame.frameContext.rendererSettings())
        encoder.setFragmentBuffer(settingsBuffer.buffer, offset: settingsBuffer.offset, index: FragmentBufferIndex.rendererSettings)
        quadMesh.drawPrimitives(encoder, frameContext: frame.frameContext)
    }
}

final class DebugDrawPass: RenderGraphPass {
    let name = "DebugDrawPass"
    let outputs: [RenderPassResourceUsage] = [
        .texture(.worldDebugColor)
    ]

    func execute(frame: RenderGraphFrame) {
        guard let snapshot = frame.sceneSnapshot,
              let worldDebug = frame.resourceRegistry.texture(.worldDebugColor) else { return }
        let debugDraw = frame.engineContext.debugDraw
        let lines = debugDraw.lines()
        let polylines = debugDraw.polylines()
        if lines.isEmpty && polylines.isEmpty {
            let pass = RenderPassBuilder.color(texture: worldDebug, clearColor: MTLClearColorMake(0, 0, 0, 0))
            if let encoder = frame.commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                encoder.label = "Debug Draw Clear"
                encoder.endEncoding()
            }
            return
        }
        let sceneConstants = snapshot.sceneConstants
        let cameraPosition = SIMD3<Float>(
            sceneConstants.cameraPositionAndIBL.x,
            sceneConstants.cameraPositionAndIBL.y,
            sceneConstants.cameraPositionAndIBL.z
        )
        let thickness = max(0.0001, frame.engineContext.debugDraw.lineThickness)
        var vertices: [DebugLineVertex] = []
        vertices.reserveCapacity((lines.count + polylines.count * 2) * 6)

        @inline(__always)
        func resolveRight(lineDir: SIMD3<Float>, anchor: SIMD3<Float>) -> SIMD3<Float> {
            var viewDir = cameraPosition - anchor
            if simd_length_squared(viewDir) < 0.0001 {
                viewDir = SIMD3<Float>(0, 0, 1)
            }
            viewDir = simd_normalize(viewDir)
            var right = simd_cross(lineDir, viewDir)
            if simd_length_squared(right) < 0.0001 {
                right = simd_cross(lineDir, SIMD3<Float>(0, 1, 0))
                if simd_length_squared(right) < 0.0001 {
                    right = simd_cross(lineDir, SIMD3<Float>(1, 0, 0))
                }
            }
            return simd_normalize(right)
        }

        @inline(__always)
        func appendQuad(v0: SIMD3<Float>, v1: SIMD3<Float>, v2: SIMD3<Float>, v3: SIMD3<Float>, color: SIMD4<Float>, u0: Float, u1: Float) {
            vertices.append(DebugLineVertex(position: v0, color: color, uv: SIMD2<Float>(u0, 0)))
            vertices.append(DebugLineVertex(position: v1, color: color, uv: SIMD2<Float>(u0, 1)))
            vertices.append(DebugLineVertex(position: v2, color: color, uv: SIMD2<Float>(u1, 0)))
            vertices.append(DebugLineVertex(position: v2, color: color, uv: SIMD2<Float>(u1, 0)))
            vertices.append(DebugLineVertex(position: v1, color: color, uv: SIMD2<Float>(u0, 1)))
            vertices.append(DebugLineVertex(position: v3, color: color, uv: SIMD2<Float>(u1, 1)))
        }

        for line in lines {
            let p0 = line.start
            let p1 = line.end
            let dir = p1 - p0
            let length = simd_length(dir)
            if length < 0.0001 { continue }
            let lineDir = dir / length
            let right = resolveRight(lineDir: lineDir, anchor: (p0 + p1) * 0.5)
            let offset = right * (thickness * 0.5)
            let v0 = p0 - offset
            let v1 = p0 + offset
            let v2 = p1 - offset
            let v3 = p1 + offset
            appendQuad(v0: v0, v1: v1, v2: v2, v3: v3, color: line.color, u0: 0.0, u1: 1.0)
        }

        for polyline in polylines {
            let points = polyline.points
            let pointCount = points.count
            if pointCount < 2 { continue }

            let closed = polyline.closed
            let segmentCount = closed ? pointCount : pointCount - 1
            if segmentCount <= 0 { continue }

            var segmentDirs = Array(repeating: SIMD3<Float>.zero, count: segmentCount)
            var segmentRights = Array(repeating: SIMD3<Float>.zero, count: segmentCount)
            var segmentLengths = Array(repeating: Float(0), count: segmentCount)
            for segmentIndex in 0..<segmentCount {
                let nextIndex = (segmentIndex + 1) % pointCount
                let dir = points[nextIndex] - points[segmentIndex]
                let len = simd_length(dir)
                if len < 0.0001 { continue }
                let lineDir = dir / len
                segmentDirs[segmentIndex] = lineDir
                segmentLengths[segmentIndex] = len
                segmentRights[segmentIndex] = resolveRight(lineDir: lineDir, anchor: (points[segmentIndex] + points[nextIndex]) * 0.5)
            }

            var leftOffsets = Array(repeating: SIMD3<Float>.zero, count: pointCount)
            var rightOffsets = Array(repeating: SIMD3<Float>.zero, count: pointCount)
            for pointIndex in 0..<pointCount {
                let prevSegment = (pointIndex - 1 + segmentCount) % segmentCount
                let nextSegment = pointIndex % segmentCount

                let right: SIMD3<Float>
                if !closed && pointIndex == 0 {
                    right = segmentRights[0]
                } else if !closed && pointIndex == pointCount - 1 {
                    right = segmentRights[segmentCount - 1]
                } else {
                    let rightPrev = segmentRights[prevSegment]
                    let rightNext = segmentRights[nextSegment]
                    if simd_length_squared(rightPrev) < 1e-8 {
                        right = rightNext
                    } else if simd_length_squared(rightNext) < 1e-8 {
                        right = rightPrev
                    } else {
                        var miter = rightPrev + rightNext
                        if simd_length_squared(miter) < 1e-8 {
                            right = rightNext
                            let offset = right * (thickness * 0.5)
                            leftOffsets[pointIndex] = points[pointIndex] - offset
                            rightOffsets[pointIndex] = points[pointIndex] + offset
                            continue
                        }
                        miter = simd_normalize(miter)
                        let denominator = max(0.25, abs(simd_dot(miter, rightNext)))
                        var scale = 1.0 / denominator
                        scale = min(scale, 4.0)
                        var candidate = miter * (thickness * 0.5 * scale)
                        if simd_dot(candidate, rightNext) < 0 {
                            candidate = -candidate
                        }
                        leftOffsets[pointIndex] = points[pointIndex] - candidate
                        rightOffsets[pointIndex] = points[pointIndex] + candidate
                        continue
                    }
                }

                let offset = right * (thickness * 0.5)
                leftOffsets[pointIndex] = points[pointIndex] - offset
                rightOffsets[pointIndex] = points[pointIndex] + offset
            }

            var uByPoint = Array(repeating: Float(0.5), count: pointCount)
            if !closed {
                let total = segmentLengths.reduce(0, +)
                if total > 0.0001 {
                    var accum: Float = 0
                    uByPoint[0] = 0
                    for segmentIndex in 0..<segmentCount {
                        let next = segmentIndex + 1
                        accum += segmentLengths[segmentIndex]
                        uByPoint[next] = min(1.0, accum / total)
                    }
                }
            }

            for segmentIndex in 0..<segmentCount {
                if segmentLengths[segmentIndex] < 0.0001 { continue }
                let nextIndex = (segmentIndex + 1) % pointCount
                appendQuad(
                    v0: leftOffsets[segmentIndex],
                    v1: rightOffsets[segmentIndex],
                    v2: leftOffsets[nextIndex],
                    v3: rightOffsets[nextIndex],
                    color: polyline.color,
                    u0: uByPoint[segmentIndex],
                    u1: uByPoint[nextIndex]
                )
            }
        }
        if vertices.isEmpty { return }
        guard let buffer = frame.engineContext.device.makeBuffer(bytes: vertices,
                                                                 length: DebugLineVertex.stride(vertices.count),
                                                                 options: [.storageModeShared]) else { return }
        let size = RenderPassHelpers.textureSize(worldDebug)
        let pass = RenderPassBuilder.color(texture: worldDebug, clearColor: MTLClearColorMake(0, 0, 0, 0))
        guard let encoder = frame.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Debug Draw"
        RenderPassHelpers.setViewport(encoder, size)
        encoder.setRenderPipelineState(frame.engineContext.graphics.renderPipelineStates[.DebugLines])
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(buffer, offset: 0, index: VertexBufferIndex.vertices)
        var constants = sceneConstants
        if !frame.frameContext.iblReady() { constants.cameraPositionAndIBL.w = 0.0 }
        let constantsBuffer = frame.frameContext.uploadSceneConstants(constants)
        encoder.setVertexBuffer(constantsBuffer, offset: 0, index: VertexBufferIndex.sceneConstants)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
    }
}

final class SelectionOutlinePass: RenderGraphPass {
    let name = "SelectionOutlinePass"
    let inputs: [RenderPassResourceUsage] = [
        .texture(.pickId, expectedFormat: .r32Uint)
    ]
    let outputs: [RenderPassResourceUsage] = [
        .texture(.outlineMask, expectedFormat: .r8Unorm)
    ]

    func execute(frame: RenderGraphFrame) {
        OutlineSystem.encodeSelectionOutline(frame: frame)
    }
}

final class HeightFogPass: RenderGraphPass {
    let name = "HeightFogPass"
    let inputs: [RenderPassResourceUsage] = [
        .namedTexture(RenderNamedResourceKey.sceneColor),
        .namedTexture(RenderNamedResourceKey.sceneDepth)
    ]
    let outputs: [RenderPassResourceUsage] = [
        .namedTexture(RenderNamedResourceKey.sceneColorFogged)
    ]

    func execute(frame: RenderGraphFrame) {
        let surfaces = CanonicalScreenSpaceTextures(registry: frame.resourceRegistry)
        let postSceneColorChain = surfaces.postSceneColorChain(heightFogEnabled: frame.renderPlan.heightFogEnabled)
        guard
            frame.renderPlan.heightFogEnabled,
            let sceneTexture = postSceneColorChain.baseSceneColor,
            let sceneDepth = surfaces.sceneDepth,
            let foggedSceneTexture = postSceneColorChain.foggedSceneColor
        else { return }

        let target = FullscreenTarget(texture: foggedSceneTexture)
        let pass = FullscreenPass(
            pipeline: .HeightFog,
            label: "Height Fog",
            inputs: PostProcessInputs(
                sampler: .LinearClampToZero,
                source: sceneTexture,
                sceneDepth: sceneDepth,
                environmentIrradiance: frame.frameContext.iblTextures().irradiance
                    ?? frame.engineContext.fallbackTextures.blackCubemap,
                settings: frame.frameContext.rendererSettings()
            )
        )
        _ = pass.encode(frame: frame, target: target)
    }
}

final class ExposureComputeEncoder {
    private var histogramPipeline: MTLComputePipelineState?
    private var reductionPipeline: MTLComputePipelineState?

    func encode(commandBuffer: MTLCommandBuffer,
                sceneTexture: MTLTexture,
                sceneDepth: MTLTexture,
                meteringMask: MTLTexture,
                resources inputResources: ExposureFrameResources,
                engineContext: EngineContext) {
        var resources = inputResources
        guard resources.automatic,
              let histogramPipeline = resolvePipeline(name: "kernel_exposure_histogram",
                                                       cached: &histogramPipeline,
                                                       engineContext: engineContext),
              let reductionPipeline = resolvePipeline(name: "kernel_exposure_reduce",
                                                       cached: &reductionPipeline,
                                                       engineContext: engineContext) else { return }

        resources.meteringUniforms.viewportWidth = UInt32(sceneTexture.width)
        resources.meteringUniforms.viewportHeight = UInt32(sceneTexture.height)
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "Exposure Histogram Clear"
            blit.fill(buffer: resources.histogramBuffer,
                      range: 0..<resources.histogramBuffer.length,
                      value: 0)
            blit.endEncoding()
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "Exposure Histogram + Reduction"
        encoder.pushDebugGroup("Exposure Histogram")
        encoder.setComputePipelineState(histogramPipeline)
        encoder.setTexture(sceneTexture, index: 0)
        encoder.setTexture(sceneDepth, index: 1)
        encoder.setTexture(meteringMask, index: 2)
        encoder.setSamplerState(engineContext.graphics.samplerStates[.LinearClampToZero], index: 0)
        encoder.setBuffer(resources.histogramBuffer, offset: 0, index: 0)
        var uniforms = resources.meteringUniforms
        encoder.setBytes(&uniforms, length: ExposureMeteringUniforms.stride, index: 1)
        let sampleWidth = (sceneTexture.width + 3) / 4
        let sampleHeight = (sceneTexture.height + 3) / 4
        encoder.dispatchThreads(MTLSize(width: sampleWidth, height: sampleHeight, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.popDebugGroup()
        encoder.pushDebugGroup("Exposure Reduction")
        encoder.setComputePipelineState(reductionPipeline)
        encoder.setBuffer(resources.histogramBuffer, offset: 0, index: 0)
        encoder.setBytes(&uniforms, length: ExposureMeteringUniforms.stride, index: 1)
        encoder.setBuffer(resources.outputBuffer, offset: 0, index: 2)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.popDebugGroup()
        encoder.endEncoding()
    }

    private func resolvePipeline(name: String,
                                 cached: inout MTLComputePipelineState?,
                                 engineContext: EngineContext) -> MTLComputePipelineState? {
        if let cached { return cached }
        guard let function = engineContext.resources.resolveFunction(
            name,
            device: engineContext.device,
            fallbackLibrary: engineContext.defaultLibrary
        ) else {
            engineContext.log.logWarning("Exposure compute function '\(name)' not found.", category: .renderer)
            return nil
        }
        do {
            let pipeline = try engineContext.device.makeComputePipelineState(function: function)
            cached = pipeline
            return pipeline
        } catch {
            engineContext.log.logWarning("Failed to create exposure compute pipeline '\(name)': \(error)", category: .renderer)
            return nil
        }
    }
}

final class AutoExposurePass: RenderGraphPass {
    let name = "AutoExposurePass"
    let inputs: [RenderPassResourceUsage] = [
        .namedTexture(RenderNamedResourceKey.sceneColor),
        .namedTexture(RenderNamedResourceKey.sceneColorFogged),
        .namedTexture(RenderNamedResourceKey.sceneDepth)
    ]
    // Histogram/output buffers are renderer-owned, per-view temporal resources rather
    // than graph-global resources, so this pass deliberately has no registry output.
    let outputs: [RenderPassResourceUsage] = []

    private let computeEncoder = ExposureComputeEncoder()

    func execute(frame: RenderGraphFrame) {
        let surfaces = CanonicalScreenSpaceTextures(registry: frame.resourceRegistry)
        let postSceneColorChain = surfaces.postSceneColorChain(heightFogEnabled: frame.renderPlan.heightFogEnabled)
        guard frame.renderPlan.autoExposureEnabled,
              let sceneTexture = postSceneColorChain.activeSceneColor,
              let sceneDepth = surfaces.sceneDepth,
              let resources = frame.frameContext.exposureFrameResources() else { return }
        computeEncoder.encode(commandBuffer: frame.commandBuffer,
                              sceneTexture: sceneTexture,
                              sceneDepth: sceneDepth,
                              meteringMask: resources.resolvedPolicy.settings.meteringMaskHandle
                                  .flatMap { frame.engineContext.assets.texture(handle: $0) }
                                  ?? frame.engineContext.fallbackTextures.whiteRGBA,
                              resources: resources,
                              engineContext: frame.engineContext)
    }
}

final class BloomExtractPass: RenderGraphPass {
    let name = "BloomExtractPass"
    let allowedDoubleWriteOutputs: Set<RenderResourceHandle> = [
        .texture(RenderTextureHandle(key: .bloomPing))
    ]
    let inputs: [RenderPassResourceUsage] = [
        .namedTexture(RenderNamedResourceKey.sceneColor),
        .namedTexture(RenderNamedResourceKey.sceneColorFogged)
    ]
    let outputs: [RenderPassResourceUsage] = [
        .texture(.bloomPing)
    ]

    func execute(frame: RenderGraphFrame) {
        let settings = frame.frameContext.rendererSettings()
        let surfaces = CanonicalScreenSpaceTextures(registry: frame.resourceRegistry)
        let postSceneColorChain = surfaces.postSceneColorChain(heightFogEnabled: frame.renderPlan.heightFogEnabled)
        guard
            let sceneTex = postSceneColorChain.activeSceneColor,
            let ping = frame.resourceRegistry.texture(.bloomPing)
        else { return }

        let extractStart = CACurrentMediaTime()
        let frameIndex = frame.frameContext.currentFrameIndex()
        let target = FullscreenTarget(texture: ping)
        let size0 = target.size
        var params = settings
        params.bloomTexelSize = SIMD2<Float>(1.0 / size0.x, 1.0 / size0.y)
        params.bloomMipLevel = 0
        let pass = FullscreenPass(
            pipeline: .BloomExtract,
            label: "Bloom Extract",
            inputs: PostProcessInputs(
                sampler: .LinearClampToZero,
                source: sceneTex,
                settings: params
            )
        )
        guard pass.encode(
            frame: frame,
            target: target,
            beforeEncoding: { encoder in
                frame.profiler.sampleGpuPassBegin(.bloomExtract, encoder: encoder, frameIndex: frameIndex)
            },
            afterEncoding: { encoder in
                frame.profiler.sampleGpuPassEnd(.bloomExtract, encoder: encoder, frameIndex: frameIndex)
            }
        ) else { return }
        frame.profiler.record(.bloomExtract, seconds: CACurrentMediaTime() - extractStart)
    }
}

final class BloomBlurPass: RenderGraphPass {
    let name = "BloomBlurPass"
    let allowedDoubleWriteOutputs: Set<RenderResourceHandle> = [
        .texture(RenderTextureHandle(key: .bloomPing)),
        .texture(RenderTextureHandle(key: .bloomPong))
    ]
    let inputs: [RenderPassResourceUsage] = [
        .texture(.bloomPing),
        .texture(.bloomPong)
    ]
    let outputs: [RenderPassResourceUsage] = [
        .texture(.bloomPing),
        .texture(.bloomPong)
    ]

    func execute(frame: RenderGraphFrame) {
        let settings = frame.frameContext.rendererSettings()
        guard
            let ping = frame.resourceRegistry.texture(.bloomPing),
            let pong = frame.resourceRegistry.texture(.bloomPong),
            let quadMesh = frame.engineContext.assets.mesh(handle: BuiltinAssets.fullscreenQuadMesh)
        else { return }

        let maxBloomMips = max(1, Int(settings.bloomMaxMips))
        let mipCount = min(maxBloomMips, ping.mipmapLevelCount)
        if mipCount == 0 { return }

        var blurTotal: Double = 0
        var downsampleTotal: Double = 0

        let frameIndex = frame.frameContext.currentFrameIndex()
        var didSampleBegin = false
        var didSampleEnd = false

        // Build bloom pyramid from extracted mip0.
        if mipCount > 1 {
            for mip in 1..<mipCount {
                let sourceMip = mip - 1
                let target = FullscreenTarget(texture: ping, mipLevel: mip)
                let size = target.size
                var params = settings
                params.bloomMipLevel = Float(sourceMip)

                let downsampleStart = CACurrentMediaTime()
                guard let enc = frame.commandBuffer.makeRenderCommandEncoder(descriptor: target.renderPassDescriptor()) else { return }
                RenderPassHelpers.setViewport(enc, size)
                let pass = FullscreenPass(
                    pipeline: .BloomDownsample,
                    label: "Bloom Downsample \(mip)",
                    inputs: PostProcessInputs(
                        sampler: .LinearClampToZero,
                        source: ping,
                        settings: params
                    )
                )
                pass.encode(into: enc, quad: quadMesh, frameContext: frame.frameContext, graphics: frame.engineContext.graphics)
                enc.endEncoding()
                downsampleTotal += CACurrentMediaTime() - downsampleStart
            }
        }

        // Dual-filter upsample: fold low mips back into higher mips.
        if mipCount > 1 {
            for mip in stride(from: mipCount - 2, through: 0, by: -1) {
                let target = FullscreenTarget(texture: pong, mipLevel: mip)
                let size = target.size
                var params = settings
                let blurStart = CACurrentMediaTime()
                params.bloomMipLevel = Float(mip)
                guard let enc = frame.commandBuffer.makeRenderCommandEncoder(descriptor: target.renderPassDescriptor()) else { return }
                RenderPassHelpers.setViewport(enc, size)
                if !didSampleBegin {
                    frame.profiler.sampleGpuPassBegin(.bloomBlur, encoder: enc, frameIndex: frameIndex)
                    didSampleBegin = true
                }
                let upsample = FullscreenPass(
                    pipeline: .BloomBlurH,
                    label: "Bloom Upsample \(mip)",
                    inputs: PostProcessInputs(
                        sampler: .LinearClampToZero,
                        source: ping,
                        bloom: ping,
                        settings: params
                    )
                )
                upsample.encode(into: enc, quad: quadMesh, frameContext: frame.frameContext, graphics: frame.engineContext.graphics)
                if mip == 0, !didSampleEnd {
                    frame.profiler.sampleGpuPassEnd(.bloomBlur, encoder: enc, frameIndex: frameIndex)
                    didSampleEnd = true
                }
                enc.endEncoding()

                // Persist current upsample result back into ping for the next higher mip.
                guard let blit = frame.commandBuffer.makeBlitCommandEncoder() else { return }
                blit.label = "Bloom Upsample Copy \(mip)"
                let copyWidth = max(1, ping.width >> mip)
                let copyHeight = max(1, ping.height >> mip)
                blit.copy(
                    from: pong,
                    sourceSlice: 0,
                    sourceLevel: mip,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
                    to: ping,
                    destinationSlice: 0,
                    destinationLevel: mip,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                blit.endEncoding()

                if mipCount == 2 && mip == 0 && !didSampleEnd {
                    didSampleEnd = true
                }
                blurTotal += CACurrentMediaTime() - blurStart
            }
        } else if !didSampleEnd {
            didSampleEnd = true
        }

        if downsampleTotal > 0 {
            frame.profiler.record(.bloomDownsample, seconds: downsampleTotal)
        }
        if blurTotal > 0 {
            frame.profiler.record(.bloomBlur, seconds: blurTotal)
        }
    }
}

final class FinalCompositePass: RenderGraphPass {
    let name = "FinalCompositePass"
    let inputs: [RenderPassResourceUsage] = [
        .namedTexture(RenderNamedResourceKey.sceneColor),
        .namedTexture(RenderNamedResourceKey.sceneColorFogged),
        .texture(.bloomPing),
        .texture(.outlineMask),
        .texture(.gridColor),
        .texture(.worldDebugColor),
        .namedTexture(RenderNamedResourceKey.ssaoRaw),
        .namedTexture(RenderNamedResourceKey.ssaoFiltered),
        .namedTexture(RenderNamedResourceKey.postFinalColor)
    ]
    let outputs: [RenderPassResourceUsage] = [
        .namedTexture(RenderNamedResourceKey.postFinalColor)
    ]

    func execute(frame: RenderGraphFrame) {
        let surfaces = CanonicalScreenSpaceTextures(registry: frame.resourceRegistry)
        let postSceneColorChain = surfaces.postSceneColorChain(heightFogEnabled: frame.renderPlan.heightFogEnabled)
        let settings = frame.frameContext.rendererSettings()
        guard
            let sceneColor = postSceneColorChain.activeSceneColor,
            let bloom = frame.resourceRegistry.texture(.bloomPing),
            let outline = frame.resourceRegistry.texture(.outlineMask),
            let grid = frame.resourceRegistry.texture(.gridColor),
            let worldDebug = frame.resourceRegistry.texture(.worldDebugColor),
            let finalColor = surfaces.finalColor
        else { return }

        let compositeStart = CACurrentMediaTime()
        let frameIndex = frame.frameContext.currentFrameIndex()
        let target = FullscreenTarget(texture: finalColor)
        let showEditorOverlays = frame.renderPlan.showEditorOverlays
        let aoDebugEnabled = settings.ssaoEnabled != 0
        let compositeInputs = FinalCompositeInputs(
            surfaces: surfaces,
            sceneColor: sceneColor,
            bloom: bloom,
            outlineMask: showEditorOverlays ? outline : nil,
            grid: showEditorOverlays ? grid : nil,
            worldDebug: (showEditorOverlays && frame.renderPlan.worldDebugEnabled) ? worldDebug : nil,
            includeSceneDepth: true,
            includeSceneNormals: true,
            includeSSAO: aoDebugEnabled,
            settings: settings
        )
        let pass = FullscreenPass(
            pipeline: .Final,
            label: "Final Composite",
            inputs: compositeInputs.postProcessInputs()
        )
        guard pass.encode(
            frame: frame,
            target: target,
            beforeEncoding: { encoder in
                frame.profiler.sampleGpuPassBegin(.finalComposite, encoder: encoder, frameIndex: frameIndex)
            },
            afterEncoding: { encoder in
                frame.profiler.sampleGpuPassEnd(.finalComposite, encoder: encoder, frameIndex: frameIndex)
            }
        ) else { return }
        frame.profiler.record(.composite, seconds: CACurrentMediaTime() - compositeStart)
    }
}
