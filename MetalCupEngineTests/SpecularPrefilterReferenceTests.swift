import Metal
import Testing
import simd
@testable import MetalCupEngine

struct SpecularPrefilterReferenceTests {
    @Test
    func uniformRadianceRemainsUniformAtEveryMipAndDirection() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase3MetalTestSupport.library(device: device)
        let color = SIMD3<Float>(0.35, 1.25, 3.5)
        let source = try Phase3MetalTestSupport.makeCube(
            device: device,
            size: 16,
            mipmapped: true,
            label: "Phase3.PrefilterUniformSource"
        )
        Phase3MetalTestSupport.fillUniform(source, color: SIMD4<Float>(color, 1))
        let prefiltered = try Phase3MetalTestSupport.renderPrefilter(
            device: device,
            library: library,
            source: source,
            size: 16,
            sampleCount: 1024
        )
        let directions: [SIMD3<Float>] = [
            [1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1],
            simd_normalize([1, 1, 1])
        ]
        for mip in 0..<prefiltered.mipmapLevelCount {
            let samples = try Phase3MetalTestSupport.sampleCube(
                device: device,
                library: library,
                texture: prefiltered,
                directionsAndMip: directions.map { SIMD4<Float>($0, Float(mip)) }
            )
            for sample in samples {
                #expect(simd_distance(sample.xyz, color) < 0.025)
                #expect(sample.x.isFinite && sample.y.isFinite && sample.z.isFinite)
                #expect(all(sample.xyz .>= .zero))
            }
        }
    }

    @Test
    func directionalFeaturePeakBroadensWithoutDarknessCollapse() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase3MetalTestSupport.library(device: device)
        let marker = simd_normalize(SIMD3<Float>(1, 0.25, -1))
        let source = try Phase3MetalTestSupport.makeCube(
            device: device,
            size: 64,
            mipmapped: true,
            label: "Phase3.PrefilterMarkerSource"
        )
        try Phase3MetalTestSupport.fillDirectionalMarker(
            source,
            direction: marker,
            radiance: 16,
            cosineThreshold: 0.992
        )
        let prefiltered = try Phase3MetalTestSupport.renderPrefilter(
            device: device,
            library: library,
            source: source,
            size: 32,
            sampleCount: 1024
        )

        let tangent = simd_normalize(simd_cross(marker, SIMD3<Float>(0, 1, 0)))
        let angularOffsets: [Float] = [0, 0.08, 0.16, 0.28, 0.45, 0.7]
        var previousPeak = Float.greatestFiniteMagnitude
        var previousWeightedWidth: Float = 0
        for mip in 0..<prefiltered.mipmapLevelCount {
            let directions = angularOffsets.map { angle in
                simd_normalize(marker * cos(angle) + tangent * sin(angle))
            }
            let samples = try Phase3MetalTestSupport.sampleCube(
                device: device,
                library: library,
                texture: prefiltered,
                directionsAndMip: directions.map { SIMD4<Float>($0, Float(mip)) }
            )
            let peak = samples[0].x
            let total = max(samples.reduce(0) { $0 + max($1.x, 0) }, 0.000001)
            let weightedWidth = zip(angularOffsets, samples).reduce(0) {
                $0 + $1.0 * max($1.1.x, 0) / total
            }
            #expect(peak <= previousPeak + 0.15)
            #expect(weightedWidth + 0.015 >= previousWeightedWidth)
            #expect(samples.allSatisfy { $0.x.isFinite && $0.x >= 0 })
            previousPeak = peak
            previousWeightedWidth = weightedWidth
        }
        #expect(previousPeak > 0)
        #expect(previousWeightedWidth > 0.08)
    }

    @Test
    func generationAndRuntimeUseTheSamePerceptualRoughnessMapping() throws {
        let shaderRoot = try #require(ResourceRegistry.bundledCanonicalShaderRootURL())
        let ibl = try String(contentsOf: shaderRoot.appendingPathComponent("IBLShaders.metal"), encoding: .utf8)
        let pbr = try String(contentsOf: shaderRoot.appendingPathComponent("BasicShaders.metal"), encoding: .utf8)
        let renderer = try engineSource(relativePath: "Core/Renderer.swift")
        #expect(renderer.contains("let roughness = Float(mip) / Float(max(mipCount - 1, 1))"))
        #expect(pbr.contains("roughness * maxMip"))
        #expect(!pbr.contains("iblSpecularLodExponent"))
        #expect(!pbr.contains("iblSpecularLodBias"))
        #expect(!pbr.contains("iblSpecularGrazingLodBias"))
        #expect(ibl.contains("PBR::importanceSampleGGX"))
        #expect(ibl.contains("float pdf = max((D * NoH) / (4.0 * VoH), 1e-5)"))
    }

    private func engineSource(relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent("MetalCupEngine").appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
