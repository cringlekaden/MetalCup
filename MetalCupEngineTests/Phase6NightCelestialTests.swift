import simd
import Testing
@testable import MetalCupEngine

@Suite("Phase 6 night and celestial reconstruction")
struct Phase6LegacyCelestialCharacterizationTests {
    @Test
    func legacyNightPublishesAVisibleMoonWithoutAnalyticMoonlight() {
        var environment = EnvironmentComponent.default
        environment.source.mode = .procedural
        environment.celestial.defaultTimeOfDay = 0
        environment.celestial.moonIntensity = 0.18
        let runtime = EnvironmentRuntimeStateComponent(seededFrom: environment)

        let state = EnvironmentRenderStateBuilder.build(environment: environment, runtime: runtime)

        // Phase 6 characterization: the old path places the Moon exactly opposite
        // the Sun and draws it, but the only generated analytic light is the Sun.
        #expect(simd_distance(state.moonDirection, -state.sunDirection) < 0.000_001)
        #expect(state.legacySkyParams.moonIntensity > 0)
        #expect(state.sunIntensity == 0)
        #expect(state.legacyFogPatch.solarIrradiance == .zero)
    }

    @Test
    func legacyMoonControlIsAnUnspecifiedArtisticMultiplier() {
        var low = EnvironmentComponent.default
        low.source.mode = .procedural
        low.celestial.defaultTimeOfDay = 0
        low.celestial.moonIntensity = 0.1
        var high = low
        high.celestial.moonIntensity = 0.2

        let lowState = EnvironmentRenderStateBuilder.build(
            environment: low,
            runtime: EnvironmentRuntimeStateComponent(seededFrom: low)
        )
        let highState = EnvironmentRenderStateBuilder.build(
            environment: high,
            runtime: EnvironmentRuntimeStateComponent(seededFrom: high)
        )

        #expect(highState.legacySkyParams.moonIntensity > lowState.legacySkyParams.moonIntensity)
        #expect(highState.sunIntensity == lowState.sunIntensity)
    }
}
