import Foundation
import simd

/// Scene-linear daytime atmosphere and solar-energy contract.
///
/// MetalCup works in linear sRGB/Rec.709 (D65). The atmosphere stores incident
/// radiance in scene-relative units; camera exposure is not part of this model.
/// `sourceEV` scales every daytime source term once by `2^EV`. The default solar
/// normalization is intentionally scene-relative rather than a claim of lux or
/// spectral accuracy: the unattenuated projected solar disk has Rec.709
/// illuminance 2.0 at EV 0. This keeps the disk below RGBA16Float's finite limit
/// through EV +1 while producing an order-one white-Lambertian direct response.
///
/// The visible result contains atmosphere + aureole + direct disk. Procedural IBL
/// capture contains atmosphere + aureole only. The disk's projected integral is
/// represented once, by the generated directional light.
public enum DaytimeAtmosphereModel {
    public static let planetRadiusKilometers: Float = 6_360
    public static let atmosphereRadiusKilometers: Float = 6_460
    public static let rayleighScaleHeightKilometers: Float = 8
    public static let mieScaleHeightKilometers: Float = 1.2
    public static let solarAngularRadiusDegrees: Float = 0.266
    public static let referenceTopSolarIlluminance: Float = 2.0
    public static let mieAnisotropy: Float = 0.8
    public static let groundAlbedo: Float = 0.10

    /// Approximate linear-sRGB solar chromaticity at the top of the atmosphere.
    public static let solarChroma = SIMD3<Float>(1.0, 0.97, 0.92)
    /// Vertically integrated optical depths for an Earth-like clear atmosphere.
    public static let rayleighOpticalDepth = SIMD3<Float>(0.055, 0.130, 0.320)
    public static let ozoneOpticalDepth = SIMD3<Float>(0.010, 0.025, 0.006)

    public struct Parameters: Equatable {
        public var sourceEV: Float
        public var densityScale: Float
        public var aerosolScale: Float
        public var ozoneScale: Float
        public var multipleScatteringStrength: Float
        public var groundAlbedo: Float
        public var solarAngularRadiusRadians: Float

        public init(sourceEV: Float = 0,
                    densityScale: Float = 1,
                    aerosolScale: Float = 1,
                    ozoneScale: Float = 1,
                    multipleScatteringStrength: Float = 1,
                    groundAlbedo: Float = DaytimeAtmosphereModel.groundAlbedo,
                    solarAngularRadiusRadians: Float = DaytimeAtmosphereModel.solarAngularRadiusDegrees * .pi / 180) {
            self.sourceEV = sourceEV
            self.densityScale = max(densityScale, 0.05)
            self.aerosolScale = max(aerosolScale, 0)
            self.ozoneScale = max(ozoneScale, 0)
            self.multipleScatteringStrength = max(multipleScatteringStrength, 0)
            self.groundAlbedo = min(max(groundAlbedo, 0), 1)
            self.solarAngularRadiusRadians = max(solarAngularRadiusRadians, 0.0001)
        }

        public init(environment: EnvironmentComponent) {
            let aerosol = 0.55
                + min(max(environment.atmosphere.haze, 0), 1) * 1.55
                + min(max(environment.atmosphere.amount, 0), 1) * 0.35
            self.init(
                sourceEV: min(max(environment.atmosphere.sourceEV, -2), 1),
                densityScale: max(environment.atmosphere.density, 0.05),
                aerosolScale: aerosol,
                ozoneScale: 0.85 + min(max(environment.atmosphere.amount, 0), 1) * 0.30,
                multipleScatteringStrength: 0.85 + min(max(environment.atmosphere.amount, 0), 1) * 0.55
            )
        }
    }

    public struct Sample: Equatable {
        public var atmosphere: SIMD3<Float>
        public var aureole: SIMD3<Float>
        public var disk: SIMD3<Float>

        public var visible: SIMD3<Float> { atmosphere + aureole + disk }
        public var capture: SIMD3<Float> { atmosphere + aureole }
    }

    public struct SolarIrradiance: Equatable {
        public var rgb: SIMD3<Float>
        public var color: SIMD3<Float>
        public var illuminance: Float
        public var transmittance: SIMD3<Float>
        public var horizonVisibility: Float
    }

    @inline(__always)
    public static func rec709Luminance(_ rgb: SIMD3<Float>) -> Float {
        simd_dot(rgb, SIMD3<Float>(0.2126, 0.7152, 0.0722))
    }

    public static func sourceScale(sourceEV: Float) -> Float {
        exp2(min(max(sourceEV, -2), 1))
    }

    public static func projectedSolidAngle(radiusRadians: Float) -> Float {
        Float.pi * pow(sin(max(radiusRadians, 0)), 2)
    }

    public static func topSolarIrradianceRGB() -> SIMD3<Float> {
        solarChroma * (referenceTopSolarIlluminance / rec709Luminance(solarChroma))
    }

    public static func topSolarDiskRadianceRGB(radiusRadians: Float) -> SIMD3<Float> {
        topSolarIrradianceRGB() / max(projectedSolidAngle(radiusRadians: radiusRadians), 1e-8)
    }

    public static func solarIrradiance(sunDirection: SIMD3<Float>,
                                       parameters: Parameters) -> SolarIrradiance {
        let direction = safeNormalize(sunDirection, fallback: SIMD3<Float>(0, 1, 0))
        let elevation = asin(min(max(direction.y, -1), 1))
        let airMass = opticalAirMass(elevationRadians: max(elevation, 0))
        let opticalDepth = totalOpticalDepth(parameters: parameters)
        let transmittance = componentExp(-opticalDepth * airMass)
        let visibility = smoothstep(-parameters.solarAngularRadiusRadians,
                                    parameters.solarAngularRadiusRadians,
                                    elevation)
        let rgb = topSolarIrradianceRGB()
            * transmittance
            * visibility
            * sourceScale(sourceEV: parameters.sourceEV)
        let illuminance = max(rec709Luminance(rgb), 0)
        let color = illuminance > 1e-7 ? rgb / illuminance : SIMD3<Float>(repeating: 0)
        return SolarIrradiance(rgb: max(rgb, SIMD3<Float>(repeating: 0)),
                              color: color,
                              illuminance: illuminance,
                              transmittance: transmittance,
                              horizonVisibility: visibility)
    }

    public static func sample(direction: SIMD3<Float>,
                              sunDirection: SIMD3<Float>,
                              parameters: Parameters) -> Sample {
        let view = safeNormalize(direction, fallback: SIMD3<Float>(0, 1, 0))
        let sun = safeNormalize(sunDirection, fallback: SIMD3<Float>(0, 1, 0))
        let sourceScale = sourceScale(sourceEV: parameters.sourceEV)
        let sunElevation = asin(min(max(sun.y, -1), 1))
        let twilight = smoothstep(-6 * .pi / 180, 1 * .pi / 180, sunElevation)
        let sunAirMass = opticalAirMass(elevationRadians: max(sunElevation, 0))
        let viewAirMass = opticalAirMass(elevationRadians: asin(max(view.y, 0.001)))
        let rayleighDepth = rayleighOpticalDepth * parameters.densityScale
        let mieDepth = SIMD3<Float>(repeating: (0.025 + 0.055 * parameters.aerosolScale) * parameters.densityScale)
        let ozoneDepth = ozoneOpticalDepth * parameters.ozoneScale
        let totalDepth = rayleighDepth + mieDepth + ozoneDepth
        let sunTransmittance = componentExp(-totalDepth * sunAirMass)
        let viewTransmittance = componentExp(-totalDepth * viewAirMass)
        let rayleighScatter = SIMD3<Float>(repeating: 1) - componentExp(-rayleighDepth * viewAirMass)
        let mieScatter = SIMD3<Float>(repeating: 1) - componentExp(-mieDepth * viewAirMass)
        let cosAngle = min(max(simd_dot(view, sun), -1), 1)
        let topIrradiance = topSolarIrradianceRGB() * sourceScale * twilight
        let incidentTint = componentSqrt(max(sunTransmittance, SIMD3<Float>(repeating: 0)))
        let rayleigh = topIrradiance * incidentTint * rayleighScatter
            * (rayleighPhase(cosAngle) * 2.8)
        let meanLoss = 1 - (viewTransmittance.x + viewTransmittance.y + viewTransmittance.z) / 3
        let multiple = topIrradiance
            * (0.045 + 0.115 * min(max(meanLoss, 0), 1))
            * parameters.multipleScatteringStrength
        let horizon = 1 - min(max(view.y, 0), 1)
        let groundBounce = topIrradiance
            * parameters.groundAlbedo
            * (0.025 + 0.075 * horizon)
        var atmosphere = max(rayleigh + multiple + groundBounce, SIMD3<Float>(repeating: 0))
        if view.y < 0 {
            atmosphere *= 0.22 + 0.18 * min(max(-view.y, 0), 1)
        }

        let aureole = max(topIrradiance * incidentTint * mieScatter
            * (miePhase(cosAngle, anisotropy: mieAnisotropy) * 0.42),
            SIMD3<Float>(repeating: 0))

        let sunAngle = acos(cosAngle)
        let diskMask = 1 - smoothstep(parameters.solarAngularRadiusRadians * 0.96,
                                      parameters.solarAngularRadiusRadians * 1.04,
                                      sunAngle)
        let horizonVisibility = smoothstep(-parameters.solarAngularRadiusRadians,
                                           parameters.solarAngularRadiusRadians,
                                           sunElevation)
        let disk = topSolarDiskRadianceRGB(radiusRadians: parameters.solarAngularRadiusRadians)
            * sunTransmittance
            * sourceScale
            * horizonVisibility
            * diskMask
        return Sample(atmosphere: atmosphere,
                      aureole: aureole,
                      disk: max(disk, SIMD3<Float>(repeating: 0)))
    }

    private static func totalOpticalDepth(parameters: Parameters) -> SIMD3<Float> {
        rayleighOpticalDepth * parameters.densityScale
            + SIMD3<Float>(repeating: (0.025 + 0.055 * parameters.aerosolScale) * parameters.densityScale)
            + ozoneOpticalDepth * parameters.ozoneScale
    }

    private static func opticalAirMass(elevationRadians: Float) -> Float {
        let degrees = min(max(elevationRadians * 180 / .pi, 0), 90)
        let sine = max(sin(elevationRadians), 0)
        return min(1 / max(sine + 0.50572 * pow(degrees + 6.07995, -1.6364), 0.025), 40)
    }

    private static func rayleighPhase(_ cosine: Float) -> Float {
        3 / (16 * .pi) * (1 + cosine * cosine)
    }

    private static func miePhase(_ cosine: Float, anisotropy: Float) -> Float {
        let g = min(max(anisotropy, 0), 0.95)
        let denominator = max(pow(1 + g * g - 2 * g * cosine, 1.5), 1e-6)
        return (1 - g * g) / (4 * .pi * denominator)
    }

    private static func componentExp(_ value: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(exp(value.x), exp(value.y), exp(value.z))
    }

    private static func componentSqrt(_ value: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(sqrt(value.x), sqrt(value.y), sqrt(value.z))
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / max(edge1 - edge0, 1e-7), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func safeNormalize(_ value: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        simd_length_squared(value) > 1e-10 ? simd_normalize(value) : fallback
    }
}
