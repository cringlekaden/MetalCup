/// ShadowRenderer.swift
/// Renders cascaded directional shadow maps.
/// Created by Kaden Cringle.

import MetalKit
import simd

enum DirectionalShadowReferenceMath {
    static func lightFacing(normal: SIMD3<Float>, surfaceToLight: SIMD3<Float>) -> Float {
        let normalizedNormal = simd_normalize(normal)
        let normalizedLight = simd_normalize(surfaceToLight)
        return max(0, min(1, simd_dot(normalizedNormal, normalizedLight)))
    }

    static func receiverDepthBiasScale(normal: SIMD3<Float>, surfaceToLight: SIMD3<Float>) -> Float {
        let slope = 1 - lightFacing(normal: normal, surfaceToLight: surfaceToLight)
        return 1 + 0.6 * slope * slope
    }

    static func selectCascade(viewDepth: Float,
                              splits: SIMD4<Float>,
                              cascadeCount: Int) -> Int {
        var cascade = 0
        if viewDepth > splits.x { cascade = 1 }
        if viewDepth > splits.y { cascade = 2 }
        if viewDepth > splits.z { cascade = 3 }
        return min(cascade, max(cascadeCount - 1, 0))
    }
}

final class ShadowRenderer {
    private struct CascadeLayout {
        let splits: [Float]
        let lightViews: [matrix_float4x4]
        let lightProjections: [matrix_float4x4]
        let lightViewProjections: [matrix_float4x4]
        let worldUnitsPerTexel: [Float]
        let halfExtents: [Float]
        let nearZ: [Float]
        let farZ: [Float]
    }

    private let engineContext: EngineContext
    private let resources: ShadowResources
    private let cascadeEpsilon: Float = 0.001
    private let extentQuantizationTexels: Float = 8.0
    private let cascadeDepthExtensionScale: Float = 1.25
    private let minOrthoExtent: Float = 0.5
    private let minNearFarSpan: Float = 0.5
    private let minLightDistance: Float = 1.0
    private let depthPadding: Float = 0.5
    private let minSphereRadius: Float = 0.05

    init(engineContext: EngineContext) {
        self.engineContext = engineContext
        self.resources = ShadowResources(device: engineContext.device, preferences: engineContext.preferences)
    }

    func render(frame: RenderGraphFrame) {
        guard let snapshot = frame.sceneSnapshot else {
#if DEBUG
            assertionFailure("ShadowRenderer requires RenderFrameSnapshot in RenderGraphFrame.")
#endif
            resetShadowState(frame: frame)
            return
        }
        render(snapshot: snapshot, frame: frame)
    }

    private func render(snapshot: RenderFrameSnapshot, frame: RenderGraphFrame) {
        let settings = frame.frameContext.rendererSettings().shadows
        guard settings.enabled != 0, settings.directionalEnabled != 0 else {
            resetShadowState(frame: frame)
            return
        }
        guard let lightDirection = snapshot.directionalShadowLightDirection else {
            resetShadowState(frame: frame)
            return
        }
        guard let cameraState = resolveShadowCamera(sceneView: frame.sceneView) else {
            resetShadowState(frame: frame)
            return
        }
        let cascadeCount = max(1, min(4, Int(settings.cascadeCount)))
        let resolution = Int(settings.shadowMapResolution)
        guard let shadowMap = resources.ensureShadowMap(resolution: resolution, cascadeCount: cascadeCount) else {
            resetShadowState(frame: frame)
            return
        }

        let maxDistance = max(0.0, settings.maxShadowDistance)
        let cameraNear = max(0.01, cameraState.nearPlane)
        let cameraFar = max(cameraNear + 0.01, cameraState.farPlane)
        let farDistance = (maxDistance > 0.0) ? min(cameraFar, maxDistance) : cameraFar
        let distanceNear = max(0.01, cameraNear)
        let splits = computeCascadeSplits(near: distanceNear, far: farDistance, count: cascadeCount, lambda: settings.cascadeSplitLambda)
        let stabilizedSplits = enforceSplitEpsilon(splits: splits, near: distanceNear, far: farDistance)

        var constants = ShadowConstants()
        constants.shadowEnabled = 1.0
        constants.shadowCasterDirection = lightDirection
        constants.cascadeCount = UInt32(cascadeCount)
        constants.shadowMapInvSize = SIMD2<Float>(1.0 / Float(shadowMap.width), 1.0 / Float(shadowMap.height))
        constants.depthBias = settings.depthBias
        constants.normalBias = settings.normalBias
        constants.pcfRadius = settings.pcfRadius
        constants.pcfTapCounts = SIMD4<Float>(
            Float(max(1, min(25, settings.pcfTapsCascade0))),
            Float(max(1, min(25, settings.pcfTapsCascade1))),
            Float(max(1, min(25, settings.pcfTapsCascade2))),
            Float(max(1, min(25, settings.pcfTapsCascade3)))
        )
        constants.filterMode = settings.filterMode
        constants.maxShadowDistance = farDistance
        constants.fadeOutDistance = max(0.0, settings.fadeOutDistance)
        constants.pcssParams0 = SIMD4<Float>(
            settings.pcssLightWorldSize,
            settings.pcssMinFilterRadiusTexels,
            settings.pcssMaxFilterRadiusTexels,
            settings.pcssBlockerSearchRadiusTexels
        )
        constants.pcssParams1 = SIMD4<Float>(
            Float(settings.pcssBlockerSamples),
            Float(settings.pcssPCFSamples),
            Float(settings.pcssNoiseEnabled),
            0.0
        )

        guard let cascadeLayout = makeCascadeLayout(
            lightDirection: lightDirection,
            cameraState: cameraState,
            cascadeCount: cascadeCount,
            resolution: resolution,
            distanceNear: distanceNear,
            stabilizedSplits: stabilizedSplits
        ) else {
            resetShadowState(frame: frame)
            return
        }
        for cascadeIndex in 0..<cascadeCount {
            constants.setLightViewProj(cascadeLayout.lightViewProjections[cascadeIndex], index: cascadeIndex)
        }

        constants.cascadeSplits = SIMD4<Float>(
            cascadeLayout.splits.count > 0 ? cascadeLayout.splits[0] : farDistance,
            cascadeLayout.splits.count > 1 ? cascadeLayout.splits[1] : farDistance,
            cascadeLayout.splits.count > 2 ? cascadeLayout.splits[2] : farDistance,
            cascadeLayout.splits.count > 3 ? cascadeLayout.splits[3] : farDistance
        )
        constants.cascadeWorldUnitsPerTexel = SIMD4<Float>(
            cascadeLayout.worldUnitsPerTexel.count > 0 ? cascadeLayout.worldUnitsPerTexel[0] : 0.0,
            cascadeLayout.worldUnitsPerTexel.count > 1 ? cascadeLayout.worldUnitsPerTexel[1] : 0.0,
            cascadeLayout.worldUnitsPerTexel.count > 2 ? cascadeLayout.worldUnitsPerTexel[2] : 0.0,
            cascadeLayout.worldUnitsPerTexel.count > 3 ? cascadeLayout.worldUnitsPerTexel[3] : 0.0
        )
        constants.cascadeNearZ = SIMD4<Float>(
            cascadeLayout.nearZ.count > 0 ? cascadeLayout.nearZ[0] : 0.0,
            cascadeLayout.nearZ.count > 1 ? cascadeLayout.nearZ[1] : 0.0,
            cascadeLayout.nearZ.count > 2 ? cascadeLayout.nearZ[2] : 0.0,
            cascadeLayout.nearZ.count > 3 ? cascadeLayout.nearZ[3] : 0.0
        )
        constants.cascadeFarZ = SIMD4<Float>(
            cascadeLayout.farZ.count > 0 ? cascadeLayout.farZ[0] : 0.0,
            cascadeLayout.farZ.count > 1 ? cascadeLayout.farZ[1] : 0.0,
            cascadeLayout.farZ.count > 2 ? cascadeLayout.farZ[2] : 0.0,
            cascadeLayout.farZ.count > 3 ? cascadeLayout.farZ[3] : 0.0
        )

        for cascadeIndex in cascadeCount..<4 {
            constants.setLightViewProj(matrix_identity_float4x4, index: cascadeIndex)
        }

        frame.frameContext.setShadowConstants(constants)
        frame.frameContext.setShadowMapTexture(shadowMap)
        frame.resourceRegistry.registerNamedTexture("shadow.map", texture: shadowMap, lifetime: .transientPerFrame)
        let shadowConstantsBuffer = frame.frameContext.shadowConstantsBuffer()
        frame.resourceRegistry.registerBuffer("shadow.constants", buffer: shadowConstantsBuffer, lifetime: .transientPerFrame)

        let frameIndex = frame.frameContext.currentFrameIndex()
        var didSampleBegin = false
        for cascadeIndex in 0..<cascadeCount {
            let pass = MTLRenderPassDescriptor()
            pass.depthAttachment.texture = shadowMap
            pass.depthAttachment.slice = cascadeIndex
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .store
            pass.depthAttachment.clearDepth = 1.0
            guard let encoder = frame.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
            encoder.label = "Shadow Cascade \(cascadeIndex)"
            encoder.pushDebugGroup("Shadow Cascade \(cascadeIndex)")
            if !didSampleBegin {
                frame.profiler.sampleGpuPassBegin(.shadows, encoder: encoder, frameIndex: frameIndex)
                didSampleBegin = true
            }
            RenderPassHelpers.setViewport(encoder, SIMD2<Float>(Float(shadowMap.width), Float(shadowMap.height)))
            let constantsBuffer = frame.frameContext.makeSceneConstantsBuffer(
                shadowSceneConstants(
                    viewMatrix: cascadeLayout.lightViews[cascadeIndex],
                    projectionMatrix: cascadeLayout.lightProjections[cascadeIndex],
                    totalTime: snapshot.sceneConstants.totalGameTime
                ),
                label: "SceneConstants.ShadowCascade\(cascadeIndex)"
            )
            RenderPassHelpers.withRenderPass(.shadow, frameContext: frame.frameContext) {
                SceneRenderer.renderShadowCasters(
                    into: encoder,
                    snapshot: snapshot,
                    frameContext: frame.frameContext,
                    sceneConstantsBuffer: constantsBuffer,
                    shadowCullVolume: SceneRenderer.ShadowCullVolume(
                        lightView: cascadeLayout.lightViews[cascadeIndex],
                        halfExtent: cascadeLayout.halfExtents[cascadeIndex],
                        nearZ: cascadeLayout.nearZ[cascadeIndex],
                        farZ: cascadeLayout.farZ[cascadeIndex]
                    )
                )
            }
            encoder.popDebugGroup()
            if cascadeIndex == cascadeCount - 1 {
                frame.profiler.sampleGpuPassEnd(.shadows, encoder: encoder, frameIndex: frameIndex)
            }
            encoder.endEncoding()
        }

    }

    private func makeCascadeLayout(lightDirection: SIMD3<Float>,
                                   cameraState: CameraState,
                                   cascadeCount: Int,
                                   resolution: Int,
                                   distanceNear: Float,
                                   stabilizedSplits: [Float]) -> CascadeLayout? {
        var lightViews: [matrix_float4x4] = []
        var lightProjections: [matrix_float4x4] = []
        var lightViewProjections: [matrix_float4x4] = []
        var worldUnitsPerTexel: [Float] = []
        var halfExtents: [Float] = []
        var nearValues: [Float] = []
        var farValues: [Float] = []
        for cascadeIndex in 0..<cascadeCount {
            let splitFar = stabilizedSplits[cascadeIndex]
            let splitNear = cascadeIndex == 0 ? distanceNear : stabilizedSplits[cascadeIndex - 1]
            let sphere = stableFrustumSliceBoundingSphere(
                near: splitNear,
                far: splitFar,
                projection: cameraState.projection,
                viewMatrix: cameraState.viewMatrix
            )
            let center = sphere.center
            let extent = quantizedCascadeExtent(
                radius: max(sphere.radius, minSphereRadius),
                resolution: resolution
            )
            let stabilizedView = stabilizeLightView(
                lightView: lightViewMatrix(lightDirection: lightDirection, center: center, radius: extent),
                center: center,
                radius: extent,
                resolution: resolution
            )
            let centerLightSpace = stabilizedView * SIMD4<Float>(center, 1)
            let depthSpan = max(splitFar - splitNear, 0)
            let depthExtension = max(depthSpan * cascadeDepthExtensionScale, extent)
            let (nearZ, farZ) = computeLightNearFar(
                centerZ: centerLightSpace.z,
                radius: extent,
                extraDepth: depthExtension
            )
            let projection = lightProjectionMatrix(radius: extent, nearZ: nearZ, farZ: farZ)
            let viewProjection = projection * stabilizedView
            guard isFinite(stabilizedView), isFinite(projection), isFinite(viewProjection) else {
                return nil
            }
            lightViews.append(stabilizedView)
            lightProjections.append(projection)
            lightViewProjections.append(viewProjection)
            worldUnitsPerTexel.append((2 * extent) / max(Float(resolution), 1))
            halfExtents.append(extent)
            nearValues.append(nearZ)
            farValues.append(farZ)
        }
        return CascadeLayout(
            splits: stabilizedSplits,
            lightViews: lightViews,
            lightProjections: lightProjections,
            lightViewProjections: lightViewProjections,
            worldUnitsPerTexel: worldUnitsPerTexel,
            halfExtents: halfExtents,
            nearZ: nearValues,
            farZ: farValues
        )
    }

    /// Uses the production cascade-layout path so tests can assert finite matrices
    /// without encoding a frame or exposing renderer-owned textures.
    func validationCascadeViewProjections(viewMatrix: matrix_float4x4,
                                          projectionMatrix: matrix_float4x4,
                                          lightDirection: SIMD3<Float>,
                                          maxDistance: Float,
                                          cascadeCount: Int,
                                          resolution: Int,
                                          splitLambda: Float) -> [matrix_float4x4]? {
        guard let projection = deriveProjection(from: projectionMatrix) else { return nil }
        let count = max(1, min(4, cascadeCount))
        let near = max(0.01, projection.near)
        let far = maxDistance > 0 ? min(projection.far, maxDistance) : projection.far
        let splits = enforceSplitEpsilon(
            splits: computeCascadeSplits(near: near, far: far, count: count, lambda: splitLambda),
            near: near,
            far: far
        )
        let cameraState = CameraState(
            viewMatrix: viewMatrix,
            position: .zero,
            forward: SIMD3<Float>(0, 0, -1),
            nearPlane: projection.near,
            farPlane: projection.far,
            projection: projection.projection
        )
        return makeCascadeLayout(
            lightDirection: lightDirection,
            cameraState: cameraState,
            cascadeCount: count,
            resolution: resolution,
            distanceNear: near,
            stabilizedSplits: splits
        )?.lightViewProjections
    }

    private func resetShadowState(frame: RenderGraphFrame) {
        frame.frameContext.setShadowConstants(ShadowConstants())
        frame.frameContext.setShadowMapTexture(nil)
    }

    private enum CameraProjection {
        case perspective(tanHalfFov: Float, aspect: Float)
        case orthographic(halfWidth: Float, halfHeight: Float)
    }

    private struct CameraState {
        let viewMatrix: matrix_float4x4
        let position: SIMD3<Float>
        let forward: SIMD3<Float>
        let nearPlane: Float
        let farPlane: Float
        let projection: CameraProjection
    }

    private struct ProjectionInfo {
        let near: Float
        let far: Float
        let projection: CameraProjection
    }

    private func resolveShadowCamera(sceneView: SceneView) -> CameraState? {
        let viewMatrix = sceneView.viewMatrix
        guard let projectionInfo = deriveProjection(from: sceneView.projectionMatrix) else {
            return nil
        }
        let forward = normalize(-SIMD3<Float>(viewMatrix.columns.2.x, viewMatrix.columns.2.y, viewMatrix.columns.2.z))
        return CameraState(
            viewMatrix: viewMatrix,
            position: sceneView.cameraPosition,
            forward: forward,
            nearPlane: projectionInfo.near,
            farPlane: projectionInfo.far,
            projection: projectionInfo.projection
        )
    }

    private func deriveProjection(from projection: matrix_float4x4) -> ProjectionInfo? {
        let m22 = projection.columns.2.z
        let m32 = projection.columns.3.z
        guard m22.isFinite, m32.isFinite else { return nil }

        let isPerspective = abs(projection.columns.2.w + 1.0) < 0.01 && abs(projection.columns.3.w) < 0.01
        if isPerspective {
            guard abs(m22) > 1e-6, abs(m22 + 1.0) > 1e-6 else { return nil }
            var near = m32 / m22
            var far = m32 / (m22 + 1.0)
            if near > far {
                swap(&near, &far)
            }
            near = max(0.01, near)
            far = max(near + 0.01, far)

            let m11 = projection.columns.1.y
            let m00 = projection.columns.0.x
            guard abs(m11) > 1e-6, abs(m00) > 1e-6 else { return nil }
            let tanHalfFov = 1.0 / m11
            let aspect = m11 / m00
            return ProjectionInfo(
                near: near,
                far: far,
                projection: .perspective(tanHalfFov: tanHalfFov, aspect: aspect)
            )
        }

        guard abs(m22) > 1e-6 else { return nil }
        var near = m32 / m22
        var far = near - 1.0 / m22
        if near > far {
            swap(&near, &far)
        }
        near = max(0.01, near)
        far = max(near + 0.01, far)

        let m11 = projection.columns.1.y
        let m00 = projection.columns.0.x
        guard abs(m11) > 1e-6, abs(m00) > 1e-6 else { return nil }
        let halfWidth = 1.0 / m00
        let halfHeight = 1.0 / m11
        return ProjectionInfo(
            near: near,
            far: far,
            projection: .orthographic(halfWidth: halfWidth, halfHeight: halfHeight)
        )
    }

    private func computeCascadeSplits(near: Float, far: Float, count: Int, lambda: Float) -> [Float] {
        var splits: [Float] = []
        splits.reserveCapacity(count)
        let range = far - near
        let ratio = far / near
        for i in 1...count {
            let p = Float(i) / Float(count)
            let logSplit = near * pow(ratio, p)
            let linearSplit = near + range * p
            let split = linearSplit + (logSplit - linearSplit) * lambda
            splits.append(split)
        }
        return splits
    }

    private func enforceSplitEpsilon(splits: [Float], near: Float, far: Float) -> [Float] {
        guard !splits.isEmpty else { return splits }
        var stabilized: [Float] = []
        stabilized.reserveCapacity(splits.count)
        var previous = near
        for index in 0..<splits.count {
            let maxAllowed = far - Float(splits.count - index - 1) * cascadeEpsilon
            var value = min(splits[index], maxAllowed)
            value = max(value, previous + cascadeEpsilon)
            stabilized.append(value)
            previous = value
        }
        return stabilized
    }

    private func stableFrustumSliceBoundingSphere(
        near: Float,
        far: Float,
        projection: CameraProjection,
        viewMatrix: matrix_float4x4
    ) -> BoundingSphere {
        let localCorners = frustumCornersCameraSpace(near: near, far: far, projection: projection)
        let localCenter = SIMD3<Float>(0.0, 0.0, -0.5 * (near + far))
        let radiusSquared = localCorners.reduce(Float.zero) { partialResult, corner in
            max(partialResult, simd_length_squared(corner - localCenter))
        }
        let invView = simd_inverse(viewMatrix)
        let worldCenter4 = invView * SIMD4<Float>(localCenter, 1.0)
        let worldCenter = SIMD3<Float>(worldCenter4.x, worldCenter4.y, worldCenter4.z)
        if !isFinite(worldCenter) || !radiusSquared.isFinite {
            return BoundingSphere(center: .zero, radius: minSphereRadius)
        }
        return BoundingSphere(center: worldCenter, radius: max(sqrt(radiusSquared), minSphereRadius))
    }

    private func frustumCornersWorld(
        near: Float,
        far: Float,
        projection: CameraProjection,
        viewMatrix: matrix_float4x4
    ) -> [SIMD3<Float>] {
        let localCorners = frustumCornersCameraSpace(near: near, far: far, projection: projection)
        let invView = simd_inverse(viewMatrix)
        return localCorners.compactMap { corner in
            let world = invView * SIMD4<Float>(corner, 1.0)
            let worldPoint = SIMD3<Float>(world.x, world.y, world.z)
            return isFinite(worldPoint) ? worldPoint : nil
        }
    }

    private func frustumCornersCameraSpace(
        near: Float,
        far: Float,
        projection: CameraProjection
    ) -> [SIMD3<Float>] {
        let nearZ = -near
        let farZ = -far
        switch projection {
        case .perspective(let tanHalfFov, let aspect):
            let nearHeight = tanHalfFov * near
            let nearWidth = nearHeight * aspect
            let farHeight = tanHalfFov * far
            let farWidth = farHeight * aspect
            return [
                SIMD3<Float>(-nearWidth, -nearHeight, nearZ),
                SIMD3<Float>(nearWidth, -nearHeight, nearZ),
                SIMD3<Float>(nearWidth, nearHeight, nearZ),
                SIMD3<Float>(-nearWidth, nearHeight, nearZ),
                SIMD3<Float>(-farWidth, -farHeight, farZ),
                SIMD3<Float>(farWidth, -farHeight, farZ),
                SIMD3<Float>(farWidth, farHeight, farZ),
                SIMD3<Float>(-farWidth, farHeight, farZ)
            ]
        case .orthographic(let halfWidth, let halfHeight):
            return [
                SIMD3<Float>(-halfWidth, -halfHeight, nearZ),
                SIMD3<Float>(halfWidth, -halfHeight, nearZ),
                SIMD3<Float>(halfWidth, halfHeight, nearZ),
                SIMD3<Float>(-halfWidth, halfHeight, nearZ),
                SIMD3<Float>(-halfWidth, -halfHeight, farZ),
                SIMD3<Float>(halfWidth, -halfHeight, farZ),
                SIMD3<Float>(halfWidth, halfHeight, farZ),
                SIMD3<Float>(-halfWidth, halfHeight, farZ)
            ]
        }
    }

    private func lightViewMatrix(lightDirection: SIMD3<Float>, center: SIMD3<Float>, radius: Float) -> matrix_float4x4 {
        // lightDirection is the direction light rays travel in world space.
        let forward = safeNormalize(lightDirection, fallback: SIMD3<Float>(0, -1, 0))
        let worldUp = SIMD3<Float>(0, 1, 0)
        let worldRight = SIMD3<Float>(1, 0, 0)
        let upCandidate = abs(dot(forward, worldUp)) > 0.99 ? worldRight : worldUp
        var right = safeNormalize(cross(upCandidate, forward), fallback: worldRight)
        var up = cross(forward, right)
        if determinant3x3(right: right, up: up, forward: forward) < 0.0 {
            right = -right
            up = cross(forward, right)
        }
        let extraMargin = max(1.0, radius * 0.1)
        let distance = max(minLightDistance, radius + extraMargin)
        let eye = center - forward * distance
        return viewMatrix(right: right, up: up, forward: forward, eye: eye)
    }

    private func stabilizeLightView(
        lightView: matrix_float4x4,
        center: SIMD3<Float>,
        radius: Float,
        resolution: Int
    ) -> matrix_float4x4 {
        let safeResolution = max(1, resolution)
        let worldUnitsPerTexel = (2.0 * radius) / Float(safeResolution)
        guard worldUnitsPerTexel > 0.0 else { return lightView }

        let centerLS = lightView * SIMD4<Float>(center, 1.0)
        let snappedX = round(centerLS.x / worldUnitsPerTexel) * worldUnitsPerTexel
        let snappedY = round(centerLS.y / worldUnitsPerTexel) * worldUnitsPerTexel
        if !snappedX.isFinite || !snappedY.isFinite {
            return lightView
        }
        var stabilized = lightView
        stabilized.columns.3.x += snappedX - centerLS.x
        stabilized.columns.3.y += snappedY - centerLS.y
        return stabilized
    }

    private func quantizedCascadeExtent(radius: Float, resolution: Int) -> Float {
        let baseExtent = max(radius, minOrthoExtent * 0.5)
        let safeResolution = max(Float(resolution), 1.0)
        let rawWorldUnitsPerTexel = (2.0 * baseExtent) / safeResolution
        guard rawWorldUnitsPerTexel.isFinite, rawWorldUnitsPerTexel > 0.0 else {
            return baseExtent
        }

        let quantizationStep = max(rawWorldUnitsPerTexel * extentQuantizationTexels, rawWorldUnitsPerTexel)
        let quantizedExtent = ceil(baseExtent / quantizationStep) * quantizationStep
        if quantizedExtent.isFinite {
            return max(quantizedExtent, minOrthoExtent * 0.5)
        }
        return baseExtent
    }

    private func computeLightNearFar(centerZ: Float, radius: Float, extraDepth: Float) -> (Float, Float) {
        let depthPad = max(depthPadding, radius * 0.005)
        var minZ = centerZ - radius - depthPad
        var maxZ = centerZ + radius + depthPad
        let depthExtension = max(extraDepth, 0.0)
        if depthExtension > 0.0 {
            minZ -= depthExtension
            maxZ += depthExtension
        }
        let span = abs(maxZ - minZ)
        if span < minNearFarSpan {
            let extra = (minNearFarSpan - span) * 0.5
            maxZ += extra
            minZ -= extra
        }
        if !minZ.isFinite || !maxZ.isFinite {
            maxZ = -depthPadding
            minZ = maxZ - minNearFarSpan
        }
        let nearZ = maxZ
        let farZ = minZ
        return (nearZ, farZ)
    }

    private func lightProjectionMatrix(radius: Float, nearZ: Float, farZ: Float) -> matrix_float4x4 {
        let extent = radius
        return metalOrthographic(
            left: -extent,
            right: extent,
            bottom: -extent,
            top: extent,
            nearZ: nearZ,
            farZ: farZ
        )
    }

    private func metalOrthographic(
        left: Float,
        right: Float,
        bottom: Float,
        top: Float,
        nearZ: Float,
        farZ: Float
    ) -> matrix_float4x4 {
        let rl = right - left
        let tb = top - bottom
        var fn = farZ - nearZ
        if abs(fn) < 1e-6 {
            fn = fn >= 0.0 ? 1e-6 : -1e-6
        }
        var result = matrix_identity_float4x4
        result.columns = (
            SIMD4<Float>(2.0 / rl, 0, 0, 0),
            SIMD4<Float>(0, 2.0 / tb, 0, 0),
            SIMD4<Float>(0, 0, 1.0 / fn, 0),
            SIMD4<Float>(-(right + left) / rl, -(top + bottom) / tb, -nearZ / fn, 1.0)
        )
        return result
    }

    private struct BoundingSphere {
        let center: SIMD3<Float>
        let radius: Float
    }

    private func ritterBoundingSphere(points: [SIMD3<Float>]) -> BoundingSphere {
        guard !points.isEmpty else {
            return BoundingSphere(center: SIMD3<Float>(0, 0, 0), radius: minSphereRadius)
        }

        let first = points[0]
        var farthest = first
        var maxDist = Float.leastNonzeroMagnitude
        for p in points {
            let d = simd_length_squared(p - first)
            if d > maxDist {
                maxDist = d
                farthest = p
            }
        }

        var farthest2 = farthest
        maxDist = Float.leastNonzeroMagnitude
        for p in points {
            let d = simd_length_squared(p - farthest)
            if d > maxDist {
                maxDist = d
                farthest2 = p
            }
        }

        var center = (farthest + farthest2) * 0.5
        var radius = max(sqrt(simd_length_squared(farthest2 - farthest)) * 0.5, minSphereRadius)

        for p in points {
            let toPoint = p - center
            let dist = simd_length(toPoint)
            if dist > radius {
                let newRadius = (radius + dist) * 0.5
                let shift = (newRadius - radius) / max(dist, 1e-6)
                center += toPoint * shift
                radius = newRadius
            }
        }

        if !center.x.isFinite || !center.y.isFinite || !center.z.isFinite || !radius.isFinite {
            center = points.reduce(SIMD3<Float>(0, 0, 0), +) / Float(points.count)
            var maxDistanceSquared: Float = 0.0
            for p in points {
                maxDistanceSquared = max(maxDistanceSquared, simd_length_squared(p - center))
            }
            radius = max(sqrt(maxDistanceSquared), minSphereRadius)
        }

        return BoundingSphere(center: center, radius: max(radius, minSphereRadius))
    }

    private func determinant3x3(right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>) -> Float {
        let m00 = right.x
        let m01 = up.x
        let m02 = forward.x
        let m10 = right.y
        let m11 = up.y
        let m12 = forward.y
        let m20 = right.z
        let m21 = up.z
        let m22 = forward.z
        return m00 * (m11 * m22 - m12 * m21)
            - m01 * (m10 * m22 - m12 * m20)
            + m02 * (m10 * m21 - m11 * m20)
    }

    private func shadowSceneConstants(viewMatrix: matrix_float4x4, projectionMatrix: matrix_float4x4, totalTime: Float) -> SceneConstants {
        var constants = SceneConstants()
        constants.totalGameTime = totalTime
        constants.viewMatrix = viewMatrix
        constants.inverseViewMatrix = simd_inverse(viewMatrix)
        constants.skyViewMatrix = viewMatrix
        constants.projectionMatrix = projectionMatrix
        constants.inverseProjectionMatrix = simd_inverse(projectionMatrix)
        constants.inverseViewProjectionMatrix = simd_inverse(projectionMatrix * viewMatrix)
        constants.cameraPositionAndIBL = SIMD4<Float>(0, 0, 0, 0)
        return constants
    }

    private func viewMatrix(right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>, eye: SIMD3<Float>) -> matrix_float4x4 {
        let r = SIMD4<Float>(right.x, up.x, -forward.x, 0.0)
        let u = SIMD4<Float>(right.y, up.y, -forward.y, 0.0)
        let f = SIMD4<Float>(right.z, up.z, -forward.z, 0.0)
        let t = SIMD4<Float>(-dot(right, eye), -dot(up, eye), dot(forward, eye), 1.0)
        return matrix_float4x4(columns: (r, u, f, t))
    }

    private func isFinite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private func isFinite(_ value: SIMD4<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite && value.w.isFinite
    }

    private func isFinite(_ matrix: matrix_float4x4) -> Bool {
        isFinite(matrix.columns.0) && isFinite(matrix.columns.1) && isFinite(matrix.columns.2) && isFinite(matrix.columns.3)
    }

    private func safeNormalize(_ value: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let lengthSquared = simd_length_squared(value)
        if lengthSquared > 1e-8 {
            return simd_normalize(value)
        }
        return fallback
    }

}
