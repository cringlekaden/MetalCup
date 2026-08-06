/// Renderer.swift
/// Renderer entry point and frame orchestration.
/// Created by Kaden Cringle

import MetalKit
import Foundation
import simd
import QuartzCore
import Foundation

public enum RenderPassType {
    case main
    case normal
    case ssaoNormal
    case transparent
    case picking
    case depthPrepass
    case shadow
}

public final class Renderer: NSObject {
    public let engineContext: EngineContext
    public var delegate: RendererDelegate?
    public var inputAccumulator: InputAccumulator?
    public var settings: RendererSettings {
        get { engineContext.rendererSettings }
        set { engineContext.rendererSettings = newValue }
    }
    public let profiler = RendererProfiler()

    private let _projection = float4x4(perspectiveFov: .pi / 2, aspect: 1.0, nearZ: 0.1, farZ: 10.0)
    private var _lastPerfFlags: UInt32 = 0
    private let _renderResources: RenderResources
    private let _renderGraph = RenderGraph()
    private let _frameContextStorage: RendererFrameContextStorage
    private let _skyRebuildFrameContextStorage: RendererFrameContextStorage
    private let _reflectionProbeCaptureFrameContextStorage: RendererFrameContextStorage
    let shadowRenderer: ShadowRenderer
    private var _lastFrameTimestamp: TimeInterval?
    private var _frameCount: UInt64 = 0
    private let _maxFramesInFlight = 3
    private let _inFlightSemaphore = DispatchSemaphore(value: 3)
    private var _totalTime: Float = 0.0
    private var _unscaledTotalTime: Float = 0.0
    private var _timeScale: Float = 1.0
    private var _fixedDeltaTime: Float = 1.0 / 60.0
    private let _maxFrameDelta: Float = 0.25
    // MARK: - Shared cubemap views
    // Engine convention reference:
    // - World space uses +Y as up. Scene cameras look down their local -Z axis through the Metal
    //   right-handed clip path. Directional light direction is the ray direction from light to scene.
    // - Runtime texturecube sampling expects reflection vectors in world space; global IBL samples R
    //   directly, while local reflection probes currently compensate their scene-capture convention
    //   with a Z flip in the PBR shader.
    // - Metal cube slices are intended as +X, -X, +Y, -Y, +Z, -Z. The shader-side
    //   cubeDirectionFromFaceUV helper documents that canonical order. These long-standing capture
    //   views are intentionally left unchanged for diagnostics; any future convention fix must make
    //   Renderer._views, cubeDirectionFromFaceUV, skybox sampling, probe capture, and PBR reflection
    //   sampling agree explicitly.
    private let _views: [float4x4] = [
        float4x4(lookAt: .zero, center: [ 1, 0, 0], up: [0, 1, 0]),
        float4x4(lookAt: .zero, center: [-1, 0, 0], up: [0, 1, 0]),
        float4x4(lookAt: .zero, center: [ 0, 1, 0], up: [0, 0, 1]),
        float4x4(lookAt: .zero, center: [ 0,-1, 0], up: [0, 0,-1]),
        float4x4(lookAt: .zero, center: [ 0, 0,-1], up: [0, 1, 0]),
        float4x4(lookAt: .zero, center: [ 0, 0, 1], up: [0, 1, 0])
    ]
    private var _viewProjections: [float4x4]!
    private let _environmentSize = 2048
    private let _irradianceSize = 64
    private let _prefilteredSize = 1024
    private let _environmentSizeFast = 512
    private let _irradianceSizeFast = 32
    private let _prefilteredSizeFast = 256
    private let _brdfLutSize = 512
    private let _diagnosticEnvironmentSize = 512
    private let _diagnosticIrradianceSize = 32
    private let _diagnosticPrefilteredSize = 256
    private let _skyRebuildQueue = DispatchQueue(label: "MetalCup.Renderer.SkyRebuild", qos: .userInitiated)
    private let _environmentIBLCommandQueue: MTLCommandQueue
    private let _skyRebuildCooldown: Double = 2.0
    private let _environmentIBLEditDebounce: Double = 0.75
    private let _skyInteractiveSettleDelay: Double = 4.0
    private var _skyRebuildInFlight = false
    private var _lastSkyRequestedSnapshot: SkyLightComponent?
    private var _lastSkyLiveSnapshot: SkyLightComponent?
    private var _lastSkyLiveUpdateTime: Double = 0.0
    private var _lastSkyRebuildStartTime: Double = 0.0
    private var _lastSkyInteractionTime: Double = 0.0
    private var _pendingSkySnapshot: SkyLightComponent?
    private var _pendingEnvironmentRenderState: EnvironmentRenderState?
    private var _diagnosticOrientationIBLGenerated = false
    private var _didLogMoonAlbedoResolution = false
    private var _didLogMilkyWayResolution = false
    private var _didLogCloudAtlasResolution = false

    private struct EnvironmentIBLRebuildRequest {
        let entity: Entity
        let signature: EnvironmentIBLSignature
        let sourceMode: EnvironmentSourceMode
        let hdriTexture: MTLTexture?
        let moonAlbedoTexture: MTLTexture?
        let galaxyTexture: MTLTexture?
        let cloudAtlasTexture: MTLTexture?
        let skyParams: SkyParams
        let targetHandles: IBLTextureHandles
        let targetEnvironment: MTLTexture
        let targetIrradiance: MTLTexture
        let targetPrefiltered: MTLTexture
        let generationConfig: IBLGenerationConfig
        let quality: EnvironmentIBLRebuildQuality
        let requestedAt: Double
        let manual: Bool
    }

    private struct EnvironmentIBLRebuildResult {
        let entity: Entity
        let signature: EnvironmentIBLSignature
        let handles: IBLTextureHandles
        let quality: EnvironmentIBLRebuildQuality
        let completedAt: Double
    }

    private struct EnvironmentIBLRebuildFailure {
        let entity: Entity
        let signature: EnvironmentIBLSignature
        let message: String
    }

    private enum EnvironmentIBLRebuildCompletion {
        case success(EnvironmentIBLRebuildResult)
        case failure(EnvironmentIBLRebuildFailure)
    }

    private let _environmentIBLCompletionLock = NSLock()
    private var _pendingEnvironmentIBLCompletions: [EnvironmentIBLRebuildCompletion] = []

    private struct IBLTextureHandles {
        let environment: AssetHandle
        let irradiance: AssetHandle
        let prefiltered: AssetHandle
        let brdf: AssetHandle
    }

    private var _iblHandleSets: [IBLTextureHandles] = []
    private var _iblFastHandles: IBLTextureHandles?
    private var _activeIBLHandleIndex = 0
    private var _brdfPipelineStateByFormat: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    // Runtime-only probe capture state lives in a dedicated manager so authored ECS data stays separate.
    private lazy var _reflectionProbeRuntimeManager = ReflectionProbeRuntimeManager(
        engineContext: engineContext,
        projection: _projection,
        captureViews: _views,
        captureFrameContextStorage: _reflectionProbeCaptureFrameContextStorage,
        renderResourceRegistryBuilder: { [unowned self] in
            self._renderResources.buildRegistry()
        },
        rendererSettingsProvider: { [unowned self] in
            self.settings
        },
        assetStateRevisionProvider: { [unowned self] in
            self.engineContext.assets.cacheRevisionToken()
        },
        prefilterRenderer: { [unowned self] sourceEnvironment, targetPrefiltered, frameContext, commandBuffer in
            self.renderPrefilteredSpecularMap(
                sourceEnvironment: sourceEnvironment,
                targetPrefiltered: targetPrefiltered,
                config: self.iblConfig(mode: .final),
                frameContext: frameContext,
                commandBuffer: commandBuffer
            )
        }
    )

    // MARK: - Static sizes

    public private(set) var screenSize = SIMD2<Float>(0, 0)
    public private(set) var drawableSize = SIMD2<Float>(0, 0)
    public private(set) var viewportSize = SIMD2<Float>(0, 0)
    public var aspectRatio: Float {
        let size = (viewportSize.x > 0 && viewportSize.y > 0) ? viewportSize : screenSize
        return size.y.isZero ? 1 : size.x / size.y
    }

    // MARK: - Init

    init(_ mtkView: MTKView, engineContext: EngineContext) {
        self.engineContext = engineContext
        self._renderResources = RenderResources(
            preferences: engineContext.preferences,
            settingsProvider: { engineContext.rendererSettings },
            settingsUpdater: { updated in engineContext.rendererSettings = updated },
            assetManager: engineContext.assets,
            device: engineContext.device
        )
        self._frameContextStorage = RendererFrameContextStorage(engineContext: engineContext)
        self._skyRebuildFrameContextStorage = RendererFrameContextStorage(engineContext: engineContext)
        self._reflectionProbeCaptureFrameContextStorage = RendererFrameContextStorage(engineContext: engineContext)
        self._environmentIBLCommandQueue = engineContext.device.makeCommandQueue() ?? engineContext.commandQueue
        self.shadowRenderer = ShadowRenderer(engineContext: engineContext)
        super.init()
        self._lastPerfFlags = settings.perfFlags
        _viewProjections = _views.map { _projection * $0 }
        updateScreenSize(view: mtkView) // builds render targets + base pass desc
        let iblAllocationStart = CACurrentMediaTime()
        BuiltinAssets.registerIBLTextures(
            assetManager: engineContext.assets,
            preferences: engineContext.preferences,
            device: engineContext.device,
            environmentSize: _environmentSize,
            irradianceSize: _irradianceSize,
            prefilteredSize: _prefilteredSize,
            brdfLutSize: _brdfLutSize
        )
        _ = ensureBRDFLUTTexture()
        prewarmIBLPipelinesWithTiming()
        BuiltinAssets.registerFallbackIBLTextures(assetManager: engineContext.assets, preferences: engineContext.preferences, device: engineContext.device)
        ensureDiagnosticOrientationIBLTextures()
        renderDiagnosticOrientationIBL(frameContext: _skyRebuildFrameContextStorage.beginFrame())
        let builtinHandles = IBLTextureHandles(
            environment: BuiltinAssets.environmentCubemap,
            irradiance: BuiltinAssets.irradianceCubemap,
            prefiltered: BuiltinAssets.prefilteredCubemap,
            brdf: BuiltinAssets.brdfLut
        )
        let alternateHandles = IBLTextureHandles(
            environment: AssetHandle(),
            irradiance: AssetHandle(),
            prefiltered: AssetHandle(),
            brdf: BuiltinAssets.brdfLut
        )
        _iblHandleSets = [builtinHandles, alternateHandles]
        _activeIBLHandleIndex = 0
        ensureIBLTextureSet(handles: alternateHandles)
        let fastHandles = IBLTextureHandles(
            environment: AssetHandle(),
            irradiance: AssetHandle(),
            prefiltered: AssetHandle(),
            brdf: BuiltinAssets.brdfLut
        )
        _iblFastHandles = fastHandles
        ensureIBLTextureSet(
            handles: fastHandles,
            environmentSize: _environmentSizeFast,
            irradianceSize: _irradianceSizeFast,
            prefilteredSize: _prefilteredSizeFast,
            labelSuffix: "Fast"
        )
        _lastSkyInteractionTime = CACurrentMediaTime()
        let iblAllocationEnd = CACurrentMediaTime()
        EngineLoggerContext.log(
            "IBL resource allocation/prewarm dt=\(String(format: "%.3f", iblAllocationEnd - iblAllocationStart))s",
            level: .debug,
            category: .renderer
        )
        let frameContext = _frameContextStorage.beginFrame()
        _frameContextStorage.updateRendererState(
            settings: settings,
            viewContext: RenderViewContext()
        )
        renderBRDFLUT(frameContext: frameContext)
    }

    // MARK: - IBL generation config

    private struct IBLGenerationConfig {
        var qualityPreset: IBLQualityPreset
        var irradianceSamples: UInt32
        var prefilterSamplesMin: UInt32
        var prefilterSamplesMax: UInt32
        var fireflyClamp: Float
        var fireflyClampEnabled: Bool
        var samplingStrategy: String
    }

    private typealias IBLBuildMode = EnvironmentIBLRebuildQuality

    // MARK: - Render pass descriptor helpers
    private func makeRenderPassDescriptor(
        colorTarget: AssetHandle,
        depthTarget: AssetHandle? = nil,
        slice: Int? = nil,
        level: Int = 0,
        depthLoadAction: MTLLoadAction = .clear
    ) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = engineContext.assets.texture(handle: colorTarget)
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = ClearColor.Black
        pass.colorAttachments[0].level = level
        if let slice {
            pass.colorAttachments[0].slice = slice
        }
        if let depthTarget {
            pass.depthAttachment.texture = engineContext.assets.texture(handle: depthTarget)
            pass.depthAttachment.loadAction = depthLoadAction
            pass.depthAttachment.storeAction = .store
        }
        return pass
    }

    private func makeRenderPassDescriptor(
        colorTexture: MTLTexture,
        depthTexture: MTLTexture? = nil,
        slice: Int? = nil,
        level: Int = 0,
        depthLoadAction: MTLLoadAction = .clear
    ) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = ClearColor.Black
        pass.colorAttachments[0].level = level
        if let slice {
            pass.colorAttachments[0].slice = slice
        }
        if let depthTexture {
            pass.depthAttachment.texture = depthTexture
            pass.depthAttachment.loadAction = depthLoadAction
            pass.depthAttachment.storeAction = .store
        }
        return pass
    }

    private func createColorOnlyRenderPassDescriptor(colorTarget: AssetHandle) -> MTLRenderPassDescriptor {
        makeRenderPassDescriptor(colorTarget: colorTarget)
    }

    private func createCubemapRenderPassDescriptor(target: AssetHandle, face: Int) -> MTLRenderPassDescriptor {
        makeRenderPassDescriptor(colorTarget: target, slice: face, level: 0)
    }

    private func createMippedCubemapRenderPassDescriptor(target: AssetHandle, face: Int, mip: Int) -> MTLRenderPassDescriptor {
        makeRenderPassDescriptor(colorTarget: target, slice: face, level: mip)
    }

    private func createCubemapRenderPassDescriptor(texture: MTLTexture, face: Int) -> MTLRenderPassDescriptor {
        makeRenderPassDescriptor(colorTexture: texture, slice: face, level: 0)
    }

    private func createMippedCubemapRenderPassDescriptor(texture: MTLTexture, face: Int, mip: Int) -> MTLRenderPassDescriptor {
        makeRenderPassDescriptor(colorTexture: texture, slice: face, level: mip)
    }

    // MARK: - IBL generation
    private func iblQualityPreset() -> IBLQualityPreset {
        return IBLQualityPreset(rawValue: settings.iblQualityPreset) ?? .high
    }

    private func iblSampleMultiplier(for preset: IBLQualityPreset) -> Float {
        switch preset {
        case .low:
            return 0.25
        case .medium:
            return 0.5
        case .high:
            return 1.0
        case .ultra:
            return 2.0
        case .custom:
            return max(settings.iblSampleMultiplier, 0.1)
        }
    }

    private func iblConfig(mode: IBLBuildMode) -> IBLGenerationConfig {
        let preset = iblQualityPreset()
        let multiplier = iblSampleMultiplier(for: preset)
        let modeScale: Float = (mode == .interactive) ? 0.2 : 1.0
        let irradianceSamples = UInt32(max(128.0, min(8192.0, modeScale * multiplier * 2048.0)))
        let prefilterBase = max(64.0, min(4096.0, modeScale * multiplier * 1024.0))
        let minSamples = UInt32(max(64.0, min(1024.0, prefilterBase * 0.20)))
        let maxSamples = UInt32(max(128.0, min(4096.0, prefilterBase)))
        return IBLGenerationConfig(
            qualityPreset: preset,
            irradianceSamples: irradianceSamples,
            prefilterSamplesMin: minSamples,
            prefilterSamplesMax: maxSamples,
            fireflyClamp: settings.iblFireflyClamp,
            fireflyClampEnabled: settings.iblFireflyClampEnabled != 0,
            samplingStrategy: mode == .interactive
                ? "interactive reduced-sample cosine + GGX"
                : "cosine + GGX importance sampling"
        )
    }

    private func iblMipCount(for size: Int) -> Int {
        guard size > 0 else { return 1 }
        return Int(floor(log2(Double(size)))) + 1
    }

    private func makeCubemapTexture(size: Int, mipmapped: Bool, label: String) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.textureCubeDescriptor(
            pixelFormat: engineContext.preferences.HDRPixelFormat,
            size: size,
            mipmapped: mipmapped
        )
        if mipmapped {
            descriptor.mipmapLevelCount = iblMipCount(for: size)
        }
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = engineContext.device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = label
        return texture
    }

    private func makeDepthTexture(size: Int, label: String) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: engineContext.preferences.defaultDepthPixelFormat,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        guard let texture = engineContext.device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = label
        return texture
    }

    private func ensureIBLTextureSet(handles: IBLTextureHandles) {
        ensureIBLTextureSet(
            handles: handles,
            environmentSize: _environmentSize,
            irradianceSize: _irradianceSize,
            prefilteredSize: _prefilteredSize,
            labelSuffix: "Next"
        )
    }

    private func ensureIBLTextureSet(
        handles: IBLTextureHandles,
        environmentSize: Int,
        irradianceSize: Int,
        prefilteredSize: Int,
        labelSuffix: String
    ) {
        if engineContext.assets.texture(handle: handles.environment) == nil,
           let env = makeCubemapTexture(size: environmentSize, mipmapped: true, label: "IBL.EnvironmentCubemap.\(labelSuffix)") {
            engineContext.assets.registerRuntimeTexture(handle: handles.environment, texture: env)
        }
        if engineContext.assets.texture(handle: handles.irradiance) == nil,
           let irr = makeCubemapTexture(size: irradianceSize, mipmapped: false, label: "IBL.IrradianceCubemap.\(labelSuffix)") {
            engineContext.assets.registerRuntimeTexture(handle: handles.irradiance, texture: irr)
        }
        if engineContext.assets.texture(handle: handles.prefiltered) == nil,
           let pre = makeCubemapTexture(size: prefilteredSize, mipmapped: true, label: "IBL.PrefilteredCubemap.\(labelSuffix)") {
            engineContext.assets.registerRuntimeTexture(handle: handles.prefiltered, texture: pre)
        }
    }

    private func ensureDiagnosticOrientationIBLTextures() {
        let handles = IBLTextureHandles(
            environment: BuiltinAssets.diagnosticOrientationCubemap,
            irradiance: BuiltinAssets.diagnosticOrientationIrradianceCubemap,
            prefiltered: BuiltinAssets.diagnosticOrientationPrefilteredCubemap,
            brdf: BuiltinAssets.brdfLut
        )
        ensureIBLTextureSet(
            handles: handles,
            environmentSize: _diagnosticEnvironmentSize,
            irradianceSize: _diagnosticIrradianceSize,
            prefilteredSize: _diagnosticPrefilteredSize,
            labelSuffix: "DiagnosticOrientation"
        )
    }

    private func renderDiagnosticOrientationCubemap(targetEnvironment: MTLTexture,
                                                    frameContext: RendererFrameContext,
                                                    commandBuffer: MTLCommandBuffer) {
        guard let quadMesh = engineContext.assets.mesh(handle: BuiltinAssets.fullscreenQuadMesh) else { return }
        validateIBLResources(environment: targetEnvironment, irradiance: nil, prefiltered: nil)
        for face in 0..<6 {
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: createCubemapRenderPassDescriptor(texture: targetEnvironment, face: face)) else { continue }
            encoder.label = "Diagnostic Orientation Cubemap face \(face)"
            encoder.setRenderPipelineState(engineContext.graphics.renderPipelineStates[.CubemapOrientationDiagnostic])
            encoder.setCullMode(.none)
            var vp = matrix_identity_float4x4
            encoder.setVertexBytes(&vp, length: MemoryLayout<float4x4>.stride, index: VertexBufferIndex.cubemapViewProjection)
            var cubemapParams = SIMD2<Float>(1.0, Float(face))
            encoder.setFragmentBytes(&cubemapParams, length: MemoryLayout<SIMD2<Float>>.stride, index: FragmentBufferIndex.skyIntensity)
            quadMesh.drawPrimitives(encoder, frameContext: frameContext)
            encoder.endEncoding()
        }
        if targetEnvironment.mipmapLevelCount > 1,
           let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: targetEnvironment)
            blit.endEncoding()
        }
    }

    private func renderDiagnosticOrientationIBL(frameContext: RendererFrameContext) {
        guard !_diagnosticOrientationIBLGenerated else { return }
        ensureDiagnosticOrientationIBLTextures()
        guard let environment = engineContext.assets.texture(handle: BuiltinAssets.diagnosticOrientationCubemap),
              let irradiance = engineContext.assets.texture(handle: BuiltinAssets.diagnosticOrientationIrradianceCubemap),
              let prefiltered = engineContext.assets.texture(handle: BuiltinAssets.diagnosticOrientationPrefilteredCubemap),
              let commandBuffer = engineContext.commandQueue.makeCommandBuffer() else {
            return
        }
        commandBuffer.label = "Render Diagnostic Orientation IBL"
        let config = IBLGenerationConfig(
            qualityPreset: .low,
            irradianceSamples: 256,
            prefilterSamplesMin: 64,
            prefilterSamplesMax: 256,
            fireflyClamp: settings.iblFireflyClamp,
            fireflyClampEnabled: settings.iblFireflyClampEnabled != 0,
            samplingStrategy: "diagnostic orientation"
        )
        renderDiagnosticOrientationCubemap(targetEnvironment: environment, frameContext: frameContext, commandBuffer: commandBuffer)
        renderIrradianceMap(sourceEnvironment: environment, targetIrradiance: irradiance, config: config, frameContext: frameContext, commandBuffer: commandBuffer)
        renderPrefilteredSpecularMap(sourceEnvironment: environment, targetPrefiltered: prefiltered, config: config, frameContext: frameContext, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        _diagnosticOrientationIBLGenerated = true
    }

    public func queueReflectionProbeRebuilds(scene: EngineScene, entities: [Entity]? = nil, force: Bool = false) {
        _reflectionProbeRuntimeManager.queueReflectionProbeRebuilds(scene: scene, entities: entities, force: force)
    }

    public func reflectionProbeBakeStatus(scene: EngineScene, entityID: UUID) -> ReflectionProbeRuntimeStatus? {
        _reflectionProbeRuntimeManager.reflectionProbeBakeStatus(scene: scene, entityID: entityID)
    }

    public func debugReflectionProbeSelection(scene: EngineScene, entityID: UUID) -> ReflectionProbeDebugSelection? {
        _reflectionProbeRuntimeManager.debugReflectionProbeSelection(scene: scene, entityID: entityID)
    }

    private func updateReflectionProbesIfNeeded(scene: EngineScene) {
        _reflectionProbeRuntimeManager.updateReflectionProbesIfNeeded(scene: scene)
    }

    private func applyReflectionProbeRuntimeState(to snapshot: RenderFrameSnapshot,
                                                  scene: EngineScene) -> RenderFrameSnapshot {
        _reflectionProbeRuntimeManager.applyRuntimeState(to: snapshot, scene: scene)
    }

    private func prewarmIBLPipelinesWithTiming() {
        let warmStart = CACurrentMediaTime()
        let cubemapStart = CACurrentMediaTime()
        _ = engineContext.graphics.renderPipelineStates[.Cubemap]
        _ = engineContext.graphics.renderPipelineStates[.CubemapOrientationDiagnostic]
        let cubemapDt = CACurrentMediaTime() - cubemapStart
        let irradianceStart = CACurrentMediaTime()
        _ = engineContext.graphics.renderPipelineStates[.IrradianceMap]
        let irradianceDt = CACurrentMediaTime() - irradianceStart
        let prefilteredStart = CACurrentMediaTime()
        _ = engineContext.graphics.renderPipelineStates[.PrefilteredMap]
        let prefilteredDt = CACurrentMediaTime() - prefilteredStart
        let proceduralStart = CACurrentMediaTime()
        _ = engineContext.graphics.renderPipelineStates[.ProceduralSkyCubemap]
        let proceduralDt = CACurrentMediaTime() - proceduralStart
        let totalDt = CACurrentMediaTime() - warmStart
        EngineLoggerContext.log(
            "IBL pipeline warmup total=\(String(format: "%.3f", totalDt))s [cubemap=\(String(format: "%.3f", cubemapDt))s, irr=\(String(format: "%.3f", irradianceDt))s, pre=\(String(format: "%.3f", prefilteredDt))s, procedural=\(String(format: "%.3f", proceduralDt))s]",
            level: .debug,
            category: .renderer
        )
    }

    private func activeIBLHandles() -> IBLTextureHandles {
        return _iblHandleSets[_activeIBLHandleIndex]
    }

    private func nextIBLHandles() -> IBLTextureHandles {
        let nextIndex = (_activeIBLHandleIndex + 1) % _iblHandleSets.count
        return _iblHandleSets[nextIndex]
    }

    private func skySettingsMatch(_ lhs: SkyLightComponent, _ rhs: SkyLightComponent) -> Bool {
        return !SkySystem.requiresIBLRebuild(previous: lhs, next: rhs)
    }

    private func validateIBLResources(environment: MTLTexture?, irradiance: MTLTexture?, prefiltered: MTLTexture?) {
        if let env = environment {
            MC_ASSERT(env.textureType == .typeCube, "Environment texture must be cubemap.")
            MC_ASSERT(env.mipmapLevelCount >= 1, "Environment texture missing mip levels.")
            MC_ASSERT(env.width == env.height, "Environment texture must be square.")
        }
        if let irr = irradiance {
            MC_ASSERT(irr.textureType == .typeCube, "Irradiance texture must be cubemap.")
        }
        if let pre = prefiltered {
            MC_ASSERT(pre.textureType == .typeCube, "Prefiltered texture must be cubemap.")
            MC_ASSERT(pre.mipmapLevelCount >= 1, "Prefiltered texture missing mip levels.")
            MC_ASSERT(pre.width == pre.height, "Prefiltered texture must be square.")
        }
    }

    private func renderSkyToEnvironmentMap(hdriTexture: MTLTexture, intensity: Float, targetEnvironment: MTLTexture, frameContext: RendererFrameContext, commandBuffer: MTLCommandBuffer) {
        guard let quadMesh = engineContext.assets.mesh(handle: BuiltinAssets.fullscreenQuadMesh) else { return }
        validateIBLResources(environment: targetEnvironment, irradiance: nil, prefiltered: nil)
        for face in 0..<6 {
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: createCubemapRenderPassDescriptor(texture: targetEnvironment, face: face)) else { continue }
            encoder.label = "Cubemap face \(face)"
            encoder.setRenderPipelineState(engineContext.graphics.renderPipelineStates[.Cubemap])
            encoder.setCullMode(.none)
            var vp = matrix_identity_float4x4
            encoder.setVertexBytes(&vp, length: MemoryLayout<float4x4>.stride, index: VertexBufferIndex.cubemapViewProjection)
            var cubemapParams = SIMD2<Float>(max(intensity, 0.0), Float(face))
            encoder.setFragmentBytes(&cubemapParams, length: MemoryLayout<SIMD2<Float>>.stride, index: FragmentBufferIndex.skyIntensity)
            encoder.setFragmentTexture(hdriTexture, index: IBLTextureIndex.environment)
            encoder.setFragmentSamplerState(engineContext.graphics.samplerStates[.LinearClamp], index: FragmentSamplerIndex.linearClamp)
            quadMesh.drawPrimitives(encoder, frameContext: frameContext)
            encoder.endEncoding()
        }
        if targetEnvironment.mipmapLevelCount > 1,
           let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: targetEnvironment)
            blit.endEncoding()
        }
    }

    private func renderIrradianceMap(sourceEnvironment: MTLTexture,
                                     targetIrradiance: MTLTexture,
                                     config: IBLGenerationConfig,
                                     frameContext: RendererFrameContext,
                                     commandBuffer: MTLCommandBuffer) {
        guard let quadMesh = engineContext.assets.mesh(handle: BuiltinAssets.fullscreenQuadMesh) else { return }
        validateIBLResources(environment: sourceEnvironment, irradiance: targetIrradiance, prefiltered: nil)
        for face in 0..<6 {
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: createCubemapRenderPassDescriptor(texture: targetIrradiance, face: face)) else { continue }
            encoder.label = "Irradiance Cubemap face: \(face)"
            encoder.setRenderPipelineState(engineContext.graphics.renderPipelineStates[.IrradianceMap])
            encoder.setCullMode(.none)
            var vp = matrix_identity_float4x4
            encoder.setVertexBytes(&vp, length: MemoryLayout<float4x4>.stride, index: VertexBufferIndex.cubemapViewProjection)
            var params = IBLIrradianceParams()
            params.sampleCount = config.irradianceSamples
            params.fireflyClamp = config.fireflyClamp
            params.fireflyClampEnabled = config.fireflyClampEnabled ? 1 : 0
            params.padding = Float(face)
            encoder.setFragmentBytes(&params, length: IBLIrradianceParams.stride, index: FragmentBufferIndex.iblParams)
            encoder.setFragmentTexture(sourceEnvironment, index: IBLTextureIndex.environment)
            encoder.setFragmentSamplerState(engineContext.graphics.samplerStates[.LinearClamp], index: FragmentSamplerIndex.linearClamp)
            quadMesh.drawPrimitives(encoder, frameContext: frameContext)
            encoder.endEncoding()
        }
    }

    private func renderPrefilteredSpecularMap(sourceEnvironment: MTLTexture,
                                              targetPrefiltered: MTLTexture,
                                              config: IBLGenerationConfig,
                                              frameContext: RendererFrameContext,
                                              commandBuffer: MTLCommandBuffer) {
        let mipCount = targetPrefiltered.mipmapLevelCount
        let baseSize = targetPrefiltered.width
        guard let quadMesh = engineContext.assets.mesh(handle: BuiltinAssets.fullscreenQuadMesh) else { return }
        validateIBLResources(environment: sourceEnvironment, irradiance: nil, prefiltered: targetPrefiltered)
        if sourceEnvironment.mipmapLevelCount > 1, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: sourceEnvironment)
            blit.endEncoding()
        }
        for mip in 0..<mipCount {
            let roughness = Float(mip) / Float(max(mipCount - 1, 1))
            let mipSize = max(1, baseSize >> mip)
            for face in 0..<6 {
                let passDescriptor = createMippedCubemapRenderPassDescriptor(texture: targetPrefiltered, face: face, mip: mip)
                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { continue }
                encoder.label = "Specular face \(face), mip \(mip)"
                encoder.setRenderPipelineState(engineContext.graphics.renderPipelineStates[.PrefilteredMap])
                encoder.setCullMode(.none)
                encoder.setViewport(MTLViewport(
                    originX: 0, originY: 0,
                    width: Double(mipSize), height: Double(mipSize),
                    znear: 0, zfar: 1
                ))
                var vp = matrix_identity_float4x4
                encoder.setVertexBytes(&vp, length: MemoryLayout<float4x4>.stride, index: VertexBufferIndex.cubemapViewProjection)
                var params = IBLPrefilterParams()
                params.roughness = roughness
                params.sampleCount = prefilterSampleCount(for: roughness, mipIndex: mip, mipCount: mipCount, config: config)
                params.fireflyClamp = config.fireflyClamp
                params.fireflyClampEnabled = config.fireflyClampEnabled ? 1 : 0
                params.envMipCount = Float(sourceEnvironment.mipmapLevelCount)
                params.padding = Float(face)
                encoder.setFragmentBytes(&params, length: IBLPrefilterParams.stride, index: FragmentBufferIndex.iblParams)
                encoder.setFragmentTexture(sourceEnvironment, index: IBLTextureIndex.environment)
                encoder.setFragmentSamplerState(engineContext.graphics.samplerStates[.LinearClamp], index: FragmentSamplerIndex.linearClamp)
                quadMesh.drawPrimitives(encoder, frameContext: frameContext)
                encoder.endEncoding()
            }
        }
    }

    private func prefilterSampleCount(for roughness: Float, mipIndex: Int, mipCount: Int, config: IBLGenerationConfig) -> UInt32 {
        let glossyFactor = pow(max(1.0 - roughness, 0.0), 2.0)
        let mipT = Float(mipIndex) / Float(max(mipCount - 1, 1))
        let mipScale = max(0.25, 1.0 - mipT * 0.70)
        let range = max(Float(config.prefilterSamplesMax - config.prefilterSamplesMin), 1.0)
        let samples = Float(config.prefilterSamplesMin) + range * glossyFactor * mipScale
        return UInt32(max(Float(config.prefilterSamplesMin), min(Float(config.prefilterSamplesMax), samples)))
    }

    private func createBRDFLUTTexture(pixelFormat: MTLPixelFormat) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: _brdfLutSize,
            height: _brdfLutSize,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return engineContext.device.makeTexture(descriptor: descriptor)
    }

    private func resolveBRDFLUTPixelFormat() -> MTLPixelFormat {
        if createBRDFLUTTexture(pixelFormat: .rg16Float) != nil {
            return .rg16Float
        }
        if createBRDFLUTTexture(pixelFormat: .rg32Float) != nil {
            return .rg32Float
        }
        return .rg16Float
    }

    @discardableResult
    private func ensureBRDFLUTTexture() -> MTLTexture? {
        let targetFormat = resolveBRDFLUTPixelFormat()
        if let existing = engineContext.assets.texture(handle: BuiltinAssets.brdfLut),
           existing.width == _brdfLutSize,
           existing.height == _brdfLutSize,
           existing.pixelFormat == targetFormat {
            return existing
        }
        guard let texture = createBRDFLUTTexture(pixelFormat: targetFormat) else { return nil }
        texture.label = "IBL.BRDFLUT"
        engineContext.assets.registerRuntimeTexture(handle: BuiltinAssets.brdfLut, texture: texture)
        return texture
    }

    private func brdfPipelineState(for pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        if pixelFormat == .rg16Float {
            return engineContext.graphics.renderPipelineStates[.BRDF]
        }
        if let cached = _brdfPipelineStateByFormat[pixelFormat] {
            return cached
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "BRDF (\(pixelFormat.rawValue))"
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.depthAttachmentPixelFormat = .invalid
        descriptor.vertexFunction = engineContext.graphics.shaders[.FSQuadVertex]
        descriptor.fragmentFunction = engineContext.graphics.shaders[.BRDFFragment]
        descriptor.vertexDescriptor = engineContext.graphics.vertexDescriptors[.Simple]
        guard let state = try? engineContext.device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        _brdfPipelineStateByFormat[pixelFormat] = state
        return state
    }

    private func renderBRDFLUT(frameContext: RendererFrameContext) {
        guard let brdfTexture = ensureBRDFLUTTexture() else { return }
        guard let pipelineState = brdfPipelineState(for: brdfTexture.pixelFormat) else { return }
        guard let commandBuffer = engineContext.commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "Render BRDF LUT"
        let passDescriptor = makeRenderPassDescriptor(colorTexture: brdfTexture)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }
        guard let quadMesh = engineContext.assets.mesh(handle: BuiltinAssets.fullscreenQuadMesh) else { return }
        encoder.label = "BRDF LUT Encoder"
        encoder.setRenderPipelineState(pipelineState)
        encoder.setCullMode(.none)
        quadMesh.drawPrimitives(encoder, frameContext: frameContext)
        encoder.endEncoding()
        commandBuffer.commit()
    }

    private func resolveMoonAlbedoTexture(context: String) -> MTLTexture? {
        resolveBuiltinSkyTexture(
            context: context,
            sourcePath: "Textures/Moon/lroc_color_2k.jpg",
            fallbackHandle: BuiltinAssets.moonAlbedo,
            logPrefix: "Moon albedo",
            didLog: &_didLogMoonAlbedoResolution
        ) {
            BuiltinAssets.registerMoonAlbedoTextureIfNeeded(
                assetManager: engineContext.assets,
                resourcesRootURL: engineContext.resources.resourcesRootURL,
                device: engineContext.device
            )
        }
    }

    private func resolveMilkyWayBackgroundTexture(context: String) -> MTLTexture? {
        resolveBuiltinSkyTexture(
            context: context,
            sourcePath: "Textures/Sky/MilkyWay/milkyway_2020_4k.exr",
            fallbackHandle: BuiltinAssets.milkyWayBackground,
            logPrefix: "Milky Way background",
            didLog: &_didLogMilkyWayResolution
        ) {
            BuiltinAssets.registerMilkyWayBackgroundTextureIfNeeded(
                assetManager: engineContext.assets,
                resourcesRootURL: engineContext.resources.resourcesRootURL,
                device: engineContext.device
            )
        }
    }

    private func resolveCloudAtlasTexture(context: String) -> MTLTexture? {
        resolveBuiltinSkyTexture(
            context: context,
            sourcePath: "Textures/Sky/Clouds/cloud_atlas_4k.png",
            fallbackHandle: BuiltinAssets.cloudAtlas,
            logPrefix: "Cloud atlas",
            didLog: &_didLogCloudAtlasResolution
        ) {
            BuiltinAssets.registerCloudAtlasTextureIfNeeded(
                assetManager: engineContext.assets,
                resourcesRootURL: engineContext.resources.resourcesRootURL,
                device: engineContext.device
            )
        }
    }

    private func resolveBuiltinSkyTexture(context: String,
                                          sourcePath: String,
                                          fallbackHandle: AssetHandle,
                                          logPrefix: String,
                                          didLog: inout Bool,
                                          registerFallback: () -> Void) -> MTLTexture? {
        let sourceHandle = engineContext.assets.handle(forSourcePath: sourcePath)
        let sourceTexture = sourceHandle.flatMap { engineContext.assets.texture(handle: $0) }
        if sourceTexture == nil {
            registerFallback()
        }
        let fallbackTexture = engineContext.assets.texture(handle: fallbackHandle)
        let usedBuiltinFallback = sourceTexture == nil
        let handle = usedBuiltinFallback ? fallbackHandle : (sourceHandle ?? fallbackHandle)
        let texture = sourceTexture ?? fallbackTexture
        if !didLog {
            didLog = true
            let textureSummary: String
            let fallbackHint: Bool
            if let texture {
                let label = texture.label ?? "<nil>"
                let lowerLabel = label.lowercased()
                fallbackHint = lowerLabel.contains("fallback") || lowerLabel.contains("error") || lowerLabel.contains("white")
                textureSummary = "label=\(label) size=\(texture.width)x\(texture.height) pixelFormat=\(texture.pixelFormat) fallbackHint=\(fallbackHint)"
            } else {
                fallbackHint = false
                textureSummary = "nil"
            }
            EngineLoggerContext.log(
                "\(logPrefix) resolve context=\(context) sourcePath=\(sourcePath) sourceLookupSucceeded=\(sourceHandle != nil) sourceTextureAvailable=\(sourceTexture != nil) usedBuiltinFallback=\(usedBuiltinFallback) handle=\(handle.rawValue.uuidString) texture=\(textureSummary)",
                level: .debug,
                category: .renderer
            )
            _ = fallbackHint
        }
        return texture
    }

    private func renderProceduralSkyToEnvironmentMap(params: SkyParams, moonAlbedoTexture: MTLTexture?, galaxyTexture: MTLTexture?, cloudAtlasTexture: MTLTexture?, targetEnvironment: MTLTexture, frameContext: RendererFrameContext, commandBuffer: MTLCommandBuffer) {
        guard let quadMesh = engineContext.assets.mesh(handle: BuiltinAssets.fullscreenQuadMesh) else { return }
        validateIBLResources(environment: targetEnvironment, irradiance: nil, prefiltered: nil)
        for face in 0..<6 {
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: createCubemapRenderPassDescriptor(texture: targetEnvironment, face: face)) else { continue }
            encoder.label = "Procedural Sky face \(face)"
            encoder.setRenderPipelineState(engineContext.graphics.renderPipelineStates[.ProceduralSkyCubemap])
            encoder.setCullMode(.none)
            var vp = matrix_identity_float4x4
            var skyParams = params
            skyParams.cloudAtlasEnabled = cloudAtlasTexture == nil ? 0.0 : skyParams.cloudAtlasEnabled
            var faceIndex = Float(face)
            encoder.setVertexBytes(&vp, length: MemoryLayout<float4x4>.stride, index: VertexBufferIndex.cubemapViewProjection)
            encoder.setFragmentBytes(&skyParams, length: SkyParams.stride, index: FragmentBufferIndex.skyParams)
            encoder.setFragmentBytes(&faceIndex, length: MemoryLayout<Float>.stride, index: FragmentBufferIndex.skyFace)
            encoder.setFragmentTexture(moonAlbedoTexture ?? engineContext.fallbackTextures.whiteRGBA, index: FragmentTextureIndex.moonAlbedo)
            encoder.setFragmentTexture(galaxyTexture ?? engineContext.fallbackTextures.whiteRGBA, index: FragmentTextureIndex.galaxyBackground)
            encoder.setFragmentTexture(cloudAtlasTexture ?? engineContext.fallbackTextures.blackRGBA, index: FragmentTextureIndex.cloudAtlas)
            quadMesh.drawPrimitives(encoder, frameContext: frameContext)
            encoder.endEncoding()
        }
        if targetEnvironment.mipmapLevelCount > 1,
           let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: targetEnvironment)
            blit.endEncoding()
        }
    }

    private func skyParams(from sky: SkyLightComponent,
                           environmentState: EnvironmentStateComponent?) -> SkyParams {
        SkySystem.shaderParams(authored: sky, runtime: environmentState)
    }

    private func resolvedRendererSettings(for scene: EngineScene?) -> RendererSettings {
        var resolved = settings
        if let environmentEntry = scene?.ecs.activeEnvironment() {
            let runtime = scene?.ecs.get(EnvironmentRuntimeStateComponent.self, for: environmentEntry.0)
            let renderState = EnvironmentRenderStateBuilder.build(
                environment: environmentEntry.1,
                runtime: runtime,
                rendererSettings: resolved
            )
            renderState.legacyFogPatch.applying(to: &resolved)
            resolved.iblIntensity = max(0.0, resolved.iblIntensity) * renderState.iblLightingIntensity
            return resolved
        }

        let activeSkyEntry = scene?.ecs.activeSkyLight()
        let environmentState = activeSkyEntry.flatMap { scene?.ecs.get(EnvironmentStateComponent.self, for: $0.0) }
        SkySystem.applyDerivedFogSettings(&resolved,
                                          authored: activeSkyEntry?.1,
                                          runtime: environmentState)
        return resolved
    }

    private func enqueueEnvironmentIBLCompletion(_ completion: EnvironmentIBLRebuildCompletion) {
        _environmentIBLCompletionLock.lock()
        _pendingEnvironmentIBLCompletions.append(completion)
        _environmentIBLCompletionLock.unlock()
    }

    private func takeEnvironmentIBLCompletions() -> [EnvironmentIBLRebuildCompletion] {
        _environmentIBLCompletionLock.lock()
        let completions = _pendingEnvironmentIBLCompletions
        _pendingEnvironmentIBLCompletions.removeAll(keepingCapacity: true)
        _environmentIBLCompletionLock.unlock()
        return completions
    }

    private func drainEnvironmentIBLCompletions(scene: EngineScene) {
        let completions = takeEnvironmentIBLCompletions()
        guard !completions.isEmpty else { return }

        for completion in completions {
            _skyRebuildInFlight = false

            switch completion {
            case let .success(result):
                applyEnvironmentIBLResult(result, scene: scene)
            case let .failure(failure):
                applyEnvironmentIBLFailure(failure, scene: scene)
            }
        }
    }

    private func applyEnvironmentIBLResult(_ result: EnvironmentIBLRebuildResult, scene: EngineScene) {
        guard let entity = scene.ecs.entity(with: result.entity.id),
              let environment = scene.ecs.get(EnvironmentComponent.self, for: entity) else {
            return
        }

        let activeEnvironmentEntity = scene.ecs.activeEnvironment()?.0
        let runtime = scene.ecs.get(EnvironmentRuntimeStateComponent.self, for: entity)
        let currentRenderState = EnvironmentRenderStateBuilder.build(
            environment: environment,
            runtime: runtime,
            rendererSettings: settings
        )
        var state = scene.ecs.get(EnvironmentIBLStateComponent.self, for: entity)
            ?? EnvironmentIBLStateComponent.defaultNeedsRebuild
        let keepManualFinalRequest = state.rebuildRequested && result.quality == .interactive

        if activeEnvironmentEntity == entity, currentRenderState.iblSignature == result.signature {
            if let appliedIndex = _iblHandleSets.firstIndex(where: {
                $0.environment == result.handles.environment
                    && $0.irradiance == result.handles.irradiance
                    && $0.prefiltered == result.handles.prefiltered
            }) {
                _activeIBLHandleIndex = appliedIndex
            }
            state.environmentTexture = result.handles.environment
            state.irradianceTexture = result.handles.irradiance
            state.prefilteredTexture = result.handles.prefiltered
            state.brdfLUT = result.handles.brdf
            state.dirty = false
            state.needsRebuild = false
            state.rebuildRequested = false
            state.isRebuilding = false
            state.lastBuiltSignature = result.signature
            state.currentRebuildQuality = nil
            state.lastBuiltQuality = result.quality
            state.pendingSignature = nil
            state.lastFailureMessage = nil
            if keepManualFinalRequest {
                state.dirty = true
                state.needsRebuild = true
                state.rebuildRequested = true
                state.pendingSignature = currentRenderState.iblSignature
            }
        } else {
            state.dirty = true
            state.needsRebuild = false
            state.isRebuilding = false
            state.currentRebuildQuality = nil
            state.pendingSignature = currentRenderState.iblSignature
            _pendingEnvironmentRenderState = currentRenderState
        }

        scene.ecs.add(state, to: entity)
        EngineLoggerContext.log(
            "Environment IBL rebuild result applied (stale=\(currentRenderState.iblSignature != result.signature), t=\(String(format: "%.3f", result.completedAt)))",
            level: .debug,
            category: .renderer
        )
    }

    private func applyEnvironmentIBLFailure(_ failure: EnvironmentIBLRebuildFailure, scene: EngineScene) {
        guard let entity = scene.ecs.entity(with: failure.entity.id) else { return }
        var state = scene.ecs.get(EnvironmentIBLStateComponent.self, for: entity)
            ?? EnvironmentIBLStateComponent.defaultNeedsRebuild
        state.isRebuilding = false
        state.dirty = true
        state.needsRebuild = true
        state.pendingSignature = failure.signature
        state.currentRebuildQuality = nil
        state.lastFailureMessage = failure.message
        scene.ecs.add(state, to: entity)
    }

    @discardableResult
    private func updateEnvironmentIBLIfNeeded(scene: EngineScene) -> Bool {
        drainEnvironmentIBLCompletions(scene: scene)
        guard let environmentEntry = scene.ecs.activeEnvironment() else { return false }
        let entity = environmentEntry.0
        let environment = environmentEntry.1
        guard environment.enabled else { return true }

        let runtime: EnvironmentRuntimeStateComponent
        if let existingRuntime = scene.ecs.get(EnvironmentRuntimeStateComponent.self, for: entity) {
            runtime = existingRuntime
        } else {
            runtime = EnvironmentRuntimeStateComponent.default(from: environment)
            scene.ecs.add(runtime, to: entity)
        }

        var iblState = scene.ecs.get(EnvironmentIBLStateComponent.self, for: entity)
            ?? EnvironmentIBLStateComponent.defaultNeedsRebuild
        let renderState = EnvironmentRenderStateBuilder.build(
            environment: environment,
            runtime: runtime,
            rendererSettings: settings
        )
        let signature = renderState.iblSignature

        let activeHandles = activeIBLHandles()
        var didUpdateHandles = false
        if iblState.environmentTexture == nil {
            iblState.environmentTexture = activeHandles.environment
            didUpdateHandles = true
        }
        if iblState.irradianceTexture == nil {
            iblState.irradianceTexture = activeHandles.irradiance
            didUpdateHandles = true
        }
        if iblState.prefilteredTexture == nil {
            iblState.prefilteredTexture = activeHandles.prefiltered
            didUpdateHandles = true
        }
        if iblState.brdfLUT == nil {
            iblState.brdfLUT = activeHandles.brdf
            didUpdateHandles = true
        }

        let hdriLoaded = renderState.sourceMode != .hdri
            || (renderState.hdriTextureHandle.flatMap { engineContext.assets.texture(handle: $0) } != nil)
        if renderState.sourceMode == .hdri, !hdriLoaded {
            if didUpdateHandles {
                scene.ecs.add(iblState, to: entity)
            }
            return true
        }

        let environmentTexture = iblState.environmentTexture.flatMap { engineContext.assets.texture(handle: $0) }
        let irradianceTexture = iblState.irradianceTexture.flatMap { engineContext.assets.texture(handle: $0) }
        let prefilteredTexture = iblState.prefilteredTexture.flatMap { engineContext.assets.texture(handle: $0) }
        let brdfTexture = iblState.brdfLUT.flatMap { engineContext.assets.texture(handle: $0) }
        let texturesMissing = (environmentTexture?.width ?? 0) <= 1
            || (irradianceTexture?.width ?? 0) <= 1
            || (prefilteredTexture?.width ?? 0) <= 1
            || brdfTexture == nil
        if texturesMissing {
            iblState.dirty = true
            iblState.needsRebuild = true
        }

        let now = CACurrentMediaTime()
        let signatureChanged = iblState.lastBuiltSignature.map { $0 != signature } ?? true
        let policyAllowsAutomaticRebuild = environment.ibl.realtimeUpdate || environment.ibl.autoRebuildOnChange
        if signatureChanged, policyAllowsAutomaticRebuild {
            iblState.dirty = true
            _lastSkyInteractionTime = now
        }

        if didUpdateHandles || texturesMissing || signatureChanged || iblState.dirty {
            iblState.pendingSignature = signature
            scene.ecs.add(iblState, to: entity)
        }

        if _skyRebuildInFlight {
            _pendingEnvironmentRenderState = renderState
            iblState.isRebuilding = true
            iblState.pendingSignature = signature
            scene.ecs.add(iblState, to: entity)
            return true
        }

        let manualRebuild = iblState.rebuildRequested
        let shouldRebuild = manualRebuild
            || iblState.needsRebuild
            || (iblState.dirty && policyAllowsAutomaticRebuild)
        if !shouldRebuild { return true }

        let bypassCooldown = manualRebuild || iblState.needsRebuild
        let isDebouncingEdit = !bypassCooldown
            && (now - _lastSkyInteractionTime) < _environmentIBLEditDebounce
        let isInCooldown = !bypassCooldown
            && (now - _lastSkyRebuildStartTime) < _skyRebuildCooldown
        if isDebouncingEdit || isInCooldown {
            _pendingEnvironmentRenderState = renderState
            iblState.pendingSignature = signature
            scene.ecs.add(iblState, to: entity)
            return true
        }

        let snapshot = _pendingEnvironmentRenderState ?? renderState
        _pendingEnvironmentRenderState = nil
        let snapshotSignature = snapshot.iblSignature
        let rebuildQuality: EnvironmentIBLRebuildQuality = manualRebuild ? .final : .interactive
        let nextIndex = (_activeIBLHandleIndex + 1) % _iblHandleSets.count
        let finalHandles = _iblHandleSets[nextIndex]
        let targetHandles = (rebuildQuality == .interactive ? (_iblFastHandles ?? finalHandles) : finalHandles)
        guard let targetEnv = engineContext.assets.texture(handle: targetHandles.environment),
              let targetIrr = engineContext.assets.texture(handle: targetHandles.irradiance),
              let targetPre = engineContext.assets.texture(handle: targetHandles.prefiltered) else {
            iblState.isRebuilding = false
            iblState.dirty = true
            iblState.needsRebuild = true
            iblState.lastFailureMessage = "Missing preallocated IBL textures."
            scene.ecs.add(iblState, to: entity)
            return true
        }

        let hdriTexture = snapshot.hdriTextureHandle.flatMap { engineContext.assets.texture(handle: $0) }
        if snapshot.sourceMode == .hdri, hdriTexture == nil {
            iblState.isRebuilding = false
            iblState.dirty = true
            iblState.needsRebuild = true
            iblState.lastFailureMessage = "HDRI texture could not be resolved."
            scene.ecs.add(iblState, to: entity)
            return true
        }

        let moonAlbedoTexture = snapshot.sourceMode == .procedural
            ? resolveMoonAlbedoTexture(context: "environmentIBLRebuild")
            : nil
        let galaxyTexture = snapshot.sourceMode == .procedural
            ? resolveMilkyWayBackgroundTexture(context: "environmentIBLRebuild")
            : nil
        let cloudAtlasTexture = snapshot.sourceMode == .procedural
            ? resolveCloudAtlasTexture(context: "environmentIBLRebuild")
            : nil
        var skyParams = snapshot.legacySkyParams
        skyParams.moonTextureEnabled = moonAlbedoTexture == nil ? 0.0 : 1.0
        skyParams.galaxyTextureEnabled = galaxyTexture == nil ? 0.0 : 1.0
        skyParams.cloudAtlasEnabled = cloudAtlasTexture == nil ? 0.0 : 1.0

        let request = EnvironmentIBLRebuildRequest(
            entity: entity,
            signature: snapshotSignature,
            sourceMode: snapshot.sourceMode,
            hdriTexture: hdriTexture,
            moonAlbedoTexture: moonAlbedoTexture,
            galaxyTexture: galaxyTexture,
            cloudAtlasTexture: cloudAtlasTexture,
            skyParams: skyParams,
            targetHandles: targetHandles,
            targetEnvironment: targetEnv,
            targetIrradiance: targetIrr,
            targetPrefiltered: targetPre,
            generationConfig: iblConfig(mode: rebuildQuality),
            quality: rebuildQuality,
            requestedAt: now,
            manual: manualRebuild
        )
        _skyRebuildInFlight = true
        _lastSkyRebuildStartTime = now
        iblState.lastRebuildTime = now
        iblState.isRebuilding = true
        iblState.needsRebuild = texturesMissing
        iblState.rebuildRequested = false
        iblState.pendingSignature = snapshotSignature
        iblState.currentRebuildQuality = rebuildQuality
        iblState.lastFailureMessage = nil
        scene.ecs.add(iblState, to: entity)

        EngineLoggerContext.log(
            "Environment IBL rebuild scheduled (t=\(String(format: "%.3f", now)), quality=\(rebuildQuality.rawValue))",
            level: .debug,
            category: .renderer
        )

        _skyRebuildQueue.async { [weak self] in
            guard let self = self else { return }
            let isMainThread = Thread.isMainThread
            MC_ASSERT(!isMainThread, "Environment IBL rebuild must not run on the main thread.")
            let threadLabel = isMainThread ? "main" : "background"
            let frameContext = self._skyRebuildFrameContextStorage.beginFrame()
            guard let commandBuffer = self._environmentIBLCommandQueue.makeCommandBuffer() else {
                EngineLoggerContext.log(
                    "Environment IBL rebuild aborted: failed to create command buffer.",
                    level: .warning,
                    category: .renderer
                )
                self.enqueueEnvironmentIBLCompletion(.failure(EnvironmentIBLRebuildFailure(
                    entity: request.entity,
                    signature: request.signature,
                    message: "Failed to create IBL command buffer."
                )))
                return
            }
            commandBuffer.label = "Environment IBL Rebuild"
            let encodeStart = CACurrentMediaTime()

            switch request.sourceMode {
            case .hdri:
                guard let hdriTexture = request.hdriTexture else {
                    EngineLoggerContext.log(
                        "Environment IBL rebuild aborted: HDRI texture not resolved.",
                        level: .warning,
                        category: .renderer
                    )
                    self.enqueueEnvironmentIBLCompletion(.failure(EnvironmentIBLRebuildFailure(
                        entity: request.entity,
                        signature: request.signature,
                        message: "HDRI texture could not be resolved."
                    )))
                    return
                }
                self.renderSkyToEnvironmentMap(
                    hdriTexture: hdriTexture,
                    intensity: 1.0,
                    targetEnvironment: request.targetEnvironment,
                    frameContext: frameContext,
                    commandBuffer: commandBuffer
                )
            case .procedural:
                self.renderProceduralSkyToEnvironmentMap(
                    params: request.skyParams,
                    moonAlbedoTexture: request.moonAlbedoTexture,
                    galaxyTexture: request.galaxyTexture,
                    cloudAtlasTexture: request.cloudAtlasTexture,
                    targetEnvironment: request.targetEnvironment,
                    frameContext: frameContext,
                    commandBuffer: commandBuffer
                )
            }

            self.renderIrradianceMap(
                sourceEnvironment: request.targetEnvironment,
                targetIrradiance: request.targetIrradiance,
                config: request.generationConfig,
                frameContext: frameContext,
                commandBuffer: commandBuffer
            )
            self.renderPrefilteredSpecularMap(
                sourceEnvironment: request.targetEnvironment,
                targetPrefiltered: request.targetPrefiltered,
                config: request.generationConfig,
                frameContext: frameContext,
                commandBuffer: commandBuffer
            )
            let encodeDt = CACurrentMediaTime() - encodeStart

            commandBuffer.addCompletedHandler { [weak self] buffer in
                guard let self = self else { return }
                let completed = CACurrentMediaTime()
                let totalCpuWallDt = completed - request.requestedAt
                EngineLoggerContext.log(
                    "Environment IBL rebuild timings [quality=\(request.quality.rawValue), thread=\(threadLabel), queue=dedicated, manual=\(request.manual), waitUntilCompleted=none]: totalCpuWall=\(String(format: "%.3f", totalCpuWallDt))s, encode=\(String(format: "%.3f", encodeDt))s",
                    level: .debug,
                    category: .renderer
                )
                if buffer.status == .error {
                    let message = buffer.error?.localizedDescription ?? "Environment IBL command buffer failed."
                    self.enqueueEnvironmentIBLCompletion(.failure(EnvironmentIBLRebuildFailure(
                        entity: request.entity,
                        signature: request.signature,
                        message: message
                    )))
                    return
                }
                self.enqueueEnvironmentIBLCompletion(.success(EnvironmentIBLRebuildResult(
                    entity: request.entity,
                    signature: request.signature,
                    handles: request.targetHandles,
                    quality: request.quality,
                    completedAt: completed
                )))
            }
            commandBuffer.commit()
        }

        return true
    }

    private func updateSkyIfNeeded(scene: EngineScene) {
        if updateEnvironmentIBLIfNeeded(scene: scene) {
            return
        }

        guard let skyEntry = scene.ecs.activeSkyLight() else { return }
        let entity = skyEntry.0
        let sky = skyEntry.1
        guard sky.enabled else { return }
        var iblState = scene.ecs.get(SkyIBLStateComponent.self, for: entity) ?? SkyIBLStateComponent()

        let activeHandles = activeIBLHandles()
        var didUpdateHandles = false
        if iblState.iblEnvironmentHandle == nil {
            iblState.iblEnvironmentHandle = activeHandles.environment
            didUpdateHandles = true
        }
        if iblState.iblIrradianceHandle == nil {
            iblState.iblIrradianceHandle = activeHandles.irradiance
            didUpdateHandles = true
        }
        if iblState.iblPrefilteredHandle == nil {
            iblState.iblPrefilteredHandle = activeHandles.prefiltered
            didUpdateHandles = true
        }
        if iblState.iblBrdfHandle == nil {
            iblState.iblBrdfHandle = activeHandles.brdf
            didUpdateHandles = true
        }
        if didUpdateHandles {
            scene.ecs.add(iblState, to: entity)
        }

        let hdriLoaded = sky.mode != .hdri || (sky.hdriHandle.flatMap { engineContext.assets.texture(handle: $0) } != nil)
        if sky.mode == .hdri, !hdriLoaded { return }

        let environment = iblState.iblEnvironmentHandle.flatMap { engineContext.assets.texture(handle: $0) }
        let irradiance = iblState.iblIrradianceHandle.flatMap { engineContext.assets.texture(handle: $0) }
        let prefiltered = iblState.iblPrefilteredHandle.flatMap { engineContext.assets.texture(handle: $0) }
        let isFallbackIBL = (environment?.width ?? 0) <= 1
            || (irradiance?.width ?? 0) <= 1
            || (prefiltered?.width ?? 0) <= 1
        if isFallbackIBL && !iblState.needsRebuild {
            iblState.needsRebuild = true
            iblState.rebuildRequested = true
            scene.ecs.add(iblState, to: entity)
        }

        let now = CACurrentMediaTime()
        if !iblState.needsRebuild {
            let paramsChanged = _lastSkyLiveSnapshot.map { !SkySystem.liveSkyParamsMatch($0, sky) } ?? true
            let wantsCloudMotion = sky.cloudsEnabled && abs(sky.cloudsSpeed) > 0.0001
            let needsCloudTick = wantsCloudMotion && (now - _lastSkyLiveUpdateTime) > 0.35
            let shouldUpdateLive = paramsChanged || needsCloudTick
            if shouldUpdateLive && !_skyRebuildInFlight && (now - iblState.lastRebuildTime) >= _skyRebuildCooldown {
                if let requested = _lastSkyRequestedSnapshot, SkySystem.liveSkyParamsMatch(requested, sky) {
                    _lastSkyLiveUpdateTime = now
                } else {
                    iblState.needsRebuild = true
                    iblState.rebuildRequested = true
                    scene.ecs.add(iblState, to: entity)
                    _lastSkyRequestedSnapshot = sky
                    _lastSkyLiveUpdateTime = now
                    _lastSkyInteractionTime = now
                }
            }
        }
        if _skyRebuildInFlight {
            _pendingSkySnapshot = sky
            return
        }
        if !iblState.needsRebuild { return }
        let allowRebuild = iblState.realtimeUpdate || iblState.rebuildRequested
        if !allowRebuild { return }
        if (now - _lastSkyRebuildStartTime) < _skyRebuildCooldown {
            _pendingSkySnapshot = sky
            return
        }

        iblState.lastRebuildTime = now
        iblState.rebuildRequested = false
        scene.ecs.add(iblState, to: entity)

        let snapshot = _pendingSkySnapshot ?? sky
        _pendingSkySnapshot = nil
        let nextIndex = (_activeIBLHandleIndex + 1) % _iblHandleSets.count
        let finalHandles = _iblHandleSets[nextIndex]
        let withinInteractiveWindow = (now - _lastSkyInteractionTime) < _skyInteractiveSettleDelay
        let buildMode: IBLBuildMode = withinInteractiveWindow ? .interactive : .final
        let targetHandles = (buildMode == .interactive ? (_iblFastHandles ?? finalHandles) : finalHandles)
        let modeLabel = buildMode.rawValue
        _skyRebuildInFlight = true
        _lastSkyRebuildStartTime = now
        let requestStart = CACurrentMediaTime()
        EngineLoggerContext.log(
            "IBL rebuild scheduled (t=\(String(format: "%.3f", now)), mode=\(modeLabel))",
            level: .debug,
            category: .renderer
        )
        _skyRebuildQueue.async { [weak self] in
            guard let self = self else { return }
            let isMainThread = Thread.isMainThread
            MC_ASSERT(!isMainThread, "IBL rebuild must not run on the main thread.")
            let threadLabel = isMainThread ? "main" : "background"
            let frameContext = self._skyRebuildFrameContextStorage.beginFrame()
            let generationConfig = self.iblConfig(mode: buildMode)
            let resourceLookupStart = CACurrentMediaTime()
            guard let targetEnv = self.engineContext.assets.texture(handle: targetHandles.environment),
                  let targetIrr = self.engineContext.assets.texture(handle: targetHandles.irradiance),
                  let targetPre = self.engineContext.assets.texture(handle: targetHandles.prefiltered) else {
                EngineLoggerContext.log(
                    "IBL rebuild aborted: missing preallocated textures.",
                    level: .warning,
                    category: .renderer
                )
                DispatchQueue.main.async { [weak self] in
                    self?._skyRebuildInFlight = false
                }
                return
            }
            let resourceLookupDt = CACurrentMediaTime() - resourceLookupStart
            guard let commandBuffer = self.engineContext.commandQueue.makeCommandBuffer() else {
                EngineLoggerContext.log(
                    "IBL rebuild aborted: failed to create command buffer.",
                    level: .warning,
                    category: .renderer
                )
                DispatchQueue.main.async { [weak self] in
                    self?._skyRebuildInFlight = false
                }
                return
            }
            commandBuffer.label = "IBL Rebuild"
            let encodeStart = CACurrentMediaTime()
            var hdriResolveDt: Double = 0.0
            switch snapshot.mode {
            case .hdri:
                let hdriResolveStart = CACurrentMediaTime()
                guard let hdriHandle = snapshot.hdriHandle,
                      let hdriTexture = self.engineContext.assets.texture(handle: hdriHandle) else {
                    EngineLoggerContext.log(
                        "IBL rebuild aborted: HDRI texture not resolved.",
                        level: .warning,
                        category: .renderer
                    )
                    DispatchQueue.main.async { [weak self] in
                        self?._skyRebuildInFlight = false
                    }
                    return
                }
                hdriResolveDt = CACurrentMediaTime() - hdriResolveStart
                self.renderSkyToEnvironmentMap(
                    hdriTexture: hdriTexture,
                    intensity: snapshot.intensity,
                    targetEnvironment: targetEnv,
                    frameContext: frameContext,
                    commandBuffer: commandBuffer
                )
            case .procedural:
                let environmentState = scene.ecs.get(EnvironmentStateComponent.self, for: entity)
                let moonAlbedoTexture = self.resolveMoonAlbedoTexture(context: "legacySkyIBLRebuild")
                let galaxyTexture = self.resolveMilkyWayBackgroundTexture(context: "legacySkyIBLRebuild")
                let cloudAtlasTexture = self.resolveCloudAtlasTexture(context: "legacySkyIBLRebuild")
                var params = self.skyParams(from: snapshot, environmentState: environmentState)
                params.moonTextureEnabled = moonAlbedoTexture == nil ? 0.0 : 1.0
                params.galaxyTextureEnabled = galaxyTexture == nil ? 0.0 : 1.0
                params.cloudAtlasEnabled = cloudAtlasTexture == nil ? 0.0 : 1.0
                self.renderProceduralSkyToEnvironmentMap(
                    params: params,
                    moonAlbedoTexture: moonAlbedoTexture,
                    galaxyTexture: galaxyTexture,
                    cloudAtlasTexture: cloudAtlasTexture,
                    targetEnvironment: targetEnv,
                    frameContext: frameContext,
                    commandBuffer: commandBuffer
                )
            }

            self.renderIrradianceMap(
                sourceEnvironment: targetEnv,
                targetIrradiance: targetIrr,
                config: generationConfig,
                frameContext: frameContext,
                commandBuffer: commandBuffer
            )
            self.renderPrefilteredSpecularMap(
                sourceEnvironment: targetEnv,
                targetPrefiltered: targetPre,
                config: generationConfig,
                frameContext: frameContext,
                commandBuffer: commandBuffer
            )
            let encodeDt = CACurrentMediaTime() - encodeStart

            var commitTimestamp: Double = 0.0
            var commitCpuDt: Double = 0.0
            commandBuffer.addCompletedHandler { [weak self] _ in
                let completed = CACurrentMediaTime()
                let commitToCompleteDt = commitTimestamp > 0.0 ? (completed - commitTimestamp) : 0.0
                let totalCpuWallDt = completed - requestStart
                EngineLoggerContext.log(
                    "IBL rebuild timings [mode=\(modeLabel), thread=\(threadLabel), waitUntilCompleted=none]: totalCpuWall=\(String(format: "%.3f", totalCpuWallDt))s, resources=\(String(format: "%.3f", resourceLookupDt))s, hdriResolve=\(String(format: "%.3f", hdriResolveDt))s, encode=\(String(format: "%.3f", encodeDt))s, commitCpu=\(String(format: "%.3f", commitCpuDt))s, commitToComplete=\(String(format: "%.3f", commitToCompleteDt))s",
                    level: .debug,
                    category: .renderer
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self._skyRebuildInFlight = false
                    guard let currentScene = self.delegate?.activeScene(),
                          let currentEntry = currentScene.ecs.activeSkyLight() else { return }
                    let (currentEntity, currentSky) = currentEntry
                    var regen = currentScene.ecs.get(SkyIBLStateComponent.self, for: currentEntity) ?? SkyIBLStateComponent()
                    if self.skySettingsMatch(currentSky, snapshot) {
                        if buildMode == .interactive {
                            regen.iblEnvironmentHandle = targetHandles.environment
                            regen.iblIrradianceHandle = targetHandles.irradiance
                            regen.iblPrefilteredHandle = targetHandles.prefiltered
                            regen.iblBrdfHandle = targetHandles.brdf
                            regen.needsRebuild = true
                            regen.rebuildRequested = true
                        } else {
                            self._activeIBLHandleIndex = nextIndex
                            regen.iblEnvironmentHandle = finalHandles.environment
                            regen.iblIrradianceHandle = finalHandles.irradiance
                            regen.iblPrefilteredHandle = finalHandles.prefiltered
                            regen.iblBrdfHandle = finalHandles.brdf
                            regen.needsRebuild = false
                            regen.rebuildRequested = false
                        }
                        self._lastSkyLiveSnapshot = snapshot
                        self._lastSkyRequestedSnapshot = snapshot
                    } else {
                        regen.needsRebuild = true
                    }
                    if let pending = self._pendingSkySnapshot {
                        let pendingMatches = self.skySettingsMatch(pending, snapshot)
                            && SkySystem.liveSkyParamsMatch(pending, snapshot)
                        if pendingMatches {
                            self._pendingSkySnapshot = nil
                        } else {
                            regen.needsRebuild = true
                            regen.rebuildRequested = true
                        }
                    }
                    currentScene.ecs.add(regen, to: currentEntity)
                    let swapped = CACurrentMediaTime()
                    EngineLoggerContext.log(
                        "IBL rebuild swapped (t=\(String(format: "%.3f", swapped)))",
                        level: .debug,
                        category: .renderer
                    )
                }
            }
            let commitCpuStart = CACurrentMediaTime()
            commitTimestamp = commitCpuStart
            commandBuffer.commit()
            commitCpuDt = CACurrentMediaTime() - commitCpuStart
        }
    }

}

// MARK: - MTKViewDelegate

extension Renderer: MTKViewDelegate {

    public func updateScreenSize(view: MTKView) {
        applyViewSizes(view: view)
        delegate?.activeScene()?.updateAspectRatio()
        _renderResources.rebuild(drawableSize: view.drawableSize)
    }

    private func applyViewSizes(view: MTKView) {
        screenSize = SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height))
        drawableSize = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))
        if viewportSize.x.isZero || viewportSize.y.isZero {
            viewportSize = screenSize
        }
    }

    private func updateFrameSizingIfNeeded(view: MTKView) {
        if _lastPerfFlags != settings.perfFlags {
            _lastPerfFlags = settings.perfFlags
            updateScreenSize(view: view)
        }
        let currentSize = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))
        if drawableSize != currentSize
            || !_renderResources.isValid(for: view.drawableSize) {
            drawableSize = currentSize
            updateScreenSize(view: view)
        }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        updateScreenSize(view: view)
    }

    private func makeRenderViewContext(sceneView: SceneView, view: MTKView) -> RenderViewContext {
        let resolvedViewport = SIMD2<Float>(
            max(1.0, sceneView.viewportSize.x),
            max(1.0, sceneView.viewportSize.y)
        )
        let resolvedViewId: UInt64 = {
            if sceneView.viewId != 0 {
                return sceneView.viewId
            }
            let fallbackId = ObjectIdentifier(view).hashValue
            return UInt64(bitPattern: Int64(fallbackId))
        }()
        return RenderViewContext(
            viewId: resolvedViewId,
            viewportSize: resolvedViewport,
            layerFilterMask: sceneView.layerMask,
            depthPrepassEnabled: sceneView.depthPrepassEnabled,
            updatesPickingMapping: true,
            updatesBatchStats: true,
            debugFlags: sceneView.debugFlags,
            showEditorOverlays: sceneView.isEditorView,
            exposureSettings: sceneView.exposureSettings
        )
    }

    public func draw(in view: MTKView) {
        let frameStart = CACurrentMediaTime()
        updateFrameSizingIfNeeded(view: view)
        guard let drawable = view.currentDrawable,
              view.drawableSize.width > 0,
              view.drawableSize.height > 0 else { return }
        _inFlightSemaphore.wait()
        var frameSubmitted = false
        defer {
            if !frameSubmitted {
                _inFlightSemaphore.signal()
            }
        }
        let updateStart = CACurrentMediaTime()
        let frameTime = buildFrameTime(timestamp: frameStart)
        let inputState = inputAccumulator?.snapshotAndReset() ?? InputState(
            mousePosition: .zero,
            mouseDelta: .zero,
            scrollDelta: 0,
            mouseButtons: [],
            keys: [],
            viewportOrigin: .zero,
            viewportSize: .zero,
            textInput: ""
        )
        let frame = FrameContext(time: frameTime, input: inputState)
        delegate?.update(frame: frame)
        profiler.record(.update, seconds: CACurrentMediaTime() - updateStart)
        let frameContext = _frameContextStorage.beginFrame()
        let renderStart = CACurrentMediaTime()
        // Render graph executes scene passes, fullscreen/post passes, and final composite into
        // post.finalColor / BuiltinAssets.finalColorRender. The editor overlay layer samples that
        // final composite texture and presents it inside the viewport UI.
        let sceneView = delegate?.buildSceneView(renderer: self) ?? SceneView(viewportSize: viewportSize)
        let activeScene = delegate?.activeScene()
        let frameSettings = resolvedRendererSettings(for: activeScene)
        _frameContextStorage.updateRendererState(
            settings: frameSettings,
            viewContext: makeRenderViewContext(sceneView: sceneView, view: view)
        )
        _frameContextStorage.setAssetStateRevision(engineContext.assets.cacheRevisionToken())
        frameContext.setRenderResourceRegistry(_renderResources.buildRegistry())
        let frameDiagnostics = frameContext.diagnostics
        let snapshotStart = CACurrentMediaTime()
        if let activeScene {
            SceneRenderer.prepareRenderFrameSnapshot(scene: activeScene, frameContext: frameContext)
            if let snapshot = frameContext.renderFrameSnapshot() {
                frameContext.setRenderFrameSnapshot(applyReflectionProbeRuntimeState(to: snapshot, scene: activeScene))
            }
        } else {
            frameContext.setRenderFrameSnapshot(nil)
        }
        profiler.record(.snapshotExtract, seconds: CACurrentMediaTime() - snapshotStart)
        guard let overlayCommandBuffer = engineContext.commandQueue.makeCommandBuffer() else { return }
        overlayCommandBuffer.label = "MetalCup Frame"
        let frameId = frameContext.currentFrameCounter()
        let frameIndex = frameContext.currentFrameIndex()
        let gpuPassTimingsEnabled = profiler.gpuPassTimingsEnabled()
        let counterSupported = profiler.gpuCounterSamplingSupported(device: engineContext.device)
        let useCounterSampling = gpuPassTimingsEnabled && counterSupported
        if useCounterSampling {
            _ = profiler.prepareGpuCounterSampling(device: engineContext.device, inFlightFrames: frameContext.maxFramesInFlight())
            profiler.beginGpuCounterFrame(frameIndex: frameIndex, frameId: frameId)
        }
        let graphFrame = RenderGraphFrame(
            renderer: self,
            engineContext: engineContext,
            view: view,
            sceneView: sceneView,
            commandBuffer: overlayCommandBuffer,
            resources: _renderResources,
            resourceRegistry: frameContext.renderResourceRegistry() ?? _renderResources.buildRegistry(),
            delegate: delegate,
            sceneSnapshot: frameContext.renderFrameSnapshot(),
            frameContext: frameContext,
            profiler: profiler,
            frameInFlightIndex: frameContext.frameInFlightIndex(),
            viewSignature: frameContext.viewSignature(),
            settingsRevision: frameContext.rendererStateRevision(),
            renderPlan: RenderPlan.unplanned(viewSignature: frameContext.viewSignature())
        )
        let gpuStart = CACurrentMediaTime()
        if !useCounterSampling {
            overlayCommandBuffer.addCompletedHandler { [weak self] buffer in
                let duration = buffer.gpuEndTime - buffer.gpuStartTime
                let resolved = duration > 0 ? duration : CACurrentMediaTime() - gpuStart
                self?.profiler.record(.gpu, seconds: resolved)
            }
        }
        let renderGraphEncodeStart = CACurrentMediaTime()
        _renderGraph.execute(frame: graphFrame)
        profiler.record(.renderGraphEncode, seconds: CACurrentMediaTime() - renderGraphEncodeStart)
        overlayCommandBuffer.addCompletedHandler { [weak engineContext] _ in
            guard let engineContext else { return }
            var forwardPlus = frameDiagnostics.forwardPlus
            if let statsBuffer = frameDiagnostics.forwardPlusStatsReadbackBufferValue() {
                let gpuStats = statsBuffer.contents().bindMemory(to: ForwardPlusStats.self, capacity: 1).pointee
                forwardPlus.stats.tileOverflowCount = gpuStats.tileOverflowCount
                forwardPlus.stats.clusterOverflowCount = gpuStats.clusterOverflowCount
                forwardPlus.stats.tileIndicesWritten = gpuStats.tileIndicesWritten
                forwardPlus.stats.clusterIndicesWritten = gpuStats.clusterIndicesWritten
                forwardPlus.stats.totalTiles = gpuStats.totalTiles
                forwardPlus.stats.totalClusters = gpuStats.totalClusters
                forwardPlus.stats.activeTilesCount = gpuStats.activeTilesCount
            }
            frameDiagnostics.forwardPlus = forwardPlus
            let committed = engineContext.rendererDiagnostics.commit(
                viewSignature: frameDiagnostics.viewSignature,
                forwardPlus: forwardPlus
            )
            engineContext.forwardPlusStats = committed.stats
            engineContext.forwardPlusCullingDepthSource = committed.cullingDepthSource.rawValue
        }

        let overlaysStart = CACurrentMediaTime()
        delegate?.renderOverlays(view: view, commandBuffer: overlayCommandBuffer, frameContext: frameContext)
        profiler.record(.overlays, seconds: CACurrentMediaTime() - overlaysStart)
        profiler.record(.render, seconds: CACurrentMediaTime() - renderStart)

        if let scene = activeScene {
            updateSkyIfNeeded(scene: scene)
            updateReflectionProbesIfNeeded(scene: scene)
        }

        let presentStart = CACurrentMediaTime()
        if useCounterSampling {
            profiler.encodeGpuCounterResolve(commandBuffer: overlayCommandBuffer, frameIndex: frameIndex)
            overlayCommandBuffer.addCompletedHandler { [weak self] buffer in
                self?.profiler.processResolvedGpuCounters(frameIndex: frameIndex, frameId: frameId, commandBuffer: buffer)
            }
        }
        overlayCommandBuffer.present(drawable)
        overlayCommandBuffer.addCompletedHandler { [weak self] _ in
            self?._inFlightSemaphore.signal()
        }
        frameSubmitted = true
        overlayCommandBuffer.commit()
        profiler.record(.present, seconds: CACurrentMediaTime() - presentStart)
        profiler.record(.frame, seconds: CACurrentMediaTime() - frameStart)
    }

    private func buildFrameTime(timestamp: TimeInterval) -> FrameTime {
        let deltaSeconds: Float
        if let last = _lastFrameTimestamp {
            deltaSeconds = Float(timestamp - last)
        } else {
            deltaSeconds = 0.0
        }
        _lastFrameTimestamp = timestamp
        let clampedUnscaled = min(max(deltaSeconds, 0.0), _maxFrameDelta)
        let unscaledDelta = clampedUnscaled
        let delta = clampedUnscaled * _timeScale
        _unscaledTotalTime += unscaledDelta
        _totalTime += delta
        _frameCount &+= 1
        return FrameTime(
            deltaTime: delta,
            unscaledDeltaTime: unscaledDelta,
            timeScale: _timeScale,
            fixedDeltaTime: _fixedDeltaTime,
            frameCount: _frameCount,
            totalTime: _totalTime,
            unscaledTotalTime: _unscaledTotalTime
        )
    }

}
