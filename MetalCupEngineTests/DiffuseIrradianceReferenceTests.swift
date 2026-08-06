import Metal
import Testing
import simd
@testable import MetalCupEngine

struct DiffuseIrradianceReferenceTests {
    private let normals: [SIMD3<Float>] = [
        [1, 0, 0], [-1, 0, 0], [0, 1, 0],
        [0, -1, 0], [0, 0, 1], [0, 0, -1],
        simd_normalize([1, 1, 1])
    ]

    @Test
    func uniformWhiteAndColoredRadianceProducePiTimesRadiance() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase3MetalTestSupport.library(device: device)
        for color in [SIMD3<Float>(repeating: 1), SIMD3<Float>(0.25, 0.5, 2)] {
            let source = try Phase3MetalTestSupport.makeCube(
                device: device,
                size: 16,
                mipmapped: true,
                label: "Phase3.UniformRadiance"
            )
            Phase3MetalTestSupport.fillUniform(source, color: SIMD4<Float>(color, 1))
            let irradiance = try Phase3MetalTestSupport.renderIrradiance(
                device: device,
                library: library,
                source: source,
                size: 12,
                sampleCount: 2048
            )
            let samples = try Phase3MetalTestSupport.sampleCube(
                device: device,
                library: library,
                texture: irradiance,
                directionsAndMip: normals.map { SIMD4<Float>($0, 0) }
            )
            let expected = color * Float.pi
            for sample in samples {
                #expect(simd_distance(sample.xyz, expected) < 0.035)
                #expect(all(sample.xyz .>= .zero))
                #expect(sample.x.isFinite && sample.y.isFinite && sample.z.isFinite)
            }
        }
    }

    @Test
    func uniformEnvironmentReturnsLambertianAlbedo() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase3MetalTestSupport.library(device: device)
        let source = try Phase3MetalTestSupport.makeCube(
            device: device,
            size: 8,
            mipmapped: true,
            label: "Phase3.LambertianUniform"
        )
        Phase3MetalTestSupport.fillUniform(source, color: [1, 1, 1, 1])
        let irradiance = try Phase3MetalTestSupport.renderIrradiance(
            device: device,
            library: library,
            source: source,
            size: 8,
            sampleCount: 2048
        )
        let sample = try #require(Phase3MetalTestSupport.sampleCube(
            device: device,
            library: library,
            texture: irradiance,
            directionsAndMip: [[0, 1, 0, 0]]
        ).first)
        let white = sample.xyz / Float.pi
        let gray = sample.xyz * 0.18 / Float.pi
        #expect(simd_distance(white, SIMD3<Float>(repeating: 1)) < 0.012)
        #expect(simd_distance(gray, SIMD3<Float>(repeating: 0.18)) < 0.003)
    }

    @Test
    func directionalRadianceRetainsHemisphereOrientation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase3MetalTestSupport.library(device: device)
        let source = try Phase3MetalTestSupport.makeCube(
            device: device,
            size: 32,
            mipmapped: true,
            label: "Phase3.DirectionalRadiance"
        )
        try Phase3MetalTestSupport.fillDirectionalMarker(
            source,
            direction: [1, 0.2, -0.4],
            radiance: 16,
            cosineThreshold: 0.97
        )
        let irradiance = try Phase3MetalTestSupport.renderIrradiance(
            device: device,
            library: library,
            source: source,
            size: 12,
            sampleCount: 4096
        )
        let toward = simd_normalize(SIMD3<Float>(1, 0.2, -0.4))
        let samples = try Phase3MetalTestSupport.sampleCube(
            device: device,
            library: library,
            texture: irradiance,
            directionsAndMip: [SIMD4<Float>(toward, 0), SIMD4<Float>(-toward, 0)]
        )
        #expect(samples[0].x > samples[1].x * 8)
        #expect(samples[0].x > 0)
        #expect(samples[1].x >= 0)
    }
}
