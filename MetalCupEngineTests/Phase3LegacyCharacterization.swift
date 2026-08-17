import Foundation
import Testing
@testable import MetalCupEngine

/// Regression coverage for the production divergences captured before the
/// Phase 3 repairs. These tests now pin the corrected contract.
struct Phase3LegacyCharacterization {
    @Test
    func localProbeSamplingDoesNotRequireAPrivateAxisFlip() throws {
        let source = try canonicalShaderSource(named: "BasicShaders.metal")
        #expect(!source.contains("float3 localProbeR = float3(R.x, R.y, -R.z)"))
        #expect(!source.contains("float3(worldLookupDirection.x, worldLookupDirection.y, -worldLookupDirection.z)"))
    }

    @Test
    func HDRIConversionUsesTheSameWorldDirectionAsProceduralCapture() throws {
        let source = try canonicalShaderSource(named: "IBLShaders.metal")
        #expect(!source.contains("dir.z = -dir.z"))
    }

    @Test
    func automaticEnvironmentBuildCannotSettleAtInteractiveQuality() throws {
        let renderer = try engineSource(relativePath: "Core/Renderer.swift")
        #expect(!renderer.contains("let rebuildQuality: EnvironmentIBLRebuildQuality = manualRebuild ? .final : .interactive"))
        #expect(renderer.contains("interactiveReady"))
        #expect(renderer.contains("rebuildingFinal"))
    }

    @Test
    func finalEnvironmentIdentityIsNotCoarselyQuantized() throws {
        let source = try engineSource(relativePath: "Game/ECS/EnvironmentRenderState.swift")
        #expect(!source.contains("quantizeStep("))
        #expect(!source.contains("quantizeStep01("))
    }

    @Test
    func productionPBRBindsAndBlendsIncomingIBLRadiance() throws {
        let shader = try canonicalShaderSource(named: "BasicShaders.metal")
        let mesh = try engineSource(relativePath: "Assets/MCMesh.swift")
        #expect(shader.contains("FragmentTextureIndexIncomingIrradiance"))
        #expect(shader.contains("FragmentTextureIndexIncomingPrefiltered"))
        #expect(shader.contains("computeBlendedSplitSumSpecularIBL"))
        #expect(shader.contains("mix(activeRadiance, incomingRadiance"))
        #expect(mesh.contains("GlobalIBLBlendUniform(diffuse: ibl.diffuseBlend, specular: ibl.specularBlend)"))
    }

    @Test
    func continuousEnvironmentPathHasNoPerFrameDebounceGate() throws {
        let renderer = try engineSource(relativePath: "Core/Renderer.swift")
        #expect(!renderer.contains("_environmentIBLEditDebounce"))
        #expect(renderer.contains("shouldScheduleInteractive"))
        #expect(renderer.contains("coalescedRequestCount"))
        #expect(renderer.contains("incomingIrradianceTexture"))
    }

    private func canonicalShaderSource(named name: String) throws -> String {
        let root = try #require(ResourceRegistry.bundledCanonicalShaderRootURL())
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    private func engineSource(relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("MetalCupEngine")
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
