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
/// Twilight is evaluated continuously through -24 degrees solar elevation and a
/// bounded airglow floor remains after scattered sunlight has vanished. The
/// visible result contains atmosphere + aureole + direct disk. Procedural IBL
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
    public static let groundAlbedo: Float = 0.08

    /// Scene-relative D65 daylight at the top of the atmosphere. Sunset color is
    /// produced by atmospheric transmittance rather than an authored warm tint.
    public static let solarChroma = SIMD3<Float>(repeating: 1)
    /// Vertically integrated optical depths for the calibrated clear-day model.
    /// Ratios are intentionally explicit because they own the daylight chroma.
    public static let rayleighOpticalDepth = SIMD3<Float>(0.025, 0.075, 0.220)
    public static let ozoneOpticalDepth = SIMD3<Float>(0.003, 0.008, 0.002)
    /// Deep-night source radiance before view/horizon shaping. These values are
    /// in the same scene-linear domain as daytime scattering and IBL capture.
    public static let airglowZenithRGB = SIMD3<Float>(0.000_010, 0.000_018, 0.000_040)
    public static let airglowHorizonRGB = SIMD3<Float>(0.000_020, 0.000_024, 0.000_036)

    public struct Parameters: Equatable {
        public var sourceEV: Float
        public var densityScale: Float
        public var aerosolScale: Float
        public var ozoneScale: Float
        public var multipleScatteringStrength: Float
        public var groundAlbedo: Float
        public var solarAngularRadiusRadians: Float
        public var nightBrightness: Float

        public init(sourceEV: Float = 0,
                    densityScale: Float = 1,
                    aerosolScale: Float = 1,
                    ozoneScale: Float = 1,
                    multipleScatteringStrength: Float = 1,
                    groundAlbedo: Float = DaytimeAtmosphereModel.groundAlbedo,
                    solarAngularRadiusRadians: Float = DaytimeAtmosphereModel.solarAngularRadiusDegrees * .pi / 180,
                    nightBrightness: Float = 1) {
            self.sourceEV = sourceEV
            self.densityScale = max(densityScale, 0.05)
            self.aerosolScale = max(aerosolScale, 0)
            self.ozoneScale = max(ozoneScale, 0)
            self.multipleScatteringStrength = max(multipleScatteringStrength, 0)
            self.groundAlbedo = min(max(groundAlbedo, 0), 1)
            self.solarAngularRadiusRadians = max(solarAngularRadiusRadians, 0.0001)
            self.nightBrightness = min(max(nightBrightness, 0), 3)
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
                multipleScatteringStrength: 0.85 + min(max(environment.atmosphere.amount, 0), 1) * 0.55,
                nightBrightness: environment.celestial.nightBrightness
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

    /// Smooth, monotonic scattered-sun scale. Segment endpoints have zero first
    /// derivative so civil, nautical, and astronomical boundaries do not flash.
    public static func twilightSolarScale(elevationDegrees: Float) -> Float {
        let elevation = min(max(elevationDegrees, -24), 1)
        let knots: [(Float, Float)] = [
            (-24, 0),
            (-18, 0.000_08),
            (-12, 0.001_2),
            (-6, 0.025),
            (0, 0.65),
            (1, 1)
        ]
        guard elevation > knots[0].0 else { return 0 }
        for index in 0..<(knots.count - 1) {
            let lower = knots[index]
            let upper = knots[index + 1]
            guard elevation <= upper.0 else { continue }
            let t = smoothstep(lower.0, upper.0, elevation)
            if lower.1 <= 0 {
                return upper.1 * t
            }
            return exp2(log2(lower.1) + (log2(upper.1) - log2(lower.1)) * t)
        }
        return 1
    }

    public static func deepNightFactor(elevationDegrees: Float) -> Float {
        1 - smoothstep(-18, -6, elevationDegrees)
    }

    public static func airglowRadiance(direction: SIMD3<Float>,
                                       solarElevationDegrees: Float,
                                       parameters: Parameters) -> SIMD3<Float> {
        let view = safeNormalize(direction, fallback: SIMD3<Float>(0, 1, 0))
        let zenithBlend = smoothstep(0, 0.72, max(view.y, 0))
        let base = airglowHorizonRGB + (airglowZenithRGB - airglowHorizonRGB) * zenithBlend
        return base
            * deepNightFactor(elevationDegrees: solarElevationDegrees)
            * parameters.nightBrightness
            * sourceScale(sourceEV: parameters.sourceEV)
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

    /// Ground-observer transmittance for a celestial source along a world-space
    /// direction. Horizon visibility is intentionally handled by the caller so
    /// solar and lunar disks can use their own angular radii at the boundary.
    public static func atmosphericTransmittance(direction: SIMD3<Float>,
                                                 parameters: Parameters) -> SIMD3<Float> {
        let normalized = safeNormalize(direction, fallback: SIMD3<Float>(0, 1, 0))
        let elevation = asin(min(max(normalized.y, -1), 1))
        let airMass = opticalAirMass(elevationRadians: max(elevation, 0))
        return componentExp(-totalOpticalDepth(parameters: parameters) * airMass)
    }

    public static func sample(direction: SIMD3<Float>,
                              sunDirection: SIMD3<Float>,
                              parameters: Parameters) -> Sample {
        let view = safeNormalize(direction, fallback: SIMD3<Float>(0, 1, 0))
        let sun = safeNormalize(sunDirection, fallback: SIMD3<Float>(0, 1, 0))
        let sourceScale = sourceScale(sourceEV: parameters.sourceEV)
        let sunElevation = asin(min(max(sun.y, -1), 1))
        let sunElevationDegrees = sunElevation * 180 / .pi
        let twilight = twilightSolarScale(elevationDegrees: sunElevationDegrees)
        let sunAirMass = opticalAirMass(elevationRadians: max(sunElevation, 0))
        let viewAirMass = opticalAirMass(elevationRadians: asin(max(view.y, 0.001)))
        let rayleighDepth = rayleighOpticalDepth * parameters.densityScale
        let mieDepth = SIMD3<Float>(repeating: (0.018 + 0.022 * parameters.aerosolScale) * parameters.densityScale)
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
            * (rayleighPhase(cosAngle) * 3.2)
        let meanLoss = 1 - (viewTransmittance.x + viewTransmittance.y + viewTransmittance.z) / 3
        let scatteringDepth = rayleighDepth + mieDepth
        let scatteringAlbedo = scatteringDepth / max(totalDepth, SIMD3<Float>(repeating: 1e-5))
        let scatteredSolar = (SIMD3<Float>(repeating: 1) - sunTransmittance) * scatteringAlbedo
        let scatteredLuminance = max(rec709Luminance(scatteredSolar), 1e-5)
        let multipleTint = scatteredSolar / scatteredLuminance
        let multiple = topIrradiance * multipleTint
            * (0.045 + 0.115 * min(max(meanLoss, 0), 1))
            * parameters.multipleScatteringStrength * 1.2
        let horizon = 1 - min(max(view.y, 0), 1)
        let groundBounce = topIrradiance * sunTransmittance
            * parameters.groundAlbedo
            * max(sun.y, 0)
            * (0.025 + 0.075 * horizon)
        let upperAtmosphere = max(rayleigh + multiple + groundBounce, SIMD3<Float>(repeating: 0))
        let lowerGround = max(
            topIrradiance * sunTransmittance * max(sun.y, 0)
                * (parameters.groundAlbedo / .pi)
                + multiple * parameters.groundAlbedo * 0.5,
            SIMD3<Float>(repeating: 0)
        )
        let upperBlend = smoothstep(-0.02, 0.02, view.y)
        let atmosphere = lowerGround + (upperAtmosphere - lowerGround) * upperBlend
            + airglowRadiance(direction: view,
                              solarElevationDegrees: sunElevationDegrees,
                              parameters: parameters)

        let aureole = max(topIrradiance * incidentTint * mieScatter
            * (miePhase(cosAngle, anisotropy: mieAnisotropy) * 0.45),
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

    /// Low-cost deterministic hemispherical integral used for live cloud/fog
    /// lighting. It excludes the unscattered disk, matching the IBL partition.
    public static func hemisphericalSkyIrradiance(sunDirection: SIMD3<Float>,
                                                   parameters: Parameters,
                                                   sampleCount: Int = 32) -> SIMD3<Float> {
        let count = max(sampleCount, 8)
        let goldenAngle = Float.pi * (3 - sqrt(5 as Float))
        var irradiance = SIMD3<Float>(repeating: 0)
        for index in 0..<count {
            let y = (Float(index) + 0.5) / Float(count)
            let radius = sqrt(max(1 - y * y, 0))
            let phi = Float(index) * goldenAngle
            let direction = SIMD3<Float>(cos(phi) * radius, y, sin(phi) * radius)
            let value = sample(direction: direction,
                               sunDirection: sunDirection,
                               parameters: parameters)
            irradiance += (value.atmosphere + value.aureole) * y
        }
        return max(irradiance * (2 * .pi / Float(count)), SIMD3<Float>(repeating: 0))
    }

    private static func totalOpticalDepth(parameters: Parameters) -> SIMD3<Float> {
        rayleighOpticalDepth * parameters.densityScale
            + SIMD3<Float>(repeating: (0.018 + 0.022 * parameters.aerosolScale) * parameters.densityScale)
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
