import simd

/// Test-only mirrors of the Phase 2A defects. The characterization commit uses
/// these to prove each proposed invariant is currently violated; production code
/// does not call them. The Phase 2B repair commits replace these mirrors with
/// assertions against the production CPU/GPU contracts.
enum Phase2LegacyCharacterization {
    static func appliesDirectionalShadow(lightType: UInt32) -> Bool {
        lightType == 2
    }

    static func slopeFacing(normal: SIMD3<Float>, surfaceToLight: SIMD3<Float>) -> Float {
        max(0, min(1, simd_dot(normal, -surfaceToLight)))
    }

    static func rangeAttenuation(distance: Float, range: Float) -> Float {
        var attenuation = 1 / max(distance * distance, 0.0001)
        if range > 0 {
            let rangeAttenuation = max(0, min(1, 1 - distance / range))
            attenuation *= rangeAttenuation * rangeAttenuation
        }
        return attenuation
    }

    static func ggxDistribution(nDotH: Float, roughness: Float) -> Float {
        let alpha = roughness * roughness
        let alphaSquared = alpha * alpha
        let denominatorBase = nDotH * nDotH * (alphaSquared - 1) + 1
        return alphaSquared / max(Float.pi * denominatorBase * denominatorBase, 0.00001)
    }

    static func saoVisibility(obscurance: Float,
                              totalWeight: Float,
                              intensity: Float,
                              power: Float) -> Float {
        let normalized = totalWeight > 0 ? obscurance / totalWeight : 0
        let scaled = max(0, min(1, normalized * intensity))
        return pow(max(scaled, 0.0001), power)
    }
}
