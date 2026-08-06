import Metal
import Testing
import simd
@testable import MetalCupEngine

struct ReflectionProbeConventionTests {
    @Test
    func globalAndLocalSamplingUseTheSameWorldDirection() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase3MetalTestSupport.library(device: device)
        let marker = simd_normalize(SIMD3<Float>(1, 0.25, -1))
        let cube = try Phase3MetalTestSupport.makeCube(
            device: device,
            size: 64,
            mipmapped: true,
            label: "Phase3.GlobalLocalMarker"
        )
        try Phase3MetalTestSupport.fillDirectionalMarker(
            cube,
            direction: marker,
            radiance: 12,
            cosineThreshold: 0.99
        )
        let worldDirections: [SIMD4<Float>] = [
            SIMD4<Float>(marker, 0),
            SIMD4<Float>(simd_normalize([1, 0.25, 1]), 0),
            SIMD4<Float>(simd_normalize([-1, 0.25, -1]), 0)
        ]
        let global = try Phase3MetalTestSupport.sampleCube(
            device: device,
            library: library,
            texture: cube,
            directionsAndMip: worldDirections
        )
        let local = try Phase3MetalTestSupport.sampleCube(
            device: device,
            library: library,
            texture: cube,
            directionsAndMip: worldDirections
        )
        for index in worldDirections.indices {
            #expect(simd_distance(global[index], local[index]) < 0.000001)
        }
        #expect(global[0].x > 8)
        #expect(global[1].x < 1)
    }

    @Test
    func productionProbeSamplingContainsNoPrivateFlipOrGlobalEnergyMultiplier() throws {
        let root = try #require(ResourceRegistry.bundledCanonicalShaderRootURL())
        let shader = try String(contentsOf: root.appendingPathComponent("BasicShaders.metal"), encoding: .utf8)
        #expect(!shader.contains("float3 localProbeR"))
        #expect(!shader.contains("worldLookupDirection.x, worldLookupDirection.y, -worldLookupDirection.z"))
        #expect(!shader.contains("localProbeIntensity"))
        #expect(shader.contains("localProbeSpecularR = R"))
        #expect(shader.contains("F0,\n            1.0,"))
    }

    @Test
    func probeCaptureUsesTheCanonicalSixFaceMatricesAndMirroredProjection() throws {
        let source = try engineSource(relativePath: "Core/Renderer.swift")
        let manager = try engineSource(relativePath: "Core/ReflectionProbeRuntimeManager.swift")
        #expect(source.contains("private let _views = CubemapConvention.captureViewMatrices"))
        #expect(source.contains("CubemapConvention.captureProjection"))
        #expect(manager.contains("usesMirroredCubemapProjection: true"))
        #expect(manager.contains("return captureViews[face] * translation"))
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
