import Testing
@testable import MetalCupEngine

struct SAOVisibilityTests {
    @Test
    func currentNoSampleCaseIsNotFullyVisible() {
        withKnownIssue("Phase 2A: no valid SAO samples resolve near zero visibility") {
            #expect(Phase2LegacyCharacterization.saoVisibility(
                obscurance: 0,
                totalWeight: 0,
                intensity: 1,
                power: 1
            ) == 1)
        }
    }

    @Test
    func currentIntensityMovesVisibilityInTheWrongDirection() {
        withKnownIssue("Phase 2A: increasing SAO intensity increases stored visibility") {
            let low = Phase2LegacyCharacterization.saoVisibility(
                obscurance: 0.25,
                totalWeight: 1,
                intensity: 0.5,
                power: 1
            )
            let high = Phase2LegacyCharacterization.saoVisibility(
                obscurance: 0.25,
                totalWeight: 1,
                intensity: 2,
                power: 1
            )
            #expect(high <= low)
        }
    }
}
