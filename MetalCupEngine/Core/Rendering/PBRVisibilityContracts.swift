/// PBRVisibilityContracts.swift
/// CPU reference math for Phase 2 GGX and SAO invariants exercised against Metal.

import Foundation
import simd

public enum DirectPBRReferenceMath {
    public static let minimumPerceptualRoughness: Float = 0.06
    public static let ndfDenominatorEpsilon: Float = 1e-12

    public static func boundedRoughness(_ roughness: Float) -> Float {
        min(max(roughness, minimumPerceptualRoughness), 1)
    }

    public static func distributionGGX(normalDotHalf: Float,
                                       perceptualRoughness: Float) -> Float {
        let roughness = boundedRoughness(perceptualRoughness)
        let alpha = roughness * roughness
        let alphaSquared = alpha * alpha
        let nDotH = min(max(normalDotHalf, 0), 1)
        let denominatorBase = nDotH * nDotH * (alphaSquared - 1) + 1
        let denominator = Float.pi * denominatorBase * denominatorBase
        return alphaSquared / max(denominator, ndfDenominatorEpsilon)
    }

    public static func dielectricF0() -> SIMD3<Float> {
        SIMD3<Float>(repeating: 0.04)
    }

    public static func f0(baseColor: SIMD3<Float>, metallic: Float) -> SIMD3<Float> {
        simd_mix(dielectricF0(), simd_max(baseColor, .zero), SIMD3<Float>(repeating: min(max(metallic, 0), 1)))
    }

    public static func diffuseWeight(metallic: Float) -> Float {
        1 - min(max(metallic, 0), 1)
    }

    public static func fresnelSchlick(cosine: Float, f0: SIMD3<Float>) -> SIMD3<Float> {
        let oneMinusCosine = 1 - min(max(cosine, 0), 1)
        return f0 + (SIMD3<Float>(repeating: 1) - f0) * Float(Foundation.pow(Double(oneMinusCosine), 5))
    }

    public static func directSpecular(normalDotView: Float,
                                      normalDotLight: Float,
                                      normalDotHalf: Float,
                                      halfDotView: Float,
                                      perceptualRoughness: Float,
                                      f0: SIMD3<Float>) -> SIMD3<Float> {
        let nDotV = max(normalDotView, 0)
        let nDotL = max(normalDotLight, 0)
        let d = distributionGGX(
            normalDotHalf: normalDotHalf,
            perceptualRoughness: perceptualRoughness
        )
        let g = geometrySchlick(normalDot: nDotV, perceptualRoughness: perceptualRoughness)
            * geometrySchlick(normalDot: nDotL, perceptualRoughness: perceptualRoughness)
        let f = fresnelSchlick(cosine: halfDotView, f0: f0)
        return d * g * f / max(4 * nDotV * nDotL, 0.0001)
    }

    public static func halfMaximumAngle(perceptualRoughness: Float) -> Float {
        let roughness = boundedRoughness(perceptualRoughness)
        let alphaSquared = roughness * roughness * roughness * roughness
        let numerator = max(1 - sqrt(2) * alphaSquared, 0)
        let denominator = max(1 - alphaSquared, 0.000001)
        return acos(sqrt(min(max(numerator / denominator, 0), 1)))
    }

    private static func geometrySchlick(normalDot: Float,
                                        perceptualRoughness: Float) -> Float {
        let roughness = boundedRoughness(perceptualRoughness)
        let r = roughness + 1
        let k = r * r / 8
        return normalDot / max(normalDot * (1 - k) + k, 0.000001)
    }
}

public enum SAOVisibilityContract {
    /// SAO targets store visibility: 1 is open and 0 is fully occluded.
    public static func visibility(weightedObscurance: Float,
                                  totalWeight: Float,
                                  intensity: Float,
                                  power: Float) -> Float {
        guard totalWeight > 0 else { return 1 }
        let obscurance = saturate(weightedObscurance / totalWeight)
        let baseVisibility = 1 - saturate(obscurance * max(intensity, 0))
        return Float(Foundation.pow(Double(baseVisibility), Double(max(power, 0.1))))
    }

    public static func weightedBlur(centerVisibility: Float,
                                    sampleVisibilities: [Float],
                                    sampleWeights: [Float],
                                    centerWeight: Float = 1) -> Float {
        var weighted = saturate(centerVisibility) * max(centerWeight, 0)
        var total = max(centerWeight, 0)
        for (visibility, weight) in zip(sampleVisibilities, sampleWeights) where weight > 0 {
            weighted += saturate(visibility) * weight
            total += weight
        }
        return total > 0 ? weighted / total : 1
    }

    private static func saturate(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}
