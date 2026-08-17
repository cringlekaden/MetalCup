import Foundation
import simd

/// Scene-linear night/celestial contract.
///
/// The Moon is a diffuse reflector of the same D65 solar source used by the
/// daytime atmosphere. `lunarAlbedo` is an effective geometric reflectance,
/// not a brightness control. Camera exposure remains outside this model.
/// The visible sky contains the lunar disk, while procedural IBL capture omits
/// that unscattered disk because its projected integral is represented once by
/// the generated analytic Moon light. Atmospheric moon glow, the night sky,
/// stars, and the Milky Way may enter IBL, with unresolved point-like celestial
/// art deliberately bounded by `celestialCaptureScale`.
public enum NightCelestialModel {
    public static let defaultLunarAlbedo: Float = 0.12
    public static let defaultMoonDiameterDegrees: Float = 0.54
    public static let celestialCaptureScale: Float = 0.04

    public enum DirectionalSource: UInt32, Equatable {
        case none = 0
        case sun = 1
        case moon = 2
    }

    public struct State: Equatable {
        public var moonDirection: SIMD3<Float>
        public var moonAngularRadiusRadians: Float
        public var phase: Float
        public var phaseAngleRadians: Float
        public var illuminatedFraction: Float
        public var phaseResponse: Float
        /// Full-lit disk-center radiance after atmospheric transmission.
        public var diskRadianceRGB: SIMD3<Float>
        /// Projected lunar-disk integral used by the analytic directional light.
        public var irradianceRGB: SIMD3<Float>
        public var horizonVisibility: Float
        public var starVisibility: Float
        public var nightVisibility: Float
        public var directionalSource: DirectionalSource
        public var directionalDirection: SIMD3<Float>
        public var directionalIrradianceRGB: SIMD3<Float>
        public var directionalColor: SIMD3<Float>
        public var directionalIlluminance: Float
    }

    public static func build(timeOfDay: Float,
                             sunDirection: SIMD3<Float>,
                             solarIrradianceRGB: SIMD3<Float>,
                             atmosphere: DaytimeAtmosphereModel.Parameters,
                             lunarAlbedo: Float,
                             moonDiameterDegrees: Float,
                             moonPhase: Float,
                             haze: Float,
                             cloudCoverage: Float) -> State {
        let phase = positiveUnitPhase(moonPhase)
        let moonDirection = lunarOrbitDirection(sunDirection: sunDirection,
                                                phase: phase,
                                                timeOfDay: timeOfDay)
        let radius = max(moonDiameterDegrees * 0.5 * .pi / 180, 0.0001)
        let phaseAngle = acos(min(max(-simd_dot(moonDirection, sunDirection), -1), 1))
        let illuminatedFraction = 0.5 * (1 + cos(phaseAngle))
        let phaseResponse = lambertPhase(angleRadians: phaseAngle)
        let horizonVisibility = smoothstep(-radius, radius, asin(min(max(moonDirection.y, -1), 1)))
        let transmittance = DaytimeAtmosphereModel.atmosphericTransmittance(
            direction: moonDirection,
            parameters: atmosphere
        )
        let reflectance = min(max(lunarAlbedo, 0), 1)
        let topSolar = DaytimeAtmosphereModel.topSolarIrradianceRGB()
            * DaytimeAtmosphereModel.sourceScale(sourceEV: atmosphere.sourceEV)
        let diskRadiance = max(
            topSolar * (reflectance / .pi) * transmittance * horizonVisibility,
            SIMD3<Float>(repeating: 0)
        )
        // A Lambert sphere integrates to 2/3 of its disk-center radiance at full phase.
        let irradiance = diskRadiance
            * (DaytimeAtmosphereModel.projectedSolidAngle(radiusRadians: radius) * (2 / Float(3)))
            * phaseResponse

        let sunElevation = asin(min(max(sunDirection.y, -1), 1))
        // First stars appear during civil twilight; full celestial contrast is
        // not reached until astronomical twilight has ended.
        let nightVisibility = 1 - smoothstep(-18 * .pi / 180, -4 * .pi / 180, sunElevation)
        let clarity = (1 - min(max(haze, 0), 1) * 0.72)
            * (1 - min(max(cloudCoverage, 0), 1) * 0.65)
        let moonWashout = 1 - min(max(illuminatedFraction * horizonVisibility * 0.45, 0), 0.45)
        let starVisibility = min(max(nightVisibility * clarity * moonWashout, 0), 1)

        let sunIlluminance = DaytimeAtmosphereModel.rec709Luminance(solarIrradianceRGB)
        let moonIlluminance = DaytimeAtmosphereModel.rec709Luminance(irradiance)
        let directionalSource: DirectionalSource
        let directionalDirection: SIMD3<Float>
        let directionalIrradiance: SIMD3<Float>
        if sunIlluminance > max(moonIlluminance, 1e-8) {
            directionalSource = .sun
            directionalDirection = sunDirection
            directionalIrradiance = solarIrradianceRGB
        } else if moonIlluminance > 1e-10 {
            directionalSource = .moon
            directionalDirection = moonDirection
            directionalIrradiance = irradiance
        } else {
            directionalSource = .none
            directionalDirection = sunDirection
            directionalIrradiance = .zero
        }
        let directionalIlluminance = max(
            DaytimeAtmosphereModel.rec709Luminance(directionalIrradiance),
            0
        )
        let directionalColor = directionalIlluminance > 1e-10
            ? directionalIrradiance / directionalIlluminance
            : SIMD3<Float>(repeating: 0)

        return State(
            moonDirection: moonDirection,
            moonAngularRadiusRadians: radius,
            phase: phase,
            phaseAngleRadians: phaseAngle,
            illuminatedFraction: illuminatedFraction,
            phaseResponse: phaseResponse,
            diskRadianceRGB: diskRadiance,
            irradianceRGB: max(irradiance, SIMD3<Float>(repeating: 0)),
            horizonVisibility: horizonVisibility,
            starVisibility: starVisibility,
            nightVisibility: nightVisibility,
            directionalSource: directionalSource,
            directionalDirection: directionalDirection,
            directionalIrradianceRGB: directionalIrradiance,
            directionalColor: directionalColor,
            directionalIlluminance: directionalIlluminance
        )
    }

    public static func lambertPhase(angleRadians: Float) -> Float {
        let angle = min(max(angleRadians, 0), .pi)
        return max((sin(angle) + (.pi - angle) * cos(angle)) / .pi, 0)
    }

    public static func lunarOrbitDirection(sunDirection: SIMD3<Float>,
                                           phase: Float,
                                           timeOfDay: Float) -> SIMD3<Float> {
        let sun = simd_length_squared(sunDirection) > 1e-10
            ? simd_normalize(sunDirection)
            : SIMD3<Float>(0, 1, 0)
        let reference = abs(sun.y) < 0.95
            ? SIMD3<Float>(0, 1, 0)
            : SIMD3<Float>(1, 0, 0)
        var tangent = simd_normalize(simd_cross(reference, sun))
        // The slow daily roll avoids a fixed orbital seam while preserving exact
        // new/full alignment and one deterministic frame-owned direction.
        let roll = normalizedHours(timeOfDay) / 24 * 2 * Float.pi
        let bitangent = simd_normalize(simd_cross(sun, tangent))
        tangent = tangent * cos(roll) + bitangent * sin(roll)
        let angle = positiveUnitPhase(phase) * 2 * Float.pi
        return simd_normalize(sun * cos(angle) + tangent * sin(angle))
    }

    private static func normalizedHours(_ value: Float) -> Float {
        let wrapped = value.truncatingRemainder(dividingBy: 24)
        return wrapped >= 0 ? wrapped : wrapped + 24
    }

    private static func positiveUnitPhase(_ value: Float) -> Float {
        let wrapped = value.truncatingRemainder(dividingBy: 1)
        return wrapped >= 0 ? wrapped : wrapped + 1
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / max(edge1 - edge0, 1e-7), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
