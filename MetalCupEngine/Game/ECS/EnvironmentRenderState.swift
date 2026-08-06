/// EnvironmentRenderState.swift
/// Defines renderer-facing environment derivation for the new environment model.
/// Created by OpenAI.

import Foundation
import simd

public struct EnvironmentFogRenderPatch: Equatable {
    public var heightFogEnabled: Bool
    public var heightFogBaseHeight: Float
    public var heightFogDensity: Float
    public var heightFogHeightFalloff: Float
    public var heightFogColor: SIMD3<Float>
    public var heightFogStartDistance: Float
    public var heightFogDistanceDensity: Float
    public var heightFogColorMode: FogColorMode
    public var fogSkyMatchColor: SIMD3<Float>
    public var fogSkyHorizonColor: SIMD3<Float>
    public var fogSkySunScatterStrength: Float
    public var heightFogPadding: SIMD2<Float>
    public var padding0: SIMD4<Float>
    public var padding1: SIMD4<Float>
    public var aerialFogSunDirectionAndNight: SIMD4<Float>
    public var aerialFogSunColorAndStrength: SIMD4<Float>
    public var aerialFogParams: SIMD4<Float>

    public init(settings: RendererSettings) {
        self.heightFogEnabled = settings.isHeightFogEnabled
        self.heightFogBaseHeight = settings.heightFogBaseHeight
        self.heightFogDensity = settings.heightFogDensity
        self.heightFogHeightFalloff = settings.heightFogHeightFalloff
        self.heightFogColor = settings.heightFogColor
        self.heightFogStartDistance = settings.heightFogStartDistance
        self.heightFogDistanceDensity = settings.heightFogDistanceDensity
        self.heightFogColorMode = settings.heightFogColorMode
        self.fogSkyMatchColor = settings.fogSkyMatchColor
        self.fogSkyHorizonColor = settings.fogSkyHorizonColor
        self.fogSkySunScatterStrength = settings.fogSkySunScatterStrength
        self.heightFogPadding = settings.heightFogPadding
        self.padding0 = settings.padding0
        self.padding1 = settings.padding1
        self.aerialFogSunDirectionAndNight = settings.aerialFogSunDirectionAndNight
        self.aerialFogSunColorAndStrength = settings.aerialFogSunColorAndStrength
        self.aerialFogParams = settings.aerialFogParams
    }

    public func applying(to settings: inout RendererSettings) {
        settings.setHeightFogEnabled(heightFogEnabled)
        settings.heightFogBaseHeight = heightFogBaseHeight
        settings.heightFogDensity = heightFogDensity
        settings.heightFogHeightFalloff = heightFogHeightFalloff
        settings.heightFogColor = heightFogColor
        settings.heightFogStartDistance = heightFogStartDistance
        settings.heightFogDistanceDensity = heightFogDistanceDensity
        settings.setHeightFogColorMode(heightFogColorMode)
        settings.setFogSkyMatchColor(fogSkyMatchColor)
        settings.setFogSkyHorizonColor(fogSkyHorizonColor)
        settings.setFogSkySunScatterStrength(fogSkySunScatterStrength)
        settings.heightFogPadding = heightFogPadding
        settings.padding0 = padding0
        settings.padding1 = padding1
        settings.aerialFogSunDirectionAndNight = aerialFogSunDirectionAndNight
        settings.aerialFogSunColorAndStrength = aerialFogSunColorAndStrength
        settings.aerialFogParams = aerialFogParams
    }
}

public struct EnvironmentCloudRenderParams: Equatable {
    public var enabled: Bool
    public var coverage: Float
    public var style: EnvironmentCloudStyle
    public var softness: Float
    public var scale: Float
    public var speed: Float
    public var windDirection: SIMD2<Float>
    public var shaderWindDirection: SIMD2<Float>
    public var height: Float
    public var thickness: Float
    public var brightness: Float
    public var sunInfluence: Float
    public var cloudPhase: Float
    public var windPhase: Float
    public var skyTime: Float

    public init(enabled: Bool,
                coverage: Float,
                style: EnvironmentCloudStyle,
                softness: Float,
                scale: Float,
                speed: Float,
                windDirection: SIMD2<Float>,
                shaderWindDirection: SIMD2<Float>,
                height: Float,
                thickness: Float,
                brightness: Float,
                sunInfluence: Float,
                cloudPhase: Float,
                windPhase: Float,
                skyTime: Float) {
        self.enabled = enabled
        self.coverage = coverage
        self.style = style
        self.softness = softness
        self.scale = scale
        self.speed = speed
        self.windDirection = windDirection
        self.shaderWindDirection = shaderWindDirection
        self.height = height
        self.thickness = thickness
        self.brightness = brightness
        self.sunInfluence = sunInfluence
        self.cloudPhase = cloudPhase
        self.windPhase = windPhase
        self.skyTime = skyTime
    }
}

public struct EnvironmentRenderState {
    public var enabled: Bool
    public var sourceMode: EnvironmentSourceMode
    public var hdriTextureHandle: AssetHandle?
    public var finalTimeOfDay: Float
    public var weatherPrimary: EnvironmentWeatherType
    public var weatherSecondary: EnvironmentWeatherType
    public var weatherBlend: Float
    public var weatherAmount: Float
    public var atmosphereAmount: Float
    public var atmosphereHaze: Float
    public var atmosphereDensity: Float
    public var atmosphereTemperature: Float
    public var atmosphereMood: Float
    public var lookMood: Float
    public var lookWarmth: Float
    public var lookCinematicAmount: Float
    public var cloudCoverage: Float
    public var cloudStyle: EnvironmentCloudStyle
    public var cloudRenderMode: EnvironmentCloudRenderMode
    public var cloudRenderParams: EnvironmentCloudRenderParams
    public var cloudPhase: Float
    public var windPhase: Float
    public var fogAmount: Float
    public var fogHeight: Float
    public var fogDistance: Float
    public var moonIntensity: Float
    public var moonSizeDegrees: Float
    public var starIntensity: Float
    public var starRichness: Float
    public var milkyWayIntensity: Float
    public var milkyWayChroma: Float
    public var milkyWayRotation: Float
    public var nightBrightness: Float
    /// World-space unit vector from the scene toward the visible sun.
    public var sunDirection: SIMD3<Float>
    public var sunColor: SIMD3<Float>
    public var sunIntensity: Float
    public var moonDirection: SIMD3<Float>
    public var moonColor: SIMD3<Float>
    public var iblLightingIntensity: Float
    public var legacySkyParams: SkyParams
    public var legacyFogPatch: EnvironmentFogRenderPatch
    public var iblSignature: EnvironmentIBLSignature
}

public enum EnvironmentRenderStateBuilder {
    public static func build(environment: EnvironmentComponent,
                             runtime: EnvironmentRuntimeStateComponent?,
                             rendererSettings: RendererSettings? = nil) -> EnvironmentRenderState {
        let resolved = ResolvedEnvironmentInputs(environment: environment, runtime: runtime)
        let legacySky = LegacyEnvironmentSkyAdapter.makeSkyLight(environment: environment, resolved: resolved)
        let legacyRuntime = LegacyEnvironmentSkyAdapter.makeRuntimeState(resolved: resolved)
        let derived = SkySystem.derivedAtmosphere(authored: legacySky, runtime: legacyRuntime)
        var legacySkyParams = SkySystem.shaderParams(authored: legacySky, runtime: legacyRuntime)
        let cloudRenderParams = EnvironmentCloudRenderParamBuilder.make(authored: legacySky,
                                                                         runtime: legacyRuntime,
                                                                         derivedAtmosphere: derived)
        EnvironmentCloudRenderParamBuilder.apply(cloudRenderParams, to: &legacySkyParams)
        if environment.clouds.renderMode == .cards {
            legacySkyParams.cloudsEnabled = 0
            legacySkyParams.cloudsCoverage = 0.0
            legacySkyParams.cloudAtlasEnabled = 0.0
        }
        let legacyFogPatch = makeFogPatch(rendererSettings: rendererSettings,
                                          legacySky: legacySky,
                                          legacyRuntime: legacyRuntime)

        var state = EnvironmentRenderState(
            enabled: environment.enabled,
            sourceMode: environment.source.mode,
            hdriTextureHandle: environment.source.hdriTextureHandle,
            finalTimeOfDay: resolved.finalTimeOfDay,
            weatherPrimary: resolved.weatherPrimary,
            weatherSecondary: resolved.weatherSecondary,
            weatherBlend: resolved.weatherBlend,
            weatherAmount: resolved.weatherAmount,
            atmosphereAmount: environment.atmosphere.amount,
            atmosphereHaze: environment.atmosphere.haze,
            atmosphereDensity: environment.atmosphere.density,
            atmosphereTemperature: environment.atmosphere.temperature,
            atmosphereMood: environment.atmosphere.mood,
            lookMood: environment.look.mood,
            lookWarmth: environment.look.warmth,
            lookCinematicAmount: environment.look.cinematicAmount,
            cloudCoverage: environment.clouds.coverage,
            cloudStyle: environment.clouds.style,
            cloudRenderMode: environment.clouds.renderMode,
            cloudRenderParams: cloudRenderParams,
            cloudPhase: resolved.cloudPhase,
            windPhase: resolved.windPhase,
            fogAmount: environment.fog.amount,
            fogHeight: environment.fog.height,
            fogDistance: environment.fog.distance,
            moonIntensity: environment.celestial.moonIntensity,
            moonSizeDegrees: environment.celestial.moonSizeDegrees,
            starIntensity: environment.celestial.starIntensity,
            starRichness: environment.celestial.starRichness,
            milkyWayIntensity: environment.celestial.milkyWayIntensity,
            milkyWayChroma: environment.celestial.milkyWayChroma,
            milkyWayRotation: environment.celestial.milkyWayRotation,
            nightBrightness: environment.celestial.nightBrightness,
            sunDirection: derived.sunDirectionWorld,
            sunColor: max(derived.sunLightColor, SIMD3<Float>(repeating: 0.0)),
            sunIntensity: derived.sunLightIntensity,
            moonDirection: derived.moonDirectionWorld,
            moonColor: max(derived.moonTint, SIMD3<Float>(repeating: 0.0)),
            iblLightingIntensity: EnvironmentLightingBalance.iblIntensity(environment: environment),
            legacySkyParams: legacySkyParams,
            legacyFogPatch: legacyFogPatch,
            iblSignature: EnvironmentIBLSignature()
        )
        state.iblSignature = EnvironmentIBLSignature.make(from: state)
        return state
    }

    public static func legacySkyParams(environment: EnvironmentComponent,
                                       runtime: EnvironmentRuntimeStateComponent?) -> SkyParams {
        build(environment: environment, runtime: runtime).legacySkyParams
    }

    public static func legacyFogPatch(environment: EnvironmentComponent,
                                      runtime: EnvironmentRuntimeStateComponent?,
                                      rendererSettings: RendererSettings? = nil) -> EnvironmentFogRenderPatch {
        build(environment: environment, runtime: runtime, rendererSettings: rendererSettings).legacyFogPatch
    }

    private static func makeFogPatch(rendererSettings: RendererSettings?,
                                     legacySky: SkyLightComponent,
                                     legacyRuntime: EnvironmentStateComponent) -> EnvironmentFogRenderPatch {
        var settings = rendererSettings ?? RendererSettings()
        SkySystem.applyDerivedFogSettings(&settings, authored: legacySky, runtime: legacyRuntime)
        return EnvironmentFogRenderPatch(settings: settings)
    }
}

public extension EnvironmentIBLSignature {
    static func make(from state: EnvironmentRenderState) -> EnvironmentIBLSignature {
        if state.sourceMode == .hdri {
            return EnvironmentIBLSignature(
                enabled: state.enabled,
                sourceMode: state.sourceMode,
                hdriTextureHandle: state.hdriTextureHandle
            )
        }

        return EnvironmentIBLSignature(
            enabled: state.enabled,
            sourceMode: state.sourceMode,
            hdriTextureHandle: nil,
            finalTimeOfDay: exactFloatBits(state.finalTimeOfDay),
            weatherPrimary: state.weatherPrimary.rawValue,
            weatherSecondary: state.weatherSecondary.rawValue,
            weatherBlend: exactFloatBits(min(max(state.weatherBlend, 0), 1)),
            weatherAmount: exactFloatBits(min(max(state.weatherAmount, 0), 1)),
            atmosphereAmount: exactFloatBits(min(max(state.atmosphereAmount, 0), 1)),
            atmosphereHaze: exactFloatBits(min(max(state.atmosphereHaze, 0), 1)),
            atmosphereDensity: exactFloatBits(max(state.atmosphereDensity, 0)),
            atmosphereTemperature: exactFloatBits(state.atmosphereTemperature),
            atmosphereMood: exactFloatBits(state.atmosphereMood),
            lookMood: exactFloatBits(state.lookMood),
            lookWarmth: exactFloatBits(state.lookWarmth),
            lookCinematicAmount: exactFloatBits(max(state.lookCinematicAmount, 0)),
            cloudCoverage: exactFloatBits(min(max(state.cloudCoverage, 0), 1)),
            cloudStyle: state.cloudStyle.rawValue,
            cloudRenderMode: state.cloudRenderMode.rawValue,
            moonIntensity: exactFloatBits(max(state.moonIntensity, 0)),
            moonSizeDegrees: exactFloatBits(max(state.moonSizeDegrees, 0)),
            starIntensity: exactFloatBits(max(state.starIntensity, 0)),
            starRichness: exactFloatBits(max(state.starRichness, 0)),
            milkyWayIntensity: exactFloatBits(max(state.milkyWayIntensity, 0)),
            milkyWayChroma: exactFloatBits(max(state.milkyWayChroma, 0)),
            milkyWayRotation: exactFloatBits(state.milkyWayRotation),
            nightBrightness: exactFloatBits(max(state.nightBrightness, 0))
        )
    }

    private static func exactFloatBits(_ value: Float) -> Int32 {
        guard value.isFinite else { return 0 }
        return Int32(bitPattern: value.bitPattern)
    }
}

private enum EnvironmentCloudRenderParamBuilder {
    static func make(authored sky: SkyLightComponent,
                     runtime environment: EnvironmentStateComponent?,
                     derivedAtmosphere: AtmosphereDerivedSettings) -> EnvironmentCloudRenderParams {
        let cloudPhase = environment?.cloudPhase ?? 0.0
        let windPhase = environment?.windPhase ?? 0.0
        let windDirection = simd_length_squared(sky.cloudsWindDirection) > 0.0001
            ? simd_normalize(sky.cloudsWindDirection)
            : SIMD2<Float>(1.0, 0.0)
        let windAngle = windPhase * (Float.pi * 2.0)
        let shaderWindDirection = SIMD2<Float>(
            windDirection.x * cos(windAngle) - windDirection.y * sin(windAngle),
            windDirection.x * sin(windAngle) + windDirection.y * cos(windAngle)
        )
        let speed = sky.cloudsSpeed
        let skyTime = abs(speed) > 0.0001 ? (cloudPhase / max(abs(speed), 0.0001)) : 0.0

        return EnvironmentCloudRenderParams(
            enabled: sky.cloudsEnabled,
            coverage: clamp(sky.cloudsCoverage, min: 0.0, max: 1.0),
            style: sky.cloudStyle,
            softness: clamp(sky.cloudsSoftness, min: 0.01, max: 1.0),
            scale: max(0.01, sky.cloudsScale),
            speed: speed,
            windDirection: windDirection,
            shaderWindDirection: shaderWindDirection,
            height: clamp(sky.cloudsHeight, min: 0.0, max: 1.0),
            thickness: clamp(sky.cloudsThickness, min: 0.0, max: 1.0),
            brightness: max(0.0, sky.cloudsBrightness) * (0.92 + derivedAtmosphere.hazeAmount * 0.12),
            sunInfluence: max(0.0, sky.cloudsSunInfluence) * (0.9 + derivedAtmosphere.sunWarmth * 0.2),
            cloudPhase: cloudPhase,
            windPhase: windPhase,
            skyTime: skyTime
        )
    }

    static func apply(_ clouds: EnvironmentCloudRenderParams, to params: inout SkyParams) {
        params.skyTime = clouds.skyTime
        params.cloudsEnabled = clouds.enabled ? 1 : 0
        params.cloudsCoverage = clouds.coverage
        params.cloudsSoftness = clouds.softness
        params.cloudsScale = clouds.scale
        params.cloudsSpeed = clouds.speed
        params.cloudsWindDirection = clouds.shaderWindDirection
        params.cloudsHeight = clouds.height
        params.cloudsThickness = clouds.thickness
        params.cloudsBrightness = clouds.brightness
        params.cloudsSunInfluence = clouds.sunInfluence
        params.cloudAtlasStyle = Float(clouds.style.rawValue)
    }

    private static func clamp(_ value: Float, min minimum: Float, max maximum: Float) -> Float {
        Swift.min(Swift.max(value, minimum), maximum)
    }
}

enum EnvironmentLightingBalance {
    /// Captured procedural and HDRI resources already contain their source energy.
    /// Weather, daylight, haze, and mood must never be multiplied into IBL again.
    static func iblIntensity(environment: EnvironmentComponent) -> Float {
        environment.enabled ? 1.0 : 0.0
    }
}

private struct ResolvedEnvironmentInputs {
    var finalTimeOfDay: Float
    var weatherPrimary: EnvironmentWeatherType
    var weatherSecondary: EnvironmentWeatherType
    var weatherBlend: Float
    var weatherAmount: Float
    var cloudPhase: Float
    var windPhase: Float
    var timeControlMode: EnvironmentTimeControlMode
    var dayLengthSeconds: Float
    var timeScale: Float
    var scriptedTimeOfDayOverride: Float?
    var precipitationAmount: Float
    var stormActivity: Float
    var lightningActivity: Float
    var wetnessDriver: Float

    init(environment: EnvironmentComponent, runtime: EnvironmentRuntimeStateComponent?) {
        if let runtime {
            let runtimeTime: Float
            switch runtime.timeControlMode {
            case .scripted:
                runtimeTime = runtime.scriptedTimeOfDayOverride ?? runtime.currentTimeOfDay
            case .fixed, .cycle:
                runtimeTime = runtime.currentTimeOfDay
            }
            self.finalTimeOfDay = runtimeTime
            self.weatherPrimary = runtime.currentWeatherType
            self.weatherSecondary = runtime.targetWeatherType
            self.weatherBlend = runtime.weatherBlend
            self.weatherAmount = runtime.weatherAmount
            self.cloudPhase = runtime.cloudPhase
            self.windPhase = runtime.windPhase
            self.timeControlMode = runtime.timeControlMode
            self.dayLengthSeconds = runtime.dayLengthSeconds
            self.timeScale = runtime.timeScale
            self.scriptedTimeOfDayOverride = runtime.scriptedTimeOfDayOverride
            self.precipitationAmount = runtime.precipitationAmount
            self.stormActivity = runtime.stormActivity
            self.lightningActivity = runtime.lightningActivity
            self.wetnessDriver = runtime.wetnessDriver
        } else {
            self.finalTimeOfDay = environment.celestial.defaultTimeOfDay
            self.weatherPrimary = environment.weather.primaryType
            self.weatherSecondary = environment.weather.secondaryType
            self.weatherBlend = environment.weather.blend
            self.weatherAmount = environment.weather.amount
            self.cloudPhase = 0.0
            self.windPhase = 0.0
            self.timeControlMode = .fixed
            self.dayLengthSeconds = 600.0
            self.timeScale = 1.0
            self.scriptedTimeOfDayOverride = nil
            self.precipitationAmount = 0.0
            self.stormActivity = environment.weather.primaryType == .storm || environment.weather.secondaryType == .storm ? environment.weather.amount : 0.0
            self.lightningActivity = 0.0
            self.wetnessDriver = 0.0
        }
    }
}

private enum LegacyEnvironmentSkyAdapter {
    static func makeSkyLight(environment: EnvironmentComponent,
                             resolved: ResolvedEnvironmentInputs) -> SkyLightComponent {
        let lookMood = clamp(environment.look.mood, min: -1.0, max: 1.0)
        let lookWarmth = clamp(environment.look.warmth, min: -1.0, max: 1.0)
        let lookCinematic = clamp(environment.look.cinematicAmount, min: 0.0, max: 1.0)
        let positiveMood = max(lookMood, 0.0)
        let negativeMood = max(-lookMood, 0.0)
        let atmosphereAmount = clamp(environment.atmosphere.amount + lookCinematic * 0.07 + positiveMood * 0.04, min: 0.0, max: 1.0)
        let atmosphereHaze = clamp(environment.atmosphere.haze + lookCinematic * 0.06 + positiveMood * 0.035 + abs(lookWarmth) * 0.025, min: 0.0, max: 1.0)
        let atmosphereDensity = max(0.0, environment.atmosphere.density * (1.0 + lookCinematic * 0.10 + positiveMood * 0.06 - negativeMood * 0.04))
        let atmosphereTemperature = clamp(environment.atmosphere.temperature + lookWarmth * 0.65 + lookCinematic * max(lookWarmth, 0.0) * 0.18, min: -1.0, max: 1.0)
        let atmosphereMood = clamp(environment.atmosphere.mood + lookMood * 0.70 + lookCinematic * 0.22, min: -1.0, max: 1.0)
        let starIntensity = environment.celestial.starIntensity * (1.0 + lookCinematic * 0.45 + positiveMood * 0.12)
        let starRichness = environment.celestial.starRichness + lookCinematic * 0.35 + positiveMood * 0.12
        let milkyWayIntensity = environment.celestial.milkyWayIntensity * (1.0 + lookCinematic * 0.42 + positiveMood * 0.10)
        let milkyWayChroma = environment.celestial.milkyWayChroma + lookCinematic * 0.20 + max(lookWarmth, 0.0) * 0.06
        let nightBrightness = environment.celestial.nightBrightness * (1.0 + negativeMood * 0.08 - lookCinematic * 0.08)
        var sky = SkyLightComponent(
            mode: skyMode(from: environment.source.mode),
            enabled: environment.enabled,
            hdriHandle: environment.source.hdriTextureHandle,
            timeOfDay: clamp(resolved.finalTimeOfDay, min: 0.0, max: 24.0),
            weatherType: resolved.weatherPrimary,
            secondaryWeatherType: resolved.weatherSecondary,
            weatherBlend: clamp(resolved.weatherBlend, min: 0.0, max: 1.0),
            weatherAmount: clamp(resolved.weatherAmount, min: 0.0, max: 1.0),
            atmosphereAmount: atmosphereAmount,
            cloudCoverage: clamp(environment.clouds.coverage, min: 0.0, max: 1.0),
            cloudStyle: environment.clouds.style,
            temperature: atmosphereTemperature,
            mood: atmosphereMood,
            moonIntensity: environment.celestial.moonIntensity,
            moonSizeDegrees: environment.celestial.moonSizeDegrees,
            starIntensity: starIntensity,
            starRichness: starRichness,
            milkyWayIntensity: milkyWayIntensity,
            milkyWayChroma: milkyWayChroma,
            milkyWayRotation: environment.celestial.milkyWayRotation,
            nightBrightness: nightBrightness,
            fogAmount: clamp(environment.fog.amount * (1.0 + lookCinematic * 0.18 + positiveMood * 0.08), min: 0.0, max: 1.0),
            fogHeight: environment.fog.height,
            fogDistance: environment.fog.distance
        )
        applyPreviewCompatibility(to: &sky,
                                  atmosphereHaze: atmosphereHaze,
                                  atmosphereDensity: atmosphereDensity)
        return sky
    }

    static func makeRuntimeState(resolved: ResolvedEnvironmentInputs) -> EnvironmentStateComponent {
        EnvironmentStateComponent(
            currentTimeOfDay: resolved.finalTimeOfDay,
            timeControlMode: resolved.timeControlMode,
            dayLengthSeconds: resolved.dayLengthSeconds,
            environmentTimeScale: resolved.timeScale,
            currentWeatherType: resolved.weatherPrimary,
            targetWeatherType: resolved.weatherSecondary,
            weatherTransitionProgress: resolved.weatherBlend,
            weatherTransitionDuration: 10.0,
            weatherAmount: resolved.weatherAmount,
            cloudPhase: resolved.cloudPhase,
            windPhase: resolved.windPhase,
            scriptedTimeOfDayOverride: resolved.scriptedTimeOfDayOverride,
            precipitationAmount: resolved.precipitationAmount,
            stormActivity: resolved.stormActivity,
            lightningActivity: resolved.lightningActivity,
            wetnessDriver: resolved.wetnessDriver
        )
    }

    private static func skyMode(from mode: EnvironmentSourceMode) -> SkyMode {
        switch mode {
        case .hdri: return .hdri
        case .procedural: return .procedural
        }
    }

    private static func applyPreviewCompatibility(to sky: inout SkyLightComponent,
                                                  atmosphereHaze: Float,
                                                  atmosphereDensity: Float) {
        let timeOfDay = clamp(sky.timeOfDay, min: 0.0, max: 24.0)
        let weatherBlend = clamp(sky.weatherBlend, min: 0.0, max: 1.0)
        let weatherAmount = clamp(sky.weatherAmount, min: 0.0, max: 1.0)
        let atmosphereAmount = clamp(sky.atmosphereAmount, min: 0.0, max: 1.0)
        let hazeAmount = clamp(atmosphereHaze, min: 0.0, max: 1.0)
        let densityAmount = max(0.0, atmosphereDensity)
        let cloudCoverage = clamp(sky.cloudCoverage, min: 0.0, max: 1.0)
        let temperature = clamp(sky.temperature, min: -1.0, max: 1.0)
        let mood = clamp(sky.mood, min: -1.0, max: 1.0)
        let resolvedWeather = SkySystem.resolvedWeatherProfile(primary: sky.weatherType,
                                                               secondary: sky.secondaryWeatherType,
                                                               blend: weatherBlend)

        sky.timeOfDay = timeOfDay
        sky.weatherBlend = weatherBlend
        sky.weatherAmount = weatherAmount
        sky.atmosphereAmount = atmosphereAmount
        sky.cloudCoverage = cloudCoverage
        sky.temperature = temperature
        sky.mood = mood

        let normalizedTime = timeOfDay / 24.0
        sky.azimuthDegrees = fmodf(normalizedTime * 360.0 + 90.0, 360.0)
        let solarAngle = ((timeOfDay - 6.0) / 12.0) * Float.pi
        let solarHeight = sin(solarAngle)
        sky.elevationDegrees = clamp(solarHeight * 88.0, min: -12.0, max: 88.0)
        sky.sunSizeDegrees = clamp(0.52 + weatherAmount * 0.08, min: 0.35, max: 0.9)

        let targetTurbidity = simd_mix(2.0 + atmosphereAmount * 4.0,
                                       resolvedWeather.turbidity,
                                       weatherAmount)
        var targetCloudCoverage = simd_mix(cloudCoverage,
                                           max(cloudCoverage, resolvedWeather.cloudCoverageFloor),
                                           weatherAmount)
        var targetCloudSoftness = simd_mix(0.55, resolvedWeather.cloudSoftness, weatherAmount)
        var targetCloudScale = simd_mix(1.0, resolvedWeather.cloudScale, weatherAmount)
        var targetCloudThickness = simd_mix(0.32, resolvedWeather.cloudThickness, weatherAmount)
        var targetCloudBrightness = simd_mix(0.95, resolvedWeather.cloudBrightness, weatherAmount)
        var targetCloudSunInfluence = simd_mix(0.9, resolvedWeather.cloudSunInfluence, weatherAmount)
        var targetCloudSpeed = simd_mix(0.02, resolvedWeather.cloudSpeed, weatherAmount)
        let authoredHaze = max(hazeAmount, atmosphereAmount)
        let targetHaze = max(authoredHaze, resolvedWeather.hazeFloor * weatherAmount)
        let targetIntensity = simd_mix(1.0, resolvedWeather.intensity, weatherAmount)

        switch sky.cloudStyle {
        case .clear:
            targetCloudCoverage = 0.0
            targetCloudThickness = 0.22
        case .wispy:
            targetCloudSoftness = max(targetCloudSoftness, 0.68)
            targetCloudScale *= 1.5
            targetCloudThickness = min(targetCloudThickness, 0.24)
            targetCloudBrightness *= 1.05
        case .puffy:
            targetCloudSoftness = max(targetCloudSoftness, 0.55)
        case .layered:
            targetCloudSoftness = max(targetCloudSoftness, 0.72)
            targetCloudScale *= 1.25
            targetCloudThickness = max(targetCloudThickness, 0.44)
        case .overcast:
            targetCloudCoverage = max(targetCloudCoverage, 0.84)
            targetCloudSoftness = max(targetCloudSoftness, 0.82)
            targetCloudThickness = max(targetCloudThickness, 0.55)
            targetCloudSunInfluence = min(targetCloudSunInfluence, 0.4)
        case .storm:
            targetCloudCoverage = max(targetCloudCoverage, 0.88)
            targetCloudScale *= 1.35
            targetCloudThickness = max(targetCloudThickness, 0.65)
            targetCloudBrightness *= 0.88
            targetCloudSunInfluence = min(targetCloudSunInfluence, 0.28)
            targetCloudSpeed = max(targetCloudSpeed, 0.03)
        case .custom:
            break
        }

        let warmth = temperature * 0.18
        let moodShadow = clamp(-mood, min: 0.0, max: 1.0)
        let moodLift = clamp(mood, min: 0.0, max: 1.0)

        sky.intensity = clamp(targetIntensity + mood * 0.16, min: 0.45, max: 1.35)
        sky.skyTint = SIMD3<Float>(1.0 + warmth * 0.45,
                                   1.0 + moodLift * 0.04,
                                   1.0 - warmth * 0.35 - moodShadow * 0.05)
        sky.zenithTint = SIMD3<Float>(0.24 + warmth * 0.05 - moodShadow * 0.08,
                                      0.42 + moodLift * 0.05 - moodShadow * 0.06,
                                      0.78 - warmth * 0.08 + moodLift * 0.08)
        sky.horizonTint = SIMD3<Float>(0.92 + warmth * 0.09,
                                       0.78 + warmth * 0.03 - moodShadow * 0.05,
                                       0.64 - warmth * 0.08 - moodShadow * 0.03)
        sky.gradientStrength = clamp(0.82 + atmosphereAmount * 0.32 + moodLift * 0.12, min: 0.35, max: 1.5)
        sky.hazeDensity = clamp(targetHaze * 1.15 * max(0.0, densityAmount), min: 0.0, max: 1.25)
        sky.hazeFalloff = clamp(1.8 + targetHaze * 1.7 + moodShadow * 0.35, min: 0.75, max: 4.5)
        sky.hazeHeight = clamp((atmosphereAmount - 0.5) * 0.2, min: -0.3, max: 0.3)
        sky.turbidity = clamp((targetTurbidity + atmosphereAmount * 1.2) * max(0.25, densityAmount), min: 1.0, max: 10.0)
        sky.ozoneStrength = clamp(0.42 - warmth * 0.12 + moodLift * 0.08, min: 0.0, max: 1.5)
        sky.ozoneTint = SIMD3<Float>(0.58 - warmth * 0.04,
                                     0.72 - warmth * 0.03,
                                     0.96 + moodLift * 0.05)

        let lowSunFactor = clamp(1.0 - max(sky.elevationDegrees, 0.0) / 90.0, min: 0.0, max: 1.0)
        sky.sunHaloSize = clamp(2.0 + atmosphereAmount * 0.9 + weatherAmount * 0.45, min: 0.5, max: 4.5)
        sky.sunHaloIntensity = clamp(0.3 + atmosphereAmount * 0.22 + lowSunFactor * 0.25 - moodShadow * 0.08, min: 0.0, max: 1.5)
        sky.sunHaloSoftness = clamp(1.1 + atmosphereAmount * 0.5 + weatherAmount * 0.25, min: 0.4, max: 2.4)

        sky.cloudsEnabled = targetCloudCoverage > 0.02 || sky.cloudStyle != .clear
        sky.cloudsCoverage = clamp(targetCloudCoverage, min: 0.0, max: 1.0)
        sky.cloudsSoftness = clamp(targetCloudSoftness, min: 0.01, max: 1.0)
        sky.cloudsScale = clamp(targetCloudScale, min: 0.01, max: 4.0)
        sky.cloudsSpeed = clamp(targetCloudSpeed, min: -0.25, max: 0.25)
        sky.cloudsHeight = clamp(0.22 + moodLift * 0.04, min: 0.0, max: 1.0)
        sky.cloudsThickness = clamp(targetCloudThickness, min: 0.08, max: 1.0)
        sky.cloudsBrightness = clamp(targetCloudBrightness + moodLift * 0.06 - moodShadow * 0.05, min: 0.2, max: 1.6)
        sky.cloudsSunInfluence = clamp(targetCloudSunInfluence, min: 0.0, max: 2.0)
    }

    private static func clamp(_ value: Float, min minimum: Float, max maximum: Float) -> Float {
        Swift.min(Swift.max(value, minimum), maximum)
    }
}
