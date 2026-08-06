/// SceneLinearHDRContract.swift
/// Defines the testable reference math for MetalCup's scene-linear HDR output contract.

import Foundation
import simd

public enum SceneLinearHDRContract {
    public static let workingRGBDescription = "linear sRGB/Rec.709, D65"
    public static let filmicWhitePoint: Float = 16.0

    // Phase 2 analytic-light convention:
    // - Directional LightData.brightness is scene-relative incident illuminance.
    //   A value of pi produces radiance 1 from a white Lambertian at NdotL=1,
    //   before dielectric Fresnel redistribution.
    // - Point/spot brightness is the numerator of inverse-square irradiance.
    // - Range is only a smooth cutoff over the final 20% of finite support.
    // - LightData diffuse/specular intensity fields remain serialized advanced
    //   compatibility controls. Normal authored values are both 1.
    // These units are exposure-relative, not calibrated lux/candela. The accepted
    // dark procedural-sky observation is deferred to Phase 4 without compensation.

    public static func exposureMultiplier(forEV exposureEV: Float) -> Float {
        Float(Foundation.pow(2.0, Double(exposureEV)))
    }

    public static func exposureEV(fromLegacyMultiplier multiplier: Float,
                                  epsilon: Float = 0.0001) -> Float {
        Float(Foundation.log2(Double(max(multiplier, epsilon))))
    }

    public static func metalCupFilmicV1(_ sceneLinear: SIMD3<Float>) -> SIMD3<Float> {
        let positive = simd_max(sceneLinear, .zero)
        var base = uncharted2(positive)
        let whiteScale = 1.0 / uncharted2(filmicWhitePoint)
        base *= whiteScale

        let luminanceWeights = SIMD3<Float>(0.2126, 0.7152, 0.0722)
        let inputLuminance = simd_dot(positive, luminanceWeights)
        let outputLuminance = simd_dot(simd_max(base, .zero), luminanceWeights)
        let chromaPreserved = inputLuminance > 0.000001
            ? positive * (outputLuminance / inputLuminance)
            : base

        let highlight = smoothstep(edge0: 1.5, edge1: 24.0, value: inputLuminance)
        let preserveAmount = mix(0.82, 0.28, t: highlight)
        return simd_max(mix(base, chromaPreserved, t: preserveAmount), .zero)
    }

    public static func linearToSRGB(_ linear: SIMD3<Float>) -> SIMD3<Float> {
        let positive = simd_max(linear, .zero)
        return SIMD3<Float>(
            srgbEncode(positive.x),
            srgbEncode(positive.y),
            srgbEncode(positive.z)
        )
    }

    public static func finalSDROutput(sceneLinear: SIMD3<Float>,
                                      exposureEV: Float) -> SIMD3<Float> {
        let exposed = simd_max(sceneLinear, .zero) * exposureMultiplier(forEV: exposureEV)
        let tonemapped = simd_clamp(metalCupFilmicV1(exposed), .zero, SIMD3<Float>(repeating: 1.0))
        return linearToSRGB(tonemapped)
    }

    private static func uncharted2(_ value: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(uncharted2(value.x), uncharted2(value.y), uncharted2(value.z))
    }

    private static func uncharted2(_ value: Float) -> Float {
        let a: Float = 0.15
        let b: Float = 0.50
        let c: Float = 0.10
        let d: Float = 0.20
        let e: Float = 0.02
        let f: Float = 0.30
        return ((value * (a * value + c * b) + d * e)
            / (value * (a * value + b) + d * f)) - e / f
    }

    private static func srgbEncode(_ value: Float) -> Float {
        value <= 0.0031308
            ? 12.92 * value
            : 1.055 * Float(Foundation.pow(Double(value), 1.0 / 2.4)) - 0.055
    }

    private static func smoothstep(edge0: Float, edge1: Float, value: Float) -> Float {
        let t = min(max((value - edge0) / (edge1 - edge0), 0.0), 1.0)
        return t * t * (3.0 - 2.0 * t)
    }

    private static func mix(_ a: Float, _ b: Float, t: Float) -> Float {
        a + (b - a) * t
    }

    private static func mix(_ a: SIMD3<Float>,
                            _ b: SIMD3<Float>,
                            t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }
}
