import Foundation
import simd

/// Advances the runtime environment state for the single active environment owner.
/// The new environment model is the primary path; the old sky state update remains
/// temporarily so current renderer/editor paths keep working during the transition.
public enum EnvironmentSimulationSystem {
    @inline(__always)
    private static func saturate(_ value: Float) -> Float {
        min(max(value, 0.0), 1.0)
    }

    @inline(__always)
    private static func positiveWrappedPhase(_ value: Float) -> Float {
        let wrapped = value.truncatingRemainder(dividingBy: 1.0)
        return wrapped >= 0.0 ? wrapped : (wrapped + 1.0)
    }

    @inline(__always)
    private static func normalizedTimeOfDay(_ hours: Float) -> Float {
        let wrapped = hours.truncatingRemainder(dividingBy: 24.0)
        return wrapped >= 0.0 ? wrapped : (wrapped + 24.0)
    }

    public static func update(scene: EngineScene,
                              frame: FrameContext,
                              isPlaying: Bool,
                              isPaused: Bool) {
        let ecs = scene.ecs
        if updateActiveEnvironment(in: ecs, frame: frame, isPlaying: isPlaying, isPaused: isPaused) {
            return
        }

        updateLegacySkyEnvironment(in: ecs, frame: frame, isPlaying: isPlaying, isPaused: isPaused)
    }

    @discardableResult
    private static func updateActiveEnvironment(in ecs: SceneECS,
                                                frame: FrameContext,
                                                isPlaying: Bool,
                                                isPaused: Bool) -> Bool {
        guard let (entity, environment) = ecs.activeEnvironment() else { return false }
        var state = ecs.get(EnvironmentRuntimeStateComponent.self, for: entity)
            ?? EnvironmentRuntimeStateComponent(seededFrom: environment)

        state.dayLengthSeconds = max(state.dayLengthSeconds, 1.0)
        state.timeScale = max(state.timeScale, 0.0)
        state.weatherBlend = saturate(state.weatherBlend)
        state.weatherAmount = saturate(state.weatherAmount)
        state.precipitationAmount = saturate(state.precipitationAmount)
        state.stormActivity = saturate(state.stormActivity)
        state.lightningActivity = saturate(state.lightningActivity)
        state.wetnessDriver = saturate(state.wetnessDriver)
        state.currentTimeOfDay = normalizedTimeOfDay(state.currentTimeOfDay)

        guard isPlaying, !isPaused else {
            if state.timeControlMode == .scripted, let override = state.scriptedTimeOfDayOverride {
                state.currentTimeOfDay = normalizedTimeOfDay(override)
            }
            ecs.add(state, to: entity)
            return true
        }

        let simulationDelta = max(frame.time.deltaTime, 0.0) * state.timeScale

        switch state.timeControlMode {
        case .fixed:
            break
        case .cycle:
            let dayProgress = (simulationDelta / state.dayLengthSeconds) * 24.0
            state.currentTimeOfDay = normalizedTimeOfDay(state.currentTimeOfDay + dayProgress)
        case .scripted:
            if let override = state.scriptedTimeOfDayOverride {
                state.currentTimeOfDay = normalizedTimeOfDay(override)
            }
        }

        let renderState = EnvironmentRenderStateBuilder.build(environment: environment, runtime: state)
        let cloudSpeed = abs(renderState.legacySkyParams.cloudsSpeed)
        state.cloudPhase = positiveWrappedPhase(state.cloudPhase + cloudSpeed * simulationDelta)
        let windMagnitude = simd_length(renderState.legacySkyParams.cloudsWindDirection)
        state.windPhase = positiveWrappedPhase(state.windPhase + windMagnitude * cloudSpeed * simulationDelta)

        ecs.add(state, to: entity)
        return true
    }

    private static func updateLegacySkyEnvironment(in ecs: SceneECS,
                                                   frame: FrameContext,
                                                   isPlaying: Bool,
                                                   isPaused: Bool) {
        guard let (entity, sky) = ecs.activeSkyLight(),
              var state = ecs.get(EnvironmentStateComponent.self, for: entity)
        else { return }

        // Keep runtime fields normalized even while paused or in edit mode.
        state.dayLengthSeconds = max(state.dayLengthSeconds, 1.0)
        state.environmentTimeScale = max(state.environmentTimeScale, 0.0)
        state.weatherTransitionDuration = max(state.weatherTransitionDuration, 0.0001)
        state.weatherTransitionProgress = saturate(state.weatherTransitionProgress)
        state.weatherAmount = saturate(state.weatherAmount)
        state.precipitationAmount = saturate(state.precipitationAmount)
        state.stormActivity = saturate(state.stormActivity)
        state.lightningActivity = saturate(state.lightningActivity)
        state.wetnessDriver = saturate(state.wetnessDriver)
        state.currentTimeOfDay = normalizedTimeOfDay(state.currentTimeOfDay)

        guard isPlaying, !isPaused else {
            if state.timeControlMode == .scripted, let override = state.scriptedTimeOfDayOverride {
                state.currentTimeOfDay = normalizedTimeOfDay(override)
            }
            ecs.add(state, to: entity)
            return
        }

        let simulationDelta = max(frame.time.deltaTime, 0.0) * state.environmentTimeScale

        switch state.timeControlMode {
        case .fixed:
            break
        case .cycle:
            let dayProgress = (simulationDelta / state.dayLengthSeconds) * 24.0
            state.currentTimeOfDay = normalizedTimeOfDay(state.currentTimeOfDay + dayProgress)
        case .scripted:
            if let override = state.scriptedTimeOfDayOverride {
                state.currentTimeOfDay = normalizedTimeOfDay(override)
            }
        }

        if state.currentWeatherType != state.targetWeatherType {
            let progressDelta = simulationDelta / state.weatherTransitionDuration
            state.weatherTransitionProgress = saturate(state.weatherTransitionProgress + progressDelta)
            if state.weatherTransitionProgress >= 1.0 {
                state.currentWeatherType = state.targetWeatherType
            }
        } else {
            state.weatherTransitionProgress = 1.0
        }

        let cloudSpeed = abs(sky.cloudsSpeed)
        state.cloudPhase = positiveWrappedPhase(state.cloudPhase + cloudSpeed * simulationDelta)
        let windMagnitude = simd_length(sky.cloudsWindDirection)
        state.windPhase = positiveWrappedPhase(state.windPhase + windMagnitude * cloudSpeed * simulationDelta)

        ecs.add(state, to: entity)
    }
}
