import Metal
import Testing
import simd
@testable import MetalCupEngine

struct CubemapConventionTests {
    @Test
    func faceCentersDirectionsAndUpVectorsAreAuthoritative() {
        let expectedDirections: [SIMD3<Float>] = [
            [1, 0, 0], [-1, 0, 0], [0, 1, 0],
            [0, -1, 0], [0, 0, 1], [0, 0, -1]
        ]
        let expectedUp: [SIMD3<Float>] = [
            [0, 1, 0], [0, 1, 0], [0, 0, -1],
            [0, 0, 1], [0, 1, 0], [0, 1, 0]
        ]
        #expect(CubemapConvention.faceBases.count == 6)
        for index in 0..<6 {
            #expect(CubemapConvention.faceBases[index].direction == expectedDirections[index])
            #expect(CubemapConvention.faceBases[index].up == expectedUp[index])
            #expect(CubemapConvention.direction(
                face: CubemapConvention.faceBases[index].face,
                uv: [0.5, 0.5]
            ) == expectedDirections[index])
        }
    }

    @Test
    func captureMatricesProjectCanonicalDirectionsBackToTheirFaceUVs() {
        let projection = CubemapConvention.captureProjection(nearZ: 0.1, farZ: 10)
        let samples: [SIMD2<Float>] = [
            [0.5, 0.5], [0.15, 0.2], [0.85, 0.2],
            [0.15, 0.8], [0.85, 0.8]
        ]
        for basis in CubemapConvention.faceBases {
            let view = CubemapConvention.captureViewMatrices[basis.face.rawValue]
            for uv in samples {
                let direction = CubemapConvention.direction(face: basis.face, uv: uv)
                let clip = projection * view * SIMD4<Float>(direction * 2, 1)
                let ndc = SIMD2<Float>(clip.x, clip.y) / clip.w
                let projectedUV = SIMD2<Float>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5)
                #expect(simd_distance(projectedUV, uv) < 0.00001)
            }
        }
    }

    @Test
    func equirectangularCardinalDirectionsHaveOneStableMapping() {
        let references: [(SIMD3<Float>, SIMD2<Float>)] = [
            ([0, 0, 1], [0.5, 0.5]),
            ([1, 0, 0], [0.75, 0.5]),
            ([-1, 0, 0], [0.25, 0.5]),
            ([0, 1, 0], [0.5, 0]),
            ([0, -1, 0], [0.5, 1])
        ]
        for (direction, uv) in references {
            #expect(simd_distance(CubemapConvention.equirectangularUV(worldDirection: direction), uv) < 0.00001)
        }
        let negativeZ = CubemapConvention.equirectangularUV(worldDirection: [0, 0, -1])
        #expect(abs(negativeZ.y - 0.5) < 0.00001)
        #expect(negativeZ.x == 0 || abs(negativeZ.x - 1) < 0.00001)
    }

    @Test
    func productionGPUFaceUVAndEquirectangularHelpersMatchCPU() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase3MetalTestSupport.library(device: device)
        let uvSamples: [SIMD2<Float>] = [[0.5, 0.5], [0.1, 0.1], [0.9, 0.1], [0.1, 0.9], [0.9, 0.9]]
        let inputs: [SIMD4<Float>] = CubemapConvention.Face.allCases.flatMap { face in
            uvSamples.map { SIMD4<Float>(Float(face.rawValue), $0.x, $0.y, 0) }
        }
        let gpuDirections: [SIMD4<Float>] = try Phase3MetalTestSupport.compute(
            device: device,
            library: library,
            functionName: "phase3_cubemap_direction_samples",
            inputs: inputs,
            outputType: SIMD4<Float>.self
        )
        for index in inputs.indices {
            let face = try #require(CubemapConvention.Face(rawValue: Int(inputs[index].x)))
            let expected = CubemapConvention.direction(face: face, uv: inputs[index].yz)
            #expect(simd_distance(gpuDirections[index].xyz, expected) < 0.00001)
        }

        let cardinalDirections: [SIMD4<Float>] = [
            [1, 0, 0, 0], [-1, 0, 0, 0], [0, 1, 0, 0],
            [0, -1, 0, 0], [0, 0, 1, 0], [0, 0, -1, 0]
        ]
        let gpuUV: [SIMD4<Float>] = try Phase3MetalTestSupport.compute(
            device: device,
            library: library,
            functionName: "phase3_equirectangular_uv_samples",
            inputs: cardinalDirections,
            outputType: SIMD4<Float>.self
        )
        for index in cardinalDirections.indices {
            let expected = CubemapConvention.equirectangularUV(worldDirection: cardinalDirections[index].xyz)
            let wrappedDelta = min(abs(gpuUV[index].x - expected.x), 1 - abs(gpuUV[index].x - expected.x))
            #expect(wrappedDelta < 0.00001)
            #expect(abs(gpuUV[index].y - expected.y) < 0.00001)
        }
    }
}
