/// SceneRenderer.swift
/// Provides a single render entry point for scene rendering.
/// Created by Kaden Cringle.

import Foundation
import MetalKit
import QuartzCore
import simd

public struct ReflectionProbeSnapshot {
    let entity: Entity
    let enabled: Bool
    let worldTransform: TransformComponent
    let boxExtents: SIMD3<Float>
    let blendDistance: Float
    let priority: Int32
    let intensity: Float
    let captureResolution: Int32
    let rebuildMode: ReflectionProbeRebuildMode
    let includeSky: Bool
    let runtimeReady: Bool
    let prefilteredHandle: AssetHandle?
}

public struct RenderFrameSnapshot {
    public struct Renderable {
        let entity: Entity
        let meshHandle: AssetHandle?
        let meshRenderer: MeshRendererComponent
        let inheritedMaterialHandle: AssetHandle?
        let worldTransform: TransformComponent
    }

    let sceneKey: ObjectIdentifier
    let frameToken: UInt64
    let signature: UInt64
    let sceneConstants: SceneConstants
    let activeEnvironmentRenderState: EnvironmentRenderState?
    let activeEnvironmentIBLState: EnvironmentIBLStateComponent?
    let activeSkyLight: SkyLightComponent?
    let activeEnvironmentState: EnvironmentStateComponent?
    let activeSkyIBLState: SkyIBLStateComponent?
    let directionalLights: [LightData]
    let localLights: [LightData]
    let directionalShadowLightEntityID: UUID?
    let directionalShadowLightDirection: SIMD3<Float>?
    let animationPayload: AnimationSnapshotPayload?
    let renderables: [Renderable]
    let reflectionProbes: [ReflectionProbeSnapshot]
}

public enum ReflectionProbeDebugFallbackReason {
    case none
    case noEnabledProbes
    case noReadyProbes
    case outsideInfluence
}

public struct ReflectionProbeDebugSelection {
    public let selectedProbeEntityID: UUID?
    public let weight: Float
    public let fallbackReason: ReflectionProbeDebugFallbackReason

    public init(selectedProbeEntityID: UUID?,
                weight: Float,
                fallbackReason: ReflectionProbeDebugFallbackReason) {
        self.selectedProbeEntityID = selectedProbeEntityID
        self.weight = weight
        self.fallbackReason = fallbackReason
    }
}

public enum SceneRenderer {
    private struct FrameCacheKey: Hashable {
        let sceneKey: ObjectIdentifier
        let frameToken: UInt64
        let snapshotSignature: UInt64
        let viewSignature: UInt64
        let cullingConfigSignature: UInt64
        let stateRevision: UInt64
        let assetStateRevision: UInt64
    }

    private struct FrameCacheEntry {
        let key: FrameCacheKey
        let snapshot: RenderFrameSnapshot
        let result: RenderSubmissionResult?
    }

    private static var frameCache: [FrameCacheKey: FrameCacheEntry] = [:]
    private static var didLogMoonAlbedoResolution = false
    private static var didLogMilkyWayResolution = false
    private static var didLogCloudAtlasResolution = false
    private static var didLogCloudCardCumulusResolution = false
    private static var didLogCloudCardDiagnosticFallback = false
    private static var didLogFarCloudCardDraw = false
    private static var farCloudCardSkipLogKeys: Set<String> = []
    private struct SnapshotPreparationKey: Hashable {
        let sceneKey: ObjectIdentifier
        let frameToken: UInt64
        let viewSignature: UInt64
    }

    #if DEBUG
    private static var preparedSnapshotFrameToken: UInt64 = 0
    private static var preparedSnapshotKeys: Set<SnapshotPreparationKey> = []
    #else
    private static var lastMissingSnapshotFrameToken: UInt64 = 0
    private static var missingSnapshotLogKeys: Set<SnapshotPreparationKey> = []
    #endif

    #if DEBUG
    private static var didInstanceSanityCheck = false
    private static var invalidSkinningLogKeys: Set<String> = []
    private static var validSkinningLogKeys: Set<String> = []
    #endif
    @discardableResult
    public static func render(scene: EngineScene, view: SceneView, context: RenderContext, frameContext: RendererFrameContext) -> RenderOutputs {
        frameContext.setViewContext(
            RenderViewContext(
                viewId: view.viewId,
                viewportSize: view.viewportSize,
                layerFilterMask: view.layerMask,
                depthPrepassEnabled: view.depthPrepassEnabled,
                updatesPickingMapping: true,
                updatesBatchStats: true,
                debugFlags: view.debugFlags,
                showEditorOverlays: view.isEditorView,
                exposureSettings: view.exposureSettings,
                exposureIdentity: ExposureViewStateIdentity(
                    sceneID: view.sceneId,
                    cameraID: view.cameraId,
                    viewportInstanceID: view.viewId,
                    viewKind: view.viewKind
                )
            )
        )
        prepareRenderFrameSnapshot(scene: scene, frameContext: frameContext)
        if let encoder = context.renderEncoder {
            renderScene(into: encoder, scene: scene, frameContext: frameContext)
        }
        return RenderOutputs(color: context.colorTarget,
                             depth: context.depthTarget,
                             pickingId: context.idTarget,
                             sceneColor: context.colorTarget,
                             sceneDepth: context.depthTarget,
                             finalColor: context.colorTarget)
    }

    @discardableResult
    public static func render(scene: EngineScene, view: SceneView, context: RenderContext, engineContext: EngineContext) -> RenderOutputs {
        let storage = RendererFrameContextStorage(engineContext: engineContext)
        let frameContext = storage.beginFrame()
        return render(scene: scene, view: view, context: context, frameContext: frameContext)
    }

    static func renderScene(into encoder: MTLRenderCommandEncoder, scene: EngineScene, frameContext: RendererFrameContext) {
        encoder.pushDebugGroup("Rendering Scene \(scene.name)...")
        guard let snapshot = currentFrameSnapshot(scene: scene, frameContext: frameContext) else {
            encoder.popDebugGroup()
            return
        }
        // Reserved seam for future skinning data consumption.
        _ = snapshot.animationPayload
        prepareLightingInputs(snapshot: snapshot, frameContext: frameContext)
        syncIBLTextures(snapshot: snapshot, frameContext: frameContext)
        let sceneConstantsBuffer = resolvedSceneConstantsBuffer(snapshot: snapshot, frameContext: frameContext)
        switch frameContext.currentRenderPass() {
        case .main:
            bindRendererSettings(encoder, settings: frameContext.rendererSettings(), frameContext: frameContext)
            bindShadowResources(encoder, frameContext: frameContext)
            bindLightingInputs(encoder, frameContext: frameContext)
            renderSky(encoder, snapshot: snapshot, frameContext: frameContext, sceneConstantsBuffer: sceneConstantsBuffer)
            renderFarCloudCards(encoder, snapshot: snapshot, frameContext: frameContext, sceneConstantsBuffer: sceneConstantsBuffer)
            renderMeshes(encoder, snapshot: snapshot, pass: .main, frameContext: frameContext, sceneConstantsBuffer: sceneConstantsBuffer)
        case .normal:
            renderMeshes(encoder, snapshot: snapshot, pass: .normal, frameContext: frameContext, sceneConstantsBuffer: sceneConstantsBuffer)
        case .ssaoNormal:
            renderMeshes(encoder, snapshot: snapshot, pass: .ssaoNormal, frameContext: frameContext, sceneConstantsBuffer: sceneConstantsBuffer)
        case .transparent:
            bindRendererSettings(encoder, settings: frameContext.rendererSettings(), frameContext: frameContext)
            bindShadowResources(encoder, frameContext: frameContext)
            bindLightingInputs(encoder, frameContext: frameContext)
            renderMeshes(encoder, snapshot: snapshot, pass: .transparent, frameContext: frameContext, sceneConstantsBuffer: sceneConstantsBuffer)
        case .shadow:
            renderMeshes(encoder, snapshot: snapshot, pass: .shadow, frameContext: frameContext, sceneConstantsBuffer: sceneConstantsBuffer)
        case .picking:
            renderMeshes(encoder, snapshot: snapshot, pass: .picking, frameContext: frameContext, sceneConstantsBuffer: sceneConstantsBuffer)
        case .depthPrepass:
            renderMeshes(encoder, snapshot: snapshot, pass: .depthPrepass, frameContext: frameContext, sceneConstantsBuffer: sceneConstantsBuffer)
        }
        encoder.popDebugGroup()
    }

    static func renderPreview(encoder: MTLRenderCommandEncoder,
                              snapshot: RenderFrameSnapshot,
                              camera: CameraComponent,
                              worldTransform: TransformComponent,
                              viewportSize: SIMD2<Float>,
                              previewViewId: UInt64,
                              frameContext: RendererFrameContext) {
        guard viewportSize.x > 1, viewportSize.y > 1 else { return }
        let previousPass = frameContext.currentRenderPass()
        let previousUsePrepass = frameContext.useDepthPrepass()
        let previousViewContext = frameContext.viewContext()
        let aspect = max(0.01, viewportSize.x / viewportSize.y)
        var previewConstants = snapshot.sceneConstants
        previewConstants.viewMatrix = viewMatrix(from: worldTransform)
        previewConstants.inverseViewMatrix = simd_inverse(previewConstants.viewMatrix)
        previewConstants.skyViewMatrix = previewConstants.viewMatrix
        previewConstants.skyViewMatrix[3][0] = 0
        previewConstants.skyViewMatrix[3][1] = 0
        previewConstants.skyViewMatrix[3][2] = 0
        previewConstants.projectionMatrix = projectionMatrix(from: camera, aspectRatio: aspect)
        previewConstants.inverseProjectionMatrix = simd_inverse(previewConstants.projectionMatrix)
        previewConstants.inverseViewProjectionMatrix = simd_inverse(previewConstants.projectionMatrix * previewConstants.viewMatrix)
        previewConstants.cameraPositionAndIBL = SIMD4<Float>(worldTransform.position, snapshot.sceneConstants.cameraPositionAndIBL.w)
        let previewConstantsBuffer = frameContext.makeSceneConstantsBuffer(
            previewConstants,
            label: "SceneConstants.Preview"
        )
        frameContext.setCurrentRenderPass(.main)
        var previewViewContext = previousViewContext
        previewViewContext.viewId = previewViewId
        previewViewContext.viewportSize = viewportSize
        previewViewContext.depthPrepassEnabled = false
        previewViewContext.updatesPickingMapping = false
        previewViewContext.updatesBatchStats = false
        previewViewContext.showEditorOverlays = false
        frameContext.setViewContext(previewViewContext)
        encoder.setViewport(MTLViewport(originX: 0,
                                        originY: 0,
                                        width: Double(viewportSize.x),
                                        height: Double(viewportSize.y),
                                        znear: 0,
                                        zfar: 1))
        prepareLightingInputs(snapshot: snapshot, frameContext: frameContext)
        syncIBLTextures(snapshot: snapshot, frameContext: frameContext)
        bindRendererSettings(encoder, settings: frameContext.rendererSettings(), frameContext: frameContext)
        bindShadowResources(encoder, frameContext: frameContext)
        bindLightingInputs(encoder, frameContext: frameContext)
        // Inspector camera previews render into dedicated single-sample targets, so they must not
        // inherit the main scene's MSAA-derived pipeline variants.
        let previewSampleCount = 1
        renderSky(
            encoder,
            snapshot: snapshot,
            frameContext: frameContext,
            sceneConstantsBuffer: previewConstantsBuffer,
            sampleCountOverride: previewSampleCount
        )
        renderMeshes(
            encoder,
            snapshot: snapshot,
            pass: .main,
            frameContext: frameContext,
            sceneConstantsBuffer: previewConstantsBuffer,
            sampleCountOverride: previewSampleCount
        )
        frameContext.setCurrentRenderPass(.transparent)
        renderMeshes(
            encoder,
            snapshot: snapshot,
            pass: .transparent,
            frameContext: frameContext,
            sceneConstantsBuffer: previewConstantsBuffer,
            sampleCountOverride: previewSampleCount
        )
        frameContext.setViewContext(previousViewContext)
        frameContext.setUseDepthPrepass(previousUsePrepass)
        frameContext.setCurrentRenderPass(previousPass)
    }

    static func renderCaptureView(encoder: MTLRenderCommandEncoder,
                                  snapshot: RenderFrameSnapshot,
                                  viewMatrix: matrix_float4x4,
                                  projectionMatrix: matrix_float4x4,
                                  cameraPosition: SIMD3<Float>,
                                  viewportSize: SIMD2<Float>,
                                  captureViewId: UInt64,
                                  includeSky: Bool,
                                  frameContext: RendererFrameContext) {
        guard viewportSize.x > 1, viewportSize.y > 1 else { return }
        let previousPass = frameContext.currentRenderPass()
        let previousUsePrepass = frameContext.useDepthPrepass()
        let previousViewContext = frameContext.viewContext()
        let captureSnapshot = makeCaptureSnapshot(
            from: snapshot,
            viewMatrix: viewMatrix,
            projectionMatrix: projectionMatrix,
            cameraPosition: cameraPosition
        )
        let captureConstantsBuffer = frameContext.makeSceneConstantsBuffer(
            captureSnapshot.sceneConstants,
            label: "SceneConstants.ReflectionProbeCapture"
        )
        frameContext.setCurrentRenderPass(.main)
        var captureViewContext = previousViewContext
        captureViewContext.viewId = captureViewId
        captureViewContext.viewportSize = viewportSize
        captureViewContext.depthPrepassEnabled = false
        captureViewContext.updatesPickingMapping = false
        captureViewContext.updatesBatchStats = false
        captureViewContext.showEditorOverlays = false
        frameContext.setViewContext(captureViewContext)
        encoder.setViewport(MTLViewport(originX: 0,
                                        originY: 0,
                                        width: Double(viewportSize.x),
                                        height: Double(viewportSize.y),
                                        znear: 0,
                                        zfar: 1))
        prepareLightingInputs(snapshot: captureSnapshot, frameContext: frameContext)
        syncIBLTextures(snapshot: captureSnapshot, frameContext: frameContext)
        bindRendererSettings(encoder, settings: frameContext.rendererSettings(), frameContext: frameContext)
        bindShadowResources(encoder, frameContext: frameContext)
        bindLightingInputs(encoder, frameContext: frameContext)
        let captureSampleCount = 1
        if includeSky {
            renderSky(
                encoder,
                snapshot: captureSnapshot,
                frameContext: frameContext,
                sceneConstantsBuffer: captureConstantsBuffer,
                sampleCountOverride: captureSampleCount,
                useDisplayCompensatedProceduralSky: false
            )
        }
        renderMeshes(
            encoder,
            snapshot: captureSnapshot,
            pass: .main,
            frameContext: frameContext,
            sceneConstantsBuffer: captureConstantsBuffer,
            sampleCountOverride: captureSampleCount
        )
        frameContext.setViewContext(previousViewContext)
        frameContext.setUseDepthPrepass(previousUsePrepass)
        frameContext.setCurrentRenderPass(previousPass)
    }

    static func makeCaptureSnapshot(from snapshot: RenderFrameSnapshot,
                                    viewMatrix: matrix_float4x4,
                                    projectionMatrix: matrix_float4x4,
                                    cameraPosition: SIMD3<Float>) -> RenderFrameSnapshot {
        let captureSnapshot = RenderFrameSnapshot(
            sceneKey: snapshot.sceneKey,
            frameToken: snapshot.frameToken,
            signature: snapshot.signature,
            sceneConstants: snapshot.sceneConstants,
            activeEnvironmentRenderState: snapshot.activeEnvironmentRenderState,
            activeEnvironmentIBLState: snapshot.activeEnvironmentIBLState,
            activeSkyLight: snapshot.activeSkyLight,
            activeEnvironmentState: snapshot.activeEnvironmentState,
            activeSkyIBLState: snapshot.activeSkyIBLState,
            directionalLights: snapshot.directionalLights,
            localLights: snapshot.localLights,
            directionalShadowLightEntityID: snapshot.directionalShadowLightEntityID,
            directionalShadowLightDirection: snapshot.directionalShadowLightDirection,
            animationPayload: snapshot.animationPayload,
            renderables: snapshot.renderables,
            reflectionProbes: []
        )
        var captureConstants = captureSnapshot.sceneConstants
        captureConstants.viewMatrix = viewMatrix
        captureConstants.inverseViewMatrix = simd_inverse(viewMatrix)
        captureConstants.skyViewMatrix = viewMatrix
        captureConstants.skyViewMatrix[3][0] = 0
        captureConstants.skyViewMatrix[3][1] = 0
        captureConstants.skyViewMatrix[3][2] = 0
        captureConstants.projectionMatrix = projectionMatrix
        captureConstants.inverseProjectionMatrix = simd_inverse(projectionMatrix)
        captureConstants.inverseViewProjectionMatrix = simd_inverse(projectionMatrix * viewMatrix)
        captureConstants.cameraPositionAndIBL = SIMD4<Float>(cameraPosition, captureSnapshot.sceneConstants.cameraPositionAndIBL.w)
        return RenderFrameSnapshot(
            sceneKey: captureSnapshot.sceneKey,
            frameToken: captureSnapshot.frameToken,
            signature: captureSnapshot.signature,
            sceneConstants: captureConstants,
            activeEnvironmentRenderState: captureSnapshot.activeEnvironmentRenderState,
            activeEnvironmentIBLState: captureSnapshot.activeEnvironmentIBLState,
            activeSkyLight: captureSnapshot.activeSkyLight,
            activeEnvironmentState: captureSnapshot.activeEnvironmentState,
            activeSkyIBLState: captureSnapshot.activeSkyIBLState,
            directionalLights: captureSnapshot.directionalLights,
            localLights: captureSnapshot.localLights,
            directionalShadowLightEntityID: captureSnapshot.directionalShadowLightEntityID,
            directionalShadowLightDirection: captureSnapshot.directionalShadowLightDirection,
            animationPayload: captureSnapshot.animationPayload,
            renderables: captureSnapshot.renderables,
            reflectionProbes: captureSnapshot.reflectionProbes
        )
    }

    private static func resolveMoonAlbedoTexture(engineContext: EngineContext, context: String) -> MTLTexture? {
        resolveBuiltinSkyTexture(
            engineContext: engineContext,
            context: context,
            sourcePath: "Textures/Moon/lroc_color_2k.jpg",
            fallbackHandle: BuiltinAssets.moonAlbedo,
            logPrefix: "Moon albedo",
            didLog: &didLogMoonAlbedoResolution
        ) {
            BuiltinAssets.registerMoonAlbedoTextureIfNeeded(
                assetManager: engineContext.assets,
                resourcesRootURL: engineContext.resources.resourcesRootURL,
                device: engineContext.device
            )
        }
    }

    private static func resolveMilkyWayBackgroundTexture(engineContext: EngineContext, context: String) -> MTLTexture? {
        resolveBuiltinSkyTexture(
            engineContext: engineContext,
            context: context,
            sourcePath: "Textures/Sky/MilkyWay/milkyway_2020_4k.exr",
            fallbackHandle: BuiltinAssets.milkyWayBackground,
            logPrefix: "Milky Way background",
            didLog: &didLogMilkyWayResolution
        ) {
            BuiltinAssets.registerMilkyWayBackgroundTextureIfNeeded(
                assetManager: engineContext.assets,
                resourcesRootURL: engineContext.resources.resourcesRootURL,
                device: engineContext.device
            )
        }
    }

    private static func resolveCloudAtlasTexture(engineContext: EngineContext, context: String) -> MTLTexture? {
        resolveBuiltinSkyTexture(
            engineContext: engineContext,
            context: context,
            sourcePath: "Textures/Sky/Clouds/cloud_atlas_4k.png",
            fallbackHandle: BuiltinAssets.cloudAtlas,
            logPrefix: "Cloud atlas",
            didLog: &didLogCloudAtlasResolution
        ) {
            BuiltinAssets.registerCloudAtlasTextureIfNeeded(
                assetManager: engineContext.assets,
                resourcesRootURL: engineContext.resources.resourcesRootURL,
                device: engineContext.device
            )
        }
    }

    private static func resolveCloudCardCumulusTexture(engineContext: EngineContext, context: String) -> MTLTexture? {
        resolveBuiltinSkyTexture(
            engineContext: engineContext,
            context: context,
            sourcePath: "Textures/Sky/Clouds/Impostors/cloud_card_cumulus.png",
            fallbackHandle: BuiltinAssets.cloudCardCumulus,
            logPrefix: "Cloud card cumulus",
            didLog: &didLogCloudCardCumulusResolution
        ) {
            BuiltinAssets.registerCloudCardTexturesIfNeeded(
                assetManager: engineContext.assets,
                resourcesRootURL: engineContext.resources.resourcesRootURL,
                device: engineContext.device
            )
        }
    }

    private static func resolveBuiltinSkyTexture(engineContext: EngineContext,
                                                 context: String,
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
                level: (texture == nil || fallbackHint) ? .warning : .debug,
                category: .renderer
            )
            _ = fallbackHint
        }
        return texture
    }

    private static func renderSky(_ encoder: MTLRenderCommandEncoder,
                                  snapshot: RenderFrameSnapshot,
                                  frameContext: RendererFrameContext,
                                  sceneConstantsBuffer: MTLBuffer? = nil,
                                  sampleCountOverride: Int? = nil,
                                  useDisplayCompensatedProceduralSky: Bool = true) {
        let environmentRenderState = snapshot.activeEnvironmentRenderState
        let legacySky = snapshot.activeSkyLight
        guard environmentRenderState?.enabled == true || legacySky?.enabled == true else { return }
        let engineContext = frameContext.engineContext()
        guard let mesh = engineContext.assets.mesh(handle: BuiltinAssets.fullscreenQuadMesh) else { return }
        bindSceneConstants(encoder, snapshot: snapshot, frameContext: frameContext, overrideBuffer: sceneConstantsBuffer)
        encoder.setTriangleFillMode(engineContext.preferences.isWireframeEnabled ? .lines : .fill)
        let sampleCount = scenePipelineSampleCount(
            for: .main,
            frameContext: frameContext,
            sampleCountOverride: sampleCountOverride
        )
        let orientationSkyboxEnabled = frameContext.rendererSettings().diagnosticFlags.contains(.orientationSkybox)
        let sourceMode: EnvironmentSourceMode
        if orientationSkyboxEnabled {
            sourceMode = .hdri
        } else if let environmentRenderState {
            sourceMode = environmentRenderState.sourceMode
        } else if legacySky?.mode == .procedural {
            sourceMode = .procedural
        } else {
            sourceMode = .hdri
        }

        switch sourceMode {
        case .procedural:
            // Keep separate visible/capture pipeline entry points, but both now shade from the
            // same HDR procedural sky radiance model so the camera view matches sky-driven IBL.
            encoder.setRenderPipelineState(
                useDisplayCompensatedProceduralSky
                    ? engineContext.graphics.renderPipelineStates.proceduralSkyVisiblePipeline(sampleCount: sampleCount)
                    : engineContext.graphics.renderPipelineStates.proceduralSkyVisibleCapturePipeline(sampleCount: sampleCount)
            )
            var skyParams = environmentRenderState?.legacySkyParams
                ?? SkySystem.shaderParams(authored: legacySky ?? SkyLightComponent(), runtime: snapshot.activeEnvironmentState)
            let moonAlbedoTexture = resolveMoonAlbedoTexture(engineContext: engineContext, context: "visibleSky")
            let galaxyTexture = resolveMilkyWayBackgroundTexture(engineContext: engineContext, context: "visibleSky")
            let cloudAtlasTexture = resolveCloudAtlasTexture(engineContext: engineContext, context: "visibleSky")
            skyParams.moonTextureEnabled = moonAlbedoTexture == nil ? 0.0 : 1.0
            skyParams.galaxyTextureEnabled = galaxyTexture == nil ? 0.0 : 1.0
            skyParams.cloudAtlasEnabled = cloudAtlasTexture == nil ? 0.0 : 1.0
            encoder.setFragmentBytes(&skyParams, length: SkyParams.stride, index: FragmentBufferIndex.skyParams)
            encoder.setFragmentTexture(moonAlbedoTexture ?? engineContext.fallbackTextures.whiteRGBA, index: FragmentTextureIndex.moonAlbedo)
            encoder.setFragmentTexture(galaxyTexture ?? engineContext.fallbackTextures.whiteRGBA, index: FragmentTextureIndex.galaxyBackground)
            encoder.setFragmentTexture(cloudAtlasTexture ?? engineContext.fallbackTextures.blackRGBA, index: FragmentTextureIndex.cloudAtlas)
        case .hdri:
            encoder.setRenderPipelineState(
                engineContext.graphics.renderPipelineStates.skyboxPipeline(sampleCount: sampleCount)
            )
        }
        encoder.setDepthStencilState(engineContext.graphics.depthStencilStates[.LessEqualNoWrite])
        encoder.setCullMode(.none)
        encoder.setFrontFacing(.clockwise)
        var modelConstants = ModelConstants()
        modelConstants.modelMatrix = matrix_identity_float4x4
        encoder.setVertexBytes(&modelConstants, length: ModelConstants.stride, index: VertexBufferIndex.modelConstants)
        if sourceMode == .hdri {
            let authoredEnvironmentTexture = environmentRenderState?.hdriTextureHandle
                .flatMap { engineContext.assets.texture(handle: $0) }
            let diagnosticTexture = orientationSkyboxEnabled
                ? engineContext.assets.texture(handle: BuiltinAssets.diagnosticOrientationCubemap)
                : nil
            let envTexture = diagnosticTexture
                ?? (authoredEnvironmentTexture?.textureType == .typeCube ? authoredEnvironmentTexture : nil)
                ?? frameContext.iblTextures().environment
                ?? engineContext.assets.texture(handle: BuiltinAssets.environmentCubemap)
                ?? engineContext.fallbackTextures.blackCubemap
            encoder.setFragmentSamplerState(engineContext.graphics.samplerStates[.LinearClamp], index: FragmentSamplerIndex.linearClamp)
            encoder.setFragmentTexture(envTexture, index: FragmentTextureIndex.skybox)
        }
        mesh.drawPrimitives(encoder, frameContext: frameContext)
    }

    private static func renderFarCloudCards(_ encoder: MTLRenderCommandEncoder,
                                            snapshot: RenderFrameSnapshot,
                                            frameContext: RendererFrameContext,
                                            sceneConstantsBuffer: MTLBuffer?) {
        let forceDebugCards = farCloudCardsDebugOverrideEnabled()
        guard let environmentState = snapshot.activeEnvironmentRenderState,
              environmentState.enabled else {
            logFarCloudCardsSkip("no active enabled Environment")
            return
        }
        let clouds = environmentState.cloudRenderParams
        let authoredCoverage = min(max(clouds.coverage, 0.0), 1.0)
        guard environmentState.cloudRenderMode != .procedural || forceDebugCards else {
            logFarCloudCardsSkip("cloud render mode is procedural")
            return
        }
        guard clouds.enabled || forceDebugCards else {
            logFarCloudCardsSkip("cloud render params disabled style=\(clouds.style) coverage=\(authoredCoverage)")
            return
        }
        guard clouds.style == .puffy || forceDebugCards else {
            logFarCloudCardsSkip("style is \(clouds.style), expected puffy")
            return
        }
        guard authoredCoverage > 0.02 || forceDebugCards else {
            logFarCloudCardsSkip("coverage too low: \(authoredCoverage)")
            return
        }
        let coverage = forceDebugCards ? max(authoredCoverage, 0.65) : authoredCoverage

        let engineContext = frameContext.engineContext()
        let resolvedCloudCardTexture = resolveCloudCardCumulusTexture(engineContext: engineContext, context: "visibleFarCloudCards")
        let cloudCardTexture: MTLTexture
        let usingDiagnosticTexture: Bool
        if let resolvedCloudCardTexture {
            cloudCardTexture = resolvedCloudCardTexture
            usingDiagnosticTexture = false
        } else {
            cloudCardTexture = engineContext.fallbackTextures.whiteRGBA
            usingDiagnosticTexture = true
            if !didLogCloudCardDiagnosticFallback {
                didLogCloudCardDiagnosticFallback = true
                EngineLoggerContext.log(
                    "Far cloud cards using Fallback.WhiteRGBA diagnostic texture because cloud_card_cumulus.png resolved nil. Solid white rectangles mean the pass is drawing but the cloud card asset lookup/load failed.",
                    level: .warning,
                    category: .renderer
                )
            }
        }
        guard usingDiagnosticTexture || (cloudCardTexture.width > 16 && cloudCardTexture.height > 16) else {
            logFarCloudCardsSkip("cumulus card texture too small: \(cloudCardTexture.width)x\(cloudCardTexture.height) label=\(cloudCardTexture.label ?? "<nil>")")
            return
        }

        let cardCount = min(max(Int(round(2.0 + coverage * 5.0)), 1), 7)
        let windOffset = clouds.windDirection * clouds.windPhase * 0.05
        var params = CloudImpostorParams()
        params.sunDirection = SIMD4<Float>(environmentState.sunDirection, 0)
        params.moonDirection = SIMD4<Float>(environmentState.moonDirection, 0)
        params.windOffsetCoverageAndCount = SIMD4<Float>(windOffset.x, windOffset.y, coverage, Float(cardCount))
        params.skyRadianceAndMultipleScattering = SIMD4<Float>(clouds.skyAmbientRadianceRGB,
                                                               clouds.multipleScattering)
        params.sunIrradiance = SIMD4<Float>(clouds.sunIrradianceRGB, 0)
        params.moonIrradiance = SIMD4<Float>(clouds.moonIrradianceRGB, 0)
        params.layout = SIMD4<Float>(
            7.0,
            2.1 + coverage * 0.5,
            1.45 + coverage * 0.55,
            0.38 + coverage * 0.54
        )

        #if DEBUG
        MC_ASSERT(CloudImpostorParams.stride == CloudImpostorParams.expectedMetalStride,
                  "CloudImpostorParams stride mismatch. Keep Swift and Metal layouts in sync.")
        #endif

        bindSceneConstants(encoder, snapshot: snapshot, frameContext: frameContext, overrideBuffer: sceneConstantsBuffer)
        let sampleCount = scenePipelineSampleCount(for: .main, frameContext: frameContext)
        encoder.setRenderPipelineState(engineContext.graphics.renderPipelineStates.farCloudCardsPipeline(sampleCount: sampleCount))
        encoder.setDepthStencilState(engineContext.graphics.depthStencilStates[.AlwaysNoWrite])
        encoder.setCullMode(.none)
        encoder.setFrontFacing(.clockwise)
        encoder.setTriangleFillMode(.fill)
        encoder.setVertexBytes(&params, length: CloudImpostorParams.stride, index: VertexBufferIndex.cloudImpostorParams)
        encoder.setFragmentBytes(&params, length: CloudImpostorParams.stride, index: FragmentBufferIndex.cloudImpostorParams)
        encoder.setFragmentTexture(cloudCardTexture, index: FragmentTextureIndex.cloudCard)
        encoder.setFragmentSamplerState(engineContext.graphics.samplerStates[.LinearClamp], index: FragmentSamplerIndex.linearClamp)
        if !didLogFarCloudCardDraw {
            didLogFarCloudCardDraw = true
            EngineLoggerContext.log(
                "Far cloud cards draw active forced=\(forceDebugCards) style=\(clouds.style) authoredCoverage=\(authoredCoverage) resolvedCoverage=\(coverage) cardCount=\(cardCount) texture=\(cloudCardTexture.label ?? "<nil>") size=\(cloudCardTexture.width)x\(cloudCardTexture.height)",
                level: .warning,
                category: .renderer
            )
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: cardCount)
    }

    private static func farCloudCardsDebugOverrideEnabled() -> Bool {
        let value = ProcessInfo.processInfo.environment["METALCUP_FORCE_FAR_CLOUD_CARDS"] ?? ""
        return value == "1" || value.lowercased() == "true"
    }

    private static func logFarCloudCardsSkip(_ reason: String) {
        guard !farCloudCardSkipLogKeys.contains(reason) else { return }
        farCloudCardSkipLogKeys.insert(reason)
        EngineLoggerContext.log(
            "Far cloud cards skipped: \(reason). Set METALCUP_FORCE_FAR_CLOUD_CARDS=1 to force the diagnostic card pass when an Environment is active.",
            level: .warning,
            category: .renderer
        )
    }

    private static func syncIBLTextures(snapshot: RenderFrameSnapshot, frameContext: RendererFrameContext) {
        let engineContext = frameContext.engineContext()
        let fallback = engineContext.fallbackTextures
        let environmentState = snapshot.activeEnvironmentRenderState
        let environmentIBLState = snapshot.activeEnvironmentIBLState
        let legacySky = snapshot.activeSkyLight
        let legacyIBLState = snapshot.activeSkyIBLState

        let usesEnvironmentIBL = environmentState?.enabled == true && environmentIBLState != nil
        let envHandle = usesEnvironmentIBL
            ? (environmentIBLState?.environmentTexture ?? BuiltinAssets.environmentCubemap)
            : (legacyIBLState?.iblEnvironmentHandle ?? BuiltinAssets.environmentCubemap)
        let irrHandle = usesEnvironmentIBL
            ? (environmentIBLState?.irradianceTexture ?? BuiltinAssets.irradianceCubemap)
            : (legacyIBLState?.iblIrradianceHandle ?? BuiltinAssets.irradianceCubemap)
        let preHandle = usesEnvironmentIBL
            ? (environmentIBLState?.prefilteredTexture ?? BuiltinAssets.prefilteredCubemap)
            : (legacyIBLState?.iblPrefilteredHandle ?? BuiltinAssets.prefilteredCubemap)
        let brdfHandle = usesEnvironmentIBL
            ? (environmentIBLState?.brdfLUT ?? BuiltinAssets.brdfLut)
            : (legacyIBLState?.iblBrdfHandle ?? BuiltinAssets.brdfLut)
        let env = engineContext.assets.texture(handle: envHandle) ?? fallback.blackCubemap
        let irr = engineContext.assets.texture(handle: irrHandle) ?? fallback.blackCubemap
        let pre = engineContext.assets.texture(handle: preHandle) ?? fallback.blackCubemap
        let brdf = engineContext.assets.texture(handle: brdfHandle) ?? fallback.brdfLut
        let diagnosticFlags = frameContext.rendererSettings().diagnosticFlags
        let diagnosticGlobalIBLEnabled = diagnosticFlags.contains(.orientationGlobalIBL)
        let diagnosticEnv = diagnosticGlobalIBLEnabled
            ? engineContext.assets.texture(handle: BuiltinAssets.diagnosticOrientationCubemap)
            : nil
        let diagnosticIrr = diagnosticGlobalIBLEnabled
            ? engineContext.assets.texture(handle: BuiltinAssets.diagnosticOrientationIrradianceCubemap)
            : nil
        let diagnosticPre = diagnosticGlobalIBLEnabled
            ? engineContext.assets.texture(handle: BuiltinAssets.diagnosticOrientationPrefilteredCubemap)
            : nil
        let needsRebuild = usesEnvironmentIBL
            ? (environmentIBLState?.needsRebuild ?? true)
            : (legacyIBLState?.needsRebuild ?? true)
        let ownerEnabled = usesEnvironmentIBL
            ? (environmentState?.enabled ?? false)
            : (legacySky?.enabled ?? false)
        let hasValidIBL = ownerEnabled
            && !needsRebuild
            && !fallback.isFallbackTexture(irr)
            && !fallback.isFallbackTexture(pre)
            && !fallback.isFallbackTexture(brdf)
        frameContext.updateIBLTextures(
            environment: diagnosticEnv ?? env,
            irradiance: diagnosticIrr ?? irr,
            prefiltered: diagnosticPre ?? pre,
            brdfLut: brdf
        )
        frameContext.setIBLReady(diagnosticGlobalIBLEnabled ? (diagnosticIrr != nil && diagnosticPre != nil) : hasValidIBL)
    }

    private static func renderMeshes(_ encoder: MTLRenderCommandEncoder,
                                     snapshot: RenderFrameSnapshot,
                                     pass: RenderPassType,
                                     frameContext: RendererFrameContext,
                                     sceneConstantsBuffer: MTLBuffer? = nil,
                                     shadowCullVolume: ShadowCullVolume? = nil,
                                     sampleCountOverride: Int? = nil) {
        let submissionResult = currentSubmissionResult(snapshot: snapshot, frameContext: frameContext)
        let batchResult = submissionResult.opaqueBatchResult
        if let bonePaletteBuffer = batchResult.bonePaletteBuffer {
            encoder.setVertexBuffer(bonePaletteBuffer, offset: 0, index: VertexBufferIndex.bonePalette)
        } else {
            var identityPalette = matrix_identity_float4x4
            encoder.setVertexBytes(&identityPalette,
                                   length: MemoryLayout<matrix_float4x4>.stride,
                                   index: VertexBufferIndex.bonePalette)
        }
        bindSceneConstants(encoder, snapshot: snapshot, frameContext: frameContext, overrideBuffer: sceneConstantsBuffer)
        if let instanceBuffer = batchResult.instanceBuffer {
            renderOpaqueBatches(
                encoder,
                snapshot: snapshot,
                pass: pass,
                batchResult: batchResult,
                instanceBuffer: instanceBuffer,
                sceneConstantsBuffer: sceneConstantsBuffer,
                shadowCullVolume: shadowCullVolume,
                frameContext: frameContext,
                sampleCountOverride: sampleCountOverride
            )
        }
        if pass == .transparent {
            renderTransparentDraws(
                encoder,
                snapshot: snapshot,
                submissionResult: submissionResult,
                sceneConstantsBuffer: sceneConstantsBuffer,
                frameContext: frameContext,
                sampleCountOverride: sampleCountOverride
            )
        } else if pass == .picking {
            renderTransparentPickingDraws(
                encoder,
                snapshot: snapshot,
                submissionResult: submissionResult,
                sceneConstantsBuffer: sceneConstantsBuffer,
                frameContext: frameContext
            )
        }
    }

    private static func renderOpaqueBatches(_ encoder: MTLRenderCommandEncoder,
                                            snapshot: RenderFrameSnapshot,
                                            pass: RenderPassType,
                                            batchResult: RenderBatchResult,
                                            instanceBuffer: MTLBuffer,
                                            sceneConstantsBuffer: MTLBuffer?,
                                            shadowCullVolume: ShadowCullVolume?,
                                            frameContext: RendererFrameContext,
                                            sampleCountOverride: Int? = nil) {
        let instanceStride = InstanceData.stride
        for batch in batchResult.batches {
            let instanceCount = batch.instanceRange.count
            if instanceCount == 0 { continue }
            MC_ASSERT(batch.instanceRange.upperBound <= batchResult.instances.count, "Batch instance range out of bounds.")
            applyPerDrawState(
                encoder,
                pass: pass,
                passKey: batch.bindings.passKey,
                cullMode: batch.bindings.cullMode,
                frameContext: frameContext
            )
            if pass == .shadow, let shadowCullVolume {
                if !batch.bindings.passKey.castsShadows { continue }
                var visibleStart = -1
                for instanceIndex in batch.instanceRange {
                    MC_ASSERT(instanceIndex < batchResult.instanceBounds.count, "Batch bounds range out of bounds.")
                    let bounds = batchResult.instanceBounds[instanceIndex]
                    let isVisible = intersects(bounds: bounds, volume: shadowCullVolume)
                    if isVisible {
                        if visibleStart < 0 {
                            visibleStart = instanceIndex
                        }
                    } else if visibleStart >= 0 {
                        encodeShadowDrawRange(
                            encoder,
                            snapshot: snapshot,
                            batch: batch,
                            batchResult: batchResult,
                            instanceBuffer: instanceBuffer,
                            startIndex: visibleStart,
                            endIndex: instanceIndex,
                            instanceStride: instanceStride,
                            sceneConstantsBuffer: sceneConstantsBuffer,
                            frameContext: frameContext
                        )
                        visibleStart = -1
                    }
                }
                if visibleStart >= 0 {
                    encodeShadowDrawRange(
                        encoder,
                        snapshot: snapshot,
                        batch: batch,
                        batchResult: batchResult,
                        instanceBuffer: instanceBuffer,
                        startIndex: visibleStart,
                        endIndex: batch.instanceRange.upperBound,
                        instanceStride: instanceStride,
                        sceneConstantsBuffer: sceneConstantsBuffer,
                        frameContext: frameContext
                    )
                }
                continue
            }

            let instanceOffset = batch.instanceRange.lowerBound * instanceStride
            switch pass {
            case .depthPrepass:
                encodeDepthPrepass(
                    encoder,
                    snapshot: snapshot,
                    batch: batch,
                    batchResult: batchResult,
                    instanceBuffer: instanceBuffer,
                    instanceOffset: instanceOffset,
                    instanceCount: instanceCount,
                    sceneConstantsBuffer: sceneConstantsBuffer,
                    frameContext: frameContext
                )
            case .normal, .ssaoNormal:
                encodeNormalPass(
                    encoder,
                    pass: pass,
                    snapshot: snapshot,
                    batch: batch,
                    batchResult: batchResult,
                    instanceBuffer: instanceBuffer,
                    instanceOffset: instanceOffset,
                    instanceCount: instanceCount,
                    sceneConstantsBuffer: sceneConstantsBuffer,
                    frameContext: frameContext
                )
            case .shadow:
                if !batch.bindings.passKey.castsShadows { continue }
                encodeShadowPass(
                    encoder,
                    snapshot: snapshot,
                    batch: batch,
                    batchResult: batchResult,
                    instanceBuffer: instanceBuffer,
                    instanceOffset: instanceOffset,
                    instanceCount: instanceCount,
                    sceneConstantsBuffer: sceneConstantsBuffer,
                    frameContext: frameContext
                )
            case .picking:
                encodePicking(
                    encoder,
                    snapshot: snapshot,
                    batch: batch,
                    instanceBuffer: instanceBuffer,
                    instanceOffset: instanceOffset,
                    instanceCount: instanceCount,
                    sceneConstantsBuffer: sceneConstantsBuffer,
                    frameContext: frameContext
                )
            case .main:
                encodeMainPass(
                    encoder,
                    snapshot: snapshot,
                    batch: batch,
                    batchResult: batchResult,
                    instanceBuffer: instanceBuffer,
                    instanceOffset: instanceOffset,
                    instanceCount: instanceCount,
                    sceneConstantsBuffer: sceneConstantsBuffer,
                    frameContext: frameContext,
                    sampleCountOverride: sampleCountOverride
                )
            case .transparent:
                continue
            }
        }
    }

    private static func renderTransparentDraws(_ encoder: MTLRenderCommandEncoder,
                                               snapshot: RenderFrameSnapshot,
                                               submissionResult: RenderSubmissionResult,
                                               sceneConstantsBuffer: MTLBuffer?,
                                               frameContext: RendererFrameContext,
                                               sampleCountOverride: Int? = nil) {
        guard let instanceBuffer = submissionResult.transparentInstanceBuffer else { return }
        let instanceStride = InstanceData.stride
        for draw in submissionResult.transparentDraws {
            applyPerDrawState(
                encoder,
                pass: .transparent,
                passKey: draw.item.bindings.passKey,
                cullMode: draw.item.bindings.cullMode,
                frameContext: frameContext
            )
            let pipeline = pipelineState(
                for: .transparent,
                key: draw.item.bindings.passKey,
                frameContext: frameContext,
                sampleCountOverride: sampleCountOverride
            )
            let instanceOffset = draw.instanceIndex * instanceStride
            encodeTransparentDraw(
                encoder,
                snapshot: snapshot,
                item: draw.item,
                instanceBuffer: instanceBuffer,
                instanceOffset: instanceOffset,
                pipelineState: pipeline,
                sceneConstantsBuffer: sceneConstantsBuffer,
                frameContext: frameContext
            )
        }
    }

    private static func renderTransparentPickingDraws(_ encoder: MTLRenderCommandEncoder,
                                                      snapshot: RenderFrameSnapshot,
                                                      submissionResult: RenderSubmissionResult,
                                                      sceneConstantsBuffer: MTLBuffer?,
                                                      frameContext: RendererFrameContext) {
        guard let instanceBuffer = submissionResult.transparentInstanceBuffer else { return }
        let instanceStride = InstanceData.stride
        for draw in submissionResult.transparentDraws {
            // Phase 1 policy: visible transparent/additive items participate in picking.
            // Use picking-specific depth behavior instead of the transparent color-pass state.
            applyPerDrawState(
                encoder,
                pass: .picking,
                passKey: draw.item.bindings.passKey,
                cullMode: draw.item.bindings.cullMode,
                frameContext: frameContext
            )
            let instanceOffset = draw.instanceIndex * instanceStride
            encodeTransparentPickingDraw(
                encoder,
                snapshot: snapshot,
                item: draw.item,
                instanceBuffer: instanceBuffer,
                instanceOffset: instanceOffset,
                sceneConstantsBuffer: sceneConstantsBuffer,
                frameContext: frameContext
            )
        }
    }

    private static func applyPerDrawState(_ encoder: MTLRenderCommandEncoder,
                                          pass: RenderPassType,
                                          passKey: MaterialPassKey,
                                          cullMode: MTLCullMode,
                                          frameContext: RendererFrameContext) {
        let engineContext = frameContext.engineContext()
        encoder.setTriangleFillMode(engineContext.preferences.isWireframeEnabled ? .lines : .fill)
        let usePrepassEquality: Bool
        if pass == .normal {
            // SceneNormalsPass always depth-tests against canonical single-sample scene.depth,
            // so it should use strict equality whenever the prepass populated that attachment.
            usePrepassEquality = frameContext.useDepthPrepass()
        } else if pass == .ssaoNormal {
            // The AO pass owns and clears its single-sample depth attachment, so it writes the
            // closest surface while producing the matching smooth view-space normal.
            usePrepassEquality = false
        } else {
            usePrepassEquality = frameContext.useDepthPrepass()
                && pass == .main
                && mainPassUsesPrepassDepth(frameContext: frameContext)
        }
        if pass == .depthPrepass || pass == .ssaoNormal {
            encoder.setDepthStencilState(engineContext.graphics.depthStencilStates[.LessEqual])
        } else if (pass == .main || pass == .transparent), passKey.blendMode.usesDepthWrite == false {
            encoder.setDepthStencilState(engineContext.graphics.depthStencilStates[.LessNoWrite])
        } else if usePrepassEquality {
            // Shared vertex shader keeps clip-space depth identical, so strict equality is only safe
            // when the main pass depth-tests against the same attachment produced by the prepass.
            encoder.setDepthStencilState(engineContext.graphics.depthStencilStates[.EqualNoWrite])
        } else {
            encoder.setDepthStencilState(engineContext.graphics.depthStencilStates[.Less])
        }
        if pass == .shadow {
            // Default to front-face culling to reduce self-shadowing (acne).
            // Preserve double-sided materials by honoring .none from material bindings.
            let isDoubleSided = (cullMode == .none)
            encoder.setCullMode(isDoubleSided ? .none : .front)
        } else {
            encoder.setCullMode(cullMode)
        }
        encoder.setFrontFacing(
            frameContext.viewContext().usesMirroredCubemapProjection ? .clockwise : .counterClockwise
        )
        switch pass {
        case .depthPrepass:
            // Depth prepass should match main pass depth without bias.
            encoder.setDepthBias(0.0, slopeScale: 0.0, clamp: 0.0)
        case .shadow:
            // Shadow bias is handled in shader to avoid double-biasing.
            encoder.setDepthBias(0.0, slopeScale: 0.0, clamp: 0.0)
        default:
            encoder.setDepthBias(0.0, slopeScale: 0.0, clamp: 0.0)
        }
    }

    private static func mainPassUsesPrepassDepth(frameContext: RendererFrameContext) -> Bool {
        guard let registry = frameContext.renderResourceRegistry(),
              let sceneDepth = registry.namedTexture(RenderNamedResourceKey.sceneDepthMSAA),
              let prepassDepth = registry.namedTexture(RenderNamedResourceKey.sceneDepth) else {
            return true
        }
        // Strict equality is only valid when the main pass actually tests against the exact depth
        // texture produced by the prepass. Matching sample count alone is not sufficient.
        return sceneDepth === prepassDepth
    }

    private static func encodeDepthPrepass(
        _ encoder: MTLRenderCommandEncoder,
        snapshot: RenderFrameSnapshot,
        batch: RenderBatch,
        batchResult: RenderBatchResult,
        instanceBuffer: MTLBuffer,
        instanceOffset: Int,
        instanceCount: Int,
        sceneConstantsBuffer: MTLBuffer?,
        frameContext: RendererFrameContext
    ) {
        let pipeline = pipelineState(for: .depthPrepass, key: batch.bindings.passKey, frameContext: frameContext)
        let useAlphaClip = batch.bindings.passKey.blendMode == .alphaClip
        encodeMeshBatch(
            encoder,
            snapshot: snapshot,
            batch: batch,
            batchResult,
            instanceBuffer: instanceBuffer,
            instanceOffset: instanceOffset,
            instanceCount: instanceCount,
            pipelineState: pipeline,
            bindings: useAlphaClip ? batch.bindings : nil,
            sceneConstantsBuffer: sceneConstantsBuffer,
            frameContext: frameContext
        )
    }

    private static func encodeShadowPass(
        _ encoder: MTLRenderCommandEncoder,
        snapshot: RenderFrameSnapshot,
        batch: RenderBatch,
        batchResult: RenderBatchResult,
        instanceBuffer: MTLBuffer,
        instanceOffset: Int,
        instanceCount: Int,
        sceneConstantsBuffer: MTLBuffer?,
        frameContext: RendererFrameContext
    ) {
        let pipeline = pipelineState(for: .shadow, key: batch.bindings.passKey, frameContext: frameContext)
        let useAlphaClip = batch.bindings.passKey.blendMode == .alphaClip
        encodeMeshBatch(
            encoder,
            snapshot: snapshot,
            batch: batch,
            batchResult,
            instanceBuffer: instanceBuffer,
            instanceOffset: instanceOffset,
            instanceCount: instanceCount,
            pipelineState: pipeline,
            bindings: useAlphaClip ? batch.bindings : nil,
            sceneConstantsBuffer: sceneConstantsBuffer,
            frameContext: frameContext
        )
    }

    private static func encodeNormalPass(
        _ encoder: MTLRenderCommandEncoder,
        pass: RenderPassType,
        snapshot: RenderFrameSnapshot,
        batch: RenderBatch,
        batchResult: RenderBatchResult,
        instanceBuffer: MTLBuffer,
        instanceOffset: Int,
        instanceCount: Int,
        sceneConstantsBuffer: MTLBuffer?,
        frameContext: RendererFrameContext
    ) {
        let pipeline = pipelineState(for: pass, key: batch.bindings.passKey, frameContext: frameContext)
        let useAlphaClip = batch.bindings.passKey.blendMode == .alphaClip
        encodeMeshBatch(
            encoder,
            snapshot: snapshot,
            batch: batch,
            batchResult,
            instanceBuffer: instanceBuffer,
            instanceOffset: instanceOffset,
            instanceCount: instanceCount,
            pipelineState: pipeline,
            bindings: useAlphaClip ? batch.bindings : nil,
            sceneConstantsBuffer: sceneConstantsBuffer,
            frameContext: frameContext
        )
    }

    private static func encodePicking(
        _ encoder: MTLRenderCommandEncoder,
        snapshot: RenderFrameSnapshot,
        batch: RenderBatch,
        instanceBuffer: MTLBuffer,
        instanceOffset: Int,
        instanceCount: Int,
        sceneConstantsBuffer: MTLBuffer?,
        frameContext: RendererFrameContext
    ) {
        let engineContext = frameContext.engineContext()
        encoder.setRenderPipelineState(engineContext.graphics.renderPipelineStates[.PickID])
        bindSceneConstants(encoder, snapshot: snapshot, frameContext: frameContext, overrideBuffer: sceneConstantsBuffer)
        bindInstanceBuffer(encoder, buffer: instanceBuffer, offset: instanceOffset)
        batch.mesh.setInstanceCount(instanceCount)
        drawMesh(encoder, mesh: batch.mesh, bindings: nil, frameContext: frameContext)
    }

    private static func encodeMainPass(
        _ encoder: MTLRenderCommandEncoder,
        snapshot: RenderFrameSnapshot,
        batch: RenderBatch,
        batchResult: RenderBatchResult,
        instanceBuffer: MTLBuffer,
        instanceOffset: Int,
        instanceCount: Int,
        sceneConstantsBuffer: MTLBuffer?,
        frameContext: RendererFrameContext,
        sampleCountOverride: Int? = nil
    ) {
        let pipelineState = pipelineState(
            for: .main,
            key: batch.bindings.passKey,
            frameContext: frameContext,
            sampleCountOverride: sampleCountOverride
        )
        encodeMeshBatch(
            encoder,
            snapshot: snapshot,
            batch: batch,
            batchResult,
            instanceBuffer: instanceBuffer,
            instanceOffset: instanceOffset,
            instanceCount: instanceCount,
            pipelineState: pipelineState,
            bindings: batch.bindings,
            sceneConstantsBuffer: sceneConstantsBuffer,
            frameContext: frameContext
        )
    }

    private static func encodeTransparentDraw(
        _ encoder: MTLRenderCommandEncoder,
        snapshot: RenderFrameSnapshot,
        item: RenderItem,
        instanceBuffer: MTLBuffer,
        instanceOffset: Int,
        pipelineState: MTLRenderPipelineState,
        sceneConstantsBuffer: MTLBuffer?,
        frameContext: RendererFrameContext
    ) {
        encoder.setRenderPipelineState(pipelineState)
        bindSceneConstants(encoder, snapshot: snapshot, frameContext: frameContext, overrideBuffer: sceneConstantsBuffer)
        bindInstanceBuffer(encoder, buffer: instanceBuffer, offset: instanceOffset)
        assertInstanceBindings(instanceBuffer: instanceBuffer, instanceOffset: instanceOffset, instanceCount: 1)
        item.mesh.setInstanceCount(1)
        drawMesh(encoder, mesh: item.mesh, submeshIndex: item.submeshIndex, bindings: item.bindings, frameContext: frameContext)
    }

    private static func encodeTransparentPickingDraw(
        _ encoder: MTLRenderCommandEncoder,
        snapshot: RenderFrameSnapshot,
        item: RenderItem,
        instanceBuffer: MTLBuffer,
        instanceOffset: Int,
        sceneConstantsBuffer: MTLBuffer?,
        frameContext: RendererFrameContext
    ) {
        let engineContext = frameContext.engineContext()
        encoder.setRenderPipelineState(engineContext.graphics.renderPipelineStates[.PickID])
        bindSceneConstants(encoder, snapshot: snapshot, frameContext: frameContext, overrideBuffer: sceneConstantsBuffer)
        bindInstanceBuffer(encoder, buffer: instanceBuffer, offset: instanceOffset)
        assertInstanceBindings(instanceBuffer: instanceBuffer, instanceOffset: instanceOffset, instanceCount: 1)
        item.mesh.setInstanceCount(1)
        drawMesh(encoder, mesh: item.mesh, submeshIndex: item.submeshIndex, bindings: nil, frameContext: frameContext)
    }

    private static func encodeMeshBatch(
        _ encoder: MTLRenderCommandEncoder,
        snapshot: RenderFrameSnapshot,
        batch: RenderBatch,
        _ batchResult: RenderBatchResult,
        instanceBuffer: MTLBuffer,
        instanceOffset: Int,
        instanceCount: Int,
        pipelineState: MTLRenderPipelineState,
        bindings: MaterialBindings?,
        sceneConstantsBuffer: MTLBuffer?,
        frameContext: RendererFrameContext
    ) {
        // Instanced-only pipeline keeps a single vertex path for every draw, preventing PSO + clip-space divergence.
        encoder.setRenderPipelineState(pipelineState)
        bindSceneConstants(encoder, snapshot: snapshot, frameContext: frameContext, overrideBuffer: sceneConstantsBuffer)
        bindInstanceBuffer(encoder, buffer: instanceBuffer, offset: instanceOffset)
        assertInstanceBindings(instanceBuffer: instanceBuffer, instanceOffset: instanceOffset, instanceCount: instanceCount)
        batch.mesh.setInstanceCount(instanceCount)
        drawMesh(encoder, mesh: batch.mesh, submeshIndex: batch.submeshIndex, bindings: bindings, frameContext: frameContext)
    }

    private static func drawMesh(_ encoder: MTLRenderCommandEncoder,
                                 mesh: MCMesh,
                                 submeshIndex: Int? = nil,
                                 bindings: MaterialBindings?,
                                 frameContext: RendererFrameContext) {
        if let submeshIndex {
            mesh.drawSubmeshPrimitives(
                encoder,
                submeshIndex: submeshIndex,
                frameContext: frameContext,
                material: bindings?.materialOverride,
                albedoMapHandle: bindings?.albedoMapHandle,
                normalMapHandle: bindings?.normalMapHandle,
                metallicMapHandle: bindings?.metallicMapHandle,
                roughnessMapHandle: bindings?.roughnessMapHandle,
                mrMapHandle: bindings?.mrMapHandle,
                ormMapHandle: bindings?.ormMapHandle,
                aoMapHandle: bindings?.aoMapHandle,
                emissiveMapHandle: bindings?.emissiveMapHandle,
                localReflectionProbe: bindings?.localReflectionProbe,
                localReflectionPrefilteredHandle: bindings?.localReflectionPrefilteredHandle,
                useEmbeddedMaterial: false
            )
            return
        }

        mesh.drawPrimitives(
            encoder,
            frameContext: frameContext,
            material: bindings?.materialOverride,
            albedoMapHandle: bindings?.albedoMapHandle,
            normalMapHandle: bindings?.normalMapHandle,
            metallicMapHandle: bindings?.metallicMapHandle,
            roughnessMapHandle: bindings?.roughnessMapHandle,
            mrMapHandle: bindings?.mrMapHandle,
            ormMapHandle: bindings?.ormMapHandle,
            aoMapHandle: bindings?.aoMapHandle,
            emissiveMapHandle: bindings?.emissiveMapHandle,
            localReflectionProbe: bindings?.localReflectionProbe,
            localReflectionPrefilteredHandle: bindings?.localReflectionPrefilteredHandle,
            useEmbeddedMaterial: false
        )
    }

    private static func resolvedSceneConstantsBuffer(snapshot: RenderFrameSnapshot, frameContext: RendererFrameContext) -> MTLBuffer {
        var constants = snapshot.sceneConstants
        if !frameContext.iblReady() {
            constants.cameraPositionAndIBL.w = 0.0
        }
        let buffer = frameContext.uploadSceneConstants(constants)
#if DEBUG
        MC_ASSERT(SceneConstants.stride == SceneConstants.expectedMetalStride, "SceneConstants stride mismatch. Keep Swift and Metal layouts in sync.")
#endif
        MC_ASSERT(buffer.length >= SceneConstants.stride, "SceneConstants buffer too small.")
        return buffer
    }

    private static func bindSceneConstants(_ encoder: MTLRenderCommandEncoder,
                                           snapshot: RenderFrameSnapshot,
                                           frameContext: RendererFrameContext,
                                           overrideBuffer: MTLBuffer? = nil) {
        if let overrideBuffer {
            MC_ASSERT(overrideBuffer.length >= SceneConstants.stride, "SceneConstants override buffer too small.")
            encoder.setVertexBuffer(overrideBuffer, offset: 0, index: VertexBufferIndex.sceneConstants)
            encoder.setFragmentBuffer(overrideBuffer, offset: 0, index: FragmentBufferIndex.postProcessSceneConstants)
            return
        }
        let buffer = resolvedSceneConstantsBuffer(snapshot: snapshot, frameContext: frameContext)
        encoder.setVertexBuffer(buffer, offset: 0, index: VertexBufferIndex.sceneConstants)
        encoder.setFragmentBuffer(buffer, offset: 0, index: FragmentBufferIndex.postProcessSceneConstants)
    }

    private static func bindInstanceBuffer(_ encoder: MTLRenderCommandEncoder, buffer: MTLBuffer, offset: Int) {
        encoder.setVertexBuffer(buffer, offset: offset, index: VertexBufferIndex.instances)
    }

    private static func bindRendererSettings(_ encoder: MTLRenderCommandEncoder, settings: RendererSettings, frameContext: RendererFrameContext) {
        var resolvedSettings = settings
        if !frameContext.iblReady() {
            resolvedSettings.iblEnabled = 0
            resolvedSettings.iblIntensity = 0.0
        }
        if !frameContext.isForwardPlusAllowed() {
            resolvedSettings.setPerfFlag(.forwardPlusEnabled, enabled: false)
        }
        let settingsBuffer = frameContext.uploadRendererSettings(resolvedSettings)
#if DEBUG
        MC_ASSERT(RendererSettings.stride == RendererSettings.expectedMetalStride, "RendererSettings stride mismatch. Keep Swift and Metal layouts in sync.")
        MC_ASSERT(settingsBuffer.buffer.length >= RendererSettings.expectedMetalStride, "RendererSettings buffer too small.")
#endif
        encoder.setFragmentBuffer(settingsBuffer.buffer, offset: settingsBuffer.offset, index: FragmentBufferIndex.rendererSettings)
    }

    private static func bindShadowResources(_ encoder: MTLRenderCommandEncoder, frameContext: RendererFrameContext) {
        let shadowBuffer = frameContext.shadowConstantsBuffer()
        encoder.setFragmentBuffer(shadowBuffer, offset: 0, index: FragmentBufferIndex.shadowConstants)
        let fallback = frameContext.engineContext().fallbackTextures
        let shadowTexture = frameContext.shadowMapTexture() ?? fallback.shadowMap
        encoder.setFragmentTexture(shadowTexture, index: FragmentTextureIndex.shadowMap)
        encoder.setFragmentTexture(shadowTexture, index: FragmentTextureIndex.shadowMapSample)
        encoder.setFragmentSamplerState(frameContext.engineContext().graphics.samplerStates[.LinearClamp], index: FragmentSamplerIndex.linearClamp)
        encoder.setFragmentSamplerState(frameContext.engineContext().graphics.samplerStates[.ShadowCompare], index: FragmentSamplerIndex.shadowCompare)
        encoder.setFragmentSamplerState(frameContext.engineContext().graphics.samplerStates[.ShadowDepth], index: FragmentSamplerIndex.shadowDepth)

    }

    private static func prepareLightingInputs(snapshot: RenderFrameSnapshot, frameContext: RendererFrameContext) {
        let localLightBuffers = frameContext.uploadLocalLightData(snapshot.localLights)
        let directionalLightBuffers = frameContext.uploadDirectionalLightData(snapshot.directionalLights)
#if DEBUG
        MC_ASSERT(localLightBuffers.countBuffer !== directionalLightBuffers.countBuffer
                    && localLightBuffers.dataBuffer !== directionalLightBuffers.dataBuffer,
                  "Local and directional light streams must not share buffers.")
#endif
        let registry = frameContext.renderResourceRegistry()
        let allowForwardPlus = frameContext.isForwardPlusAllowed()
        let inputs = LightingInputs(
            localLightCountBuffer: localLightBuffers.countBuffer,
            localLightDataBuffer: localLightBuffers.dataBuffer,
            directionalLightCountBuffer: directionalLightBuffers.countBuffer,
            directionalLightDataBuffer: directionalLightBuffers.dataBuffer,
            lightGridBuffer: allowForwardPlus ? registry?.buffer(RenderNamedResourceKey.forwardPlusLightGrid) : nil,
            lightIndexListBuffer: allowForwardPlus ? registry?.buffer(RenderNamedResourceKey.forwardPlusLightIndexList) : nil,
            lightIndexCountBuffer: allowForwardPlus ? registry?.buffer(RenderNamedResourceKey.forwardPlusLightIndexCount) : nil,
            clusterParamsBuffer: allowForwardPlus ? registry?.buffer(RenderNamedResourceKey.forwardPlusClusterParams) : nil,
            tileLightGridBuffer: allowForwardPlus ? registry?.buffer(RenderNamedResourceKey.forwardPlusTileLightGrid) : nil,
            tileParamsBuffer: allowForwardPlus ? registry?.buffer(RenderNamedResourceKey.forwardPlusTileParams) : nil
        )
        frameContext.setLightingInputs(inputs)
    }

    private static func bindLightingInputs(_ encoder: MTLRenderCommandEncoder, frameContext: RendererFrameContext) {
        guard let inputs = frameContext.lightingInputs() else { return }
        encoder.setFragmentBuffer(inputs.localLightCountBuffer, offset: 0, index: FragmentBufferIndex.lightCount)
        encoder.setFragmentBuffer(inputs.localLightDataBuffer, offset: 0, index: FragmentBufferIndex.lightData)
        encoder.setFragmentBuffer(inputs.directionalLightCountBuffer, offset: 0, index: FragmentBufferIndex.directionalLightCount)
        encoder.setFragmentBuffer(inputs.directionalLightDataBuffer, offset: 0, index: FragmentBufferIndex.directionalLightData)
        encoder.setFragmentBuffer(inputs.lightGridBuffer ?? frameContext.fallbackForwardPlusLightGridBuffer(),
                                  offset: 0,
                                  index: FragmentBufferIndex.lightGrid)
        encoder.setFragmentBuffer(inputs.lightIndexListBuffer ?? frameContext.fallbackForwardPlusLightIndexListBuffer(),
                                  offset: 0,
                                  index: FragmentBufferIndex.lightIndexList)
        encoder.setFragmentBuffer(inputs.lightIndexCountBuffer ?? frameContext.fallbackForwardPlusLightIndexCountBuffer(),
                                  offset: 0,
                                  index: FragmentBufferIndex.lightIndexCount)
        encoder.setFragmentBuffer(inputs.clusterParamsBuffer ?? frameContext.fallbackForwardPlusClusterParamsBuffer(),
                                  offset: 0,
                                  index: FragmentBufferIndex.lightClusterParams)
        encoder.setFragmentBuffer(inputs.tileLightGridBuffer ?? frameContext.fallbackForwardPlusTileLightGridBuffer(),
                                  offset: 0,
                                  index: FragmentBufferIndex.tileLightGrid)
        encoder.setFragmentBuffer(inputs.tileParamsBuffer ?? frameContext.fallbackForwardPlusTileParamsBuffer(),
                                  offset: 0,
                                  index: FragmentBufferIndex.tileParams)
    }

    private static func pipelineState(for pass: RenderPassType,
                                      key: MaterialPassKey,
                                      frameContext: RendererFrameContext,
                                      sampleCountOverride: Int? = nil) -> MTLRenderPipelineState {
        let engineContext = frameContext.engineContext()
        let sampleCount = scenePipelineSampleCount(
            for: pass,
            frameContext: frameContext,
            sampleCountOverride: sampleCountOverride
        )
        switch pass {
        case .main, .transparent:
            // Short-term cutout AA policy:
            // - main scene color uses alpha-to-coverage for alpha-clip materials
            // - depth prepass and shadow passes remain binary alpha clip for now
            return engineContext.graphics.renderPipelineStates.hdrInstancedPipeline(
                settings: frameContext.rendererSettings(),
                blendMode: hdrBlendMode(for: key),
                sampleCount: sampleCount,
                alphaToCoverageEnabled: key.blendMode == .alphaClip
            )
        case .normal:
            return engineContext.graphics.renderPipelineStates.sceneNormalsPipeline(
                alphaMasked: key.blendMode == .alphaClip
            )
        case .ssaoNormal:
            return engineContext.graphics.renderPipelineStates.aoNormalsPipeline(
                alphaMasked: key.blendMode == .alphaClip
            )
        case .depthPrepass:
            return engineContext.graphics.renderPipelineStates.depthPrepassPipeline(
                alphaMasked: key.blendMode == .alphaClip,
                sampleCount: sampleCount
            )
        case .shadow:
            if key.blendMode == .alphaClip {
                return engineContext.graphics.renderPipelineStates[.ShadowAlphaInstanced]
            }
            return engineContext.graphics.renderPipelineStates[.DepthPrepassInstanced]
        case .picking:
            return engineContext.graphics.renderPipelineStates[.PickID]
        }
    }

    private static func hdrBlendMode(for key: MaterialPassKey) -> HDRBlendMode {
        switch key.blendMode {
        case .opaque, .alphaClip:
            return .opaque
        case .transparent:
            return .transparent
        case .additive:
            return .additive
        }
    }

    private static func scenePipelineSampleCount(for pass: RenderPassType,
                                                 frameContext: RendererFrameContext,
                                                 sampleCountOverride: Int? = nil) -> Int {
        if let sampleCountOverride {
            return max(sampleCountOverride, 1)
        }
        switch pass {
        case .main, .transparent, .depthPrepass, .normal, .ssaoNormal:
            if pass == .depthPrepass || pass == .normal || pass == .ssaoNormal {
                return 1
            }
            let registry = frameContext.renderResourceRegistry()
            if let sceneColorMSAA = registry?.namedTexture(RenderNamedResourceKey.sceneColorMSAA) {
                return max(sceneColorMSAA.sampleCount, 1)
            }
            return max(frameContext.engineContext().preferences.sceneMSAASampleCount, 1)
        case .shadow, .picking:
            return 1
        }
    }


    static func renderShadowCasters(into encoder: MTLRenderCommandEncoder,
                                    snapshot: RenderFrameSnapshot,
                                    frameContext: RendererFrameContext,
                                    sceneConstantsBuffer: MTLBuffer?,
                                    shadowCullVolume: ShadowCullVolume? = nil) {
        renderMeshes(
            encoder,
            snapshot: snapshot,
            pass: .shadow,
            frameContext: frameContext,
            sceneConstantsBuffer: sceneConstantsBuffer,
            shadowCullVolume: shadowCullVolume
        )
    }

    static func prepareRenderFrameSnapshot(scene: EngineScene, frameContext: RendererFrameContext) {
        let snapshot = scene.makeRenderFrameSnapshot(
            frameToken: frameContext.currentFrameCounter(),
            layerFilterMask: frameContext.layerFilterMask()
        )
        frameContext.setRenderFrameSnapshot(snapshot)
        let key = FrameCacheKey(
            sceneKey: snapshot.sceneKey,
            frameToken: snapshot.frameToken,
            snapshotSignature: snapshot.signature,
            viewSignature: frameContext.viewContext().cacheSignature(),
            cullingConfigSignature: cullingConfigSignature(frameContext: frameContext),
            stateRevision: frameContext.rendererStateRevision(),
            assetStateRevision: frameContext.assetStateRevision()
        )
        if frameCache[key] == nil {
            frameCache[key] = FrameCacheEntry(key: key, snapshot: snapshot, result: nil)
            trimFrameCache(keepingFrameToken: key.frameToken)
        }
        markSnapshotPrepared(
            SnapshotPreparationKey(
                sceneKey: snapshot.sceneKey,
                frameToken: snapshot.frameToken,
                viewSignature: key.viewSignature
            )
        )
    }


    private static func assertInstanceBindings(instanceBuffer: MTLBuffer, instanceOffset: Int, instanceCount: Int) {
        let requiredBytes = InstanceData.stride * instanceCount
        MC_ASSERT(instanceBuffer.length >= instanceOffset + requiredBytes, "Instance buffer too small for draw.")
        MC_ASSERT(instanceOffset % 16 == 0, "Instance buffer offset should be 16-byte aligned.")
    }

    private struct MaterialBindings {
        var materialHandle: AssetHandle?
        var materialOverride: MetalCupMaterial?
        var albedoMapHandle: AssetHandle?
        var normalMapHandle: AssetHandle?
        var metallicMapHandle: AssetHandle?
        var roughnessMapHandle: AssetHandle?
        var mrMapHandle: AssetHandle?
        var ormMapHandle: AssetHandle?
        var aoMapHandle: AssetHandle?
        var emissiveMapHandle: AssetHandle?
        var localReflectionProbe: LocalReflectionProbeUniform?
        var localReflectionPrefilteredHandle: AssetHandle?
        var cullMode: MTLCullMode
        var passKey: MaterialPassKey
    }

    private struct RenderItem {
        let entity: Entity
        let meshHandle: AssetHandle
        let mesh: MCMesh
        let submeshIndex: Int?
        let transform: TransformComponent
        let bonePaletteRange: AnimationSnapshotPayload.BonePaletteRange?
        let skinnedEntry: AnimationSnapshotPayload.SkinnedEntry?
        let bindings: MaterialBindings
        let bounds: InstanceBounds
    }

    private struct MaterialBatchKey: Hashable {
        let materialHandle: AssetHandle?
        let overrideHash: Int
    }

    private struct RenderBatchKey: Hashable {
        let meshHandle: AssetHandle
        let submeshIndexKey: Int
        let materialKey: MaterialBatchKey
        let pipeline: RenderPipelineStateType
        let cullModeKey: Int
        let blendModeKey: Int32
        let unlitKey: Int32
        let castsShadowsKey: Int32
        let receivesShadowsKey: Int32
        let localReflectionPrefilteredHandle: AssetHandle?
        let localReflectionProbeHash: UInt64
    }

    private struct LocalReflectionProbeSelection {
        let prefilteredHandle: AssetHandle
        let uniform: LocalReflectionProbeUniform
        let priority: Int32
        let weight: Float
        let distanceSquared: Float
        let stableEntityKey: UUID
    }

    private struct DebugReflectionProbeSelectionCandidate {
        let stableEntityKey: UUID
        let priority: Int32
        let weight: Float
        let distanceSquared: Float
    }

    private struct ReflectionProbeInfluence {
        let weight: Float
        let distanceSquared: Float
        let boxExtents: SIMD3<Float>
        let blendDistance: Float
        let worldToProbe: matrix_float4x4
    }

    private enum LocalReflectionProbeSelectionPolicy {
        // Current single-probe policy is intentionally simple:
        // 1. Higher authored priority wins.
        // 2. For equal priority, stronger influence weight wins.
        // 3. For equal weight, the closer probe wins.
        // 4. Remaining exact ties break by stable entity UUID string for determinism.
        static func selectRuntimeProbe(at samplePosition: SIMD3<Float>,
                                       snapshot: RenderFrameSnapshot) -> LocalReflectionProbeSelection? {
            var bestSelection: LocalReflectionProbeSelection?

            for probe in snapshot.reflectionProbes {
                guard probe.enabled,
                      probe.runtimeReady,
                      let prefilteredHandle = probe.prefilteredHandle else { continue }
                guard let influence = evaluateInfluence(probe: probe, samplePosition: samplePosition) else {
                    continue
                }

                let uniform = LocalReflectionProbeUniform(
                    probePositionAndWeight: SIMD4<Float>(probe.worldTransform.position, influence.weight),
                    boxExtentsAndBlendDistance: SIMD4<Float>(influence.boxExtents, influence.blendDistance),
                    // Captured texels are authoritative radiance. Keep the
                    // legacy intensity ABI lane neutral instead of coupling
                    // local energy to an unrelated authored multiplier.
                    intensityAndFlags: SIMD4<Float>(1.0, 1.0, Float(probe.priority), 0.0),
                    worldToProbeMatrix: influence.worldToProbe
                )
                let selection = LocalReflectionProbeSelection(
                    prefilteredHandle: prefilteredHandle,
                    uniform: uniform,
                    priority: probe.priority,
                    weight: influence.weight,
                    distanceSquared: influence.distanceSquared,
                    stableEntityKey: probe.entity.id
                )

                if prefers(selection, over: bestSelection) {
                    bestSelection = selection
                }
            }

            return bestSelection
        }

        static func selectDebugProbe(at samplePosition: SIMD3<Float>,
                                     snapshot: RenderFrameSnapshot) -> DebugReflectionProbeSelectionCandidate? {
            var bestSelection: DebugReflectionProbeSelectionCandidate?

            for probe in snapshot.reflectionProbes {
                guard probe.enabled else { continue }
                guard let influence = evaluateInfluence(probe: probe, samplePosition: samplePosition) else {
                    continue
                }

                let candidate = DebugReflectionProbeSelectionCandidate(
                    stableEntityKey: probe.entity.id,
                    priority: probe.priority,
                    weight: influence.weight,
                    distanceSquared: influence.distanceSquared
                )
                if prefers(candidate, over: bestSelection) {
                    bestSelection = candidate
                }
            }

            return bestSelection
        }

        static func fallbackReason(for snapshot: RenderFrameSnapshot) -> ReflectionProbeDebugFallbackReason {
            let hasEnabledProbes = snapshot.reflectionProbes.contains { $0.enabled }
            let hasReadyProbes = snapshot.reflectionProbes.contains {
                $0.enabled && $0.runtimeReady && $0.prefilteredHandle != nil
            }
            if !hasEnabledProbes {
                return .noEnabledProbes
            }
            if !hasReadyProbes {
                return .noReadyProbes
            }
            // If probes exist and at least one is runtime-ready but no candidate was selected,
            // the sample point is simply outside every authored influence volume.
            return .outsideInfluence
        }

        private static func evaluateInfluence(probe: ReflectionProbeSnapshot,
                                              samplePosition: SIMD3<Float>) -> ReflectionProbeInfluence? {
            let boxExtents = max(probe.boxExtents, SIMD3<Float>(repeating: 0.001))
            let probeTransform = TransformComponent(
                position: probe.worldTransform.position,
                rotation: probe.worldTransform.rotation,
                scale: SIMD3<Float>(repeating: 1.0)
            )
            let worldToProbe = simd_inverse(modelMatrix(for: probeTransform))
            let sampleLocal4 = worldToProbe * SIMD4<Float>(samplePosition, 1.0)
            let sampleLocal = SIMD3<Float>(sampleLocal4.x, sampleLocal4.y, sampleLocal4.z)
            let absLocal = abs(sampleLocal)
            let excess = max(absLocal - boxExtents, SIMD3<Float>(repeating: 0.0))
            let maxExcess = max(excess.x, max(excess.y, excess.z))
            let blendDistance = max(probe.blendDistance, 0.0)

            let weight: Float
            if blendDistance <= 0 {
                guard maxExcess == 0 else { return nil }
                weight = 1.0
            } else {
                guard maxExcess <= blendDistance else { return nil }
                weight = max(0.0, 1.0 - (maxExcess / blendDistance))
            }

            let distanceSquared = simd_length_squared(probe.worldTransform.position - samplePosition)
            return ReflectionProbeInfluence(
                weight: weight,
                distanceSquared: distanceSquared,
                boxExtents: boxExtents,
                blendDistance: blendDistance,
                worldToProbe: worldToProbe
            )
        }

        private static func prefers(_ candidate: DebugReflectionProbeSelectionCandidate,
                                    over current: DebugReflectionProbeSelectionCandidate?) -> Bool {
            guard let current else { return true }
            if candidate.priority != current.priority {
                return candidate.priority > current.priority
            }
            if candidate.weight != current.weight {
                return candidate.weight > current.weight
            }
            if candidate.distanceSquared != current.distanceSquared {
                return candidate.distanceSquared < current.distanceSquared
            }
            return candidate.stableEntityKey.uuidString < current.stableEntityKey.uuidString
        }

        private static func prefers(_ candidate: LocalReflectionProbeSelection,
                                    over current: LocalReflectionProbeSelection?) -> Bool {
            guard let current else { return true }
            if candidate.priority != current.priority {
                return candidate.priority > current.priority
            }
            if candidate.weight != current.weight {
                return candidate.weight > current.weight
            }
            if candidate.distanceSquared != current.distanceSquared {
                return candidate.distanceSquared < current.distanceSquared
            }
            return candidate.stableEntityKey.uuidString < current.stableEntityKey.uuidString
        }
    }

    private struct RenderBatchBuilder {
        var mesh: MCMesh
        var submeshIndex: Int?
        var bindings: MaterialBindings
        var instances: [InstanceData]
        var bounds: [InstanceBounds]
    }

    private struct RenderBatch {
        let mesh: MCMesh
        let submeshIndex: Int?
        let bindings: MaterialBindings
        let instanceRange: Range<Int>
    }

    private struct RenderBatchResult {
        let instances: [InstanceData]
        let instanceBounds: [InstanceBounds]
        let batches: [RenderBatch]
        let instanceBuffer: MTLBuffer?
        let bonePaletteBuffer: MTLBuffer?
    }

    private struct TransparentDraw {
        let item: RenderItem
        let instanceIndex: Int
        let sortDepth: Float
        let originalIndex: Int
    }

    private struct RenderSubmissionResult {
        let opaqueBatchResult: RenderBatchResult
        let transparentDraws: [TransparentDraw]
        let transparentInstanceBuffer: MTLBuffer?
    }

    struct ShadowCullVolume {
        let lightView: matrix_float4x4
        let halfExtent: Float
        let nearZ: Float
        let farZ: Float
    }

    private struct InstanceBounds {
        var center: SIMD3<Float>
        var radius: Float
    }

    private static func currentFrameSnapshot(scene: EngineScene, frameContext: RendererFrameContext) -> RenderFrameSnapshot? {
        let viewSignature = frameContext.viewContext().cacheSignature()
        let expectedKey = SnapshotPreparationKey(
            sceneKey: ObjectIdentifier(scene),
            frameToken: frameContext.currentFrameCounter(),
            viewSignature: viewSignature
        )
        guard let resolvedSnapshot = frameContext.renderFrameSnapshot(),
              resolvedSnapshot.sceneKey == expectedKey.sceneKey,
              resolvedSnapshot.frameToken == expectedKey.frameToken
        else {
#if DEBUG
            fatalError("SceneRenderer requires a prebuilt frame snapshot before render. Missing snapshot for viewSignature=\(viewSignature) frameToken=\(frameContext.currentFrameCounter()). Prepare via SceneRenderer.prepareRenderFrameSnapshot(...) before graph execution.")
#else
            logMissingSnapshotIfNeeded(expectedKey)
            return nil
#endif
        }
#if DEBUG
        guard isSnapshotPrepared(expectedKey) else {
            fatalError("SceneRenderer render started without snapshot preparation tracking for viewSignature=\(viewSignature) frameToken=\(frameContext.currentFrameCounter()). Ensure prepareRenderFrameSnapshot(...) is called once per view per frame before rendering.")
        }
#endif

        let key = FrameCacheKey(
            sceneKey: resolvedSnapshot.sceneKey,
            frameToken: resolvedSnapshot.frameToken,
            snapshotSignature: resolvedSnapshot.signature,
            viewSignature: viewSignature,
            cullingConfigSignature: cullingConfigSignature(frameContext: frameContext),
            stateRevision: frameContext.rendererStateRevision(),
            assetStateRevision: frameContext.assetStateRevision()
        )
        if let cached = frameCache[key] {
            return cached.snapshot
        }
        frameCache[key] = FrameCacheEntry(key: key, snapshot: resolvedSnapshot, result: nil)
        trimFrameCache(keepingFrameToken: key.frameToken)
        return resolvedSnapshot
    }

    private static func markSnapshotPrepared(_ key: SnapshotPreparationKey) {
#if DEBUG
        if preparedSnapshotFrameToken != key.frameToken {
            preparedSnapshotFrameToken = key.frameToken
            preparedSnapshotKeys.removeAll(keepingCapacity: true)
        }
        preparedSnapshotKeys.insert(key)
#endif
    }

    private static func isSnapshotPrepared(_ key: SnapshotPreparationKey) -> Bool {
#if DEBUG
        if preparedSnapshotFrameToken != key.frameToken {
            return false
        }
        return preparedSnapshotKeys.contains(key)
#else
        true
#endif
    }

    private static func logMissingSnapshotIfNeeded(_ key: SnapshotPreparationKey) {
#if !DEBUG
        if lastMissingSnapshotFrameToken != key.frameToken {
            lastMissingSnapshotFrameToken = key.frameToken
            missingSnapshotLogKeys.removeAll(keepingCapacity: true)
        }
        guard !missingSnapshotLogKeys.contains(key) else { return }
        missingSnapshotLogKeys.insert(key)
        EngineLoggerContext.log(
            "Skipping render: missing prepared frame snapshot for viewSignature=\(key.viewSignature) frameToken=\(key.frameToken).",
            level: .debug,
            category: .renderer
        )
#endif
    }

    private static func currentSubmissionResult(snapshot: RenderFrameSnapshot,
                                                frameContext: RendererFrameContext) -> RenderSubmissionResult {
        let key = FrameCacheKey(
            sceneKey: snapshot.sceneKey,
            frameToken: snapshot.frameToken,
            snapshotSignature: snapshot.signature,
            viewSignature: frameContext.viewContext().cacheSignature(),
            cullingConfigSignature: cullingConfigSignature(frameContext: frameContext),
            stateRevision: frameContext.rendererStateRevision(),
            assetStateRevision: frameContext.assetStateRevision()
        )
        if let cached = frameCache[key], let result = cached.result {
            return result
        }
        let result = buildRenderSubmission(snapshot: snapshot, frameContext: frameContext)
        frameCache[key] = FrameCacheEntry(key: key, snapshot: snapshot, result: result)
        trimFrameCache(keepingFrameToken: snapshot.frameToken)
        return result
    }

    private static func trimFrameCache(keepingFrameToken frameToken: UInt64) {
        if frameCache.count <= 64 { return }
        frameCache = frameCache.filter { $0.key.frameToken == frameToken }
    }

    private static func cullingConfigSignature(frameContext: RendererFrameContext) -> UInt64 {
        let viewContext = frameContext.viewContext()
        let viewportWidth = UInt32(max(Int(viewContext.viewportSize.x), 1))
        let viewportHeight = UInt32(max(Int(viewContext.viewportSize.y), 1))
        let tileCountX = max(1, (viewportWidth + ForwardPlusConfig.tileSizeX - 1) / ForwardPlusConfig.tileSizeX)
        let tileCountY = max(1, (viewportHeight + ForwardPlusConfig.tileSizeY - 1) / ForwardPlusConfig.tileSizeY)
        let forwardPlusEnabled = frameContext.rendererSettings().hasPerfFlag(.forwardPlusEnabled)

        var hasher = Hasher()
        hasher.combine(ForwardPlusConfig.configVersion)
        hasher.combine(ForwardPlusConfig.abiVersion)
        hasher.combine(ForwardPlusConfig.tileSizeX)
        hasher.combine(ForwardPlusConfig.tileSizeY)
        hasher.combine(ForwardPlusConfig.zSliceCount)
        hasher.combine(ForwardPlusConfig.maxLightsPerCluster)
        hasher.combine(tileCountX)
        hasher.combine(tileCountY)
        hasher.combine(forwardPlusEnabled)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    private static func buildRenderItems(snapshot: RenderFrameSnapshot,
                                         engineContext: EngineContext) -> [RenderItem] {
        var renderItems: [RenderItem] = []
        renderItems.reserveCapacity(snapshot.renderables.count)
        let skinnedEntries: [AnimationSnapshotPayload.SkinnedEntry] = snapshot.animationPayload?.skinnedEntries ?? []
        let paletteRangesByEntity: [Entity: AnimationSnapshotPayload.BonePaletteRange] = Dictionary(uniqueKeysWithValues: skinnedEntries.compactMap { entry in
            guard let range = entry.bonePaletteRange else { return nil }
            return (entry.entity, range)
        })
        let skinnedEntriesByEntity: [Entity: AnimationSnapshotPayload.SkinnedEntry] = Dictionary(
            uniqueKeysWithValues: skinnedEntries.map { ($0.entity, $0) }
        )

        for renderable in snapshot.renderables {
            guard let meshHandle = renderable.meshHandle,
                  let mesh = engineContext.assets.mesh(handle: meshHandle) else { continue }
            let transform = renderable.worldTransform
            let worldBounds = worldBounds(for: mesh, transform: transform)
            let submeshItemCount = max(mesh.submeshCount, 1)
            for submeshItemIndex in 0..<submeshItemCount {
                let submeshIndex = mesh.submeshCount > 0 ? submeshItemIndex : nil
                let bindings = resolveMaterialBindings(
                    renderable: renderable,
                    submeshIndex: submeshIndex,
                    engineContext: engineContext
                )
                let probeBindings = resolveLocalReflectionProbeBindings(
                    bounds: worldBounds,
                    snapshot: snapshot,
                    baseBindings: bindings
                )
                renderItems.append(RenderItem(
                    entity: renderable.entity,
                    meshHandle: meshHandle,
                    mesh: mesh,
                    submeshIndex: submeshIndex,
                    transform: transform,
                    bonePaletteRange: paletteRangesByEntity[renderable.entity],
                    skinnedEntry: skinnedEntriesByEntity[renderable.entity],
                    bindings: probeBindings,
                    bounds: worldBounds
                ))
            }
        }

        return renderItems
    }

    private static func splitRenderItems(_ items: [RenderItem]) -> (opaqueItems: [RenderItem], transparentItems: [RenderItem]) {
        var opaqueItems: [RenderItem] = []
        var transparentItems: [RenderItem] = []
        opaqueItems.reserveCapacity(items.count)
        transparentItems.reserveCapacity(items.count / 4)

        for item in items {
            if item.bindings.passKey.blendMode.isTransparent {
                transparentItems.append(item)
            } else {
                opaqueItems.append(item)
            }
        }

        return (opaqueItems, transparentItems)
    }

    private static func sortedTransparentItems(_ items: [RenderItem], viewMatrix: matrix_float4x4) -> [(item: RenderItem, sortDepth: Float, originalIndex: Int)] {
        var keyedItems: [(item: RenderItem, sortDepth: Float, originalIndex: Int)] = []
        keyedItems.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            let centerVS = viewMatrix * SIMD4<Float>(item.bounds.center, 1.0)
            let sortDepth = -centerVS.z
            keyedItems.append((item: item, sortDepth: sortDepth, originalIndex: index))
        }

        keyedItems.sort { lhs, rhs in
            if lhs.sortDepth != rhs.sortDepth {
                return lhs.sortDepth > rhs.sortDepth
            }
            return lhs.originalIndex < rhs.originalIndex
        }

        return keyedItems
    }

    private static func buildRenderSubmission(snapshot: RenderFrameSnapshot, frameContext: RendererFrameContext) -> RenderSubmissionResult {
        let engineContext = frameContext.engineContext()
        let profiler = engineContext.renderer?.profiler
        let buildStart = CACurrentMediaTime()
        let viewSignature = frameContext.viewSignature()
        let shouldUpdatePickingMapping = frameContext.viewContext().updatesPickingMapping
        let shouldUpdateBatchStats = frameContext.viewContext().updatesBatchStats
        var builders: [RenderBatchKey: RenderBatchBuilder] = [:]
        var uniqueMeshes = Set<AssetHandle>()
        let items = buildRenderItems(snapshot: snapshot, engineContext: engineContext)
        let queueSplit = splitRenderItems(items)
        let sortedTransparentItems = sortedTransparentItems(queueSplit.transparentItems, viewMatrix: snapshot.sceneConstants.viewMatrix)
        if shouldUpdatePickingMapping {
            engineContext.pickingSystem.resetMapping()
        }

        for item in queueSplit.opaqueItems {
            let bindings = item.bindings
            let materialKey = makeMaterialKey(bindings: bindings)
            let key = RenderBatchKey(
                meshHandle: item.meshHandle,
                submeshIndexKey: item.submeshIndex ?? -1,
                materialKey: materialKey,
                pipeline: .HDRInstanced,
                cullModeKey: bindings.cullMode == .none ? 0 : 1,
                blendModeKey: bindings.passKey.blendMode.rawValue,
                unlitKey: bindings.passKey.isUnlit ? 1 : 0,
                castsShadowsKey: bindings.passKey.castsShadows ? 1 : 0,
                receivesShadowsKey: bindings.passKey.receivesShadows ? 1 : 0,
                localReflectionPrefilteredHandle: bindings.localReflectionPrefilteredHandle,
                localReflectionProbeHash: localReflectionProbeHash(bindings: bindings)
            )
            var builder = builders[key] ?? RenderBatchBuilder(mesh: item.mesh, submeshIndex: item.submeshIndex, bindings: bindings, instances: [], bounds: [])
            let pickId = shouldUpdatePickingMapping
                ? engineContext.pickingSystem.assignPickId(for: item.entity)
                : 0
            let instance = makeInstanceData(
                item: item,
                snapshot: snapshot,
                engineContext: engineContext,
                pickId: pickId
            )
            builder.instances.append(instance)
            builder.bounds.append(item.bounds)
            builders[key] = builder
            uniqueMeshes.insert(item.meshHandle)
        }

        var transparentInstances: [InstanceData] = []
        var transparentDraws: [TransparentDraw] = []
        transparentInstances.reserveCapacity(sortedTransparentItems.count)
        transparentDraws.reserveCapacity(sortedTransparentItems.count)

        for (sortedIndex, entry) in sortedTransparentItems.enumerated() {
            let item = entry.item
            let pickId = shouldUpdatePickingMapping
                ? engineContext.pickingSystem.assignPickId(for: item.entity)
                : 0
            let instance = makeInstanceData(
                item: item,
                snapshot: snapshot,
                engineContext: engineContext,
                pickId: pickId
            )
            transparentInstances.append(instance)
            transparentDraws.append(
                TransparentDraw(
                    item: item,
                    instanceIndex: sortedIndex,
                    sortDepth: entry.sortDepth,
                    originalIndex: entry.originalIndex
                )
            )
            uniqueMeshes.insert(item.meshHandle)
        }

        var instances: [InstanceData] = []
        var instanceBounds: [InstanceBounds] = []
        instances.reserveCapacity(queueSplit.opaqueItems.count)
        instanceBounds.reserveCapacity(queueSplit.opaqueItems.count)
        var batches: [RenderBatch] = []
        batches.reserveCapacity(builders.count)
        var instancedDrawCalls = 0

        for builder in builders.values {
            let start = instances.count
            instances.append(contentsOf: builder.instances)
            instanceBounds.append(contentsOf: builder.bounds)
            let end = instances.count
            batches.append(RenderBatch(mesh: builder.mesh, submeshIndex: builder.submeshIndex, bindings: builder.bindings, instanceRange: start..<end))
            instancedDrawCalls += 1
        }

        let instanceBuffer = frameContext.makeDedicatedInstanceBuffer(
            instances,
            label: "OpaqueInstanceBuffer.View\(viewSignature)"
        )
#if DEBUG
        validateUploadedInstanceBuffer(instanceBuffer, against: instances)
#endif
        let transparentInstanceBuffer = frameContext.makeDedicatedInstanceBuffer(
            transparentInstances,
            label: "TransparentInstanceBuffer.View\(viewSignature)"
        )
#if DEBUG
        validateUploadedInstanceBuffer(transparentInstanceBuffer, against: transparentInstances)
        if let instanceBuffer, let transparentInstanceBuffer {
            MC_ASSERT(instanceBuffer !== transparentInstanceBuffer,
                      "Opaque and transparent instance uploads must not alias the same MTLBuffer.")
        }
#endif
        let bonePaletteBuffer = frameContext.makeDedicatedBonePaletteBuffer(
            snapshot.animationPayload?.bonePaletteMatrices ?? [],
            label: "BonePaletteBuffer.View\(viewSignature)"
        )

        let stats = RendererBatchStats(
            uniqueMeshes: uniqueMeshes.count,
            batches: batches.count,
            instancedDrawCalls: instancedDrawCalls,
            nonInstancedDrawCalls: transparentDraws.count
        )
        if shouldUpdateBatchStats {
            frameContext.updateBatchStats(stats)
        }

        if let profiler {
            profiler.record(.renderBatches, seconds: CACurrentMediaTime() - buildStart)
        }
        let opaqueBatchResult = RenderBatchResult(instances: instances,
                                                  instanceBounds: instanceBounds,
                                                  batches: batches,
                                                  instanceBuffer: instanceBuffer,
                                                  bonePaletteBuffer: bonePaletteBuffer)
        return RenderSubmissionResult(opaqueBatchResult: opaqueBatchResult,
                                      transparentDraws: transparentDraws,
                                      transparentInstanceBuffer: transparentInstanceBuffer)
    }

    private static func makeInstanceData(item: RenderItem,
                                         snapshot: RenderFrameSnapshot,
                                         engineContext: EngineContext,
                                         pickId: UInt32) -> InstanceData {
        var instance = InstanceData()
        instance.modelMatrix = modelMatrix(for: item.transform)
        instance.entityID = pickId
        if let range = validatedSkinningRange(item: item,
                                              snapshot: snapshot,
                                              engineContext: engineContext) {
            let maxUInt32AsInt = Int(UInt32.max)
            if range.startIndex >= 0,
               range.count > 0,
               range.startIndex <= maxUInt32AsInt,
               range.count <= maxUInt32AsInt {
                instance.bonePaletteOffset = UInt32(range.startIndex)
                instance.bonePaletteCount = UInt32(range.count)
                instance.skinningFlags = 1
            } else {
#if DEBUG
                MC_ASSERT(false, "Bone palette range exceeds UInt32 limits; skinning disabled for this draw instance.")
#endif
            }
        }
        return instance
    }

#if DEBUG
    private static func validateUploadedInstanceBuffer(_ instanceBuffer: MTLBuffer?, against instances: [InstanceData]) {
        guard !didInstanceSanityCheck, let instanceBuffer, let first = instances.first else { return }
        didInstanceSanityCheck = true
        let raw = instanceBuffer.contents().assumingMemoryBound(to: Float.self)
        let reconstructed = matrix_float4x4(columns: (
            SIMD4<Float>(raw[0], raw[1], raw[2], raw[3]),
            SIMD4<Float>(raw[4], raw[5], raw[6], raw[7]),
            SIMD4<Float>(raw[8], raw[9], raw[10], raw[11]),
            SIMD4<Float>(raw[12], raw[13], raw[14], raw[15])
        ))
        let expected = first.modelMatrix
        var maxDelta: Float = 0.0
        for c in 0..<4 {
            for r in 0..<4 {
                let delta = abs(reconstructed[c][r] - expected[c][r])
                if delta > maxDelta { maxDelta = delta }
            }
        }
        MC_ASSERT(maxDelta < 1e-4, "Instance matrix upload mismatch (column-major). Max delta: \(maxDelta).")
    }
#endif

    private static func resolveMaterialBindings(renderable: RenderFrameSnapshot.Renderable,
                                                submeshIndex: Int?,
                                                engineContext: EngineContext) -> MaterialBindings {
        let meshRenderer = renderable.meshRenderer
        let baseMaterialHandle = meshRenderer.materialHandle ?? renderable.inheritedMaterialHandle
        let submeshMaterialHandles = meshRenderer.submeshMaterialHandles
        var materialOverride = meshRenderer.material
        var albedoMapHandle = meshRenderer.albedoMapHandle
        var normalMapHandle = meshRenderer.normalMapHandle
        var metallicMapHandle = meshRenderer.metallicMapHandle
        var roughnessMapHandle = meshRenderer.roughnessMapHandle
        var mrMapHandle = meshRenderer.mrMapHandle
        var ormMapHandle = meshRenderer.ormMapHandle
        var aoMapHandle = meshRenderer.aoMapHandle
        var emissiveMapHandle = meshRenderer.emissiveMapHandle
        // Cull mode is derived from material state only (never from entity naming hacks).
        var passKey = MaterialPassKey(
            blendMode: .opaque,
            doubleSided: false,
            isUnlit: false,
            castsShadows: true,
            receivesShadows: true
        )

        let hasExplicitOverrides = materialOverride != nil
            || albedoMapHandle != nil
            || normalMapHandle != nil
            || metallicMapHandle != nil
            || roughnessMapHandle != nil
            || mrMapHandle != nil
            || ormMapHandle != nil
            || aoMapHandle != nil
            || emissiveMapHandle != nil
        let usesSubmeshMaterials = submeshMaterialHandles?.contains(where: { $0 != nil }) == true
        let submeshMaterialHandle: AssetHandle? = {
            guard let submeshIndex,
                  let submeshMaterialHandles,
                  submeshIndex < submeshMaterialHandles.count else { return nil }
            return submeshMaterialHandles[submeshIndex]
        }()
        let resolvedMaterialHandle = (!hasExplicitOverrides && usesSubmeshMaterials) ? submeshMaterialHandle : baseMaterialHandle

        if let resolvedMaterialHandle,
           let materialAsset = engineContext.assets.material(handle: resolvedMaterialHandle) {
            materialOverride = materialAsset.buildMetalMaterial(database: engineContext.assetDatabase)
            albedoMapHandle = materialAsset.textures.baseColor
            normalMapHandle = materialAsset.textures.normal
            metallicMapHandle = materialAsset.textures.metallic
            roughnessMapHandle = materialAsset.textures.roughness
            mrMapHandle = materialAsset.textures.metalRoughness
            ormMapHandle = materialAsset.textures.orm
            aoMapHandle = materialAsset.textures.ao
            emissiveMapHandle = materialAsset.textures.emissive
            if (materialOverride?.flags ?? 0) & MetalCupMaterialFlags.isDoubleSided.rawValue != 0 {
                passKey.doubleSided = true
            }
            switch materialAsset.alphaMode {
            case .opaque:
                passKey.blendMode = .opaque
            case .alphaClip:
                passKey.blendMode = .alphaClip
            case .transparent:
                passKey.blendMode = .transparent
            case .additive:
                passKey.blendMode = .additive
            }
            passKey.isUnlit = materialAsset.unlit
        }
        if let overrideFlags = materialOverride?.flags {
            if (overrideFlags & MetalCupMaterialFlags.alphaMasked.rawValue) != 0 {
                passKey.blendMode = .alphaClip
            } else if (overrideFlags & MetalCupMaterialFlags.additiveBlended.rawValue) != 0 {
                passKey.blendMode = .additive
            } else if (overrideFlags & MetalCupMaterialFlags.alphaBlended.rawValue) != 0 {
                passKey.blendMode = .transparent
            }
            if (overrideFlags & MetalCupMaterialFlags.isDoubleSided.rawValue) != 0 {
                passKey.doubleSided = true
            }
            if (overrideFlags & MetalCupMaterialFlags.isUnlit.rawValue) != 0 {
                passKey.isUnlit = true
            }
        }
        if let normalHandle = normalMapHandle,
           let metadata = engineContext.assetDatabase?.metadata(for: normalHandle) {
            if metadata.importSettings["flipNormalY"] == "true"
                || AssetManager.shouldFlipNormalY(path: metadata.sourcePath) {
                var material = materialOverride ?? MetalCupMaterial()
                material.flags |= MetalCupMaterialFlags.normalFlipY.rawValue
                materialOverride = material
            }
        }

        let cullMode: MTLCullMode = passKey.doubleSided ? .none : .back
        return MaterialBindings(
            materialHandle: resolvedMaterialHandle,
            materialOverride: materialOverride,
            albedoMapHandle: albedoMapHandle,
            normalMapHandle: normalMapHandle,
            metallicMapHandle: metallicMapHandle,
            roughnessMapHandle: roughnessMapHandle,
            mrMapHandle: mrMapHandle,
            ormMapHandle: ormMapHandle,
            aoMapHandle: aoMapHandle,
            emissiveMapHandle: emissiveMapHandle,
            localReflectionProbe: nil,
            localReflectionPrefilteredHandle: nil,
            cullMode: cullMode,
            passKey: passKey
        )
    }

    private static func resolveLocalReflectionProbeBindings(bounds: InstanceBounds,
                                                            snapshot: RenderFrameSnapshot,
                                                            baseBindings: MaterialBindings) -> MaterialBindings {
        guard let selection = LocalReflectionProbeSelectionPolicy.selectRuntimeProbe(at: bounds.center, snapshot: snapshot) else {
            return baseBindings
        }
        var bindings = baseBindings
        bindings.localReflectionProbe = selection.uniform
        bindings.localReflectionPrefilteredHandle = selection.prefilteredHandle
        return bindings
    }

    private static func selectLocalReflectionProbe(for bounds: InstanceBounds,
                                                   snapshot: RenderFrameSnapshot) -> LocalReflectionProbeSelection? {
        LocalReflectionProbeSelectionPolicy.selectRuntimeProbe(at: bounds.center, snapshot: snapshot)
    }

    private static func selectLocalReflectionProbe(at samplePosition: SIMD3<Float>,
                                                   snapshot: RenderFrameSnapshot) -> LocalReflectionProbeSelection? {
        LocalReflectionProbeSelectionPolicy.selectRuntimeProbe(at: samplePosition, snapshot: snapshot)
    }

    private static func selectDebugReflectionProbe(at samplePosition: SIMD3<Float>,
                                                   snapshot: RenderFrameSnapshot) -> DebugReflectionProbeSelectionCandidate? {
        LocalReflectionProbeSelectionPolicy.selectDebugProbe(at: samplePosition, snapshot: snapshot)
    }

    public static func debugLocalReflectionProbeSelection(samplePosition: SIMD3<Float>,
                                                          snapshot: RenderFrameSnapshot) -> ReflectionProbeDebugSelection {
        if let runtimeSelection = selectLocalReflectionProbe(at: samplePosition, snapshot: snapshot) {
            return ReflectionProbeDebugSelection(
                selectedProbeEntityID: runtimeSelection.stableEntityKey,
                weight: runtimeSelection.weight,
                fallbackReason: .none
            )
        }
        if let authoredSelection = selectDebugReflectionProbe(at: samplePosition, snapshot: snapshot) {
            return ReflectionProbeDebugSelection(
                selectedProbeEntityID: authoredSelection.stableEntityKey,
                weight: authoredSelection.weight,
                fallbackReason: .none
            )
        }

        return ReflectionProbeDebugSelection(
            selectedProbeEntityID: nil,
            weight: 0.0,
            fallbackReason: LocalReflectionProbeSelectionPolicy.fallbackReason(for: snapshot)
        )
    }

    private static func validatedSkinningRange(item: RenderItem,
                                               snapshot: RenderFrameSnapshot,
                                               engineContext: EngineContext) -> AnimationSnapshotPayload.BonePaletteRange? {
        guard let entry = item.skinnedEntry else { return nil }
        guard item.mesh.hasValidSkinningVertexStreams() else {
            logInvalidSkinningSetupOnce(
                entity: item.entity,
                reason: "missing joint index/weight vertex streams (\(item.mesh.skinningStreamDebugState()))"
            )
            return nil
        }
        guard let skeletonHandle = entry.skeletonHandle,
              let skeleton = engineContext.assets.skeleton(handle: skeletonHandle),
              !skeleton.joints.isEmpty else {
            logInvalidSkinningSetupOnce(entity: item.entity, reason: "missing or invalid skeleton asset")
            return nil
        }
        guard entry.evaluatedJointCount > 0 else {
            logInvalidSkinningSetupOnce(entity: item.entity, reason: "no evaluated joints in animation pose")
            return nil
        }
        guard let range = item.bonePaletteRange,
              range.startIndex >= 0,
              range.count > 0 else {
            logInvalidSkinningSetupOnce(entity: item.entity, reason: "missing or empty bone palette range")
            return nil
        }
        guard range.count <= entry.evaluatedJointCount,
              range.count <= skeleton.joints.count else {
            logInvalidSkinningSetupOnce(entity: item.entity, reason: "bone palette count exceeds evaluated pose/skeleton")
            return nil
        }
        let totalPaletteCount = snapshot.animationPayload?.bonePaletteMatrices.count ?? 0
        guard range.startIndex <= totalPaletteCount,
              range.count <= (totalPaletteCount - range.startIndex) else {
            logInvalidSkinningSetupOnce(entity: item.entity, reason: "bone palette range out of snapshot bounds")
            return nil
        }
        logValidSkinningSetupOnce(
            entity: item.entity,
            range: range,
            skeletonJointCount: skeleton.joints.count,
            evaluatedJointCount: entry.evaluatedJointCount
        )
        return range
    }

    private static func logInvalidSkinningSetupOnce(entity: Entity, reason: String) {
#if DEBUG
        let key = "\(entity.id.uuidString)|\(reason)"
        guard !invalidSkinningLogKeys.contains(key) else { return }
        invalidSkinningLogKeys.insert(key)
        EngineLoggerContext.log(
            "Skinned mesh validation failed for entity \(entity.id.uuidString): \(reason). Falling back to non-skinned draw.",
            level: .warning,
            category: .renderer
        )
#endif
    }

    private static func logValidSkinningSetupOnce(entity: Entity,
                                                  range: AnimationSnapshotPayload.BonePaletteRange,
                                                  skeletonJointCount: Int,
                                                  evaluatedJointCount: Int) {
#if DEBUG
        let key = "\(entity.id.uuidString)|\(range.startIndex)|\(range.count)"
        guard !validSkinningLogKeys.contains(key) else { return }
        validSkinningLogKeys.insert(key)
        EngineLoggerContext.log(
            "Skinned mesh validation summary entity=\(entity.id.uuidString)\nbonePaletteStart=\(range.startIndex)\nbonePaletteCount=\(range.count)\nskeletonJointCount=\(skeletonJointCount)\nevaluatedJointCount=\(evaluatedJointCount)",
            level: .debug,
            category: .renderer
        )
#endif
    }

    private static func makeMaterialKey(bindings: MaterialBindings) -> MaterialBatchKey {
        if let materialHandle = bindings.materialHandle {
            return MaterialBatchKey(materialHandle: materialHandle, overrideHash: 0)
        }
        var material = bindings.materialOverride ?? MetalCupMaterial()
        let materialHash = hashBytes(of: &material)
        var hasher = Hasher()
        hasher.combine(materialHash)
        hasher.combine(bindings.albedoMapHandle?.rawValue)
        hasher.combine(bindings.normalMapHandle?.rawValue)
        hasher.combine(bindings.metallicMapHandle?.rawValue)
        hasher.combine(bindings.roughnessMapHandle?.rawValue)
        hasher.combine(bindings.mrMapHandle?.rawValue)
        hasher.combine(bindings.ormMapHandle?.rawValue)
        hasher.combine(bindings.aoMapHandle?.rawValue)
        hasher.combine(bindings.emissiveMapHandle?.rawValue)
        return MaterialBatchKey(materialHandle: nil, overrideHash: hasher.finalize())
    }

    private static func localReflectionProbeHash(bindings: MaterialBindings) -> UInt64 {
        guard var probe = bindings.localReflectionProbe else { return 0 }
        return hashBytes(of: &probe)
    }

    private static func hashBytes<T>(of value: inout T) -> UInt64 {
        return withUnsafeBytes(of: &value) { bytes in
            var hash: UInt64 = 1469598103934665603
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 1099511628211
            }
            return hash
        }
    }

    private static func encodeShadowDrawRange(
        _ encoder: MTLRenderCommandEncoder,
        snapshot: RenderFrameSnapshot,
        batch: RenderBatch,
        batchResult: RenderBatchResult,
        instanceBuffer: MTLBuffer,
        startIndex: Int,
        endIndex: Int,
        instanceStride: Int,
        sceneConstantsBuffer: MTLBuffer?,
        frameContext: RendererFrameContext
    ) {
        let visibleCount = endIndex - startIndex
        if visibleCount <= 0 { return }
        let instanceOffset = startIndex * instanceStride
        encodeShadowPass(
            encoder,
            snapshot: snapshot,
            batch: batch,
            batchResult: batchResult,
            instanceBuffer: instanceBuffer,
            instanceOffset: instanceOffset,
            instanceCount: visibleCount,
            sceneConstantsBuffer: sceneConstantsBuffer,
            frameContext: frameContext
        )
    }

    private static func worldBounds(for mesh: MCMesh, transform: TransformComponent) -> InstanceBounds {
        let centerWS4 = TransformMath.makeMatrix(
            position: transform.position,
            rotation: transform.rotation,
            scale: transform.scale
        ) * SIMD4<Float>(mesh.boundsCenter, 1.0)
        let center = SIMD3<Float>(centerWS4.x, centerWS4.y, centerWS4.z)
        let absScale = SIMD3<Float>(abs(transform.scale.x), abs(transform.scale.y), abs(transform.scale.z))
        let maxScale = max(absScale.x, max(absScale.y, absScale.z))
        return InstanceBounds(
            center: center,
            radius: max(0.001, mesh.boundsRadius * max(maxScale, 0.001))
        )
    }

    private static func intersects(bounds: InstanceBounds, volume: ShadowCullVolume) -> Bool {
        let centerLS4 = volume.lightView * SIMD4<Float>(bounds.center, 1.0)
        if !isFinite(centerLS4) { return true }
        let center = SIMD3<Float>(centerLS4.x, centerLS4.y, centerLS4.z)
        let r = bounds.radius
        if center.x + r < -volume.halfExtent || center.x - r > volume.halfExtent { return false }
        if center.y + r < -volume.halfExtent || center.y - r > volume.halfExtent { return false }
        if center.z + r < volume.farZ || center.z - r > volume.nearZ { return false }
        return true
    }

    private static func modelMatrix(for transform: TransformComponent) -> matrix_float4x4 {
#if DEBUG
        MC_ASSERT(isFinite(transform.position) && isFinite(transform.rotation) && isFinite(transform.scale),
                  "Transform contains non-finite values (NaN/inf).")
#endif
        return TransformMath.makeMatrix(position: transform.position,
                                        rotation: transform.rotation,
                                        scale: transform.scale)
    }

    private static func isFinite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private static func isFinite(_ value: SIMD4<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite && value.w.isFinite
    }

    public static func cameraMatrices(scene: EngineScene) -> (view: matrix_float4x4, projection: matrix_float4x4) {
        let constants = scene.getSceneConstants()
        return (view: constants.viewMatrix, projection: constants.projectionMatrix)
    }

    public static func cameraPosition(scene: EngineScene) -> SIMD3<Float> {
        let constants = scene.getSceneConstants()
        return SIMD3<Float>(
            constants.cameraPositionAndIBL.x,
            constants.cameraPositionAndIBL.y,
            constants.cameraPositionAndIBL.z
        )
    }

    public static func exposureSettings(from camera: CameraComponent) -> SceneViewExposureSettings {
        SceneViewExposureSettings(cameraOverride: camera.exposurePolicy)
    }

    public static func cameraExposure(scene: EngineScene) -> SceneViewExposureSettings {
        scene.getViewExposureSettings()
    }

    public static func cameraID(scene: EngineScene) -> UUID {
        scene.getViewCameraID()
    }

    public static func gridParams(scene: EngineScene) -> GridParams {
        let constants = scene.getSceneConstants()
        var params = GridParams()
        let viewProjection = constants.projectionMatrix * constants.viewMatrix
        params.inverseViewProjection = simd_inverse(viewProjection)
        params.cameraPosition = SIMD3<Float>(
            constants.cameraPositionAndIBL.x,
            constants.cameraPositionAndIBL.y,
            constants.cameraPositionAndIBL.z
        )
        return params
    }

    static func viewMatrix(from transform: TransformComponent) -> matrix_float4x4 {
        return TransformMath.makeViewMatrix(position: transform.position,
                                            rotation: transform.rotation)
    }

    static func projectionMatrix(from camera: CameraComponent, aspectRatio: Float) -> matrix_float4x4 {
        let nearPlane = max(0.01, camera.nearPlane)
        let farPlane = max(nearPlane + 0.01, camera.farPlane)
        switch camera.projectionType {
        case .perspective:
            return matrix_float4x4.perspective(
                fovDegrees: camera.fovDegrees,
                aspectRatio: aspectRatio,
                near: nearPlane,
                far: farPlane
            )
        case .orthographic:
            let size = max(0.01, camera.orthoSize)
            return matrix_float4x4.orthographic(
                size: size,
                aspectRatio: aspectRatio,
                near: nearPlane,
                far: farPlane
            )
        }
    }
}
    private enum MaterialBlendModeKey: Int32, Hashable {
        case opaque = 0
        case alphaClip = 1
        case transparent = 2
        case additive = 3

        var isTransparent: Bool {
            switch self {
            case .transparent, .additive:
                return true
            case .opaque, .alphaClip:
                return false
            }
        }

        var usesDepthWrite: Bool {
            switch self {
            case .opaque, .alphaClip:
                return true
            case .transparent, .additive:
                return false
            }
        }
    }

    private struct MaterialPassKey: Hashable {
        var blendMode: MaterialBlendModeKey
        var doubleSided: Bool
        var isUnlit: Bool
        var castsShadows: Bool
        var receivesShadows: Bool
    }
