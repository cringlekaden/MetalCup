import Foundation
import Testing
@testable import MetalCupEngine

/// Phase 3 starts by pinning the three production divergences found by the
/// read-only trace. These expectations intentionally describe the corrected
/// contract and are recorded as known issues until the corresponding repair
/// commits land.
struct Phase3LegacyCharacterization {
    @Test
    func localProbeSamplingDoesNotRequireAPrivateAxisFlip() throws {
        let source = try canonicalShaderSource(named: "BasicShaders.metal")
        withKnownIssue("Legacy reflection probes compensate a Z-reflected capture in PBR sampling.") {
            #expect(!source.contains("float3 localProbeR = float3(R.x, R.y, -R.z)"))
            #expect(!source.contains("float3(worldLookupDirection.x, worldLookupDirection.y, -worldLookupDirection.z)"))
        }
    }

    @Test
    func HDRIConversionUsesTheSameWorldDirectionAsProceduralCapture() throws {
        let source = try canonicalShaderSource(named: "IBLShaders.metal")
        withKnownIssue("Legacy HDRI conversion applies a path-specific Z flip.") {
            #expect(!source.contains("dir.z = -dir.z"))
        }
    }

    @Test
    func automaticEnvironmentBuildCannotSettleAtInteractiveQuality() throws {
        let renderer = try engineSource(relativePath: "Core/Renderer.swift")
        withKnownIssue("The Environment path marks a matching interactive result clean without scheduling final quality.") {
            #expect(!renderer.contains("let rebuildQuality: EnvironmentIBLRebuildQuality = manualRebuild ? .final : .interactive"))
            #expect(renderer.contains("interactiveReady"))
            #expect(renderer.contains("rebuildingFinal"))
        }
    }

    @Test
    func finalEnvironmentIdentityIsNotCoarselyQuantized() throws {
        let source = try engineSource(relativePath: "Game/ECS/EnvironmentRenderState.swift")
        withKnownIssue("The current signature rounds time, weather, atmosphere, and celestial source fields.") {
            #expect(!source.contains("quantizeStep("))
            #expect(!source.contains("quantizeStep01("))
        }
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
