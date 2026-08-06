import Testing
import Metal
import simd
@testable import MetalCupEngine

struct DirectPBRReferenceTests {
    private let roughnessSamples: [Float] = [0.06, 0.10, 0.20, 0.25, 0.50, 0.80, 1.0]

    @Test
    func normalizedGGXPeakAndWidthRespondMonotonically() {
        var previousPeak: Float = 0
        var previousWidth: Float = 0
        for roughness in roughnessSamples.reversed() {
            let peak = DirectPBRReferenceMath.distributionGGX(
                normalDotHalf: 1,
                perceptualRoughness: roughness
            )
            let width = DirectPBRReferenceMath.halfMaximumAngle(
                perceptualRoughness: roughness
            )
            #expect(peak.isFinite && peak >= 0)
            #expect(peak >= previousPeak)
            #expect(width <= previousWidth || previousWidth == 0)
            previousPeak = peak
            previousWidth = width
        }
        let minimumPeak = DirectPBRReferenceMath.distributionGGX(
            normalDotHalf: 1,
            perceptualRoughness: 0.06
        )
        let quarterPeak = DirectPBRReferenceMath.distributionGGX(
            normalDotHalf: 1,
            perceptualRoughness: 0.25
        )
        #expect(minimumPeak > 24_000)
        #expect(quarterPeak > 80 && quarterPeak < 83)
        #expect(minimumPeak > quarterPeak)
    }

    @Test
    func GGXNDFRemainsNormalizedAndFinite() {
        for roughness in roughnessSamples {
            let integral = adaptiveSimpson(
                lower: 0,
                upper: 1,
                tolerance: 0.00005
            ) { normalDotHalf in
                2 * Float.pi
                    * DirectPBRReferenceMath.distributionGGX(
                        normalDotHalf: normalDotHalf,
                        perceptualRoughness: roughness
                    )
                    * normalDotHalf
            }
            #expect(integral.isFinite)
            #expect(abs(integral - 1) < 0.003)
        }
    }

    @Test
    func metallicAndDielectricReferenceTermsStayIntact() {
        let copperLike = SIMD3<Float>(0.95, 0.64, 0.54)
        #expect(simd_distance(
            DirectPBRReferenceMath.f0(baseColor: copperLike, metallic: 0),
            SIMD3<Float>(repeating: 0.04)
        ) < 0.000001)
        #expect(simd_distance(
            DirectPBRReferenceMath.f0(baseColor: copperLike, metallic: 1),
            copperLike
        ) < 0.000001)
        #expect(DirectPBRReferenceMath.diffuseWeight(metallic: 1) == 0)
        #expect(DirectPBRReferenceMath.diffuseWeight(metallic: 0) == 1)
    }

    @Test
    func directGGXIsFiniteAtGrazingAndBroadensWithRoughness() {
        let f0 = SIMD3<Float>(repeating: 0.04)
        for roughness in roughnessSamples {
            for normalDot: Float in [0.001, 0.01, 0.1, 0.5, 1] {
                let value = DirectPBRReferenceMath.directSpecular(
                    normalDotView: normalDot,
                    normalDotLight: normalDot,
                    normalDotHalf: max(normalDot, 0.001),
                    halfDotView: max(normalDot, 0.001),
                    perceptualRoughness: roughness,
                    f0: f0
                )
                #expect(value.x.isFinite && value.y.isFinite && value.z.isFinite)
                #expect(all(value .>= .zero))
            }
        }
        let offHighlightSmooth = DirectPBRReferenceMath.distributionGGX(
            normalDotHalf: 0.9,
            perceptualRoughness: 0.06
        )
        let offHighlightRough = DirectPBRReferenceMath.distributionGGX(
            normalDotHalf: 0.9,
            perceptualRoughness: 0.5
        )
        #expect(offHighlightRough > offHighlightSmooth)
    }

    @Test
    func CPUReferenceMatchesProductionGPU() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase2MetalTestSupport.canonicalLibrary(device: device)
        let function = try #require(library.makeFunction(name: "phase2_direct_pbr_reference_samples"))
        let pipeline = try device.makeComputePipelineState(function: function)
        var samples: [SIMD4<Float>] = []
        var colors: [SIMD4<Float>] = []
        for roughness in roughnessSamples {
            for normalDotHalf: Float in [0.25, 0.75, 0.95, 1] {
                samples.append(SIMD4<Float>(normalDotHalf, roughness, 1, 0))
                colors.append(SIMD4<Float>(0.95, 0.64, 0.54, 1))
            }
        }
        let sampleBuffer = try Phase2MetalTestSupport.makeBuffer(device: device, values: samples)
        let colorBuffer = try Phase2MetalTestSupport.makeBuffer(device: device, values: colors)
        let resultBuffer = try #require(device.makeBuffer(
            length: MemoryLayout<SIMD4<Float>>.stride * samples.count,
            options: .storageModeShared
        ))
        try Phase2MetalTestSupport.execute(device: device, pipeline: pipeline, width: samples.count) { encoder in
            encoder.setBuffer(sampleBuffer, offset: 0, index: 0)
            encoder.setBuffer(colorBuffer, offset: 0, index: 1)
            encoder.setBuffer(resultBuffer, offset: 0, index: 2)
        }
        let results = resultBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: samples.count)
        for index in samples.indices {
            let expectedD = DirectPBRReferenceMath.distributionGGX(
                normalDotHalf: samples[index].x,
                perceptualRoughness: samples[index].y
            )
            let expectedF0 = DirectPBRReferenceMath.f0(
                baseColor: SIMD3<Float>(colors[index].x, colors[index].y, colors[index].z),
                metallic: samples[index].z
            )
            let tolerance = max(0.0001, expectedD * 0.003)
            #expect(abs(results[index].x - expectedD) < tolerance)
            #expect(simd_distance(
                SIMD3<Float>(results[index].y, results[index].z, results[index].w),
                expectedF0
            ) < 0.00001)
        }
    }

    private func adaptiveSimpson(lower: Float,
                                 upper: Float,
                                 tolerance: Float,
                                 function: (Float) -> Float) -> Float {
        let midpoint = (lower + upper) * 0.5
        let lowerValue = function(lower)
        let midpointValue = function(midpoint)
        let upperValue = function(upper)
        let whole = simpson(
            lower: lower,
            upper: upper,
            lowerValue: lowerValue,
            midpointValue: midpointValue,
            upperValue: upperValue
        )
        return adaptiveSimpson(
            lower: lower,
            upper: upper,
            tolerance: tolerance,
            whole: whole,
            lowerValue: lowerValue,
            midpointValue: midpointValue,
            upperValue: upperValue,
            depth: 24,
            function: function
        )
    }

    private func adaptiveSimpson(lower: Float,
                                 upper: Float,
                                 tolerance: Float,
                                 whole: Float,
                                 lowerValue: Float,
                                 midpointValue: Float,
                                 upperValue: Float,
                                 depth: Int,
                                 function: (Float) -> Float) -> Float {
        let midpoint = (lower + upper) * 0.5
        let lowerMidpoint = (lower + midpoint) * 0.5
        let upperMidpoint = (midpoint + upper) * 0.5
        let lowerMidpointValue = function(lowerMidpoint)
        let upperMidpointValue = function(upperMidpoint)
        let left = simpson(
            lower: lower,
            upper: midpoint,
            lowerValue: lowerValue,
            midpointValue: lowerMidpointValue,
            upperValue: midpointValue
        )
        let right = simpson(
            lower: midpoint,
            upper: upper,
            lowerValue: midpointValue,
            midpointValue: upperMidpointValue,
            upperValue: upperValue
        )
        let delta = left + right - whole
        if depth == 0 || abs(delta) <= 15 * tolerance {
            return left + right + delta / 15
        }
        return adaptiveSimpson(
            lower: lower,
            upper: midpoint,
            tolerance: tolerance * 0.5,
            whole: left,
            lowerValue: lowerValue,
            midpointValue: lowerMidpointValue,
            upperValue: midpointValue,
            depth: depth - 1,
            function: function
        ) + adaptiveSimpson(
            lower: midpoint,
            upper: upper,
            tolerance: tolerance * 0.5,
            whole: right,
            lowerValue: midpointValue,
            midpointValue: upperMidpointValue,
            upperValue: upperValue,
            depth: depth - 1,
            function: function
        )
    }

    private func simpson(lower: Float,
                         upper: Float,
                         lowerValue: Float,
                         midpointValue: Float,
                         upperValue: Float) -> Float {
        (upper - lower) * (lowerValue + 4 * midpointValue + upperValue) / 6
    }
}
