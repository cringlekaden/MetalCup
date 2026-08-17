/// ReflectionProbeRuntimeManager.swift
/// Owns runtime-only reflection probe bake state and capture workflow.
/// Created by Kaden Cringle

import Foundation
import MetalKit
import QuartzCore
import simd

final class ReflectionProbeRuntimeManager {
    typealias PrefilterRenderer = (_ sourceEnvironment: MTLTexture,
                                   _ targetPrefiltered: MTLTexture,
                                   _ frameContext: RendererFrameContext,
                                   _ commandBuffer: MTLCommandBuffer) -> Void

    private struct ReflectionProbeRuntimeHandles {
        var capturedEnvironmentHandle: AssetHandle?
        var prefilteredHandle: AssetHandle?
    }

    private struct ReflectionProbeRuntimeState {
        let entityID: UUID
        // Mirrors authored ECS data so runtime bake orchestration never mutates serialized scene state.
        var authoredProbe: ReflectionProbeComponent
        // Runtime-only bake status and transient handles.
        var status: ReflectionProbeRuntimeStatus
        var runtimeHandles: ReflectionProbeRuntimeHandles
        var needsRebuild: Bool
        var queuedAtTime: Double?
        var lastUpdatedTime: Double
        var lastError: String?
    }

    private struct ReflectionProbeSceneRuntimeState {
        var probeStates: [UUID: ReflectionProbeRuntimeState] = [:]
        // MVP bake queue remains single-probe-at-a-time and FIFO by design.
        var queuedProbeIDs: [UUID] = []
        var activeProbeID: UUID?
    }

    private let engineContext: EngineContext
    private let projection: matrix_float4x4
    private let captureViews: [matrix_float4x4]
    private let captureFrameContextStorage: RendererFrameContextStorage
    private let renderResourceRegistryBuilder: () -> RenderResourceRegistry
    private let rendererSettingsProvider: () -> RendererSettings
    private let assetStateRevisionProvider: () -> UInt64
    private let prefilterRenderer: PrefilterRenderer
    private var runtimeStatesByScene: [ObjectIdentifier: ReflectionProbeSceneRuntimeState] = [:]

    init(engineContext: EngineContext,
         projection: matrix_float4x4,
         captureViews: [matrix_float4x4],
         captureFrameContextStorage: RendererFrameContextStorage,
         renderResourceRegistryBuilder: @escaping () -> RenderResourceRegistry,
         rendererSettingsProvider: @escaping () -> RendererSettings,
         assetStateRevisionProvider: @escaping () -> UInt64,
         prefilterRenderer: @escaping PrefilterRenderer) {
        self.engineContext = engineContext
        self.projection = projection
        self.captureViews = captureViews
        self.captureFrameContextStorage = captureFrameContextStorage
        self.renderResourceRegistryBuilder = renderResourceRegistryBuilder
        self.rendererSettingsProvider = rendererSettingsProvider
        self.assetStateRevisionProvider = assetStateRevisionProvider
        self.prefilterRenderer = prefilterRenderer
    }

    func queueReflectionProbeRebuilds(scene: EngineScene, entities: [Entity]? = nil, force: Bool = false) {
        let sceneKey = ObjectIdentifier(scene)
        pruneReflectionProbeRuntimeStates(keeping: sceneKey)
        synchronizeReflectionProbeRuntimeState(scene: scene)

        var runtimeState = runtimeStatesByScene[sceneKey] ?? ReflectionProbeSceneRuntimeState()
        let selectedEntityIDs = entities.map { Set($0.map(\.id)) }
        let now = CACurrentMediaTime()

        scene.ecs.viewReflectionProbes { entity, probe in
            guard probe.enabled else { return }
            if let selectedEntityIDs, !selectedEntityIDs.contains(entity.id) {
                return
            }
            if !force, probe.rebuildMode != .onPlay {
                return
            }
            guard var state = runtimeState.probeStates[entity.id] else { return }
            let missingRuntimeResources = state.runtimeHandles.capturedEnvironmentHandle == nil
                || state.runtimeHandles.prefilteredHandle == nil
            let shouldQueue = force || state.needsRebuild || missingRuntimeResources
            guard shouldQueue else { return }

            ensureReflectionProbeTextures(state: &state)
            state.needsRebuild = true
            state.lastError = nil
            if state.status != .queued && state.status != .capturing && state.status != .filtering {
                state.status = .queued
                state.queuedAtTime = now
            }
            if !runtimeState.queuedProbeIDs.contains(entity.id), runtimeState.activeProbeID != entity.id {
                runtimeState.queuedProbeIDs.append(entity.id)
            }
            runtimeState.probeStates[entity.id] = state
        }

        runtimeStatesByScene[sceneKey] = runtimeState
    }

    func reflectionProbeBakeStatus(scene: EngineScene, entityID: UUID) -> ReflectionProbeRuntimeStatus? {
        runtimeStatesByScene[ObjectIdentifier(scene)]?.probeStates[entityID]?.status
    }

    func debugReflectionProbeSelection(scene: EngineScene, entityID: UUID) -> ReflectionProbeDebugSelection? {
        guard let entity = scene.ecs.entity(with: entityID) else { return nil }
        let baseSnapshot = scene.makeRenderFrameSnapshot(frameToken: 0, layerFilterMask: .all)
        let snapshot = applyRuntimeState(to: baseSnapshot, scene: scene)
        let samplePosition = scene.ecs.worldTransform(for: entity).position
        return SceneRenderer.debugLocalReflectionProbeSelection(samplePosition: samplePosition, snapshot: snapshot)
    }

    func updateReflectionProbesIfNeeded(scene: EngineScene) {
        let sceneKey = ObjectIdentifier(scene)
        pruneReflectionProbeRuntimeStates(keeping: sceneKey)
        synchronizeReflectionProbeRuntimeState(scene: scene)
        queueReflectionProbeRebuilds(scene: scene)

        guard var runtimeState = runtimeStatesByScene[sceneKey] else { return }
        runtimeState.queuedProbeIDs.removeAll { queuedID in
            guard let state = runtimeState.probeStates[queuedID] else { return true }
            return !state.authoredProbe.enabled
        }
        if let activeProbeID = runtimeState.activeProbeID,
           runtimeState.probeStates[activeProbeID] == nil {
            runtimeState.activeProbeID = nil
        }
        if runtimeState.activeProbeID == nil,
           let nextProbeID = runtimeState.queuedProbeIDs.first,
           var probeState = runtimeState.probeStates[nextProbeID] {
            runtimeState.queuedProbeIDs.removeFirst()
            runtimeState.activeProbeID = nextProbeID
            probeState.status = .capturing
            probeState.lastError = nil
            probeState.lastUpdatedTime = CACurrentMediaTime()
            runtimeState.probeStates[nextProbeID] = probeState
            runtimeStatesByScene[sceneKey] = runtimeState

            let captureFrameContext = captureFrameContextStorage.beginFrame()
            captureFrameContextStorage.updateRendererState(
                settings: resolvedCaptureRendererSettings(scene: scene),
                viewContext: RenderViewContext(
                    viewId: UInt64(bitPattern: Int64(truncatingIfNeeded: nextProbeID.hashValue)),
                    viewportSize: SIMD2<Float>(Float(max(probeState.authoredProbe.captureResolution, 1)),
                                               Float(max(probeState.authoredProbe.captureResolution, 1))),
                    layerFilterMask: .all,
                    depthPrepassEnabled: false,
                    updatesPickingMapping: false,
                    updatesBatchStats: false,
                    debugFlags: 0,
                    showEditorOverlays: false,
                    usesMirroredCubemapProjection: true,
                    exposureSettings: scene.getViewExposureSettings()
                )
            )
            captureFrameContextStorage.setAssetStateRevision(assetStateRevisionProvider())
            SceneRenderer.prepareRenderFrameSnapshot(scene: scene, frameContext: captureFrameContext)
            let captureSnapshot = captureFrameContext.renderFrameSnapshot()

            var updatedRuntimeState = runtimeStatesByScene[sceneKey] ?? runtimeState
            if let captureSnapshot {
                let captureError = captureReflectionProbe(scene: scene, snapshot: captureSnapshot, state: probeState)
                if captureError == nil,
                   var filteringState = updatedRuntimeState.probeStates[nextProbeID] {
                    filteringState.status = .filtering
                    filteringState.lastUpdatedTime = CACurrentMediaTime()
                    filteringState.lastError = nil
                    updatedRuntimeState.probeStates[nextProbeID] = filteringState
                    runtimeStatesByScene[sceneKey] = updatedRuntimeState
                }

                let filterError = captureError == nil ? prefilterReflectionProbe(state: probeState) : nil
                if var completedState = updatedRuntimeState.probeStates[nextProbeID] {
                    let terminalError = captureError ?? filterError
                    completedState.lastUpdatedTime = CACurrentMediaTime()
                    completedState.needsRebuild = (terminalError != nil)
                    completedState.status = terminalError == nil ? .ready : .failed
                    completedState.lastError = terminalError
                    updatedRuntimeState.probeStates[nextProbeID] = completedState
                }
            } else if var failedState = updatedRuntimeState.probeStates[nextProbeID] {
                failedState.status = .failed
                failedState.needsRebuild = true
                failedState.lastError = "Reflection probe capture snapshot was unavailable."
                failedState.lastUpdatedTime = CACurrentMediaTime()
                updatedRuntimeState.probeStates[nextProbeID] = failedState
            }
            updatedRuntimeState.activeProbeID = nil
            runtimeStatesByScene[sceneKey] = updatedRuntimeState
            return
        }
        runtimeStatesByScene[sceneKey] = runtimeState
    }

    func applyRuntimeState(to snapshot: RenderFrameSnapshot, scene: EngineScene) -> RenderFrameSnapshot {
        guard let runtimeState = runtimeStatesByScene[ObjectIdentifier(scene)],
              !snapshot.reflectionProbes.isEmpty else {
            return snapshot
        }

        var updatedReflectionProbes: [ReflectionProbeSnapshot] = []
        updatedReflectionProbes.reserveCapacity(snapshot.reflectionProbes.count)
        var didChange = false
        var hasher = Hasher()
        hasher.combine(snapshot.signature)

        for probe in snapshot.reflectionProbes {
            let runtimeProbeState = runtimeState.probeStates[probe.entity.id]
            let prefilteredHandle = runtimeProbeState?.runtimeHandles.prefilteredHandle
            let runtimeReady = {
                guard runtimeProbeState?.status == .ready,
                      let prefilteredHandle,
                      engineContext.assets.texture(handle: prefilteredHandle) != nil else {
                    return false
                }
                return true
            }()
            let resolvedProbe = ReflectionProbeSnapshot(
                entity: probe.entity,
                enabled: probe.enabled,
                worldTransform: probe.worldTransform,
                boxExtents: probe.boxExtents,
                blendDistance: probe.blendDistance,
                priority: probe.priority,
                intensity: probe.intensity,
                captureResolution: probe.captureResolution,
                rebuildMode: probe.rebuildMode,
                includeSky: probe.includeSky,
                runtimeReady: runtimeReady,
                prefilteredHandle: runtimeReady ? prefilteredHandle : nil
            )
            updatedReflectionProbes.append(resolvedProbe)
            didChange = didChange
                || probe.runtimeReady != resolvedProbe.runtimeReady
                || probe.prefilteredHandle != resolvedProbe.prefilteredHandle
            hasher.combine(probe.entity.id)
            hasher.combine(runtimeReady)
            hasher.combine((runtimeReady ? prefilteredHandle : nil)?.rawValue)
        }

        guard didChange else {
            return snapshot
        }

        return RenderFrameSnapshot(
            sceneKey: snapshot.sceneKey,
            frameToken: snapshot.frameToken,
            signature: UInt64(bitPattern: Int64(hasher.finalize())),
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
            reflectionProbes: updatedReflectionProbes
        )
    }

    private func ensureReflectionProbeTextures(state: inout ReflectionProbeRuntimeState) {
        let captureSize = max(Int(state.authoredProbe.captureResolution), 1)
        let probeLabelPrefix = String(state.entityID.uuidString.prefix(8))

        if state.runtimeHandles.capturedEnvironmentHandle == nil {
            state.runtimeHandles.capturedEnvironmentHandle = AssetHandle()
        }
        if state.runtimeHandles.prefilteredHandle == nil {
            state.runtimeHandles.prefilteredHandle = AssetHandle()
        }

        if let capturedHandle = state.runtimeHandles.capturedEnvironmentHandle,
           engineContext.assets.texture(handle: capturedHandle) == nil,
           let capturedTexture = makeCubemapTexture(
                size: captureSize,
                mipmapped: true,
                label: "ReflectionProbe.Captured.\(probeLabelPrefix)"
           ) {
            engineContext.assets.registerRuntimeTexture(handle: capturedHandle, texture: capturedTexture)
        }

        if let prefilteredHandle = state.runtimeHandles.prefilteredHandle,
           engineContext.assets.texture(handle: prefilteredHandle) == nil,
           let prefilteredTexture = makeCubemapTexture(
                size: captureSize,
                mipmapped: true,
                label: "ReflectionProbe.Prefiltered.\(probeLabelPrefix)"
           ) {
            engineContext.assets.registerRuntimeTexture(handle: prefilteredHandle, texture: prefilteredTexture)
        }
    }

    private func releaseReflectionProbeTextures(for state: ReflectionProbeRuntimeState) {
        if let capturedHandle = state.runtimeHandles.capturedEnvironmentHandle {
            engineContext.assets.unregisterRuntimeTexture(handle: capturedHandle)
        }
        if let prefilteredHandle = state.runtimeHandles.prefilteredHandle {
            engineContext.assets.unregisterRuntimeTexture(handle: prefilteredHandle)
        }
    }

    private func captureProbeViewMatrix(position: SIMD3<Float>, face: Int) -> matrix_float4x4 {
        // Probe capture intentionally uses the renderer's established cubemap face basis.
        // Authored probe rotation remains a separate shading concern for later improvements.
        let translation = float4x4(translation: -position)
        return captureViews[face] * translation
    }

    private func makeReflectionProbeCapturePassDescriptor(colorTexture: MTLTexture,
                                                          depthTexture: MTLTexture,
                                                          face: Int) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = ClearColor.Black
        pass.colorAttachments[0].slice = face
        pass.colorAttachments[0].level = 0
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 1.0
        return pass
    }

    private func makeReflectionProbeFogPassDescriptor(colorTexture: MTLTexture,
                                                      face: Int) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = ClearColor.Black
        pass.colorAttachments[0].slice = face
        pass.colorAttachments[0].level = 0
        return pass
    }

    private func makeReflectionProbeSceneColorTexture(size: Int, label: String) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: engineContext.preferences.HDRPixelFormat,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = engineContext.device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = label
        return texture
    }

    private func resolvedCaptureRendererSettings(scene: EngineScene) -> RendererSettings {
        var settings = rendererSettingsProvider()
        // Captures are true scene-linear radiance sources. Camera pre-exposure must
        // never leak from whichever visible view happened to render most recently.
        settings.renderPreExposure = 1
        if let environmentEntry = scene.ecs.activeEnvironment() {
            let renderState = scene.ecs.get(EnvironmentFrameStateComponent.self,
                                            for: environmentEntry.0)?.renderState
                ?? EnvironmentRenderStateBuilder.build(
                    environment: environmentEntry.1,
                    runtime: scene.ecs.get(EnvironmentRuntimeStateComponent.self, for: environmentEntry.0),
                    rendererSettings: settings
                )
            renderState.legacyFogPatch.applying(to: &settings)
            return settings
        }

        let activeSkyEntry = scene.ecs.activeSkyLight()
        let environmentState = activeSkyEntry.flatMap { scene.ecs.get(EnvironmentStateComponent.self, for: $0.0) }
        SkySystem.applyDerivedFogSettings(&settings,
                                          authored: activeSkyEntry?.1,
                                          runtime: environmentState)
        return settings
    }

    private func encodeReflectionProbeHeightFog(sourceTexture: MTLTexture,
                                                depthTexture: MTLTexture,
                                                targetTexture: MTLTexture,
                                                face: Int,
                                                captureSnapshot: RenderFrameSnapshot,
                                                frameContext: RendererFrameContext,
                                                commandBuffer: MTLCommandBuffer) -> String? {
        guard let quad = engineContext.assets.mesh(handle: BuiltinAssets.fullscreenQuadMesh) else {
            return "Missing fullscreen quad mesh for reflection probe fog capture."
        }
        let previousSnapshot = frameContext.renderFrameSnapshot()
        frameContext.setRenderFrameSnapshot(captureSnapshot)
        defer { frameContext.setRenderFrameSnapshot(previousSnapshot) }

        let pass = FullscreenPass(
            pipeline: .HeightFog,
            label: "Reflection Probe Height Fog",
            inputs: PostProcessInputs(
                sampler: .LinearClampToZero,
                source: sourceTexture,
                sceneDepth: depthTexture,
                settings: frameContext.rendererSettings()
            )
        )
        let passDescriptor = makeReflectionProbeFogPassDescriptor(colorTexture: targetTexture, face: face)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return "Failed to create reflection probe fog encoder for face \(face)."
        }
        RenderPassHelpers.setViewport(encoder, SIMD2<Float>(Float(sourceTexture.width), Float(sourceTexture.height)))
        pass.encode(into: encoder, quad: quad, frameContext: frameContext, graphics: engineContext.graphics)
        encoder.endEncoding()
        return nil
    }

    private func captureReflectionProbe(scene: EngineScene,
                                        snapshot: RenderFrameSnapshot,
                                        state: ReflectionProbeRuntimeState) -> String? {
        guard let capturedHandle = state.runtimeHandles.capturedEnvironmentHandle,
              let capturedTexture = engineContext.assets.texture(handle: capturedHandle) else {
            return "Missing reflection probe capture cubemap."
        }

        let captureSize = max(Int(state.authoredProbe.captureResolution), 1)
        let resolvedSettings = resolvedCaptureRendererSettings(scene: scene)
        // Keep reflection probes free of camera-space post fog for now. Face-local fullscreen fog
        // creates cubemap discontinuities, while final camera aerial perspective remains a post pass.
        let shouldApplyHeightFog = false
        guard let depthTexture = makeDepthTexture(
            size: captureSize,
            label: "ReflectionProbe.Depth.\(String(state.entityID.uuidString.prefix(8)))"
        ) else {
            return "Failed to allocate reflection probe depth texture."
        }
        let captureSceneColorTexture = shouldApplyHeightFog
            ? makeReflectionProbeSceneColorTexture(
                size: captureSize,
                label: "ReflectionProbe.SceneColor.\(String(state.entityID.uuidString.prefix(8)))"
            )
            : nil
        if shouldApplyHeightFog, captureSceneColorTexture == nil {
            return "Failed to allocate reflection probe scene color texture."
        }

        guard let probeSnapshot = snapshot.reflectionProbes.first(where: { $0.entity.id == state.entityID }) else {
            return "Reflection probe snapshot missing from render frame."
        }

        let frameContext = captureFrameContextStorage.beginFrame()
        captureFrameContextStorage.updateRendererState(
            settings: resolvedSettings,
            viewContext: RenderViewContext(
                viewId: UInt64(bitPattern: Int64(truncatingIfNeeded: state.entityID.hashValue)),
                viewportSize: SIMD2<Float>(Float(captureSize), Float(captureSize)),
                layerFilterMask: .all,
                depthPrepassEnabled: false,
                updatesPickingMapping: false,
                updatesBatchStats: false,
                debugFlags: 0,
                showEditorOverlays: false,
                usesMirroredCubemapProjection: true,
                exposureSettings: scene.getViewExposureSettings()
            )
        )
        captureFrameContextStorage.setAssetStateRevision(assetStateRevisionProvider())
        frameContext.setRenderResourceRegistry(renderResourceRegistryBuilder())
        frameContext.setRenderFrameSnapshot(snapshot)

        guard let commandBuffer = engineContext.commandQueue.makeCommandBuffer() else {
            return "Failed to create reflection probe capture command buffer."
        }
        commandBuffer.label = "Reflection Probe Capture \(state.entityID.uuidString)"

        for face in 0..<6 {
            let viewMatrix = captureProbeViewMatrix(position: probeSnapshot.worldTransform.position, face: face)
            let captureSnapshot = SceneRenderer.makeCaptureSnapshot(
                from: snapshot,
                viewMatrix: viewMatrix,
                projectionMatrix: projection,
                cameraPosition: probeSnapshot.worldTransform.position
            )
            let passDescriptor = makeReflectionProbeCapturePassDescriptor(
                colorTexture: shouldApplyHeightFog ? captureSceneColorTexture! : capturedTexture,
                depthTexture: depthTexture,
                face: shouldApplyHeightFog ? 0 : face
            )
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
                return "Failed to create reflection probe encoder for face \(face)."
            }
            encoder.label = "Reflection Probe Capture Face \(face)"
            SceneRenderer.renderCaptureView(
                encoder: encoder,
                snapshot: snapshot,
                viewMatrix: viewMatrix,
                projectionMatrix: projection,
                cameraPosition: probeSnapshot.worldTransform.position,
                viewportSize: SIMD2<Float>(Float(captureSize), Float(captureSize)),
                captureViewId: (UInt64(bitPattern: Int64(truncatingIfNeeded: state.entityID.hashValue)) << 3) | UInt64(face),
                includeSky: probeSnapshot.includeSky,
                frameContext: frameContext
            )
            encoder.endEncoding()
            if shouldApplyHeightFog,
               let fogError = encodeReflectionProbeHeightFog(
                    sourceTexture: captureSceneColorTexture!,
                    depthTexture: depthTexture,
                    targetTexture: capturedTexture,
                    face: face,
                    captureSnapshot: captureSnapshot,
                    frameContext: frameContext,
                    commandBuffer: commandBuffer
               ) {
                return fogError
            }
        }

        if capturedTexture.mipmapLevelCount > 1,
           let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: capturedTexture)
            blit.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if commandBuffer.status == .error {
            return commandBuffer.error?.localizedDescription ?? "Reflection probe capture GPU work failed."
        }
        return nil
    }

    private func prefilterReflectionProbe(state: ReflectionProbeRuntimeState) -> String? {
        guard let capturedHandle = state.runtimeHandles.capturedEnvironmentHandle,
              let capturedTexture = engineContext.assets.texture(handle: capturedHandle) else {
            return "Missing captured reflection probe cubemap."
        }
        guard let prefilteredHandle = state.runtimeHandles.prefilteredHandle,
              let prefilteredTexture = engineContext.assets.texture(handle: prefilteredHandle) else {
            return "Missing reflection probe prefiltered cubemap target."
        }

        let frameContext = captureFrameContextStorage.beginFrame()
        captureFrameContextStorage.updateRendererState(
            settings: rendererSettingsProvider(),
            viewContext: RenderViewContext()
        )

        guard let commandBuffer = engineContext.commandQueue.makeCommandBuffer() else {
            return "Failed to create reflection probe prefilter command buffer."
        }
        commandBuffer.label = "Reflection Probe Prefilter \(state.entityID.uuidString)"

        prefilterRenderer(capturedTexture, prefilteredTexture, frameContext, commandBuffer)

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if commandBuffer.status == .error {
            return commandBuffer.error?.localizedDescription ?? "Reflection probe prefilter GPU work failed."
        }
        return nil
    }

    private func pruneReflectionProbeRuntimeStates(keeping sceneKey: ObjectIdentifier) {
        let staleKeys = runtimeStatesByScene.keys.filter { $0 != sceneKey }
        for key in staleKeys {
            guard let runtimeState = runtimeStatesByScene.removeValue(forKey: key) else { continue }
            for probeState in runtimeState.probeStates.values {
                releaseReflectionProbeTextures(for: probeState)
            }
        }
    }

    private func synchronizeReflectionProbeRuntimeState(scene: EngineScene) {
        let sceneKey = ObjectIdentifier(scene)
        var runtimeState = runtimeStatesByScene[sceneKey] ?? ReflectionProbeSceneRuntimeState()
        var liveProbeIDs = Set<UUID>()
        let now = CACurrentMediaTime()

        scene.ecs.viewReflectionProbes { entity, probe in
            liveProbeIDs.insert(entity.id)
            if var existing = runtimeState.probeStates[entity.id] {
                let authoredChanged = existing.authoredProbe != probe
                existing.authoredProbe = probe
                existing.lastUpdatedTime = now
                if authoredChanged {
                    existing.needsRebuild = true
                    if existing.status == .ready {
                        existing.status = .idle
                    }
                }
                if !probe.enabled, existing.status == .queued {
                    runtimeState.queuedProbeIDs.removeAll { $0 == entity.id }
                    existing.status = .idle
                }
                runtimeState.probeStates[entity.id] = existing
            } else {
                runtimeState.probeStates[entity.id] = ReflectionProbeRuntimeState(
                    entityID: entity.id,
                    authoredProbe: probe,
                    status: .idle,
                    runtimeHandles: ReflectionProbeRuntimeHandles(),
                    needsRebuild: true,
                    queuedAtTime: nil,
                    lastUpdatedTime: now,
                    lastError: nil
                )
            }
        }

        let removedProbeIDs = runtimeState.probeStates.keys.filter { !liveProbeIDs.contains($0) }
        for removedProbeID in removedProbeIDs {
            if let removedState = runtimeState.probeStates.removeValue(forKey: removedProbeID) {
                releaseReflectionProbeTextures(for: removedState)
            }
            runtimeState.queuedProbeIDs.removeAll { $0 == removedProbeID }
            if runtimeState.activeProbeID == removedProbeID {
                runtimeState.activeProbeID = nil
            }
        }

        runtimeState.queuedProbeIDs.removeAll { runtimeState.probeStates[$0] == nil }
        runtimeStatesByScene[sceneKey] = runtimeState
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
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = engineContext.device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = label
        return texture
    }

    private func iblMipCount(for size: Int) -> Int {
        guard size > 0 else { return 1 }
        return Int(floor(log2(Double(size)))) + 1
    }
}
