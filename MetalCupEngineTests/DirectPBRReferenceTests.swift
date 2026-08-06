import Testing
@testable import MetalCupEngine

struct DirectPBRReferenceTests {
    @Test
    func currentLowRoughnessGGXPeakCollapses() {
        withKnownIssue("Phase 2A: the denominator floor dominates supported low-roughness GGX peaks") {
            let minimumPeak = Phase2LegacyCharacterization.ggxDistribution(nDotH: 1, roughness: 0.06)
            let quarterRoughnessPeak = Phase2LegacyCharacterization.ggxDistribution(nDotH: 1, roughness: 0.25)
            #expect(minimumPeak > quarterRoughnessPeak)
        }
    }
}
