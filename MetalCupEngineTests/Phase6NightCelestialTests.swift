import Foundation
import Metal
import simd
import Testing
@testable import MetalCupEngine

@Suite("Night celestial energy")
struct NightCelestialReferenceTests {
    @Test
    func reflectedMoonPhaseAndProjectedIntegralAreCoherent() {
        let atmosphere = DaytimeAtmosphereModel.Parameters(sourceEV: 0)
        let sun = SkySystem.sunDirection(timeOfDay: 0)
        let full = NightCelestialModel.build(
            timeOfDay: 0,
            sunDirection: sun,
            solarIrradianceRGB: .zero,
            atmosphere: atmosphere,
            lunarAlbedo: 0.12,
            moonDiameterDegrees: 0.54,
            moonPhase: 0.5,
            haze: 0,
            cloudCoverage: 0
        )
        let quarter = NightCelestialModel.build(
            timeOfDay: 0,
            sunDirection: sun,
            solarIrradianceRGB: .zero,
            atmosphere: atmosphere,
            lunarAlbedo: 0.12,
            moonDiameterDegrees: 0.54,
            moonPhase: 0.25,
            haze: 0,
            cloudCoverage: 0
        )
        let new = NightCelestialModel.build(
            timeOfDay: 0,
            sunDirection: sun,
            solarIrradianceRGB: .zero,
            atmosphere: atmosphere,
            lunarAlbedo: 0.12,
            moonDiameterDegrees: 0.54,
            moonPhase: 0,
            haze: 0,
            cloudCoverage: 0
        )

        #expect(simd_distance(full.moonDirection, -sun) < 0.000_001)
        #expect(abs(full.illuminatedFraction - 1) < 0.000_001)
        #expect(abs(quarter.illuminatedFraction - 0.5) < 0.000_01)
        #expect(new.illuminatedFraction < 0.000_001)
        #expect(full.phaseResponse > quarter.phaseResponse)
        #expect(quarter.phaseResponse > new.phaseResponse)
        #expect(luminance(full.irradianceRGB) > luminance(quarter.irradianceRGB))
        #expect(luminance(new.irradianceRGB) < 1e-10)
        #expect(full.irradianceRGB.x.isFinite && full.irradianceRGB.y.isFinite && full.irradianceRGB.z.isFinite)
        #expect(simd_reduce_min(full.irradianceRGB) >= 0)
    }

    @Test
    func sourceEVScalesMoonDiskAndAnalyticMoonlightOnce() {
        let sun = SkySystem.sunDirection(timeOfDay: 0)
        let base = makeMoon(sun: sun, sourceEV: 0)
        let brighter = makeMoon(sun: sun, sourceEV: 1)
        #expect(simd_distance(brighter.diskRadianceRGB, base.diskRadianceRGB * 2) < 0.000_01)
        #expect(simd_distance(brighter.irradianceRGB, base.irradianceRGB * 2) < 0.000_01)
    }

    private func makeMoon(sun: SIMD3<Float>, sourceEV: Float) -> NightCelestialModel.State {
        NightCelestialModel.build(
            timeOfDay: 0,
            sunDirection: sun,
            solarIrradianceRGB: .zero,
            atmosphere: .init(sourceEV: sourceEV),
            lunarAlbedo: 0.12,
            moonDiameterDegrees: 0.54,
            moonPhase: 0.5,
            haze: 0,
            cloudCoverage: 0
        )
    }
}

@Suite("Celestial frame coherence")
struct CelestialFrameCoherenceTests {
    @Test
    func authoritativeFrameSelectsSunByDayAndMoonAtNight() throws {
        let day = environmentState(time: 12, phase: 0.5)
        let night = environmentState(time: 0, phase: 0.5)
        #expect(day.directionalLightSource == .sun)
        #expect(simd_distance(day.directionalLightDirection, day.sunDirection) < 0.000_001)
        #expect(day.directionalLightIntensity == day.sunIntensity)
        #expect(night.directionalLightSource == .moon)
        #expect(simd_distance(night.directionalLightDirection, night.moonDirection) < 0.000_001)
        #expect(simd_distance(night.directionalLightColor * night.directionalLightIntensity,
                             night.moonIrradianceRGB) < 0.000_001)
        #expect(simd_distance(night.legacyFogPatch.directionToSun,
                             night.moonDirection) < 0.000_001)
        #expect(simd_distance(night.legacyFogPatch.solarIrradiance,
                             night.moonIrradianceRGB) < 0.000_001)

        let scene = EngineScene(name: "Phase6MoonOwnership",
                                prefabSystem: nil,
                                engineContext: nil,
                                shouldBuildScene: false)
        let entity = scene.ecs.createEntity(name: "Environment")
        var environment = EnvironmentComponent.default
        environment.source.mode = .procedural
        environment.celestial.defaultTimeOfDay = 0
        environment.celestial.moonPhase = 0.5
        scene.ecs.add(environment, to: entity)
        scene.ecs.add(EnvironmentFrameStateComponent(renderState: night), to: entity)
        SkySystem.update(scene: scene)
        let lightEntity = try #require(scene.ecs.firstEntity(with: SkySunTag.self))
        let light = try #require(scene.ecs.get(LightComponent.self, for: lightEntity))
        let transform = try #require(scene.ecs.get(TransformComponent.self, for: lightEntity))
        let ray = TransformMath.directionalLightDirection(from: transform.rotation)
        #expect(light.castsShadows)
        #expect(simd_distance(ray, -night.moonDirection) < 0.000_01)
        #expect(simd_distance(light.data.color * light.data.brightness,
                             night.moonIrradianceRGB) < 0.000_001)
    }

    @Test
    func staleCameraAndOutputSettingsCannotChangeCelestialEnergy() {
        var environment = EnvironmentComponent.default
        environment.source.mode = .procedural
        environment.celestial.defaultTimeOfDay = 0
        environment.celestial.moonPhase = 0.5
        var a = RendererSettings()
        a.gamma = 0.25
        var b = a
        b.gamma = 4
        b.tonemap = TonemapType.reinhard.rawValue
        let first = EnvironmentRenderStateBuilder.build(environment: environment,
                                                        runtime: nil,
                                                        rendererSettings: a)
        let second = EnvironmentRenderStateBuilder.build(environment: environment,
                                                         runtime: nil,
                                                         rendererSettings: b)
        #expect(first.moonDiskRadianceRGB == second.moonDiskRadianceRGB)
        #expect(first.moonIrradianceRGB == second.moonIrradianceRGB)
        #expect(first.iblSignature == second.iblSignature)
        let lowEV = SceneLinearHDRContract.finalSDROutput(sceneLinear: first.moonDiskRadianceRGB,
                                                         exposureEV: 8)
        let highEV = SceneLinearHDRContract.finalSDROutput(sceneLinear: first.moonDiskRadianceRGB,
                                                          exposureEV: 10)
        #expect(highEV != lowEV)
    }

    @Test
    func localFogConsumesButDoesNotMutateTheCelestialFrame() {
        var clear = EnvironmentComponent.default
        clear.source.mode = .procedural
        clear.celestial.defaultTimeOfDay = 0
        clear.celestial.moonIntensity = 0.12
        clear.celestial.moonPhase = 0.5
        clear.fog.enabled = false
        var foggy = clear
        foggy.fog.enabled = true
        foggy.fog.extinction = 0.025
        foggy.fog.scatteringAlbedo = SIMD3<Float>(repeating: 0.9)
        foggy.fog.baseHeight = 0
        foggy.fog.scaleHeight = 12
        foggy.fog.anisotropy = 0.2

        let clearState = EnvironmentRenderStateBuilder.build(environment: clear, runtime: nil)
        let foggyState = EnvironmentRenderStateBuilder.build(environment: foggy, runtime: nil)
        #expect(clearState.moonDirection == foggyState.moonDirection)
        #expect(clearState.moonDiskRadianceRGB == foggyState.moonDiskRadianceRGB)
        #expect(clearState.moonIrradianceRGB == foggyState.moonIrradianceRGB)
        #expect(clearState.iblSignature == foggyState.iblSignature)
        #expect(!clearState.legacyFogPatch.parameters.enabled)
        #expect(foggyState.legacyFogPatch.parameters.enabled)
        #expect(foggyState.legacyFogPatch.directionToSun == foggyState.moonDirection)
        #expect(foggyState.legacyFogPatch.solarIrradiance == foggyState.moonIrradianceRGB)
    }

    @Test
    func missingMoonPhaseDecodesToFullMoonAndRoundTrips() throws {
        let legacy = try JSONDecoder().decode(
            EnvironmentCelestialDTO.self,
            from: Data(#"{"defaultTimeOfDay":0,"moonIntensity":0.12,"moonSizeDegrees":0.54,"starIntensity":1}"#.utf8)
        )
        #expect(legacy.moonPhase == 0.5)
        var config = legacy.toConfig()
        config.moonPhase = 0.25
        let encoded = try JSONEncoder().encode(EnvironmentCelestialDTO(config: config))
        let decoded = try JSONDecoder().decode(EnvironmentCelestialDTO.self, from: encoded)
        #expect(decoded.moonPhase == 0.25)
    }
}

@Suite("Celestial sky GPU partition")
struct CelestialSkyGPUReferenceTests {
    @Test
    func visibleMoonDiskIsExcludedFromIBLCaptureAndCelestialArtIsBounded() throws {
        let state = environmentState(time: 0, phase: 0.5)
        let support = Phase4LegacyCharacterization()
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase3MetalTestSupport.library(device: device)
        let pipeline = try device.makeComputePipelineState(function: #require(
            library.makeFunction(name: "phase4_procedural_sky_component_samples")
        ))
        var params = state.legacySkyParams
        let moon = simd_normalize(state.moonDirection)
        var directions = [SIMD4<Float>(moon, 0)]
        directions += support.hemisphereDirections(count: 512).map { SIMD4<Float>($0, 0) }
        let samples = try support.sample(device: device,
                                         pipeline: pipeline,
                                         params: &params,
                                         directions: directions)
        let visibleMoon = samples.visible[0].xyz
        let capturedMoon = samples.capture[0].xyz
        #expect(luminance(visibleMoon) > luminance(capturedMoon))
        #expect(luminance(visibleMoon - capturedMoon) > 0.001)

        var visibleEnergy: Float = 0
        var captureEnergy: Float = 0
        for index in 1..<samples.visible.count {
            let visible = samples.visible[index].xyz
            let capture = samples.capture[index].xyz
            #expect(visible.x.isFinite && visible.y.isFinite && visible.z.isFinite)
            #expect(capture.x.isFinite && capture.y.isFinite && capture.z.isFinite)
            #expect(simd_reduce_min(visible) >= 0)
            #expect(simd_reduce_min(capture) >= 0)
            #expect(simd_reduce_max(visible) < 65_504)
            #expect(simd_reduce_max(capture) < 65_504)
            visibleEnergy += luminance(visible)
            captureEnergy += luminance(capture)
        }
        #expect(captureEnergy <= visibleEnergy)
        #expect(params.celestialCaptureScale == NightCelestialModel.celestialCaptureScale)
    }

    @Test
    func dayDuskNightAndDawnRemainFiniteWithoutAResourceGap() throws {
        let support = Phase4LegacyCharacterization()
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase3MetalTestSupport.library(device: device)
        let pipeline = try device.makeComputePipelineState(function: #require(
            library.makeFunction(name: "phase4_procedural_sky_component_samples")
        ))
        let directions = [
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(simd_normalize(SIMD3<Float>(1, 0.08, 0.25)), 0)
        ]
        for time: Float in [5, 5.5, 6, 6.5, 17.5, 18, 18.5, 19, 22, 0] {
            let state = environmentState(time: time, phase: 0.5)
            var params = state.legacySkyParams
            let samples = try support.sample(device: device,
                                             pipeline: pipeline,
                                             params: &params,
                                             directions: directions)
            let total = samples.visible.reduce(Float(0)) { partial, sample in
                let rgb = sample.xyz
                #expect(rgb.x.isFinite && rgb.y.isFinite && rgb.z.isFinite)
                #expect(simd_reduce_min(rgb) >= 0)
                #expect(simd_reduce_max(rgb) < 65_504)
                return partial + luminance(rgb)
            }
            #expect(total > 1e-8)
        }
    }
}

@Suite("Time-varying celestial state")
struct TimeVaryingCelestialTests {
    @Test
    func dayDuskNightDawnProgressionIsFiniteAndDeterministic() {
        var previous: EnvironmentRenderState?
        var sawSun = false
        var sawMoon = false
        for step in 0...96 {
            let time = Float(step) * 0.25
            let state = environmentState(time: time, phase: 0.5)
            let repeated = environmentState(time: time, phase: 0.5)
            #expect(state.iblSignature == repeated.iblSignature)
            #expect(state.sunDirection == repeated.sunDirection)
            #expect(state.moonDirection == repeated.moonDirection)
            #expect(state.directionalLightIntensity.isFinite)
            #expect(state.directionalLightIntensity >= 0)
            #expect(simd_reduce_min(state.moonDiskRadianceRGB) >= 0)
            #expect(simd_reduce_max(state.moonDiskRadianceRGB) < 65_504)
            sawSun = sawSun || state.directionalLightSource == .sun
            sawMoon = sawMoon || state.directionalLightSource == .moon
            if let previous {
                #expect(simd_distance(previous.sunDirection, state.sunDirection) < 0.22)
                #expect(simd_distance(previous.moonDirection, state.moonDirection) < 0.22)
            }
            previous = state
        }
        #expect(sawSun)
        #expect(sawMoon)
    }

    @Test
    func moonPhaseAndTimeAreExactIBLSourceInputs() {
        let midnight = environmentState(time: 0, phase: 0.5)
        let later = environmentState(time: 0.01, phase: 0.5)
        let quarter = environmentState(time: 0, phase: 0.25)
        #expect(midnight.iblSignature != later.iblSignature)
        #expect(midnight.iblSignature != quarter.iblSignature)
        #expect(EnvironmentIBLSignature.currentVersion == 12)
    }
}

private func environmentState(time: Float, phase: Float) -> EnvironmentRenderState {
    var environment = EnvironmentComponent.default
    environment.source.mode = .procedural
    environment.celestial.defaultTimeOfDay = time
    environment.celestial.moonIntensity = 0.12
    environment.celestial.moonSizeDegrees = 0.54
    environment.celestial.moonPhase = phase
    environment.celestial.starIntensity = 0.75
    environment.celestial.milkyWayIntensity = 1
    environment.clouds.coverage = 0
    environment.fog.enabled = false
    let runtime = EnvironmentRuntimeStateComponent(seededFrom: environment)
    return EnvironmentRenderStateBuilder.build(environment: environment, runtime: runtime)
}

private func luminance(_ rgb: SIMD3<Float>) -> Float {
    simd_dot(rgb, SIMD3<Float>(0.2126, 0.7152, 0.0722))
}
