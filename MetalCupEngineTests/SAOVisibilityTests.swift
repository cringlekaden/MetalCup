import Testing
import Metal
@testable import MetalCupEngine

struct SAOVisibilityTests {
    @Test
    func backgroundIsolatedAndNoSampleCasesAreFullyVisible() {
        #expect(SAOVisibilityContract.visibility(
            weightedObscurance: 0,
            totalWeight: 0,
            intensity: 1,
            power: 1
        ) == 1)
        #expect(SAOVisibilityContract.visibility(
            weightedObscurance: 0,
            totalWeight: 1,
            intensity: 1,
            power: 1
        ) == 1)
    }

    @Test
    func contactCornerIntensityAndPowerAreMonotonic() {
        let contact = SAOVisibilityContract.visibility(
            weightedObscurance: 0.25,
            totalWeight: 1,
            intensity: 1,
            power: 1
        )
        let corner = SAOVisibilityContract.visibility(
            weightedObscurance: 0.75,
            totalWeight: 1,
            intensity: 1,
            power: 1
        )
        #expect(abs(contact - 0.75) < 0.000001)
        #expect(abs(corner - 0.25) < 0.000001)
        #expect(corner < contact)

        let lowIntensity = SAOVisibilityContract.visibility(
            weightedObscurance: 0.25,
            totalWeight: 1,
            intensity: 0.5,
            power: 1
        )
        let highIntensity = SAOVisibilityContract.visibility(
            weightedObscurance: 0.25,
            totalWeight: 1,
            intensity: 2,
            power: 1
        )
        #expect(highIntensity <= lowIntensity)

        let lowPower = SAOVisibilityContract.visibility(
            weightedObscurance: 0.5,
            totalWeight: 1,
            intensity: 1,
            power: 1
        )
        let highPower = SAOVisibilityContract.visibility(
            weightedObscurance: 0.5,
            totalWeight: 1,
            intensity: 1,
            power: 2
        )
        #expect(abs(lowPower - 0.5) < 0.000001)
        #expect(abs(highPower - 0.25) < 0.000001)
        #expect(highPower <= lowPower)
    }

    @Test
    func bilateralBlurAveragesVisibilityAndNeutralFallbackIsOne() {
        #expect(abs(SAOVisibilityContract.weightedBlur(
            centerVisibility: 1,
            sampleVisibilities: [0, 0.5],
            sampleWeights: [1, 2]
        ) - 0.5) < 0.000001)
        #expect(SAOVisibilityContract.weightedBlur(
            centerVisibility: 1,
            sampleVisibilities: [],
            sampleWeights: [],
            centerWeight: 0
        ) == 1)
    }

    @Test
    func AOIsAppliedOnlyAfterAnalyticDirectLighting() throws {
        let root = try #require(ResourceRegistry.bundledCanonicalShaderRootURL())
        let source = try String(contentsOf: root.appendingPathComponent("BasicShaders.metal"), encoding: .utf8)
        let directRange = try #require(source.range(of: "Lo += direct * radiance * NdotL * shadowFactor;"))
        let aoRange = try #require(source.range(of: "float combinedAOVisibility"))
        #expect(directRange.lowerBound < aoRange.lowerBound)
        let directSection = source[directRange.lowerBound..<aoRange.lowerBound]
        #expect(!directSection.contains("combinedAOVisibility"))
        #expect(source.contains("ambient = kD * diffuseIBL * combinedAOVisibility"))
    }

    @Test
    func CPUReferenceMatchesProductionGPUForReferenceCases() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase2MetalTestSupport.canonicalLibrary(device: device)
        let function = try #require(library.makeFunction(name: "phase2_sao_visibility_samples"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let samples = [
            SIMD4<Float>(0, 0, 1, 1),
            SIMD4<Float>(0, 1, 1, 1),
            SIMD4<Float>(0.25, 1, 1, 1),
            SIMD4<Float>(0.75, 1, 1, 1),
            SIMD4<Float>(0.5, 1, 1.5, 2)
        ]
        let sampleBuffer = try Phase2MetalTestSupport.makeBuffer(device: device, values: samples)
        let resultBuffer = try #require(device.makeBuffer(
            length: MemoryLayout<Float>.stride * samples.count,
            options: .storageModeShared
        ))
        try Phase2MetalTestSupport.execute(device: device, pipeline: pipeline, width: samples.count) { encoder in
            encoder.setBuffer(sampleBuffer, offset: 0, index: 0)
            encoder.setBuffer(resultBuffer, offset: 0, index: 1)
        }
        let results = resultBuffer.contents().bindMemory(to: Float.self, capacity: samples.count)
        for index in samples.indices {
            let sample = samples[index]
            let expected = SAOVisibilityContract.visibility(
                weightedObscurance: sample.x,
                totalWeight: sample.y,
                intensity: sample.z,
                power: sample.w
            )
            #expect(abs(results[index] - expected) < 0.00001)
        }
    }
}
