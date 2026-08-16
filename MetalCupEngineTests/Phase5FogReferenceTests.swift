import Foundation
import Metal
import Testing
import simd
@testable import MetalCupEngine

@Suite("Phase 5 legacy fog characterization")
struct Phase5LegacyFogCharacterizationTests {
    @Test
    func legacyBackgroundAppliesTwoExtraDirectionalCoverageCurves() {
        let opticalDepth: Float = 1
        let physicalCoverage = 1 - exp(-opticalDepth)
        let horizonWeight: Float = 1
        let zenithWeight: Float = 0
        let directionalCoverage = min(
            physicalCoverage * mix(0.18, 1, horizonWeight) * mix(1, 0.55, zenithWeight),
            mix(0.35, 0.94, horizonWeight)
        )
        let secondSkyCoverage = directionalCoverage
            * mix(0.28, 0.86, horizonWeight)
            * mix(1, 0.42, zenithWeight)

        #expect(physicalCoverage > 0.63 && physicalCoverage < 0.64)
        #expect(abs(directionalCoverage - physicalCoverage) < 0.000001)
        #expect(secondSkyCoverage < physicalCoverage)
    }

    @Test
    func legacyBackgroundUsesViewDependentVirtualDistance() {
        let maxAerialDistance: Float = 2_600
        let zenithDistance = mix(maxAerialDistance * 0.22, maxAerialDistance, 0)
        let horizonDistance = mix(maxAerialDistance * 0.22, maxAerialDistance, 1)
        #expect(zenithDistance == 572)
        #expect(horizonDistance == 2_600)
        #expect(horizonDistance / zenithDistance > 4.5)
    }

    @Test
    func legacyFogCombinesHeightAndIndependentDistanceDensity() {
        let segmentLength: Float = 50
        let heightDensity: Float = 0.03
        let distanceDensity: Float = 0.02
        let oldOpticalDepth = heightDensity * segmentLength + distanceDensity * segmentLength
        #expect(abs(oldOpticalDepth - 2.5) < 0.000001)
        #expect(oldOpticalDepth > heightDensity * segmentLength)
    }

    private func mix(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }
}
