import Metal
import Testing
import simd
@testable import MetalCupEngine

struct IBLOrientationGPUTests {
    @Test
    func continuousDirectionCubeReturnsWorldDirectionAtFacesCornersAndSeams() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase3MetalTestSupport.library(device: device)
        let cube = try Phase3MetalTestSupport.renderDiagnosticCube(
            device: device,
            library: library,
            fragmentName: "fragment_cubemap_direction_reference",
            size: 128
        )
        let directions: [SIMD3<Float>] = [
            [1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1],
            simd_normalize([1, 1, 1]), simd_normalize([-1, 1, 1]),
            simd_normalize([1, -1, -1]), simd_normalize([-1, -1, -1]),
            simd_normalize([1.0001, 0.31, 1]), simd_normalize([1, 0.31, 1.0001])
        ]
        let samples = try Phase3MetalTestSupport.sampleCube(
            device: device,
            library: library,
            texture: cube,
            directionsAndMip: directions.map { SIMD4<Float>($0, 0) }
        )
        for index in directions.indices {
            let expected = directions[index] * 0.5 + 0.5
            #expect(simd_distance(samples[index].xyz, expected) < 0.025)
            #expect(samples[index].x.isFinite && samples[index].y.isFinite && samples[index].z.isFinite)
        }
        #expect(simd_distance(samples[samples.count - 2].xyz, samples[samples.count - 1].xyz) < 0.01)
    }

    @Test
    func identityDiagnosticDistinguishesFacesAndWithinFaceOrientation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase3MetalTestSupport.library(device: device)
        let cube = try Phase3MetalTestSupport.renderDiagnosticCube(
            device: device,
            library: library,
            fragmentName: "fragment_cubemap_orientation_diagnostic",
            size: 128
        )
        let faceCenters = CubemapConvention.faceBases.map { SIMD4<Float>($0.direction, 0) }
        let samples = try Phase3MetalTestSupport.sampleCube(
            device: device,
            library: library,
            texture: cube,
            directionsAndMip: faceCenters
        )
        // +Y and -Y centers avoid the diagnostic equator stripe and retain their
        // green/magenta identity colors.
        #expect(samples[2].y > 0.75 && samples[2].x < 0.1 && samples[2].z < 0.1)
        #expect(samples[3].x > 0.75 && samples[3].z > 0.75 && samples[3].y < 0.1)

        let positiveXUp = CubemapConvention.direction(face: .positiveX, uv: [0.5, 0.08])
        let positiveXDown = CubemapConvention.direction(face: .positiveX, uv: [0.5, 0.82])
        let verticalSamples = try Phase3MetalTestSupport.sampleCube(
            device: device,
            library: library,
            texture: cube,
            directionsAndMip: [SIMD4<Float>(positiveXUp, 0), SIMD4<Float>(positiveXDown, 0)]
        )
        #expect(verticalSamples[0].x > verticalSamples[1].x)
        #expect(verticalSamples[0].y > verticalSamples[1].y)
        #expect(verticalSamples[0].z > verticalSamples[1].z)
    }

    @Test
    func reflectionDirectionUsesEstablishedSurfaceToCameraConvention() {
        let normal = simd_normalize(SIMD3<Float>(0.2, 1, -0.1))
        let surfaceToCamera = simd_normalize(SIMD3<Float>(0.4, 0.8, 0.3))
        let incident = -surfaceToCamera
        let reflected = incident - 2 * simd_dot(incident, normal) * normal
        #expect(abs(simd_length(reflected) - 1) < 0.00001)
        #expect(abs(simd_dot(reflected, normal) - simd_dot(surfaceToCamera, normal)) < 0.00001)
    }
}
