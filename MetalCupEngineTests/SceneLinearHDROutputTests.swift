import Foundation
import Metal
import Testing
import simd
@testable import MetalCupEngine

struct SceneLinearHDROutputTests {
    @Test
    func exposureEVReferencePointsAndLegacyMigrationAreDeterministic() throws {
        let references: [(Float, Float)] = [(-2, 0.25), (-1, 0.5), (0, 1), (1, 2), (2, 4)]
        for (ev, multiplier) in references {
            #expect(abs(SceneLinearHDRContract.exposureMultiplier(forEV: ev) - multiplier) < 0.000001)
        }

        let legacy = Data(#"{"manualExposure":4,"autoExposureEnabled":true}"#.utf8)
        let migrated = try JSONDecoder().decode(CameraComponentDTO.self, from: legacy)
        #expect(abs(migrated.exposureEV - 2.0) < 0.000001)

        let missing = try JSONDecoder().decode(CameraComponentDTO.self, from: Data("{}".utf8))
        #expect(missing.exposureEV == 0.0)

        let encoded = try JSONEncoder().encode(migrated)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["exposureEV"] != nil)
        #expect(json["manualExposure"] == nil)
        #expect(json["schemaVersion"] as? Int == 4)
    }

    @Test
    func staleAutoExposureFieldsCannotChangeTheManualFramePath() {
        var camera = CameraComponent(autoExposureEnabled: true, exposureEV: -1.0)
        camera.exposureCompensation = 8.0
        camera.autoExposureMin = 0.001
        camera.autoExposureMax = 64.0
        camera.adaptationSpeed = 20.0

        let settings = SceneRenderer.exposureSettings(from: camera)
        #expect(settings.autoExposureEnabled == 0)
        #expect(settings.exposureEV == -1.0)
        #expect(settings.exposureCompensation == 0.0)
        #expect(settings.autoExposureMin == 0.0)
        #expect(settings.autoExposureMax == 0.0)
        #expect(settings.adaptationSpeed == 0.0)
        #expect(SceneLinearHDRContract.exposureMultiplier(forEV: settings.exposureEV) == 0.5)

        let evMinusOne = RenderViewContext(exposureSettings: SceneViewExposureSettings(exposureEV: -1))
        let evZero = RenderViewContext(exposureSettings: SceneViewExposureSettings(exposureEV: 0))
        let evPlusOne = RenderViewContext(exposureSettings: SceneViewExposureSettings(exposureEV: 1))
        #expect(evMinusOne.cacheSignature() == evZero.cacheSignature())
        #expect(evZero.cacheSignature() == evPlusOne.cacheSignature())
    }

    @Test
    func globalIBLSamplingGainUsesCapturedEnergyForProceduralAndHDRI() throws {
        var procedural = EnvironmentComponent(
            source: EnvironmentSourceConfig(mode: .procedural)
        )
        let clearState = EnvironmentRenderStateBuilder.build(environment: procedural, runtime: nil)
        #expect(clearState.iblLightingIntensity == 1.0)

        procedural.weather = EnvironmentWeatherConfig(
            primaryType: .storm,
            secondaryType: .foggy,
            blend: 0.8,
            amount: 1.0
        )
        procedural.clouds.coverage = 1.0
        procedural.atmosphere.haze = 1.0
        procedural.atmosphere.density = 2.5
        procedural.atmosphere.mood = -1.0
        procedural.celestial.defaultTimeOfDay = 23.0
        let stormState = EnvironmentRenderStateBuilder.build(environment: procedural, runtime: nil)
        #expect(stormState.iblLightingIntensity == 1.0)
        #expect(stormState.iblSignature != clearState.iblSignature)

        let hdri = EnvironmentComponent(source: EnvironmentSourceConfig(mode: .hdri))
        #expect(EnvironmentRenderStateBuilder.build(environment: hdri, runtime: nil).iblLightingIntensity == 1.0)

        var disabledEnvironment = procedural
        disabledEnvironment.enabled = false
        #expect(EnvironmentRenderStateBuilder.build(environment: disabledEnvironment, runtime: nil).iblLightingIntensity == 0.0)

        var renderer = RendererSettings()
        renderer.iblEnabled = 1
        renderer.iblIntensity = 0.05
        renderer.applySceneLinearHDROutputInvariants()
        #expect(renderer.iblIntensity == 1.0)
        #expect(renderer.effectiveGlobalIBLSamplingGain == 1.0)
        renderer.iblEnabled = 0
        #expect(renderer.effectiveGlobalIBLSamplingGain == 0.0)

        let oldOverride = try JSONDecoder().decode(
            RendererSettingsDTO.self,
            from: Data(#"{"iblEnabled":1,"iblIntensity":0.05}"#.utf8)
        )
        #expect(oldOverride.makeRendererSettings().iblIntensity == 1.0)
        #expect(oldOverride.makeRendererSettings().effectiveGlobalIBLSamplingGain == 1.0)
    }

    @Test
    func fixedOutputIgnoresLegacyTonemapAndGammaAuthoring() throws {
        let legacyA = try JSONDecoder().decode(
            RendererSettingsDTO.self,
            from: Data(#"{"tonemap":0,"gamma":1.0}"#.utf8)
        ).makeRendererSettings()
        let legacyB = try JSONDecoder().decode(
            RendererSettingsDTO.self,
            from: Data(#"{"tonemap":4,"gamma":3.0}"#.utf8)
        ).makeRendererSettings()

        #expect(legacyA.tonemap == TonemapType.filmic.rawValue)
        #expect(legacyB.tonemap == TonemapType.filmic.rawValue)
        #expect(legacyA.gamma == 2.2)
        #expect(legacyB.gamma == 2.2)

        let color = SIMD3<Float>(0.18, 1.0, 4.0)
        let outputWithLegacyA = SceneLinearHDRContract.finalSDROutput(sceneLinear: color, exposureEV: 0)
        let outputWithLegacyB = SceneLinearHDRContract.finalSDROutput(sceneLinear: color, exposureEV: 0)
        #expect(outputWithLegacyA == outputWithLegacyB)
    }

    @Test
    func linearSRGBAndFilmicV1HaveFixedNumericReferences() {
        let srgb = SceneLinearHDRContract.linearToSRGB(SIMD3<Float>(0.0031308, 0.18, 0.5))
        #expect(abs(srgb.x - 0.040449936) < 0.000001)
        #expect(abs(srgb.y - 0.4613561) < 0.000001)
        #expect(abs(srgb.z - 0.7353569) < 0.000001)

        let sampleInputs: [Float] = [0.18, 1.0, 4.0, 16.0]
        let expectedFilmic: [Float] = [0.06261719, 0.2839292, 0.6654904, 1.0]
        for (input, expected) in zip(sampleInputs, expectedFilmic) {
            let value = SceneLinearHDRContract.metalCupFilmicV1(SIMD3<Float>(repeating: input)).x
            #expect(abs(value - expected) < 0.000002)
        }

        let representativeHDR: [SIMD3<Float>] = [
            .zero,
            SIMD3<Float>(-1.0, 0.5, 2.0),
            SIMD3<Float>(0.18, 1.0, 16.0),
            SIMD3<Float>(1_000.0, 20.0, 0.001)
        ]
        for color in representativeHDR {
            for ev: Float in [-2.0, 0.0, 2.0] {
                let output = SceneLinearHDRContract.finalSDROutput(sceneLinear: color, exposureEV: ev)
                #expect(output.x.isFinite && output.x >= 0.0)
                #expect(output.y.isFinite && output.y >= 0.0)
                #expect(output.z.isFinite && output.z >= 0.0)
            }
        }

        let exposureBeforeTonemap = SceneLinearHDRContract.finalSDROutput(
            sceneLinear: SIMD3<Float>(0.25, 0.5, 1.0),
            exposureEV: 1.0
        )
        let doubledBeforeTonemap = SceneLinearHDRContract.finalSDROutput(
            sceneLinear: SIMD3<Float>(0.5, 1.0, 2.0),
            exposureEV: 0.0
        )
        expectClose(exposureBeforeTonemap, doubledBeforeTonemap, tolerance: 0.000001)
    }

    @Test
    func productionOutputKernelAppliesExposureOnlyAtFinalOutput() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try canonicalLibrary(device: device)
        let function = try #require(library.makeFunction(name: "phase1_final_output_samples"))
        let pipeline = try device.makeComputePipelineState(function: function)

        let sceneLinear = SIMD3<Float>(0.18, 1.0, 4.0)
        let inputs = [-1.0, 0.0, 1.0].map { SIMD4<Float>(sceneLinear, $0) }
        let outputs = try executeCompute(
            device: device,
            pipeline: pipeline,
            inputs: inputs,
            outputCount: inputs.count
        )

        for index in inputs.indices {
            let expected = SceneLinearHDRContract.finalSDROutput(
                sceneLinear: sceneLinear,
                exposureEV: inputs[index].w
            )
            expectClose(SIMD3<Float>(outputs[index].x, outputs[index].y, outputs[index].z), expected, tolerance: 0.00002)
            #expect(outputs[index].x.isFinite && outputs[index].x >= 0.0)
            #expect(outputs[index].y.isFinite && outputs[index].y >= 0.0)
            #expect(outputs[index].z.isFinite && outputs[index].z >= 0.0)
        }

        // The pre-exposure owner is unchanged across EV; only the value entering the
        // final tonemapper has the expected half/unity/double relationship.
        let preExposure0 = SIMD3<Float>(inputs[0].x, inputs[0].y, inputs[0].z)
        let preExposure1 = SIMD3<Float>(inputs[1].x, inputs[1].y, inputs[1].z)
        let preExposure2 = SIMD3<Float>(inputs[2].x, inputs[2].y, inputs[2].z)
        #expect(preExposure0 == preExposure1)
        #expect(preExposure1 == preExposure2)
        #expect(outputs[0] != outputs[1])
        #expect(outputs[1] != outputs[2])
        #expect(SceneLinearHDRContract.exposureMultiplier(forEV: -1) == 0.5)
        #expect(SceneLinearHDRContract.exposureMultiplier(forEV: 0) == 1.0)
        #expect(SceneLinearHDRContract.exposureMultiplier(forEV: 1) == 2.0)
    }

    @Test
    func proceduralSkyVisibleAndCaptureRadianceScaleLinearly() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try canonicalLibrary(device: device)
        let function = try #require(library.makeFunction(name: "phase1_procedural_sky_linearity_samples"))
        let pipeline = try device.makeComputePipelineState(function: function)

        let intensities: [Float] = [0.25, 0.5, 1.0, 2.0]
        var paramsByIntensity: [Float: SkyParams] = [:]
        for intensity in intensities {
            let sky = SkyLightComponent(
                mode: .procedural,
                timeOfDay: 12.0,
                moonIntensity: 0.0,
                starIntensity: 0.0,
                intensity: intensity,
                cloudsEnabled: false
            )
            paramsByIntensity[intensity] = SkySystem.shaderParams(authored: sky, runtime: nil)
        }

        let unitParams = try #require(paramsByIntensity[1.0])
        for intensity in intensities {
            let params = try #require(paramsByIntensity[intensity])
            #expect(abs(params.atmosphereOpticalParams.z - unitParams.atmosphereOpticalParams.z) < 0.000001)
            #expect(abs(params.atmosphereOpticalParams.w - unitParams.atmosphereOpticalParams.w) < 0.000001)
        }

        let sun = simd_normalize(unitParams.sunDirection)
        let tangentSeed = abs(sun.y) < 0.95 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let tangent = simd_normalize(simd_cross(sun, tangentSeed))
        let aureoleAngle = max(unitParams.sunAngularRadius * 4.0, 0.02)
        let directions: [SIMD4<Float>] = [
            SIMD4<Float>(simd_normalize(-sun + SIMD3<Float>(0, 1.25, 0)), 0),
            SIMD4<Float>(sun, 0),
            SIMD4<Float>(simd_normalize(sun * cos(aureoleAngle) + tangent * sin(aureoleAngle)), 0)
        ]

        var visibleByIntensity: [Float: [SIMD4<Float>]] = [:]
        for intensity in intensities {
            var params = try #require(paramsByIntensity[intensity])
            let results = try executeSkyCompute(
                device: device,
                pipeline: pipeline,
                params: &params,
                directions: directions
            )
            visibleByIntensity[intensity] = results.visible
            for sampleIndex in directions.indices {
                expectClose(
                    SIMD3<Float>(results.visible[sampleIndex].x, results.visible[sampleIndex].y, results.visible[sampleIndex].z),
                    SIMD3<Float>(results.capture[sampleIndex].x, results.capture[sampleIndex].y, results.capture[sampleIndex].z),
                    tolerance: 0.00001
                )
            }
        }

        let unitVisible = try #require(visibleByIntensity[1.0])
        for sample in unitVisible {
            let radiance = SIMD3<Float>(sample.x, sample.y, sample.z)
            #expect(simd_length(radiance) > 0.0001)
            #expect(radiance.x.isFinite && radiance.y.isFinite && radiance.z.isFinite)
        }
        for intensity in intensities {
            let samples = try #require(visibleByIntensity[intensity])
            for sampleIndex in directions.indices {
                let unit = SIMD3<Float>(unitVisible[sampleIndex].x, unitVisible[sampleIndex].y, unitVisible[sampleIndex].z)
                let actual = SIMD3<Float>(samples[sampleIndex].x, samples[sampleIndex].y, samples[sampleIndex].z)
                expectClose(actual, unit * intensity, tolerance: max(0.0001, simd_reduce_max(abs(unit * intensity)) * 0.0002))
            }
        }
    }

    private func canonicalLibrary(device: MTLDevice) throws -> MTLLibrary {
        let root = try #require(ResourceRegistry.bundledCanonicalShaderRootURL())
        let registry = ResourceRegistry(canonicalShaderRootURL: root)
        #expect(registry.activateCanonicalShaders(
            device: device,
            requiredFunctions: ShaderLibrary.requiredFunctionNames
        ))
        return try #require(registry.defaultLibrary)
    }

    private func executeCompute(device: MTLDevice,
                                pipeline: MTLComputePipelineState,
                                inputs: [SIMD4<Float>],
                                outputCount: Int) throws -> [SIMD4<Float>] {
        let inputBuffer = try #require(device.makeBuffer(
            bytes: inputs,
            length: MemoryLayout<SIMD4<Float>>.stride * inputs.count,
            options: .storageModeShared
        ))
        let outputBuffer = try #require(device.makeBuffer(
            length: MemoryLayout<SIMD4<Float>>.stride * outputCount,
            options: .storageModeShared
        ))
        try execute(device: device, pipeline: pipeline, width: outputCount) { encoder in
            encoder.setBuffer(inputBuffer, offset: 0, index: 0)
            encoder.setBuffer(outputBuffer, offset: 0, index: 1)
        }
        let pointer = outputBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: outputCount)
        return Array(UnsafeBufferPointer(start: pointer, count: outputCount))
    }

    private func executeSkyCompute(device: MTLDevice,
                                   pipeline: MTLComputePipelineState,
                                   params: inout SkyParams,
                                   directions: [SIMD4<Float>]) throws -> (visible: [SIMD4<Float>], capture: [SIMD4<Float>]) {
        let paramsBuffer = try withUnsafeBytes(of: &params) { bytes in
            try #require(device.makeBuffer(bytes: bytes.baseAddress!, length: SkyParams.stride, options: .storageModeShared))
        }
        let directionBuffer = try #require(device.makeBuffer(
            bytes: directions,
            length: MemoryLayout<SIMD4<Float>>.stride * directions.count,
            options: .storageModeShared
        ))
        let resultLength = MemoryLayout<SIMD4<Float>>.stride * directions.count
        let visibleBuffer = try #require(device.makeBuffer(length: resultLength, options: .storageModeShared))
        let captureBuffer = try #require(device.makeBuffer(length: resultLength, options: .storageModeShared))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        let fallbackTexture = try #require(device.makeTexture(descriptor: descriptor))

        try execute(device: device, pipeline: pipeline, width: directions.count) { encoder in
            encoder.setBuffer(paramsBuffer, offset: 0, index: 0)
            encoder.setBuffer(directionBuffer, offset: 0, index: 1)
            encoder.setBuffer(visibleBuffer, offset: 0, index: 2)
            encoder.setBuffer(captureBuffer, offset: 0, index: 3)
            encoder.setTexture(fallbackTexture, index: 0)
            encoder.setTexture(fallbackTexture, index: 1)
            encoder.setTexture(fallbackTexture, index: 2)
        }

        let visiblePointer = visibleBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: directions.count)
        let capturePointer = captureBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: directions.count)
        return (
            Array(UnsafeBufferPointer(start: visiblePointer, count: directions.count)),
            Array(UnsafeBufferPointer(start: capturePointer, count: directions.count))
        )
    }

    private func execute(device: MTLDevice,
                         pipeline: MTLComputePipelineState,
                         width: Int,
                         configure: (MTLComputeCommandEncoder) -> Void) throws {
        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        configure(encoder)
        let groupWidth = min(max(1, pipeline.threadExecutionWidth), width)
        encoder.dispatchThreads(
            MTLSize(width: width, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: groupWidth, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        if let error = commandBuffer.error {
            throw error
        }
    }

    private func expectClose(_ actual: SIMD3<Float>,
                             _ expected: SIMD3<Float>,
                             tolerance: Float) {
        #expect(abs(actual.x - expected.x) <= tolerance)
        #expect(abs(actual.y - expected.y) <= tolerance)
        #expect(abs(actual.z - expected.z) <= tolerance)
    }
}
