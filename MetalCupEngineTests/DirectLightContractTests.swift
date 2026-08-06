import Testing
@testable import MetalCupEngine

struct DirectLightContractTests {
    @Test
    func currentPointAndSpotRangeCurveSuppressesTheWholeRange() {
        withKnownIssue("Phase 2A: the quadratic range term compounds inverse square before the late cutoff region") {
            let distance: Float = 2
            let range: Float = 10
            let inverseSquare: Float = 1 / (distance * distance)
            #expect(abs(Phase2LegacyCharacterization.rangeAttenuation(distance: distance, range: range) - inverseSquare) < 0.000001)
        }
    }
}
