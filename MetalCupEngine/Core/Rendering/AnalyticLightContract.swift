/// AnalyticLightContract.swift
/// Testable reference math and documentation for MetalCup's Phase 2 analytic-light contract.

import Foundation

public enum AnalyticLightContract {
    /// Directional `brightness` is scene-relative incident illuminance. Point and
    /// spot `brightness` are the numerator of inverse-square irradiance. These
    /// quantities are exposure-relative; they are not calibrated lux or candela.
    public static let directionalReferenceIlluminance: Float = .pi
    public static let rangeCutoffStartFraction: Float = 0.8
    public static let minimumDistanceSquared: Float = 0.0001

    /// A finite range is only a late, smooth support cutoff. The inverse-square
    /// response is unmodified through 80% of the range. A nonpositive range has
    /// infinite support, matching the established serialized convention.
    public static func rangeFade(distance: Float, range: Float) -> Float {
        guard range > 0 else { return 1 }
        let start = rangeCutoffStartFraction * range
        let t = saturate((distance - start) / max(range - start, 0.000001))
        return 1 - t * t * (3 - 2 * t)
    }

    public static func inverseSquareAttenuation(distance: Float, range: Float) -> Float {
        let inverseSquare = 1 / max(distance * distance, minimumDistanceSquared)
        return inverseSquare * rangeFade(distance: distance, range: range)
    }

    /// Spot angular falloff remains separate from distance/range attenuation.
    /// The squared smoothstep is retained from the established production look.
    public static func spotAngularFalloff(spotCos: Float,
                                          innerConeCos: Float,
                                          outerConeCos: Float) -> Float {
        let width = innerConeCos - outerConeCos
        let smooth: Float
        if width > 0.000001 {
            let t = saturate((spotCos - outerConeCos) / width)
            smooth = t * t * (3 - 2 * t)
        } else {
            smooth = spotCos >= innerConeCos ? 1 : 0
        }
        return smooth * smooth
    }

    public static func whiteLambertianRadiance(illuminance: Float,
                                                normalDotLight: Float = 1) -> Float {
        max(illuminance, 0) * saturate(normalDotLight) / Float.pi
    }

    private static func saturate(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}
