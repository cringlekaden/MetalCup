/// SkySystem.swift
/// Defines the SkySystem types and helpers for the engine.
/// Created by Kaden Cringle.

import Foundation
import simd

public struct AtmosphereDerivedSettings: Equatable {
    /// World-space unit vector from the scene toward the visible sun.
    public var sunDirectionWorld: SIMD3<Float>
    /// World-space unit vector describing the direction sunlight travels.
    public var sunRayDirectionWorld: SIMD3<Float>
    /// Procedural sky shader direction toward the visible sun, in the same world/cubemap basis used by texturecube sampling.
    public var sunDirectionSkySpace: SIMD3<Float>
    public var normalizedSunHeight: Float
    /// 0 = night, 1 = broad daylight. Twilight lives in-between and is carried separately.
    public var dayNightFactor: Float
    /// Highlights the sunset/dawn shoulder where color and extinction shift fastest.
    public var twilightFactor: Float
    /// 0 = day, 1 = deep night. Kept separate from dayNightFactor for later moon/stars work.
    public var nightFactor: Float
    public var sunWarmth: Float
    public var hazeAmount: Float
    public var horizonBlend: Float
    /// Shared horizon weighting for sky shaping, fog tinting, and later cloud horizon integration.
    public var horizonDensity: Float
    public var zenithClarity: Float
    /// Visibility of the solar disc after horizon fade and haze extinction.
    public var solarVisibility: Float
    /// Warm, extinguished sun tint used by both the sky disc and the auto sun light.
    public var solarExtinctionTint: SIMD3<Float>
    /// First non-astronomical moon path: derived under the same atmosphere owner as the sun.
    public var moonDirectionWorld: SIMD3<Float>
    public var moonDirectionSkySpace: SIMD3<Float>
    public var moonVisibility: Float
    public var moonTint: SIMD3<Float>
    public var moonDiskIntensity: Float
    /// Warm dusk shoulder tint used to enrich the horizon without adding more public knobs.
    public var duskTint: SIMD3<Float>
    /// Cooler anti-solar tint for the opposite side of the sky and future night transitions.
    public var antiSolarTint: SIMD3<Float>
    /// Broad coolness cue for later night/stars/moon work and immediate fog/sky shaping.
    public var skyCoolness: Float
    /// Prepared now for later star rendering; currently derived but not rendered.
    public var starVisibility: Float
    public var sunScatterStrength: Float
    public var ambientTint: SIMD3<Float>
    public var zenithTint: SIMD3<Float>
    public var horizonTint: SIMD3<Float>
    public var sunTint: SIMD3<Float>
    public var sunDiskIntensity: Float
    public var sunLightColor: SIMD3<Float>
    public var sunLightIntensity: Float
    public var sunForwardHazeTint: SIMD3<Float>
    public var atmosphereTint: SIMD3<Float>
    public var fogCandidateTint: SIMD3<Float>
    public var fogHorizonTint: SIMD3<Float>
    public var cloudLightTint: SIMD3<Float>

    public init(sunDirectionWorld: SIMD3<Float>,
                sunRayDirectionWorld: SIMD3<Float>,
                sunDirectionSkySpace: SIMD3<Float>,
                normalizedSunHeight: Float,
                dayNightFactor: Float,
                twilightFactor: Float,
                nightFactor: Float,
                sunWarmth: Float,
                hazeAmount: Float,
                horizonBlend: Float,
                horizonDensity: Float,
                zenithClarity: Float,
                solarVisibility: Float,
                solarExtinctionTint: SIMD3<Float>,
                moonDirectionWorld: SIMD3<Float>,
                moonDirectionSkySpace: SIMD3<Float>,
                moonVisibility: Float,
                moonTint: SIMD3<Float>,
                moonDiskIntensity: Float,
                duskTint: SIMD3<Float>,
                antiSolarTint: SIMD3<Float>,
                skyCoolness: Float,
                starVisibility: Float,
                sunScatterStrength: Float,
                ambientTint: SIMD3<Float>,
                zenithTint: SIMD3<Float>,
                horizonTint: SIMD3<Float>,
                sunTint: SIMD3<Float>,
                sunDiskIntensity: Float,
                sunLightColor: SIMD3<Float>,
                sunLightIntensity: Float,
                sunForwardHazeTint: SIMD3<Float>,
                atmosphereTint: SIMD3<Float>,
                fogCandidateTint: SIMD3<Float>,
                fogHorizonTint: SIMD3<Float>,
                cloudLightTint: SIMD3<Float>) {
        self.sunDirectionWorld = sunDirectionWorld
        self.sunRayDirectionWorld = sunRayDirectionWorld
        self.sunDirectionSkySpace = sunDirectionSkySpace
        self.normalizedSunHeight = normalizedSunHeight
        self.dayNightFactor = dayNightFactor
        self.twilightFactor = twilightFactor
        self.nightFactor = nightFactor
        self.sunWarmth = sunWarmth
        self.hazeAmount = hazeAmount
        self.horizonBlend = horizonBlend
        self.horizonDensity = horizonDensity
        self.zenithClarity = zenithClarity
        self.solarVisibility = solarVisibility
        self.solarExtinctionTint = solarExtinctionTint
        self.moonDirectionWorld = moonDirectionWorld
        self.moonDirectionSkySpace = moonDirectionSkySpace
        self.moonVisibility = moonVisibility
        self.moonTint = moonTint
        self.moonDiskIntensity = moonDiskIntensity
        self.duskTint = duskTint
        self.antiSolarTint = antiSolarTint
        self.skyCoolness = skyCoolness
        self.starVisibility = starVisibility
        self.sunScatterStrength = sunScatterStrength
        self.ambientTint = ambientTint
        self.zenithTint = zenithTint
        self.horizonTint = horizonTint
        self.sunTint = sunTint
        self.sunDiskIntensity = sunDiskIntensity
        self.sunLightColor = sunLightColor
        self.sunLightIntensity = sunLightIntensity
        self.sunForwardHazeTint = sunForwardHazeTint
        self.atmosphereTint = atmosphereTint
        self.fogCandidateTint = fogCandidateTint
        self.fogHorizonTint = fogHorizonTint
        self.cloudLightTint = cloudLightTint
    }
}

public struct ResolvedWeatherProfile: Equatable {
    public var turbidity: Float
    public var cloudCoverageFloor: Float
    public var cloudSoftness: Float
    public var cloudScale: Float
    public var cloudThickness: Float
    public var cloudBrightness: Float
    public var cloudSunInfluence: Float
    public var cloudSpeed: Float
    public var hazeFloor: Float
    public var intensity: Float
    public var horizonDensityBias: Float
    public var celestialOcclusion: Float
}

public enum SkySystem {
    @inline(__always)
    private static func saturate(_ value: Float) -> Float {
        min(max(value, 0.0), 1.0)
    }

    @inline(__always)
    private static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        simd_mix(a, b, SIMD3<Float>(repeating: saturate(t)))
    }

    @inline(__always)
    private static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float {
        simd_mix(a, b, saturate(t))
    }

    private static func weatherProfile(for weatherType: AtmosphereWeatherType) -> ResolvedWeatherProfile {
        switch weatherType {
        case .clear:
            return ResolvedWeatherProfile(turbidity: 1.9,
                                          cloudCoverageFloor: 0.0,
                                          cloudSoftness: 0.52,
                                          cloudScale: 1.0,
                                          cloudThickness: 0.24,
                                          cloudBrightness: 1.0,
                                          cloudSunInfluence: 1.0,
                                          cloudSpeed: 0.02,
                                          hazeFloor: 0.18,
                                          intensity: 1.0,
                                          horizonDensityBias: -0.04,
                                          celestialOcclusion: 0.05)
        case .partlyCloudy:
            return ResolvedWeatherProfile(turbidity: 2.6,
                                          cloudCoverageFloor: 0.28,
                                          cloudSoftness: 0.58,
                                          cloudScale: 1.1,
                                          cloudThickness: 0.32,
                                          cloudBrightness: 0.96,
                                          cloudSunInfluence: 0.82,
                                          cloudSpeed: 0.02,
                                          hazeFloor: 0.28,
                                          intensity: 1.0,
                                          horizonDensityBias: 0.02,
                                          celestialOcclusion: 0.14)
        case .overcast:
            return ResolvedWeatherProfile(turbidity: 5.5,
                                          cloudCoverageFloor: 0.78,
                                          cloudSoftness: 0.82,
                                          cloudScale: 1.6,
                                          cloudThickness: 0.56,
                                          cloudBrightness: 0.9,
                                          cloudSunInfluence: 0.35,
                                          cloudSpeed: 0.02,
                                          hazeFloor: 0.58,
                                          intensity: 0.9,
                                          horizonDensityBias: 0.16,
                                          celestialOcclusion: 0.52)
        case .storm:
            return ResolvedWeatherProfile(turbidity: 7.0,
                                          cloudCoverageFloor: 0.86,
                                          cloudSoftness: 0.76,
                                          cloudScale: 2.0,
                                          cloudThickness: 0.7,
                                          cloudBrightness: 0.78,
                                          cloudSunInfluence: 0.25,
                                          cloudSpeed: 0.035,
                                          hazeFloor: 0.72,
                                          intensity: 0.82,
                                          horizonDensityBias: 0.26,
                                          celestialOcclusion: 0.72)
        case .foggy:
            return ResolvedWeatherProfile(turbidity: 4.8,
                                          cloudCoverageFloor: 0.28,
                                          cloudSoftness: 0.68,
                                          cloudScale: 1.2,
                                          cloudThickness: 0.4,
                                          cloudBrightness: 0.88,
                                          cloudSunInfluence: 0.5,
                                          cloudSpeed: 0.018,
                                          hazeFloor: 0.82,
                                          intensity: 0.92,
                                          horizonDensityBias: 0.22,
                                          celestialOcclusion: 0.58)
        case .custom:
            return ResolvedWeatherProfile(turbidity: 2.0,
                                          cloudCoverageFloor: 0.0,
                                          cloudSoftness: 0.55,
                                          cloudScale: 1.0,
                                          cloudThickness: 0.32,
                                          cloudBrightness: 0.95,
                                          cloudSunInfluence: 0.9,
                                          cloudSpeed: 0.02,
                                          hazeFloor: 0.28,
                                          intensity: 1.0,
                                          horizonDensityBias: 0.0,
                                          celestialOcclusion: 0.0)
        }
    }

    /// Runtime can animate `weatherBlend` between the primary and secondary weather states
    /// without changing ownership or introducing a separate weather simulation layer.
    public static func resolvedWeatherProfile(primary: AtmosphereWeatherType,
                                              secondary: AtmosphereWeatherType,
                                              blend: Float) -> ResolvedWeatherProfile {
        let t = saturate(blend)
        let a = weatherProfile(for: primary)
        let b = weatherProfile(for: secondary)
        return ResolvedWeatherProfile(
            turbidity: mix(a.turbidity, b.turbidity, t),
            cloudCoverageFloor: mix(a.cloudCoverageFloor, b.cloudCoverageFloor, t),
            cloudSoftness: mix(a.cloudSoftness, b.cloudSoftness, t),
            cloudScale: mix(a.cloudScale, b.cloudScale, t),
            cloudThickness: mix(a.cloudThickness, b.cloudThickness, t),
            cloudBrightness: mix(a.cloudBrightness, b.cloudBrightness, t),
            cloudSunInfluence: mix(a.cloudSunInfluence, b.cloudSunInfluence, t),
            cloudSpeed: mix(a.cloudSpeed, b.cloudSpeed, t),
            hazeFloor: mix(a.hazeFloor, b.hazeFloor, t),
            intensity: mix(a.intensity, b.intensity, t),
            horizonDensityBias: mix(a.horizonDensityBias, b.horizonDensityBias, t),
            celestialOcclusion: mix(a.celestialOcclusion, b.celestialOcclusion, t)
        )
    }

    /// Returns the authored sun direction before any sky-shader handedness conversion.
    private static func authoredSunDirection(azimuthDegrees: Float, elevationDegrees: Float) -> SIMD3<Float> {
        let azimuth = azimuthDegrees * Float.pi / 180.0
        let elevation = elevationDegrees * Float.pi / 180.0
        let cosEl = cos(elevation)
        let dir = SIMD3<Float>(
            cosEl * cos(azimuth),
            sin(elevation),
            cosEl * sin(azimuth)
        )
        return simd_normalize(dir)
    }

    /// Returns the world-space direction from origin toward the visible sun disk in the sky.
    public static func sunDirection(azimuthDegrees: Float, elevationDegrees: Float) -> SIMD3<Float> {
        authoredSunDirection(azimuthDegrees: azimuthDegrees,
                             elevationDegrees: elevationDegrees)
    }

    /// Returns the world-space direction that sunlight rays travel (sun -> scene).
    public static func sunRayDirection(azimuthDegrees: Float, elevationDegrees: Float) -> SIMD3<Float> {
        -sunDirection(azimuthDegrees: azimuthDegrees, elevationDegrees: elevationDegrees)
    }

    private static func authoredSolarAngles(fromTimeOfDay timeOfDay: Float) -> (azimuthDegrees: Float, elevationDegrees: Float) {
        let wrappedTime = timeOfDay.truncatingRemainder(dividingBy: 24.0)
        let normalizedTime = (wrappedTime >= 0.0 ? wrappedTime : (wrappedTime + 24.0)) / 24.0
        let azimuthDegrees = fmodf(normalizedTime * 360.0 + 90.0, 360.0)
        let solarAngle = ((normalizedTime * 24.0 - 6.0) / 12.0) * Float.pi
        let solarHeight = sin(solarAngle)
        let elevationDegrees = min(max(solarHeight * 88.0, -12.0), 88.0)
        return (azimuthDegrees, elevationDegrees)
    }

    /// Deterministic world-space celestial track used by the authoritative
    /// environment frame for both solar time and the phase-offset lunar orbit.
    public static func sunDirection(timeOfDay: Float) -> SIMD3<Float> {
        let angles = authoredSolarAngles(fromTimeOfDay: timeOfDay)
        return sunDirection(azimuthDegrees: angles.azimuthDegrees,
                            elevationDegrees: angles.elevationDegrees)
    }

    private static func resolvedSolarAngles(authored sky: SkyLightComponent,
                                            runtime environment: EnvironmentStateComponent?) -> (azimuthDegrees: Float, elevationDegrees: Float) {
        guard let environment else {
            return (sky.azimuthDegrees, sky.elevationDegrees)
        }
        let sourceTimeOfDay: Float
        switch environment.timeControlMode {
        case .scripted:
            sourceTimeOfDay = environment.scriptedTimeOfDayOverride ?? environment.currentTimeOfDay
        case .fixed, .cycle:
            sourceTimeOfDay = environment.currentTimeOfDay
        }
        return authoredSolarAngles(fromTimeOfDay: sourceTimeOfDay)
    }

    private static func resolvedWeatherInputs(authored sky: SkyLightComponent,
                                              runtime environment: EnvironmentStateComponent?) -> (primary: AtmosphereWeatherType, secondary: AtmosphereWeatherType, blend: Float, amount: Float) {
        guard let environment else {
            return (sky.weatherType, sky.secondaryWeatherType, sky.weatherBlend, sky.weatherAmount)
        }
        return (environment.currentWeatherType,
                environment.targetWeatherType,
                environment.weatherTransitionProgress,
                environment.weatherAmount)
    }

    /// Converts a world-space direction into the procedural sky shader basis.
    /// Procedural visible sky, generated environment cubemaps, and runtime texturecube sampling
    /// now share the same world/cubemap direction basis; no handedness fixup belongs here.
    public static func skyShaderSunDirection(fromWorldSunDirection direction: SIMD3<Float>) -> SIMD3<Float> {
        simd_normalize(direction)
    }

    /// Computes a small shared atmosphere model from the authored sky state.
    /// The goal is not full physical atmosphere simulation; it is to derive the same
    /// horizon/zenith/sun-haze cues for both the sky shader and fog composition path.
    public static func derivedAtmosphere(authored sky: SkyLightComponent,
                                         runtime environment: EnvironmentStateComponent?) -> AtmosphereDerivedSettings {
        let resolvedAngles = resolvedSolarAngles(authored: sky, runtime: environment)
        let sunDirectionWorld = authoredSunDirection(azimuthDegrees: resolvedAngles.azimuthDegrees,
                                                     elevationDegrees: resolvedAngles.elevationDegrees)
        let sunRayDirectionWorld = -sunDirectionWorld
        let sunDirectionSkySpace = skyShaderSunDirection(fromWorldSunDirection: sunDirectionWorld)
        let weatherInputs = resolvedWeatherInputs(authored: sky, runtime: environment)
        let weatherProfile = resolvedWeatherProfile(primary: weatherInputs.primary,
                                                    secondary: weatherInputs.secondary,
                                                    blend: weatherInputs.blend)

        let normalizedSunHeight = saturate((sunDirectionWorld.y + 1.0) * 0.5)
        let dayNightFactor = saturate((sunDirectionWorld.y + 0.14) / 0.42)
        let twilightFactor = saturate(1.0 - abs(sunDirectionWorld.y - 0.01) / 0.26)
        let nightFactor = saturate((-sunDirectionWorld.y - 0.08) / 0.30)
        let sunsetFactor = saturate(max(1.0 - dayNightFactor, twilightFactor * 0.92))
        let sunWarmth = saturate(0.12 + sunsetFactor * 0.88)
        let hazeAmount = saturate(sky.hazeDensity / 1.25)
        let weatherHorizonBias = weatherProfile.horizonDensityBias * saturate(weatherInputs.amount)
        let horizonDensity = saturate(0.28 + hazeAmount * 0.42 + twilightFactor * 0.32 + nightFactor * 0.18 + weatherHorizonBias)
        let horizonBlend = saturate(0.32 + horizonDensity * 0.38 + sunsetFactor * 0.18)
        let zenithClarity = saturate(1.0 - hazeAmount * 0.68 - sunsetFactor * 0.16 - nightFactor * 0.12)
        let goldenHourFactor = saturate((1.0 - dayNightFactor) * (1.0 - nightFactor) + twilightFactor * 0.72)
        let solarExtinction = saturate(hazeAmount * 0.42 + twilightFactor * 0.26 + goldenHourFactor * 0.20)
        let sunAboveHorizonVisibility = saturate((sunDirectionWorld.y + 0.11) / 0.32)
        let solarVisibility = saturate(sunAboveHorizonVisibility * (1.0 - solarExtinction * 0.42) * (1.0 - nightFactor * 0.72))
        let skyCoolness = saturate(nightFactor * 0.75 + twilightFactor * 0.22 + hazeAmount * 0.08)
        let sunScatterStrength = saturate(0.2 + hazeAmount * 0.46 + twilightFactor * 0.26 + solarExtinction * 0.22)
        let moonDirectionWorld = simd_normalize(-sunDirectionWorld)
        let moonDirectionSkySpace = skyShaderSunDirection(fromWorldSunDirection: moonDirectionWorld)
        let moonAboveHorizon = saturate((moonDirectionWorld.y + 0.06) / 0.3)
        let moonVisibility = saturate(nightFactor
            * moonAboveHorizon
            * (1.0 - hazeAmount * 0.35)
            * (1.0 - sky.cloudsCoverage * 0.28))
        let moonTint = mix(SIMD3<Float>(0.72, 0.80, 0.96),
                           SIMD3<Float>(0.86, 0.90, 1.0),
                           0.35 + skyCoolness * 0.28)
        let moonDiskIntensity = max(0.0, sky.moonIntensity * moonVisibility * (0.72 + skyCoolness * 0.42))
        let starVisibility = saturate(nightFactor
            * (1.0 - hazeAmount * 0.72)
            * (1.0 - sky.cloudsCoverage * 0.65)
            * (1.0 - weatherProfile.celestialOcclusion * saturate(weatherInputs.amount)))

        let neutralTint = SIMD3<Float>(1.0, 1.0, 1.0)
        let baseSkyTint = max(sky.skyTint, SIMD3<Float>(repeating: 0.0))
        let duskTint = SIMD3<Float>(1.0, 0.54, 0.30)
        let antiSolarTint = SIMD3<Float>(0.34, 0.48, 0.82)
        let zenithTint = mix(max(sky.zenithTint, SIMD3<Float>(repeating: 0.0)),
                             baseSkyTint * mix(max(sky.zenithTint, SIMD3<Float>(repeating: 0.0)),
                                               antiSolarTint,
                                               0.08 + skyCoolness * 0.22),
                             0.35 + skyCoolness * 0.08)
        let ambientTint = mix(zenithTint,
                              baseSkyTint * zenithTint,
                              0.16 + zenithClarity * 0.12)
        let horizonTint = mix(max(sky.horizonTint, SIMD3<Float>(repeating: 0.0)),
                              baseSkyTint * mix(max(sky.horizonTint, SIMD3<Float>(repeating: 0.0)),
                                                duskTint,
                                                0.14 + twilightFactor * 0.4),
                              0.42 + horizonDensity * 0.08)
        let warmSunTint = SIMD3<Float>(1.0, 0.72, 0.46)
        let highSunTint = SIMD3<Float>(1.0, 0.985, 0.94)
        let lowSunGoldTint = SIMD3<Float>(1.0, 0.62, 0.30)
        let deepExtinctionTint = SIMD3<Float>(1.0, 0.54, 0.30)
        let sunTint = mix(highSunTint, warmSunTint, sunWarmth)
        let goldenExtinctionTint = mix(lowSunGoldTint, deepExtinctionTint, solarExtinction * 0.55)
        let solarExtinctionTint = mix(sunTint, goldenExtinctionTint, solarExtinction)
        let horizonAtmosphereTint = mix(horizonTint, duskTint, twilightFactor * 0.38)
        let atmosphereTint = mix(mix(ambientTint, antiSolarTint, skyCoolness * 0.16),
                                 horizonAtmosphereTint,
                                 horizonBlend)
        let sunForwardHazeTint = mix(horizonAtmosphereTint, solarExtinctionTint, 0.24 + sunScatterStrength * 0.36)
        // Keep the sun disk shaping relative to the sky model itself. Authored sky intensity
        // is applied once later by the shared procedural sky radiance path, so it should not
        // be baked into this relative sun-vs-sky term as well.
        let sunDiskIntensity = max(0.4, (8.0 + sunScatterStrength * 2.8 + twilightFactor * 0.8) * solarVisibility)
        let sunLightColor = mix(solarExtinctionTint,
                                sunForwardHazeTint,
                                hazeAmount * 0.22 + twilightFactor * 0.12)
        // Keep the direct sun tied to the same atmosphere cues as the visible sky without
        // attempting full physical calibration yet. The directional light should track the
        // procedural sun disk closely enough that the sky does not feel much hotter than the
        // scene lighting, while still leaving room for the sky dome + IBL to provide fill.
        let sunLightRelativeStrength = 0.32
            + dayNightFactor * 0.24
            + solarVisibility * 0.18
            + (1.0 - hazeAmount) * 0.06
        let sunLightIntensity = max(0.0,
                                    sky.intensity
                                        * sunDiskIntensity
                                        * sunLightRelativeStrength)
            * solarVisibility
        let fogCandidateTint = mix(mix(atmosphereTint, antiSolarTint, skyCoolness * 0.18),
                                   sunForwardHazeTint,
                                   hazeAmount * 0.45 + twilightFactor * 0.18)
        let fogHorizonTint = mix(horizonAtmosphereTint,
                                 sunForwardHazeTint,
                                 0.35 + horizonDensity * 0.22 + twilightFactor * 0.12)
        let cloudLightTint = mix(neutralTint, solarExtinctionTint, saturate(0.32 + twilightFactor * 0.38 + sunWarmth * 0.18))

        return AtmosphereDerivedSettings(
            sunDirectionWorld: sunDirectionWorld,
            sunRayDirectionWorld: sunRayDirectionWorld,
            sunDirectionSkySpace: sunDirectionSkySpace,
            normalizedSunHeight: normalizedSunHeight,
            dayNightFactor: dayNightFactor,
            twilightFactor: twilightFactor,
            nightFactor: nightFactor,
            sunWarmth: sunWarmth,
            hazeAmount: hazeAmount,
            horizonBlend: horizonBlend,
            horizonDensity: horizonDensity,
            zenithClarity: zenithClarity,
            solarVisibility: solarVisibility,
            solarExtinctionTint: solarExtinctionTint,
            moonDirectionWorld: moonDirectionWorld,
            moonDirectionSkySpace: moonDirectionSkySpace,
            moonVisibility: moonVisibility,
            moonTint: moonTint,
            moonDiskIntensity: moonDiskIntensity,
            duskTint: duskTint,
            antiSolarTint: antiSolarTint,
            skyCoolness: skyCoolness,
            starVisibility: starVisibility,
            sunScatterStrength: sunScatterStrength,
            ambientTint: ambientTint,
            zenithTint: zenithTint,
            horizonTint: horizonTint,
            sunTint: sunTint,
            sunDiskIntensity: sunDiskIntensity,
            sunLightColor: sunLightColor,
            sunLightIntensity: sunLightIntensity,
            sunForwardHazeTint: sunForwardHazeTint,
            atmosphereTint: atmosphereTint,
            fogCandidateTint: fogCandidateTint,
            fogHorizonTint: fogHorizonTint,
            cloudLightTint: cloudLightTint
        )
    }

    /// Legacy compatibility wrapper. The normal runtime path should call
    /// `derivedAtmosphere(authored:runtime:)` with `EnvironmentStateComponent`.
    public static func derivedAtmosphere(from sky: SkyLightComponent) -> AtmosphereDerivedSettings {
        derivedAtmosphere(authored: sky, runtime: nil)
    }

    /// Builds the shared procedural sky shader inputs used by both the visible sky path and
    /// the generated cubemap path so they stay visually aligned.
    public static func shaderParams(authored sky: SkyLightComponent,
                                    runtime environment: EnvironmentStateComponent?) -> SkyParams {
        var params = SkyParams()
        let derivedAtmosphere = derivedAtmosphere(authored: sky, runtime: environment)
        let hazeBlend = SIMD3<Float>(repeating: derivedAtmosphere.hazeAmount)
        let ambientTint = max(derivedAtmosphere.ambientTint, SIMD3<Float>(repeating: 0.0))
        let zenithTint = max(derivedAtmosphere.zenithTint, SIMD3<Float>(repeating: 0.0))
        let horizonTint = max(derivedAtmosphere.horizonTint, SIMD3<Float>(repeating: 0.0))
        let atmosphereTint = max(derivedAtmosphere.atmosphereTint, SIMD3<Float>(repeating: 0.0))
        let sunForwardHazeTint = max(derivedAtmosphere.sunForwardHazeTint, SIMD3<Float>(repeating: 0.0))
        let solarExtinctionTint = max(derivedAtmosphere.solarExtinctionTint, SIMD3<Float>(repeating: 0.0))
        let duskTint = max(derivedAtmosphere.duskTint, SIMD3<Float>(repeating: 0.0))
        let antiSolarTint = max(derivedAtmosphere.antiSolarTint, SIMD3<Float>(repeating: 0.0))
        let cloudPhase = environment?.cloudPhase ?? 0.0
        let windPhase = environment?.windPhase ?? 0.0
        let authoredWindDirection = simd_length_squared(sky.cloudsWindDirection) > 0.0001
            ? simd_normalize(sky.cloudsWindDirection)
            : SIMD2<Float>(1.0, 0.0)
        let windAngle = windPhase * (Float.pi * 2.0)
        let rotatedWindDirection = SIMD2<Float>(
            authoredWindDirection.x * cos(windAngle) - authoredWindDirection.y * sin(windAngle),
            authoredWindDirection.x * sin(windAngle) + authoredWindDirection.y * cos(windAngle)
        )
        let cloudTime = abs(sky.cloudsSpeed) > 0.0001 ? (cloudPhase / max(abs(sky.cloudsSpeed), 0.0001)) : 0.0
        let weatherInputs = resolvedWeatherInputs(authored: sky, runtime: environment)
        let weatherProfile = resolvedWeatherProfile(primary: weatherInputs.primary,
                                                     secondary: weatherInputs.secondary,
                                                     blend: weatherInputs.blend)
        let weatherAmount = saturate(weatherInputs.amount)
        let hazeAmount = derivedAtmosphere.hazeAmount
        let densityProxy = saturate((max(sky.turbidity, 1.0) - 1.0) / 9.0)
        let weatherAerosol = saturate((weatherProfile.turbidity - 1.9) / 5.1) * weatherAmount
        let aerosolDensity = saturate(hazeAmount * 0.58 + densityProxy * 0.18 + weatherAerosol * 0.24)
        let lowSunOpticalBoost = saturate(1.0 - derivedAtmosphere.dayNightFactor + derivedAtmosphere.twilightFactor * 0.45)
        let goldenHourFactor = saturate((1.0 - derivedAtmosphere.dayNightFactor) * (1.0 - derivedAtmosphere.nightFactor) + derivedAtmosphere.twilightFactor * 0.72)
        let rayleighStrength = max(0.62, 1.0 - aerosolDensity * 0.20 - derivedAtmosphere.nightFactor * 0.06)
        let mieStrength = min(max(0.12 + aerosolDensity * 0.62 + weatherAmount * 0.08 + derivedAtmosphere.twilightFactor * 0.08, 0.08), 0.95)
        let mieAnisotropy = min(max(0.76 + aerosolDensity * 0.10 + derivedAtmosphere.twilightFactor * 0.03, 0.72), 0.90)
        let lowSunRadianceLift = goldenHourFactor * (1.0 - derivedAtmosphere.nightFactor) * (0.12 + aerosolDensity * 0.10 + derivedAtmosphere.sunScatterStrength * 0.08)
        let horizonOpticalDepth = min(max(1.08 + aerosolDensity * 1.85 + lowSunOpticalBoost * 0.52 + derivedAtmosphere.horizonDensity * 0.46 - goldenHourFactor * 0.18, 0.72), 4.35)
        let twilightOzoneAmount = min(max(0.24 + derivedAtmosphere.twilightFactor * 0.52 + derivedAtmosphere.nightFactor * 0.14 - aerosolDensity * 0.08, 0.05), 1.0)
        // This is an atmosphere/body shaping scale, not authored source intensity.
        // `params.intensity` is applied once by the shared visible/capture evaluator.
        let skyRadianceScale = 0.96 + derivedAtmosphere.dayNightFactor * 0.04 + lowSunRadianceLift
        let sunDiskRadiance = max(0.0, derivedAtmosphere.sunDiskIntensity * skyRadianceScale * (0.88 + derivedAtmosphere.solarVisibility * 0.12))
        let sunAureoleStrength = min(max(0.14 + aerosolDensity * 0.60 + lowSunOpticalBoost * 0.30 + derivedAtmosphere.sunScatterStrength * 0.30 + goldenHourFactor * 0.20, 0.0), 1.45)
        let groundBounceStrength = min(max(0.04 + derivedAtmosphere.horizonDensity * 0.08 + weatherAmount * 0.03, 0.0), 0.22)

        // SkyParams directions are in world/cubemap sampling space. The generated environment
        // cubemap must place the sun at the same direction that runtime IBL samples with R.
        params.sunDirection = derivedAtmosphere.sunDirectionSkySpace
        params.sunAngularRadius = max(0.0001, sky.sunSizeDegrees * Float.pi / 180.0)
        params.sunColor = solarExtinctionTint
        params.sunIntensity = derivedAtmosphere.sunDiskIntensity
        params.turbidity = max(1.0, sky.turbidity)
        params.intensity = max(0.0, sky.intensity)
        params.skyTime = cloudTime
        params.skyTint = simd_mix(max(sky.skyTint, SIMD3<Float>(repeating: 0.0)),
                                  atmosphereTint,
                                  SIMD3<Float>(repeating: 0.16 + derivedAtmosphere.hazeAmount * 0.08 + derivedAtmosphere.nightFactor * 0.08))
        params.zenithTint = simd_mix(max(sky.zenithTint, SIMD3<Float>(repeating: 0.0)),
                                     simd_mix(zenithTint,
                                              antiSolarTint,
                                              SIMD3<Float>(repeating: derivedAtmosphere.skyCoolness * 0.18)),
                                     SIMD3<Float>(repeating: 0.28 + (1.0 - derivedAtmosphere.zenithClarity) * 0.18 + derivedAtmosphere.twilightFactor * 0.08))
        params.horizonTint = simd_mix(max(sky.horizonTint, SIMD3<Float>(repeating: 0.0)),
                                      simd_mix(simd_mix(horizonTint,
                                                        duskTint,
                                                        SIMD3<Float>(repeating: derivedAtmosphere.twilightFactor * 0.24)),
                                               sunForwardHazeTint,
                                               SIMD3<Float>(repeating: derivedAtmosphere.sunScatterStrength * 0.28 + derivedAtmosphere.horizonDensity * 0.12)),
                                      SIMD3<Float>(repeating: 0.46 + derivedAtmosphere.horizonDensity * 0.12))
        params.gradientStrength = min(max(sky.gradientStrength, 0.15), 1.5) * (0.94 + derivedAtmosphere.horizonDensity * 0.08)
        params.hazeDensity = min(max(sky.hazeDensity, 0.0), 1.25) * (0.88 + derivedAtmosphere.sunScatterStrength * 0.1 + derivedAtmosphere.horizonDensity * 0.12)
        params.hazeFalloff = min(max(sky.hazeFalloff, 0.75), 4.5)
        params.hazeHeight = sky.hazeHeight * 0.72 + derivedAtmosphere.horizonBlend * 0.06 + derivedAtmosphere.horizonDensity * 0.08 + (1.0 - derivedAtmosphere.zenithClarity) * 0.03
        params.ozoneStrength = min(max(sky.ozoneStrength, 0.0), 1.5)
        params.ozoneTint = simd_mix(max(sky.ozoneTint, SIMD3<Float>(repeating: 0.0)),
                                    simd_mix(ambientTint,
                                             antiSolarTint,
                                             SIMD3<Float>(repeating: derivedAtmosphere.skyCoolness * 0.16)),
                                    hazeBlend * SIMD3<Float>(repeating: 0.2) + SIMD3<Float>(repeating: 0.1))
        params.sunHaloSize = max(0.1, sky.sunHaloSize)
        params.sunHaloIntensity = max(0.0, sky.sunHaloIntensity) * (0.72 + derivedAtmosphere.sunScatterStrength * 0.36 + derivedAtmosphere.horizonDensity * 0.12) * (0.35 + derivedAtmosphere.solarVisibility * 0.65)
        params.sunHaloSoftness = max(0.15, sky.sunHaloSoftness)
        params.dayNightFactor = derivedAtmosphere.dayNightFactor
        params.twilightFactor = derivedAtmosphere.twilightFactor
        params.nightFactor = derivedAtmosphere.nightFactor
        params.solarVisibility = derivedAtmosphere.solarVisibility
        params.horizonDensity = derivedAtmosphere.horizonDensity
        params.skyCoolness = derivedAtmosphere.skyCoolness
        params.starVisibility = derivedAtmosphere.starVisibility
        params.moonPhase = 0.5
        params.solarExtinctionTint = solarExtinctionTint
        params.moonIlluminatedFraction = 1.0
        params.moonDirection = derivedAtmosphere.moonDirectionSkySpace
        params.moonAngularRadius = max(0.0001, sky.moonSizeDegrees * Float.pi / 180.0)
        params.moonColor = max(derivedAtmosphere.moonTint, SIMD3<Float>(repeating: 0.0))
        params.moonIntensity = derivedAtmosphere.moonDiskIntensity
        params.duskTint = duskTint
        params.celestialCaptureScale = NightCelestialModel.celestialCaptureScale
        params.antiSolarTint = antiSolarTint
        params.moonIrradiance = derivedAtmosphere.moonDiskIntensity
            * DaytimeAtmosphereModel.projectedSolidAngle(radiusRadians: params.moonAngularRadius)
        params.starIntensity = max(0.0, sky.starIntensity)
        params.celestialArtParams = SIMD4<Float>(
            min(max(sky.starRichness, 0.0), 3.0),
            min(max(sky.milkyWayIntensity, 0.0), 3.0),
            min(max(sky.milkyWayChroma, 0.0), 3.0),
            min(max(sky.nightBrightness, 0.0), 3.0)
        )
        params.milkyWayParams = SIMD4<Float>(sky.milkyWayRotation, 0.0, 0.0, 0.0)
        params.moonTextureEnabled = 0.0
        params.cloudsEnabled = sky.cloudsEnabled ? 1 : 0
        params.cloudsCoverage = min(max(sky.cloudsCoverage, 0.0), 1.0)
        params.cloudsSoftness = min(max(sky.cloudsSoftness, 0.01), 1.0)
        params.cloudsScale = max(0.01, sky.cloudsScale)
        params.cloudsSpeed = sky.cloudsSpeed
        params.cloudsWindDirection = rotatedWindDirection
        params.cloudsHeight = min(max(sky.cloudsHeight, 0.0), 1.0)
        params.cloudsThickness = min(max(sky.cloudsThickness, 0.0), 1.0)
        params.cloudsBrightness = max(0.0, sky.cloudsBrightness) * (0.92 + derivedAtmosphere.hazeAmount * 0.12)
        params.cloudsSunInfluence = max(0.0, sky.cloudsSunInfluence) * (0.9 + derivedAtmosphere.sunWarmth * 0.2)
        params.cloudAtlasStyle = Float(sky.cloudStyle.rawValue)
        params.atmosphereScatteringParams = SIMD4<Float>(rayleighStrength, mieStrength, mieAnisotropy, aerosolDensity)
        params.atmosphereOpticalParams = SIMD4<Float>(horizonOpticalDepth, twilightOzoneAmount, skyRadianceScale, sunDiskRadiance)
        params.sunAureoleParams = SIMD4<Float>(sunAureoleStrength, groundBounceStrength, 0.0, 0.0)
        // Phase 4 daytime contract. Legacy SkyLight authoring is mapped into the
        // same production model so there is no second evaluator hidden behind
        // the compatibility component.
        let sourceEV = log2(max(sky.intensity, 0.0001))
        let daytime = DaytimeAtmosphereModel.Parameters(
            sourceEV: sourceEV,
            densityScale: max(0.05, min(sky.turbidity / 2.5, 4.0)),
            aerosolScale: 0.55 + aerosolDensity * 1.9,
            ozoneScale: max(sky.ozoneStrength, 0),
            multipleScatteringStrength: 0.85 + saturate(sky.atmosphereAmount) * 0.55,
            groundAlbedo: DaytimeAtmosphereModel.groundAlbedo,
            solarAngularRadiusRadians: DaytimeAtmosphereModel.solarAngularRadiusDegrees * .pi / 180
        )
        let solar = DaytimeAtmosphereModel.solarIrradiance(
            sunDirection: derivedAtmosphere.sunDirectionWorld,
            parameters: daytime
        )
        let topDisk = DaytimeAtmosphereModel.topSolarDiskRadianceRGB(
            radiusRadians: daytime.solarAngularRadiusRadians
        )
        let diskLuminance = max(DaytimeAtmosphereModel.rec709Luminance(topDisk), 1e-7)
        params.sunAngularRadius = daytime.solarAngularRadiusRadians
        params.sunColor = topDisk / diskLuminance
        params.sunIntensity = diskLuminance
        params.intensity = DaytimeAtmosphereModel.sourceScale(sourceEV: daytime.sourceEV)
        params.solarVisibility = solar.horizonVisibility
        params.solarExtinctionTint = solar.transmittance
        params.atmosphereScatteringParams = SIMD4<Float>(
            daytime.densityScale,
            daytime.aerosolScale,
            DaytimeAtmosphereModel.mieAnisotropy,
            daytime.ozoneScale
        )
        params.atmosphereOpticalParams = SIMD4<Float>(
            DaytimeAtmosphereModel.referenceTopSolarIlluminance,
            daytime.multipleScatteringStrength,
            daytime.groundAlbedo,
            0
        )
        params.sunAureoleParams = .zero
        return params
    }

    /// Legacy compatibility wrapper. The normal runtime path should pass
    /// `EnvironmentStateComponent` directly.
    public static func shaderParams(from sky: SkyLightComponent, skyTime: Float) -> SkyParams {
        var params = shaderParams(authored: sky, runtime: nil)
        params.skyTime = skyTime
        return params
    }

    /// Deterministic compatibility migration for legacy SkyLight fog fields.
    /// The old independently derived sky/horizon/sun colors are intentionally inert: the
    /// production Phase 5 path derives illumination from the current environment resources.
    public static func applyDerivedFogSettings(_ settings: inout RendererSettings,
                                               authored sky: SkyLightComponent?,
                                               runtime environment: EnvironmentStateComponent?) {
        guard let sky, sky.enabled else {
            settings.setHeightFogEnabled(false)
            return
        }
        settings.localFogParameters = LocalFogTransport.Parameters(
            enabled: sky.fogAmount > 0.0001,
            extinction: max(sky.fogAmount, 0),
            scatteringAlbedo: SIMD3<Float>(repeating: 0.9),
            baseHeight: sky.fogHeight,
            scaleHeight: max(sky.fogDistance, 0.001),
            anisotropy: 0.2
        )
        let derivedAtmosphere = derivedAtmosphere(authored: sky, runtime: environment)
        settings.aerialFogSunDirection = derivedAtmosphere.sunDirectionWorld
        settings.aerialFogSunColor = .zero
    }

    public static func applyDerivedFogSettings(_ settings: inout RendererSettings, for sky: SkyLightComponent?) {
        applyDerivedFogSettings(&settings, authored: sky, runtime: nil)
    }

    public static func requiresIBLRebuild(previous: SkyLightComponent, next: SkyLightComponent) -> Bool {
        if previous.mode != next.mode { return true }
        if previous.hdriHandle != next.hdriHandle { return true }
        return false
    }

    public static func liveSkyParamsMatch(_ lhs: SkyLightComponent, _ rhs: SkyLightComponent) -> Bool {
        return lhs.timeOfDay == rhs.timeOfDay
            && lhs.weatherType == rhs.weatherType
            && lhs.weatherAmount == rhs.weatherAmount
            && lhs.atmosphereAmount == rhs.atmosphereAmount
            && lhs.cloudCoverage == rhs.cloudCoverage
            && lhs.cloudStyle == rhs.cloudStyle
            && lhs.temperature == rhs.temperature
            && lhs.mood == rhs.mood
            && lhs.moonIntensity == rhs.moonIntensity
            && lhs.moonSizeDegrees == rhs.moonSizeDegrees
            && lhs.starIntensity == rhs.starIntensity
            && lhs.starRichness == rhs.starRichness
            && lhs.milkyWayIntensity == rhs.milkyWayIntensity
            && lhs.milkyWayChroma == rhs.milkyWayChroma
            && lhs.milkyWayRotation == rhs.milkyWayRotation
            && lhs.nightBrightness == rhs.nightBrightness
            && lhs.intensity == rhs.intensity
            && lhs.skyTint == rhs.skyTint
            && lhs.turbidity == rhs.turbidity
            && lhs.azimuthDegrees == rhs.azimuthDegrees
            && lhs.elevationDegrees == rhs.elevationDegrees
            && lhs.sunSizeDegrees == rhs.sunSizeDegrees
            && lhs.zenithTint == rhs.zenithTint
            && lhs.horizonTint == rhs.horizonTint
            && lhs.gradientStrength == rhs.gradientStrength
            && lhs.hazeDensity == rhs.hazeDensity
            && lhs.hazeFalloff == rhs.hazeFalloff
            && lhs.hazeHeight == rhs.hazeHeight
            && lhs.ozoneStrength == rhs.ozoneStrength
            && lhs.ozoneTint == rhs.ozoneTint
            && lhs.sunHaloSize == rhs.sunHaloSize
            && lhs.sunHaloIntensity == rhs.sunHaloIntensity
            && lhs.sunHaloSoftness == rhs.sunHaloSoftness
            && lhs.cloudsEnabled == rhs.cloudsEnabled
            && lhs.cloudsCoverage == rhs.cloudsCoverage
            && lhs.cloudsSoftness == rhs.cloudsSoftness
            && lhs.cloudsScale == rhs.cloudsScale
            && lhs.cloudsSpeed == rhs.cloudsSpeed
            && lhs.cloudsWindDirection == rhs.cloudsWindDirection
            && lhs.cloudsHeight == rhs.cloudsHeight
            && lhs.cloudsThickness == rhs.cloudsThickness
            && lhs.cloudsBrightness == rhs.cloudsBrightness
            && lhs.cloudsSunInfluence == rhs.cloudsSunInfluence
    }

    public static func update(scene: EngineScene) {
        if updateEnvironmentSun(scene: scene) {
            return
        }

        updateLegacySkySun(scene: scene)
    }

    @discardableResult
    private static func updateEnvironmentSun(scene: EngineScene) -> Bool {
        let ecs = scene.ecs
        guard let (environmentEntity, environment) = ecs.activeEnvironment() else {
            return false
        }
        guard environment.enabled, environment.source.mode == .procedural else {
            disableSkySunIfNeeded(in: ecs)
            return true
        }

        let runtime = ecs.get(EnvironmentRuntimeStateComponent.self, for: environmentEntity)
        let renderState = ecs.get(EnvironmentFrameStateComponent.self, for: environmentEntity)?.renderState
            ?? EnvironmentRenderStateBuilder.build(environment: environment, runtime: runtime)
        let sunEntity = ecs.firstEntity(with: SkySunTag.self) ?? createSunLight(in: ecs, name: "Environment Key Light")
        let lightRayDirection = -renderState.directionalLightDirection

        var light = ecs.get(LightComponent.self, for: sunEntity) ?? LightComponent(type: .directional)
        light.type = .directional
        light.direction = lightRayDirection
        light.data.color = max(renderState.directionalLightColor, SIMD3<Float>(repeating: 0.0))
        light.data.brightness = renderState.directionalLightIntensity
        light.data.diffuseIntensity = 1.0
        light.data.specularIntensity = 1.0
        // One runtime-derived Environment key light owns the cascaded map. The
        // authoritative frame selects Sun or Moon, and this same direction owns
        // both its light data and shadow matrices.
        light.castsShadows = renderState.directionalLightIntensity > 1e-10
        ecs.add(light, to: sunEntity)

        var transform = ecs.get(TransformComponent.self, for: sunEntity) ?? TransformComponent()
        transform.rotation = TransformMath.rotationForDirectionalLight(direction: lightRayDirection)
        _ = scene.transformAuthority.setLocalTransform(entity: sunEntity,
                                                       transform: transform,
                                                       source: .engineSystem)
        if ecs.get(NameComponent.self, for: sunEntity) == nil {
            ecs.add(NameComponent(name: "Environment Key Light"), to: sunEntity)
        }
        return true
    }

    private static func updateLegacySkySun(scene: EngineScene) {
        let ecs = scene.ecs
        guard let (skyEntity, sky) = ecs.activeSkyLight() else {
            disableSkySunIfNeeded(in: ecs)
            return
        }
        guard sky.enabled, sky.mode == .procedural else {
            disableSkySunIfNeeded(in: ecs)
            return
        }

        // sunDir points from world origin toward the visible sun disc.
        // Directional light rays travel from sun to scene, so ray direction is -sunDir.
        let sunEntity = ecs.firstEntity(with: SkySunTag.self) ?? createSunLight(in: ecs, name: "Sun")
        let environment = ecs.get(EnvironmentStateComponent.self, for: skyEntity)
        let derivedAtmosphere = derivedAtmosphere(authored: sky, runtime: environment)
        let params = shaderParams(authored: sky, runtime: environment)
        let lightRayDirection = derivedAtmosphere.sunRayDirectionWorld
        let solarRGB = DaytimeAtmosphereModel.topSolarIrradianceRGB()
            * params.solarExtinctionTint
            * params.solarVisibility
            * params.intensity
        let solarIlluminance = max(DaytimeAtmosphereModel.rec709Luminance(solarRGB), 0)

        var light = ecs.get(LightComponent.self, for: sunEntity) ?? LightComponent(type: .directional)
        light.type = .directional
        light.direction = lightRayDirection
        light.data.color = solarIlluminance > 1e-7
            ? max(solarRGB / solarIlluminance, SIMD3<Float>(repeating: 0.0))
            : .zero
        light.data.brightness = solarIlluminance
        light.data.diffuseIntensity = 1.0
        light.data.specularIntensity = 1.0
        ecs.add(light, to: sunEntity)

        var transform = ecs.get(TransformComponent.self, for: sunEntity) ?? TransformComponent()
        transform.rotation = TransformMath.rotationForDirectionalLight(direction: lightRayDirection)
        _ = scene.transformAuthority.setLocalTransform(entity: sunEntity,
                                                       transform: transform,
                                                       source: .engineSystem)
        if ecs.get(NameComponent.self, for: sunEntity) == nil {
            ecs.add(NameComponent(name: "Sun"), to: sunEntity)
        }
    }

    private static func disableSkySunIfNeeded(in scene: SceneECS) {
        guard let sunEntity = scene.firstEntity(with: SkySunTag.self),
              var light = scene.get(LightComponent.self, for: sunEntity)
        else { return }
        light.data.brightness = 0.0
        scene.add(light, to: sunEntity)
    }

    private static func createSunLight(in scene: SceneECS, name: String) -> Entity {
        let entity = scene.createEntity(name: name)
        scene.add(SkySunTag(), to: entity)
        scene.add(LightComponent(type: .directional), to: entity)
        return entity
    }
}

// Future extensions:
// - Multiple skies: add priority/stacking and blend sky contributions.
// - Separate sun intensity: decouple sky intensity from sun light brightness.
// - Sky LUT caching: cache procedural sky cubemap by params hash.
// - Async IBL generation: move cubemap/irradiance/prefilter to background queue.
