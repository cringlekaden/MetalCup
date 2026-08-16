import Foundation
import Metal
import Testing
import simd
@testable import MetalCupEngine

@Suite("Phase 5 legacy fog characterization")
struct Phase5LegacyFogCharacterizationTests {
    @Test
    func legacyBackgroundAppliesTwoExtraDirectionalCoverageCurves() {
        let opticalDepth: Float = 1
        let physicalCoverage = 1 - exp(-opticalDepth)
        let horizonWeight: Float = 1
        let zenithWeight: Float = 0
        let directionalCoverage = min(
            physicalCoverage * mix(0.18, 1, horizonWeight) * mix(1, 0.55, zenithWeight),
            mix(0.35, 0.94, horizonWeight)
        )
        let secondSkyCoverage = directionalCoverage
            * mix(0.28, 0.86, horizonWeight)
            * mix(1, 0.42, zenithWeight)

        #expect(physicalCoverage > 0.63 && physicalCoverage < 0.64)
        #expect(abs(directionalCoverage - physicalCoverage) < 0.000001)
        #expect(secondSkyCoverage < physicalCoverage)
    }

    @Test
    func legacyBackgroundUsesViewDependentVirtualDistance() {
        let maxAerialDistance: Float = 2_600
        let zenithDistance = mix(maxAerialDistance * 0.22, maxAerialDistance, 0)
        let horizonDistance = mix(maxAerialDistance * 0.22, maxAerialDistance, 1)
        #expect(zenithDistance == 572)
        #expect(horizonDistance == 2_600)
        #expect(horizonDistance / zenithDistance > 4.5)
    }

    @Test
    func legacyFogCombinesHeightAndIndependentDistanceDensity() {
        let segmentLength: Float = 50
        let heightDensity: Float = 0.03
        let distanceDensity: Float = 0.02
        let oldOpticalDepth = heightDensity * segmentLength + distanceDensity * segmentLength
        #expect(abs(oldOpticalDepth - 2.5) < 0.000001)
        #expect(oldOpticalDepth > heightDensity * segmentLength)
    }

    private func mix(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }
}

@Suite("Fog transmittance references")
struct FogTransmittanceReferenceTests {
    @Test
    func homogeneousBeerLambertAndDisabledIdentity() {
        let homogeneous = LocalFogTransport.Parameters(enabled: true,
                                                        extinction: 0.02,
                                                        baseHeight: 0,
                                                        scaleHeight: 1_000_000,
                                                        anisotropy: 0)
        for distance: Float in [0, 1, 5, 10, 25, 50, 100] {
            let tau = LocalFogTransport.opticalDepth(cameraPosition: .zero,
                                                     rayDirection: SIMD3<Float>(1, 0, 0),
                                                     distance: distance,
                                                     parameters: homogeneous)
            #expect(abs(tau - 0.02 * distance) < 0.0001)
            #expect(abs(exp(-tau) - exp(-0.02 * distance)) < 0.0001)
        }
        var disabled = homogeneous
        disabled.enabled = false
        #expect(LocalFogTransport.opticalDepth(cameraPosition: .zero,
                                               rayDirection: SIMD3<Float>(1, 0, 0),
                                               distance: 100,
                                               parameters: disabled) == 0)
    }

    @Test
    func distanceAndDensityAreMonotonicAndFinite() {
        let parameters = LocalFogTransport.Parameters(enabled: true, extinction: 0.03, scaleHeight: 12)
        let near = LocalFogTransport.opticalDepth(cameraPosition: .zero,
                                                  rayDirection: SIMD3<Float>(1, 0, 0),
                                                  distance: 5,
                                                  parameters: parameters)
        let far = LocalFogTransport.opticalDepth(cameraPosition: .zero,
                                                 rayDirection: SIMD3<Float>(1, 0, 0),
                                                 distance: 50,
                                                 parameters: parameters)
        var denser = parameters
        denser.extinction *= 2
        let dense = LocalFogTransport.opticalDepth(cameraPosition: .zero,
                                                   rayDirection: SIMD3<Float>(1, 0, 0),
                                                   distance: 50,
                                                   parameters: denser)
        #expect(near < far)
        #expect(far < dense)
        #expect(near.isFinite && far.isFinite && dense.isFinite)
    }
}

@Suite("Height-fog optical-depth references")
struct HeightFogOpticalDepthTests {
    @Test(arguments: [Float(-0.8), -0.2, 0, 0.2, 0.8])
    func analyticIntegralMatchesNumericalQuadrature(rayY: Float) {
        let parameters = LocalFogTransport.Parameters(enabled: true,
                                                        extinction: 0.035,
                                                        baseHeight: -1,
                                                        scaleHeight: 14)
        let direction = simd_normalize(SIMD3<Float>(sqrt(max(1 - rayY * rayY, 0)), rayY, 0))
        let distance: Float = 80
        let analytic = LocalFogTransport.opticalDepth(cameraPosition: SIMD3<Float>(0, 3, 0),
                                                      rayDirection: direction,
                                                      distance: distance,
                                                      parameters: parameters)
        let steps = 20_000
        let step = distance / Float(steps)
        var numerical: Float = 0
        for index in 0..<steps {
            let s = (Float(index) + 0.5) * step
            let y = 3 + direction.y * s
            numerical += parameters.extinction
                * exp(-(y - parameters.baseHeight) / parameters.scaleHeight) * step
        }
        numerical = min(numerical, parameters.maximumOpticalDepth)
        #expect(abs(analytic - numerical) < 0.001)
    }

    @Test
    func backgroundLimitsAreStable() {
        let parameters = LocalFogTransport.Parameters(enabled: true, extinction: 0.02, scaleHeight: 10)
        let upward = LocalFogTransport.opticalDepth(cameraPosition: .zero,
                                                    rayDirection: SIMD3<Float>(0, 1, 0),
                                                    distance: nil,
                                                    parameters: parameters)
        let horizontal = LocalFogTransport.opticalDepth(cameraPosition: .zero,
                                                        rayDirection: SIMD3<Float>(1, 0, 0),
                                                        distance: nil,
                                                        parameters: parameters)
        let downward = LocalFogTransport.opticalDepth(cameraPosition: .zero,
                                                      rayDirection: SIMD3<Float>(0, -1, 0),
                                                      distance: nil,
                                                      parameters: parameters)
        #expect(abs(upward - 0.2) < 0.00001)
        #expect(horizontal == parameters.maximumOpticalDepth)
        #expect(downward == parameters.maximumOpticalDepth)
    }
}

@Suite("Fog in-scattering references")
struct FogInscatteringReferenceTests {
    @Test
    func zeroScatteringAlbedoCreatesNoGlow() {
        let parameters = LocalFogTransport.Parameters(enabled: true,
                                                        extinction: 0.1,
                                                        scatteringAlbedo: .zero,
                                                        scaleHeight: 20)
        let sample = LocalFogTransport.evaluate(cameraPosition: .zero,
                                                rayDirection: SIMD3<Float>(1, 0, 0),
                                                distance: 10,
                                                ambientRadiance: SIMD3<Float>(repeating: 1),
                                                solarIrradiance: SIMD3<Float>(repeating: 4),
                                                directionToSun: SIMD3<Float>(1, 0, 0),
                                                parameters: parameters)
        #expect(sample.transmittance < 1)
        #expect(sample.inscattering == .zero)
    }

    @Test
    func scatteringIsBoundedAndForwardPhaseIsFinite() {
        let parameters = LocalFogTransport.Parameters(enabled: true,
                                                        extinction: 0.08,
                                                        scatteringAlbedo: SIMD3<Float>(repeating: 0.85),
                                                        scaleHeight: 20,
                                                        anisotropy: 0.5)
        let sample = LocalFogTransport.evaluate(cameraPosition: .zero,
                                                rayDirection: SIMD3<Float>(1, 0, 0),
                                                distance: 20,
                                                ambientRadiance: SIMD3<Float>(0.4, 0.5, 0.6),
                                                solarIrradiance: SIMD3<Float>(2, 1.8, 1.5),
                                                directionToSun: SIMD3<Float>(1, 0, 0),
                                                parameters: parameters)
        #expect(sample.inscattering.x >= 0 && sample.inscattering.y >= 0 && sample.inscattering.z >= 0)
        #expect(sample.inscattering.x.isFinite && sample.inscattering.y.isFinite && sample.inscattering.z.isFinite)
        #expect(LocalFogTransport.henyeyGreenstein(cosTheta: 1, anisotropy: 0.5)
                > LocalFogTransport.henyeyGreenstein(cosTheta: -1, anisotropy: 0.5))
    }
}

@Suite("Fog production GPU references")
struct FogDepthReconstructionGPUTests {
    @Test
    func productionMetalTransportMatchesCPUReferences() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase2MetalTestSupport.canonicalLibrary(device: device)
        let function = try #require(library.makeFunction(name: "phase5_local_fog_reference_samples"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let inputs: [SIMD4<Float>] = [
            SIMD4<Float>(0, 0, 10, 0),
            SIMD4<Float>(3, 0.5, 80, 0),
            SIMD4<Float>(0, 1, 0, 1),
            SIMD4<Float>(0, 0, 0, 1),
            SIMD4<Float>(-2, -0.4, 25, 0)
        ]
        let parameters = inputs.map { _ in SIMD4<Float>(0.035, -1, 14, 0.3) }
        let inputBuffer = try Phase2MetalTestSupport.makeBuffer(device: device, values: inputs)
        let parameterBuffer = try Phase2MetalTestSupport.makeBuffer(device: device, values: parameters)
        let outputBuffer = try #require(device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride * inputs.count,
                                                          options: .storageModeShared))
        try Phase2MetalTestSupport.execute(device: device, pipeline: pipeline, width: inputs.count) { encoder in
            encoder.setBuffer(inputBuffer, offset: 0, index: 0)
            encoder.setBuffer(parameterBuffer, offset: 0, index: 1)
            encoder.setBuffer(outputBuffer, offset: 0, index: 2)
        }
        let results = outputBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: inputs.count)
        let cpuParameters = LocalFogTransport.Parameters(enabled: true,
                                                          extinction: 0.035,
                                                          baseHeight: -1,
                                                          scaleHeight: 14,
                                                          anisotropy: 0.3)
        for index in inputs.indices {
            let input = inputs[index]
            let direction = SIMD3<Float>(sqrt(max(1 - input.y * input.y, 0)), input.y, 0)
            let expected = LocalFogTransport.opticalDepth(cameraPosition: SIMD3<Float>(0, input.x, 0),
                                                          rayDirection: direction,
                                                          distance: input.w > 0.5 ? nil : input.z,
                                                          parameters: cpuParameters)
            #expect(abs(results[index].x - expected) < 0.0002)
            #expect(abs(results[index].y - exp(-expected)) < 0.0002)
            #expect(results[index].x.isFinite && results[index].y.isFinite && results[index].z.isFinite)
        }
    }

    @Test
    func productionFogFragmentReconstructsGeometryAndClassifiesBackground() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase2MetalTestSupport.canonicalLibrary(device: device)
        let cameraPosition = SIMD3<Float>(0, 2, 0)
        let projection = matrix_float4x4.perspective(
            fovDegrees: 60,
            aspectRatio: 1,
            near: 0.1,
            far: 150
        )
        var view = matrix_identity_float4x4
        view.columns.3.y = -cameraPosition.y
        var constants = SceneConstants()
        constants.viewMatrix = view
        constants.inverseViewMatrix = simd_inverse(view)
        constants.projectionMatrix = projection
        constants.inverseProjectionMatrix = simd_inverse(projection)
        constants.inverseViewProjectionMatrix = simd_inverse(projection * view)
        constants.cameraPositionAndIBL = SIMD4<Float>(cameraPosition, 1)

        var settings = RendererSettings()
        settings.localFogParameters = LocalFogTransport.Parameters(
            enabled: true,
            extinction: 0.025,
            scatteringAlbedo: SIMD3<Float>(repeating: 0.9),
            baseHeight: 0,
            scaleHeight: 12,
            anisotropy: 0.2
        )
        settings.aerialFogSunDirectionAndNight = SIMD4<Float>(0, 1, 0, 0)
        settings.aerialFogSunColorAndStrength = SIMD4<Float>(1.0, 0.9, 0.7, 0)

        let source = SIMD3<Float>(0.8, 0.6, 0.4)
        let ambient = SIMD3<Float>(repeating: 0.2)
        let worldPosition = SIMD4<Float>(0, cameraPosition.y, -10, 1)
        let clip = projection * view * worldPosition
        let geometryDepth = clip.z / clip.w
        let geometryOutput = try renderProductionFog(
            device: device,
            library: library,
            rawDepth: geometryDepth,
            source: source,
            irradiance: ambient * .pi,
            settings: settings,
            sceneConstants: constants
        )
        let geometryReference = LocalFogTransport.evaluate(
            cameraPosition: cameraPosition,
            rayDirection: SIMD3<Float>(0, 0, -1),
            distance: 10,
            ambientRadiance: ambient,
            solarIrradiance: SIMD3<Float>(1.0, 0.9, 0.7),
            directionToSun: SIMD3<Float>(0, 1, 0),
            parameters: settings.localFogParameters
        )
        let expectedGeometry = source * geometryReference.transmittance
            + geometryReference.inscattering
        #expect(simd_distance(geometryOutput.xyz, expectedGeometry) < 0.001)

        let offCenterSize = 3
        let offCenterX = 2
        let offCenterY = 1
        let offCenterOutput = try renderProductionFog(
            device: device,
            library: library,
            rawDepth: geometryDepth,
            source: source,
            irradiance: ambient * .pi,
            settings: settings,
            sceneConstants: constants,
            size: offCenterSize,
            sampleX: offCenterX,
            sampleY: offCenterY
        )
        let offCenterUV = SIMD2<Float>(
            (Float(offCenterX) + 0.5) / Float(offCenterSize),
            (Float(offCenterY) + 0.5) / Float(offCenterSize)
        )
        var offCenterClip = SIMD4<Float>(
            offCenterUV.x * 2 - 1,
            (1 - offCenterUV.y) * 2 - 1,
            geometryDepth,
            1
        )
        offCenterClip = constants.inverseViewProjectionMatrix * offCenterClip
        let offCenterWorld = offCenterClip.xyz / offCenterClip.w
        let offCenterVector = offCenterWorld - cameraPosition
        let offCenterReference = LocalFogTransport.evaluate(
            cameraPosition: cameraPosition,
            rayDirection: simd_normalize(offCenterVector),
            distance: simd_length(offCenterVector),
            ambientRadiance: ambient,
            solarIrradiance: SIMD3<Float>(1.0, 0.9, 0.7),
            directionToSun: SIMD3<Float>(0, 1, 0),
            parameters: settings.localFogParameters
        )
        let expectedOffCenter = source * offCenterReference.transmittance
            + offCenterReference.inscattering
        #expect(simd_distance(offCenterOutput.xyz, expectedOffCenter) < 0.001)

        let cameraForward = simd_normalize(SIMD3<Float>(0.6, -0.15, -1))
        let rotatedView = matrix_float4x4(
            lookAt: cameraPosition,
            center: cameraPosition + cameraForward,
            up: SIMD3<Float>(0, 1, 0)
        )
        var rotatedConstants = constants
        rotatedConstants.viewMatrix = rotatedView
        rotatedConstants.inverseViewMatrix = simd_inverse(rotatedView)
        rotatedConstants.inverseViewProjectionMatrix = simd_inverse(projection * rotatedView)
        let rotatedWorld = SIMD4<Float>(cameraPosition + cameraForward * 10, 1)
        let rotatedClip = projection * rotatedView * rotatedWorld
        let rotatedDepth = rotatedClip.z / rotatedClip.w
        let rotatedOutput = try renderProductionFog(
            device: device,
            library: library,
            rawDepth: rotatedDepth,
            source: source,
            irradiance: ambient * .pi,
            settings: settings,
            sceneConstants: rotatedConstants
        )
        let rotatedReference = LocalFogTransport.evaluate(
            cameraPosition: cameraPosition,
            rayDirection: cameraForward,
            distance: 10,
            ambientRadiance: ambient,
            solarIrradiance: SIMD3<Float>(1.0, 0.9, 0.7),
            directionToSun: SIMD3<Float>(0, 1, 0),
            parameters: settings.localFogParameters
        )
        let expectedRotated = source * rotatedReference.transmittance
            + rotatedReference.inscattering
        #expect(simd_distance(rotatedOutput.xyz, expectedRotated) < 0.001)

        let backgroundOutput = try renderProductionFog(
            device: device,
            library: library,
            rawDepth: 1,
            source: source,
            irradiance: ambient * .pi,
            settings: settings,
            sceneConstants: constants
        )
        let backgroundReference = LocalFogTransport.evaluate(
            cameraPosition: cameraPosition,
            rayDirection: SIMD3<Float>(0, 0, -1),
            distance: nil,
            ambientRadiance: ambient,
            solarIrradiance: SIMD3<Float>(1.0, 0.9, 0.7),
            directionToSun: SIMD3<Float>(0, 1, 0),
            parameters: settings.localFogParameters
        )
        let expectedBackground = source * backgroundReference.transmittance
            + backgroundReference.inscattering
        #expect(simd_distance(backgroundOutput.xyz, expectedBackground) < 0.001)

        settings.setHeightFogEnabled(false)
        let disabledOutput = try renderProductionFog(
            device: device,
            library: library,
            rawDepth: geometryDepth,
            source: source,
            irradiance: ambient * .pi,
            settings: settings,
            sceneConstants: constants
        )
        #expect(simd_distance(disabledOutput.xyz, source) < 0.000001)
    }

    private func renderProductionFog(device: MTLDevice,
                                     library: MTLLibrary,
                                     rawDepth: Float,
                                     source: SIMD3<Float>,
                                     irradiance: SIMD3<Float>,
                                     settings: RendererSettings,
                                     sceneConstants: SceneConstants,
                                     size: Int = 1,
                                     sampleX: Int = 0,
                                     sampleY: Int = 0) throws -> SIMD4<Float> {
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: size,
            height: size,
            mipmapped: false
        )
        colorDescriptor.storageMode = .shared
        colorDescriptor.usage = [.shaderRead, .renderTarget]
        let sourceTexture = try #require(device.makeTexture(descriptor: colorDescriptor))
        let outputTexture = try #require(device.makeTexture(descriptor: colorDescriptor))
        let sourcePixels = [SIMD4<Float>](
            repeating: SIMD4<Float>(source, 1),
            count: size * size
        )
        sourcePixels.withUnsafeBytes { bytes in
            sourceTexture.replace(region: MTLRegionMake2D(0, 0, size, size),
                                  mipmapLevel: 0,
                                  withBytes: bytes.baseAddress!,
                                  bytesPerRow: MemoryLayout<SIMD4<Float>>.stride * size)
        }

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: size,
            height: size,
            mipmapped: false
        )
        depthDescriptor.storageMode = .private
        depthDescriptor.usage = [.renderTarget, .shaderRead]
        let depthTexture = try #require(device.makeTexture(descriptor: depthDescriptor))

        let irradianceDescriptor = MTLTextureDescriptor.textureCubeDescriptor(
            pixelFormat: .rgba32Float,
            size: 1,
            mipmapped: false
        )
        irradianceDescriptor.storageMode = .shared
        irradianceDescriptor.usage = .shaderRead
        let irradianceTexture = try #require(device.makeTexture(descriptor: irradianceDescriptor))
        var irradianceTexel = SIMD4<Float>(irradiance, 1)
        for face in 0..<6 {
            irradianceTexture.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                                      mipmapLevel: 0,
                                      slice: face,
                                      withBytes: &irradianceTexel,
                                      bytesPerRow: MemoryLayout<SIMD4<Float>>.stride,
                                      bytesPerImage: MemoryLayout<SIMD4<Float>>.stride)
        }

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SimpleVertex>.stride
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = try #require(library.makeFunction(name: "vertex_final"))
        pipelineDescriptor.fragmentFunction = try #require(library.makeFunction(name: "fragment_height_fog"))
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        samplerDescriptor.rAddressMode = .clampToEdge
        let sampler = try #require(device.makeSamplerState(descriptor: samplerDescriptor))
        let vertices = [
            SimpleVertex(position: SIMD3<Float>(-1, -1, 0)),
            SimpleVertex(position: SIMD3<Float>( 1, -1, 0)),
            SimpleVertex(position: SIMD3<Float>(-1,  1, 0)),
            SimpleVertex(position: SIMD3<Float>(-1,  1, 0)),
            SimpleVertex(position: SIMD3<Float>( 1, -1, 0)),
            SimpleVertex(position: SIMD3<Float>( 1,  1, 0))
        ]

        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let depthPass = MTLRenderPassDescriptor()
        depthPass.depthAttachment.texture = depthTexture
        depthPass.depthAttachment.loadAction = .clear
        depthPass.depthAttachment.storeAction = .store
        depthPass.depthAttachment.clearDepth = Double(rawDepth)
        let depthEncoder = try #require(commandBuffer.makeRenderCommandEncoder(descriptor: depthPass))
        depthEncoder.endEncoding()

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = outputTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        let encoder = try #require(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(size), height: Double(size),
                                        znear: 0, zfar: 1))
        encoder.setVertexBytes(vertices,
                               length: MemoryLayout<SimpleVertex>.stride * vertices.count,
                               index: VertexBufferIndex.vertices)
        var mutableSettings = settings
        var mutableConstants = sceneConstants
        encoder.setFragmentBytes(&mutableSettings,
                                 length: RendererSettings.stride,
                                 index: FragmentBufferIndex.rendererSettings)
        encoder.setFragmentBytes(&mutableConstants,
                                 length: SceneConstants.stride,
                                 index: FragmentBufferIndex.postProcessSceneConstants)
        encoder.setFragmentTexture(sourceTexture, index: PostProcessTextureIndex.source)
        encoder.setFragmentTexture(depthTexture, index: PostProcessTextureIndex.depth)
        encoder.setFragmentTexture(irradianceTexture, index: FragmentTextureIndex.irradiance)
        encoder.setFragmentSamplerState(sampler, index: FragmentSamplerIndex.linearClamp)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        if let error = commandBuffer.error {
            Issue.record("Production fog fragment GPU render failed: \(error.localizedDescription)")
        }

        var outputPixels = [SIMD4<Float>](repeating: .zero, count: size * size)
        outputPixels.withUnsafeMutableBytes { bytes in
            outputTexture.getBytes(bytes.baseAddress!,
                                   bytesPerRow: MemoryLayout<SIMD4<Float>>.stride * size,
                                   from: MTLRegionMake2D(0, 0, size, size),
                                   mipmapLevel: 0)
        }
        return outputPixels[sampleY * size + sampleX]
    }
}

@Suite("Fog sky/object continuity")
struct FogSkyObjectContinuityTests {
    @Test
    func distantGeometryConvergesTowardHorizontalBackgroundLimit() {
        let parameters = LocalFogTransport.Parameters(enabled: true, extinction: 0.02, scaleHeight: 12)
        let direction = SIMD3<Float>(1, 0, 0)
        let distant = LocalFogTransport.opticalDepth(cameraPosition: .zero,
                                                     rayDirection: direction,
                                                     distance: 100_000,
                                                     parameters: parameters)
        let background = LocalFogTransport.opticalDepth(cameraPosition: .zero,
                                                        rayDirection: direction,
                                                        distance: nil,
                                                        parameters: parameters)
        #expect(distant == background)
        #expect(exp(-distant) < 1e-20)
    }
}

@Suite("Fog environment coupling")
struct FogEnvironmentCouplingTests {
    @Test
    func localFogDoesNotChangeIBLSourceSignature() {
        var environment = EnvironmentComponent()
        let before = EnvironmentRenderStateBuilder.build(environment: environment, runtime: nil).iblSignature
        environment.fog = EnvironmentFogConfig(enabled: true,
                                               extinction: 0.08,
                                               scatteringAlbedo: SIMD3<Float>(0.8, 0.9, 1),
                                               baseHeight: -2,
                                               scaleHeight: 6,
                                               anisotropy: 0.4)
        let after = EnvironmentRenderStateBuilder.build(environment: environment, runtime: nil).iblSignature
        #expect(before == after)
    }

    @Test
    func legacySchemaMigratesDeterministically() throws {
        let data = Data(#"{"schemaVersion":1,"amount":0.04,"height":-2,"distance":9}"#.utf8)
        let config = try JSONDecoder().decode(EnvironmentFogDTO.self, from: data).toConfig()
        #expect(config.enabled)
        #expect(config.extinction == 0.04)
        #expect(config.baseHeight == -2)
        #expect(config.scaleHeight == 9)
        #expect(config.scatteringAlbedo == SIMD3<Float>(repeating: 0.9))
    }

    @Test
    func sourceEnergyScalesInscatteringWithoutChangingTransmittance() {
        let parameters = LocalFogTransport.Parameters(enabled: true,
                                                       extinction: 0.04,
                                                       scatteringAlbedo: SIMD3<Float>(repeating: 0.8),
                                                       scaleHeight: 16,
                                                       anisotropy: 0.3)
        let baseline = LocalFogTransport.evaluate(cameraPosition: .zero,
                                                  rayDirection: simd_normalize(SIMD3<Float>(1, 0.1, 0)),
                                                  distance: 30,
                                                  ambientRadiance: SIMD3<Float>(0.2, 0.3, 0.4),
                                                  solarIrradiance: SIMD3<Float>(1.0, 0.9, 0.7),
                                                  directionToSun: simd_normalize(SIMD3<Float>(1, 0.4, 0)),
                                                  parameters: parameters)
        let doubled = LocalFogTransport.evaluate(cameraPosition: .zero,
                                                 rayDirection: simd_normalize(SIMD3<Float>(1, 0.1, 0)),
                                                 distance: 30,
                                                 ambientRadiance: SIMD3<Float>(0.4, 0.6, 0.8),
                                                 solarIrradiance: SIMD3<Float>(2.0, 1.8, 1.4),
                                                 directionToSun: simd_normalize(SIMD3<Float>(1, 0.4, 0)),
                                                 parameters: parameters)
        #expect(baseline.transmittance == doubled.transmittance)
        #expect(simd_length(doubled.inscattering - baseline.inscattering * 2) < 0.000001)
    }

    @Test
    func fogPassPrecedesBloomAndProbeCaptureExcludesLocalFog() throws {
        let graphSource = try engineSource(relativePath: "Core/Rendering/RenderGraph.swift")
        let fogOffset = try #require(graphSource.range(of: "HeightFogPass()")?.lowerBound)
        let bloomOffset = try #require(graphSource.range(of: "BloomExtractPass()")?.lowerBound)
        #expect(fogOffset < bloomOffset)

        let probeSource = try engineSource(relativePath: "Core/ReflectionProbeRuntimeManager.swift")
        #expect(probeSource.contains("let shouldApplyHeightFog = false"))
    }

    @Test
    func noonAndGoldenHourUseTheAuthoritativeEnvironmentSun() {
        var environment = EnvironmentComponent.default
        environment.fog = EnvironmentFogConfig(enabled: true,
                                                extinction: 0.025,
                                                scatteringAlbedo: SIMD3<Float>(repeating: 0.9),
                                                baseHeight: 0,
                                                scaleHeight: 12,
                                                anisotropy: 0.2)
        environment.atmosphere.sourceEV = 0

        environment.celestial.defaultTimeOfDay = 12
        let noon = EnvironmentRenderStateBuilder.build(environment: environment, runtime: nil)
        environment.celestial.defaultTimeOfDay = 17
        let golden = EnvironmentRenderStateBuilder.build(environment: environment, runtime: nil)

        for state in [noon, golden] {
            #expect(state.legacyFogPatch.directionToSun == state.sunDirection)
            #expect(state.legacyFogPatch.solarIrradiance == state.solarIrradianceRGB)
            let sample = LocalFogTransport.evaluate(
                cameraPosition: SIMD3<Float>(0, 2, 0),
                rayDirection: state.sunDirection,
                distance: 50,
                ambientRadiance: SIMD3<Float>(repeating: 0.2),
                solarIrradiance: state.legacyFogPatch.solarIrradiance,
                directionToSun: state.legacyFogPatch.directionToSun,
                parameters: state.legacyFogPatch.parameters
            )
            #expect(sample.inscattering.x.isFinite
                    && sample.inscattering.y.isFinite
                    && sample.inscattering.z.isFinite)
            #expect(sample.directionalInscattering.x >= 0
                    && sample.directionalInscattering.y >= 0
                    && sample.directionalInscattering.z >= 0)
        }
        #expect(noon.sunDirection != golden.sunDirection)
        #expect(noon.solarIrradianceRGB != golden.solarIrradianceRGB)
    }

    private func engineSource(relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("MetalCupEngine/\(relativePath)"),
                          encoding: .utf8)
    }
}

@Suite("Fog PBR integration")
struct FogPBRIntegrationTests {
    @Test
    func transportIsLinearInSurfaceRadianceAndExposureIndependent() {
        let parameters = LocalFogTransport.Parameters(enabled: true, extinction: 0.03, scaleHeight: 20)
        let fog = LocalFogTransport.evaluate(cameraPosition: .zero,
                                             rayDirection: SIMD3<Float>(1, 0, 0),
                                             distance: 25,
                                             ambientRadiance: SIMD3<Float>(0.2, 0.3, 0.4),
                                             solarIrradiance: SIMD3<Float>(1.0, 0.9, 0.7),
                                             directionToSun: SIMD3<Float>(0, 1, 0),
                                             parameters: parameters)
        let direct = SIMD3<Float>(0.7, 0.6, 0.5)
        let indirect = SIMD3<Float>(0.2, 0.25, 0.3)
        let combined = (direct + indirect) * fog.transmittance + fog.inscattering
        let decomposed = direct * fog.transmittance
            + indirect * fog.transmittance
            + fog.ambientInscattering
            + fog.directionalInscattering
        #expect(simd_length(combined - decomposed) < 0.000001)
        #expect(fog == LocalFogTransport.evaluate(cameraPosition: .zero,
                                                 rayDirection: SIMD3<Float>(1, 0, 0),
                                                 distance: 25,
                                                 ambientRadiance: SIMD3<Float>(0.2, 0.3, 0.4),
                                                 solarIrradiance: SIMD3<Float>(1.0, 0.9, 0.7),
                                                 directionToSun: SIMD3<Float>(0, 1, 0),
                                                 parameters: parameters))
    }
}
