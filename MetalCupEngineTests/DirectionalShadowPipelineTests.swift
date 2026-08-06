import Testing
import simd
@testable import MetalCupEngine

struct DirectionalShadowPipelineTests {
    @Test
    func currentReceiverPathCannotDistinguishCasterFromNoncaster() {
        withKnownIssue("Phase 2A: every directional light samples the single selected caster map") {
            let selectedCasterOwnsMap = true
            let noncasterOwnsMap = false
            #expect(Phase2LegacyCharacterization.appliesDirectionalShadow(lightType: 2) == selectedCasterOwnsMap)
            #expect(Phase2LegacyCharacterization.appliesDirectionalShadow(lightType: 2) == noncasterOwnsMap)
        }
    }

    @Test
    func identityTransformConflictsWithLegacySerializedDirection() {
        withKnownIssue("Phase 2A: legacy serialized directions are ignored even when the transform is default") {
            let intendedRay = simd_normalize(SIMD3<Float>(-0.5, -0.8, -0.3))
            let transformRay = TransformMath.directionalLightDirection(from: TransformMath.identityQuaternion)
            #expect(simd_distance(intendedRay, transformRay) < 0.00001)
        }
    }

    @Test
    func currentSlopeFacingUsesTheOppositeOfSurfaceToLight() {
        withKnownIssue("Phase 2A: receiver slope bias evaluates N dot -L") {
            let normal = SIMD3<Float>(0, 1, 0)
            let surfaceToLight = SIMD3<Float>(0, 1, 0)
            #expect(Phase2LegacyCharacterization.slopeFacing(normal: normal, surfaceToLight: surfaceToLight) == 1)
        }
    }
}
