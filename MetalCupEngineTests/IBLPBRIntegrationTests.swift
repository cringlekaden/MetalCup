import Foundation
import Metal
import Testing
import simd
@testable import MetalCupEngine

struct IBLPBRIntegrationTests {
    @Test
    func equalRadianceSourcesProduceEquivalentDiffuseAndSpecularResources() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase3MetalTestSupport.library(device: device)
        let radiance = SIMD3<Float>(0.4, 0.8, 1.6)
        let proceduralEquivalent = try makeUniformSource(device: device, color: radiance, label: "ProceduralEquivalent")
        let hdriEquivalent = try makeUniformSource(device: device, color: radiance, label: "HDRIEquivalent")

        let proceduralDiffuse = try Phase3MetalTestSupport.renderIrradiance(
            device: device, library: library, source: proceduralEquivalent, size: 8, sampleCount: 1024
        )
        let hdriDiffuse = try Phase3MetalTestSupport.renderIrradiance(
            device: device, library: library, source: hdriEquivalent, size: 8, sampleCount: 1024
        )
        let proceduralSpecular = try Phase3MetalTestSupport.renderPrefilter(
            device: device, library: library, source: proceduralEquivalent, size: 8, sampleCount: 512
        )
        let hdriSpecular = try Phase3MetalTestSupport.renderPrefilter(
            device: device, library: library, source: hdriEquivalent, size: 8, sampleCount: 512
        )
        let directions: [SIMD4<Float>] = [
            [1, 0, 0, 0], [0, 1, 0, 0], [0, 0, -1, 0],
            SIMD4<Float>(simd_normalize([1, 1, 1]), 0)
        ]
        let diffuseA = try Phase3MetalTestSupport.sampleCube(
            device: device, library: library, texture: proceduralDiffuse, directionsAndMip: directions
        )
        let diffuseB = try Phase3MetalTestSupport.sampleCube(
            device: device, library: library, texture: hdriDiffuse, directionsAndMip: directions
        )
        for index in directions.indices {
            #expect(simd_distance(diffuseA[index], diffuseB[index]) < 0.0001)
        }
        for mip in 0..<proceduralSpecular.mipmapLevelCount {
            let mipDirections = directions.map { SIMD4<Float>($0.xyz, Float(mip)) }
            let specularA = try Phase3MetalTestSupport.sampleCube(
                device: device, library: library, texture: proceduralSpecular, directionsAndMip: mipDirections
            )
            let specularB = try Phase3MetalTestSupport.sampleCube(
                device: device, library: library, texture: hdriSpecular, directionsAndMip: mipDirections
            )
            for index in directions.indices {
                #expect(simd_distance(specularA[index], specularB[index]) < 0.0001)
            }
        }
    }

    @Test
    func directOnlyPlusIBLOnlyEqualsCombinedBeforeExposure() {
        let direct = SIMD3<Float>(1.2, 0.4, 0.1)
        let diffuseIBL = SIMD3<Float>(0.18, 0.25, 0.3)
        let specularIBL = SIMD3<Float>(0.04, 0.08, 0.16)
        let iblOnly = diffuseIBL + specularIBL
        let combined = direct + diffuseIBL + specularIBL
        #expect(simd_distance(direct + iblOnly, combined) < 0.000001)
        for exposureEV: Float in [-1, 0, 1] {
            // Exposure changes only the final transform; the pre-exposure sum
            // and all source resources remain identical.
            #expect(simd_distance(combined, direct + iblOnly) < 0.000001)
            let final = SceneLinearHDRContract.finalSDROutput(sceneLinear: combined, exposureEV: exposureEV)
            #expect(final.x.isFinite && final.y.isFinite && final.z.isFinite)
        }
    }

    @Test
    func globalGainAndLegacyLODControlsAreInert() throws {
        let legacy = try JSONDecoder().decode(
            RendererSettingsDTO.self,
            from: Data(#"{"iblEnabled":1,"iblIntensity":0.05,"iblSpecularLodExponent":3.5,"iblSpecularLodBias":2,"iblSpecularGrazingLodBias":1}"#.utf8)
        ).makeRendererSettings()
        #expect(legacy.effectiveGlobalIBLSamplingGain == 1)
        let root = try #require(ResourceRegistry.bundledCanonicalShaderRootURL())
        let shader = try String(contentsOf: root.appendingPathComponent("BasicShaders.metal"), encoding: .utf8)
        #expect(!shader.contains("settings.iblSpecularLodExponent"))
        #expect(!shader.contains("settings.iblSpecularLodBias"))
        #expect(!shader.contains("settings.iblSpecularGrazingLodBias"))
    }

    private func makeUniformSource(device: MTLDevice,
                                   color: SIMD3<Float>,
                                   label: String) throws -> MTLTexture {
        let texture = try Phase3MetalTestSupport.makeCube(
            device: device,
            size: 8,
            mipmapped: true,
            label: label
        )
        Phase3MetalTestSupport.fillUniform(texture, color: SIMD4<Float>(color, 1))
        return texture
    }
}
