import Metal
import Testing
import simd
@testable import MetalCupEngine

struct BRDFLUTReferenceTests {
    private let ndotVValues: [Float] = [0.02, 0.05, 0.10, 0.25, 0.50, 0.80, 1.00]
    private let roughnessValues: [Float] = [0.06, 0.10, 0.20, 0.25, 0.50, 0.80, 1.00]

    @Test
    func productionGPUAgreesWithIndependentCPUGrid() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase3MetalTestSupport.library(device: device)
        let inputs = ndotVValues.flatMap { ndotV in
            roughnessValues.map { SIMD2<Float>(ndotV, $0) }
        }
        let gpu: [SIMD2<Float>] = try Phase3MetalTestSupport.compute(
            device: device,
            library: library,
            functionName: "phase3_brdf_lut_reference_samples",
            inputs: inputs,
            outputType: SIMD2<Float>.self
        )
        for index in inputs.indices {
            let cpu = integrateBRDF(
                ndotV: inputs[index].x,
                roughness: inputs[index].y,
                sampleCount: 2048
            )
            #expect(simd_distance(gpu[index], cpu) < 0.0035)
            #expect(gpu[index].x.isFinite && gpu[index].y.isFinite)
            #expect(gpu[index].x >= 0 && gpu[index].y >= 0)
            #expect(gpu[index].x <= 1.05 && gpu[index].y <= 1.05)
        }
    }

    @Test
    func channelsAreFresnelScaleAndBiasForDielectricsAndMetals() {
        for ndotV in ndotVValues {
            for roughness in roughnessValues {
                let lut = integrateBRDF(ndotV: ndotV, roughness: roughness, sampleCount: 2048)
                let dielectric = SIMD3<Float>(repeating: 0.04 * lut.x + lut.y)
                let copperF0 = SIMD3<Float>(0.95, 0.64, 0.54)
                let metal = copperF0 * lut.x + SIMD3<Float>(repeating: lut.y)
                #expect(all(dielectric .>= .zero))
                #expect(all(metal .>= .zero))
                #expect(dielectric.x.isFinite && metal.x.isFinite && metal.y.isFinite && metal.z.isFinite)
                // Split-sum changes only the specular term: the Phase 2 material
                // contract keeps metal diffuse at zero and dielectric F0 at 0.04.
                #expect(DirectPBRReferenceMath.diffuseWeight(metallic: 1) == 0)
                #expect(DirectPBRReferenceMath.f0(baseColor: copperF0, metallic: 1) == copperF0)
                #expect(DirectPBRReferenceMath.f0(baseColor: copperF0, metallic: 0) == SIMD3<Float>(repeating: 0.04))
            }
        }
    }

    @Test
    func LUTFragmentUsesTheSameProductionIntegratorAndSampleCount() throws {
        let root = try #require(ResourceRegistry.bundledCanonicalShaderRootURL())
        let source = try String(contentsOf: root.appendingPathComponent("IBLShaders.metal"), encoding: .utf8)
        #expect(source.contains("const uint SAMPLE_COUNT = 2048"))
        #expect(source.contains("return PBR::integrateBRDF(NdotV, roughness, SAMPLE_COUNT)"))
        #expect(source.contains("results[index] = PBR::integrateBRDF"))
    }

    private func integrateBRDF(ndotV: Float, roughness: Float, sampleCount: UInt32) -> SIMD2<Float> {
        let view = SIMD3<Float>(sqrt(max(1 - ndotV * ndotV, 0)), 0, ndotV)
        var result = SIMD2<Float>.zero
        for sampleIndex in 0..<sampleCount {
            let xi = SIMD2<Float>(
                Float(sampleIndex) / Float(sampleCount),
                radicalInverse(sampleIndex)
            )
            let half = importanceSampleGGX(xi: xi, roughness: roughness)
            let light = simd_normalize(2 * simd_dot(view, half) * half - view)
            let ndotL = max(light.z, 0)
            let ndotH = max(half.z, 0)
            let vdotH = max(simd_dot(view, half), 0.0001)
            guard ndotL > 0 else { continue }
            let geometry = geometrySchlickIBL(ndot: ndotV, roughness: roughness)
                * geometrySchlickIBL(ndot: ndotL, roughness: roughness)
            let visibility = geometry * vdotH / max(ndotH * ndotV, 0.00001)
            let fresnelComplement = pow(1 - vdotH, 5)
            result.x += (1 - fresnelComplement) * visibility
            result.y += fresnelComplement * visibility
        }
        return result / Float(sampleCount)
    }

    private func importanceSampleGGX(xi: SIMD2<Float>, roughness: Float) -> SIMD3<Float> {
        let alpha = roughness * roughness
        let phi = 2 * Float.pi * xi.x
        let cosine = sqrt((1 - xi.y) / (1 + (alpha * alpha - 1) * xi.y))
        let sine = sqrt(max(1 - cosine * cosine, 0))
        // Production constructs a stable tangent basis even for +Z. Express
        // that same world-space hemisphere explicitly while keeping the CPU
        // integration independent of the Metal implementation.
        return simd_normalize(SIMD3<Float>(sin(phi) * sine, -cos(phi) * sine, cosine))
    }

    private func geometrySchlickIBL(ndot: Float, roughness: Float) -> Float {
        let k = roughness * roughness * 0.5
        return ndot / (ndot * (1 - k) + k)
    }

    private func radicalInverse(_ input: UInt32) -> Float {
        var bits = input
        bits = (bits << 16) | (bits >> 16)
        bits = ((bits & 0x5555_5555) << 1) | ((bits & 0xAAAA_AAAA) >> 1)
        bits = ((bits & 0x3333_3333) << 2) | ((bits & 0xCCCC_CCCC) >> 2)
        bits = ((bits & 0x0F0F_0F0F) << 4) | ((bits & 0xF0F0_F0F0) >> 4)
        bits = ((bits & 0x00FF_00FF) << 8) | ((bits & 0xFF00_FF00) >> 8)
        return Float(bits) * 2.3283064365386963e-10
    }
}
