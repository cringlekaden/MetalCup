import Testing
import Metal
@testable import MetalCupEngine

struct DirectLightContractTests {
    @Test
    func pointAttenuationIsInverseSquareUntilTheLateCutoff() {
        let range: Float = 10
        for distance: Float in [1, 2, 4, 8] {
            let expected = 1 / (distance * distance)
            #expect(abs(AnalyticLightContract.inverseSquareAttenuation(
                distance: distance,
                range: range
            ) - expected) < 0.000001)
        }
        #expect(abs(AnalyticLightContract.rangeFade(distance: 9, range: range) - 0.5) < 0.000001)
        #expect(abs(AnalyticLightContract.inverseSquareAttenuation(distance: 9, range: range) - 0.5 / 81) < 0.000001)
        #expect(AnalyticLightContract.inverseSquareAttenuation(distance: 10, range: range) == 0)
        #expect(AnalyticLightContract.inverseSquareAttenuation(distance: 11, range: range) == 0)
        #expect(AnalyticLightContract.inverseSquareAttenuation(distance: 4, range: 0) == Float(1) / 16)
        #expect(AnalyticLightContract.inverseSquareAttenuation(distance: 4, range: -1) == Float(1) / 16)
    }

    @Test
    func lateCutoffIsSmoothFiniteAndNonnegative() {
        var previous = Float.greatestFiniteMagnitude
        for step in 0...200 {
            let distance = Float(step) * 0.05
            let attenuation = AnalyticLightContract.inverseSquareAttenuation(distance: distance, range: 10)
            #expect(attenuation.isFinite)
            #expect(attenuation >= 0)
            #expect(attenuation <= previous)
            previous = attenuation
        }
        let beforeBoundary = AnalyticLightContract.inverseSquareAttenuation(distance: 9.999, range: 10)
        let atBoundary = AnalyticLightContract.inverseSquareAttenuation(distance: 10, range: 10)
        #expect(beforeBoundary >= atBoundary)
        #expect(beforeBoundary < 0.000001)
    }

    @Test
    func spotConeFalloffIsExplicitAndSeparate() {
        let inner: Float = 0.95
        let outer: Float = 0.8
        #expect(AnalyticLightContract.spotAngularFalloff(
            spotCos: 1,
            innerConeCos: inner,
            outerConeCos: outer
        ) == 1)
        #expect(AnalyticLightContract.spotAngularFalloff(
            spotCos: inner,
            innerConeCos: inner,
            outerConeCos: outer
        ) == 1)
        #expect(abs(AnalyticLightContract.spotAngularFalloff(
            spotCos: (inner + outer) * 0.5,
            innerConeCos: inner,
            outerConeCos: outer
        ) - 0.25) < 0.000001)
        #expect(AnalyticLightContract.spotAngularFalloff(
            spotCos: outer,
            innerConeCos: inner,
            outerConeCos: outer
        ) == 0)
        #expect(AnalyticLightContract.spotAngularFalloff(
            spotCos: 0.7,
            innerConeCos: inner,
            outerConeCos: outer
        ) == 0)
    }

    @Test
    func directionalPiReferenceProducesUnitLambertianRadiance() {
        #expect(abs(AnalyticLightContract.whiteLambertianRadiance(
            illuminance: .pi
        ) - 1) < 0.000001)
        #expect(AnalyticLightContract.whiteLambertianRadiance(
            illuminance: .pi,
            normalDotLight: 0
        ) == 0)
    }

    @Test
    func CPUReferenceMatchesProductionGPU() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase2MetalTestSupport.canonicalLibrary(device: device)
        let function = try #require(library.makeFunction(name: "phase2_analytic_light_contract_samples"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let samples = [
            SIMD4<Float>(1, 10, 1, .pi),
            SIMD4<Float>(4, 10, 0.95, .pi * 0.5),
            SIMD4<Float>(9, 10, 0.875, .pi * 2),
            SIMD4<Float>(10, 10, 0.8, 0),
            SIMD4<Float>(4, 0, 0.7, .pi)
        ]
        let cones = Array(repeating: SIMD2<Float>(0.8, 0.95), count: samples.count)
        let sampleBuffer = try Phase2MetalTestSupport.makeBuffer(device: device, values: samples)
        let coneBuffer = try Phase2MetalTestSupport.makeBuffer(device: device, values: cones)
        let resultBuffer = try #require(device.makeBuffer(
            length: MemoryLayout<SIMD4<Float>>.stride * samples.count,
            options: .storageModeShared
        ))
        try Phase2MetalTestSupport.execute(device: device, pipeline: pipeline, width: samples.count) { encoder in
            encoder.setBuffer(sampleBuffer, offset: 0, index: 0)
            encoder.setBuffer(coneBuffer, offset: 0, index: 1)
            encoder.setBuffer(resultBuffer, offset: 0, index: 2)
        }

        let results = resultBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: samples.count)
        for index in samples.indices {
            let sample = samples[index]
            let cone = cones[index]
            #expect(abs(results[index].x - AnalyticLightContract.inverseSquareAttenuation(
                distance: sample.x,
                range: sample.y
            )) < 0.00001)
            #expect(abs(results[index].y - AnalyticLightContract.rangeFade(
                distance: sample.x,
                range: sample.y
            )) < 0.00001)
            #expect(abs(results[index].z - AnalyticLightContract.spotAngularFalloff(
                spotCos: sample.z,
                innerConeCos: cone.y,
                outerConeCos: cone.x
            )) < 0.00001)
            #expect(abs(results[index].w - AnalyticLightContract.whiteLambertianRadiance(
                illuminance: sample.w
            )) < 0.00001)
        }
    }
}
