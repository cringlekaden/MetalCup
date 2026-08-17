import Testing
@testable import MetalCupEngine

struct IBLRebuildLifecycleTests {
    private func renderState(time: Float) -> EnvironmentRenderState {
        var environment = EnvironmentComponent.default
        environment.source.mode = .procedural
        environment.celestial.defaultTimeOfDay = time
        return EnvironmentRenderStateBuilder.build(environment: environment, runtime: nil)
    }

    @Test
    func continuousAnimationSchedulesWithoutWaitingForExactSignatureToSettle() {
        let midday = renderState(time: 12)
        let later = renderState(time: 13)
        let state = EnvironmentIBLStateComponent(
            dirty: true,
            needsRebuild: false,
            lastBuiltSignature: midday.iblSignature,
            lastBuiltQuality: .interactive,
            phase: .interactiveReady,
            sourceGeneration: 20,
            lastBuiltGeneration: 12,
            lastBuiltTimeOfDay: midday.finalTimeOfDay,
            lastBuiltSunDirection: midday.sunDirection,
            lastBuiltMoonDirection: midday.moonDirection,
            lastBuiltSkyLogLuminance: EnvironmentIBLRebuildLifecycle.skyLogLuminance(midday)
        )
        #expect(!EnvironmentIBLRebuildLifecycle.shouldScheduleInteractive(
            state: state, current: later, now: 0.19, lastBuildStart: 0
        ))
        #expect(EnvironmentIBLRebuildLifecycle.shouldScheduleInteractive(
            state: state, current: later, now: 0.20, lastBuildStart: 0
        ))
    }

    @Test
    func staleDaytimeCompletionCannotPublishAtNight() {
        let midday = renderState(time: 12)
        let midnight = renderState(time: 0)
        let state = EnvironmentIBLStateComponent(
            lastBuiltSignature: midnight.iblSignature,
            sourceGeneration: 40,
            lastBuiltGeneration: 38,
            lastBuiltTimeOfDay: midnight.finalTimeOfDay,
            lastBuiltSunDirection: midnight.sunDirection,
            lastBuiltMoonDirection: midnight.moonDirection,
            lastBuiltSkyLogLuminance: EnvironmentIBLRebuildLifecycle.skyLogLuminance(midnight)
        )
        #expect(!EnvironmentIBLRebuildLifecycle.completionImprovesFreshness(
            state: state,
            current: midnight,
            completedGeneration: 39,
            completedTime: midday.finalTimeOfDay,
            completedSun: midday.sunDirection,
            completedMoon: midday.moonDirection,
            completedSkyLogLuminance: EnvironmentIBLRebuildLifecycle.skyLogLuminance(midday)
        ))
    }

    @Test
    func boundedNewerInteractiveCompletionMayAdvanceRepresentation() {
        let old = renderState(time: 12.0)
        let completed = renderState(time: 12.25)
        let current = renderState(time: 12.5)
        let state = EnvironmentIBLStateComponent(
            lastBuiltSignature: old.iblSignature,
            sourceGeneration: 9,
            lastBuiltGeneration: 4,
            lastBuiltTimeOfDay: old.finalTimeOfDay,
            lastBuiltSunDirection: old.sunDirection,
            lastBuiltMoonDirection: old.moonDirection,
            lastBuiltSkyLogLuminance: EnvironmentIBLRebuildLifecycle.skyLogLuminance(old)
        )
        #expect(EnvironmentIBLRebuildLifecycle.completionImprovesFreshness(
            state: state,
            current: current,
            completedGeneration: 8,
            completedTime: completed.finalTimeOfDay,
            completedSun: completed.sunDirection,
            completedMoon: completed.moonDirection,
            completedSkyLogLuminance: EnvironmentIBLRebuildLifecycle.skyLogLuminance(completed)
        ))
    }

    @Test(arguments: [60.0, 10.0])
    func acceleratedCycleNeverWaitsForAnimationToStop(dayLengthSeconds: Double) {
        var represented = renderState(time: 0)
        var state = EnvironmentIBLStateComponent(
            dirty: true,
            needsRebuild: false,
            lastBuiltSignature: represented.iblSignature,
            lastBuiltQuality: .interactive,
            phase: .interactiveReady,
            sourceGeneration: 1,
            lastBuiltGeneration: 1,
            lastBuiltTimeOfDay: represented.finalTimeOfDay,
            lastBuiltSunDirection: represented.sunDirection,
            lastBuiltMoonDirection: represented.moonDirection,
            lastBuiltSkyLogLuminance: EnvironmentIBLRebuildLifecycle.skyLogLuminance(represented)
        )
        var lastBuild = 0.0
        var buildCount = 0
        for frame in 1...Int(dayLengthSeconds * 60) {
            let now = Double(frame) / 60
            let current = renderState(time: Float((now / dayLengthSeconds) * 24).truncatingRemainder(dividingBy: 24))
            state.dirty = true
            if EnvironmentIBLRebuildLifecycle.shouldScheduleInteractive(
                state: state, current: current, now: now, lastBuildStart: lastBuild
            ) {
                represented = current
                lastBuild = now
                buildCount += 1
                state.lastBuiltSignature = current.iblSignature
                state.lastBuiltTimeOfDay = current.finalTimeOfDay
                state.lastBuiltSunDirection = current.sunDirection
                state.lastBuiltMoonDirection = current.moonDirection
                state.lastBuiltSkyLogLuminance = EnvironmentIBLRebuildLifecycle.skyLogLuminance(current)
            }
        }
        #expect(buildCount > 0)
        let endLag = EnvironmentIBLRebuildLifecycle.lag(
            current: renderState(time: 0),
            representedTime: represented.finalTimeOfDay,
            representedSun: represented.sunDirection,
            representedMoon: represented.moonDirection,
            representedSkyLogLuminance: EnvironmentIBLRebuildLifecycle.skyLogLuminance(represented)
        )
        #expect(endLag.timeHours < 1.0)
    }
    @Test
    func exactSourceSignatureChangesAreNotCoarselyQuantized() {
        var environment = EnvironmentComponent(source: EnvironmentSourceConfig(mode: .procedural))
        let base = EnvironmentRenderStateBuilder.build(environment: environment, runtime: nil).iblSignature
        environment.atmosphere.haze += 0.000001
        let hazeChanged = EnvironmentRenderStateBuilder.build(environment: environment, runtime: nil).iblSignature
        #expect(hazeChanged != base)

        environment.atmosphere.haze -= 0.000001
        environment.celestial.defaultTimeOfDay += 0.000001
        let timeChanged = EnvironmentRenderStateBuilder.build(environment: environment, runtime: nil).iblSignature
        #expect(timeChanged != base)
        #expect(EnvironmentIBLSignature.currentVersion == 13)
    }

    @Test
    func unrelatedFrameAndOutputStateDoesNotChangeIBLIdentity() {
        let environment = EnvironmentComponent(source: EnvironmentSourceConfig(mode: .procedural))
        var settingsA = RendererSettings()
        var settingsB = settingsA
        settingsB.gamma = 1.1
        settingsB.tonemap = TonemapType.reinhard.rawValue
        settingsB.bloomIntensity = 8
        settingsB.shadows.enabled = settingsA.shadows.enabled == 0 ? 1 : 0
        let a = EnvironmentRenderStateBuilder.build(
            environment: environment,
            runtime: nil,
            rendererSettings: settingsA
        ).iblSignature
        let b = EnvironmentRenderStateBuilder.build(
            environment: environment,
            runtime: nil,
            rendererSettings: settingsB
        ).iblSignature
        #expect(a == b)
        settingsA.iblEnabled = 0
        let c = EnvironmentRenderStateBuilder.build(
            environment: environment,
            runtime: nil,
            rendererSettings: settingsA
        ).iblSignature
        #expect(a == c)
    }

    @Test
    func interactiveReadyAutomaticallySelectsFinalAfterSettle() {
        let signature = EnvironmentIBLSignature(enabled: true, sourceMode: .procedural)
        let state = EnvironmentIBLStateComponent(
            dirty: false,
            needsRebuild: false,
            lastBuiltSignature: signature,
            lastBuiltQuality: .interactive,
            phase: .interactiveReady,
            sourceGeneration: 4,
            lastBuiltGeneration: 4,
            lastSourceChangeTime: 10
        )
        #expect(!EnvironmentIBLRebuildLifecycle.requiresFinalBuild(
            state: state,
            desiredSignature: signature,
            now: 13.9,
            settleDelay: 4
        ))
        #expect(EnvironmentIBLRebuildLifecycle.requiresFinalBuild(
            state: state,
            desiredSignature: signature,
            now: 14,
            settleDelay: 4
        ))
        #expect(EnvironmentIBLRebuildLifecycle.selectedQuality(
            manualRebuild: false,
            resourcesMissing: false,
            finalBuildNeeded: true
        ) == .final)
    }

    @Test
    func staleGenerationCannotPublishOverNewerSource() {
        let old = EnvironmentIBLSignature(enabled: true, sourceMode: .procedural, finalTimeOfDay: 1)
        let current = EnvironmentIBLSignature(enabled: true, sourceMode: .procedural, finalTimeOfDay: 2)
        let state = EnvironmentIBLStateComponent(
            pendingSignature: current,
            phase: .rebuildingInteractive,
            sourceGeneration: 8,
            inFlightGeneration: 7,
            lastSourceChangeTime: 2
        )
        #expect(!EnvironmentIBLRebuildLifecycle.completionIsCurrent(
            activeEnvironmentMatches: true,
            desiredSignature: current,
            state: state,
            completedSignature: old,
            completedGeneration: 7
        ))
        #expect(!EnvironmentIBLRebuildLifecycle.completionIsCurrent(
            activeEnvironmentMatches: true,
            desiredSignature: current,
            state: state,
            completedSignature: current,
            completedGeneration: 7
        ))
        #expect(EnvironmentIBLRebuildLifecycle.completionIsCurrent(
            activeEnvironmentMatches: true,
            desiredSignature: current,
            state: state,
            completedSignature: current,
            completedGeneration: 8
        ))
    }

    @Test
    func lifecycleStatesDistinguishInteractiveAndFinalReadiness() {
        let expected: [EnvironmentIBLRebuildPhase] = [
            .dirty,
            .rebuildingInteractive,
            .interactiveReady,
            .rebuildingFinal,
            .finalReady
        ]
        #expect(Set(expected.map(\.rawValue)).count == 5)
        #expect(EnvironmentIBLRebuildLifecycle.selectedQuality(
            manualRebuild: false,
            resourcesMissing: false,
            finalBuildNeeded: false
        ) == .interactive)
        #expect(EnvironmentIBLRebuildLifecycle.selectedQuality(
            manualRebuild: true,
            resourcesMissing: false,
            finalBuildNeeded: false
        ) == .final)
    }

    @Test
    func freshnessNeverLabelsMismatchedOrInteractiveResourcesFinalCurrent() {
        var environment = EnvironmentComponent.default
        environment.source.mode = .procedural
        environment.celestial.defaultTimeOfDay = 19
        let current = EnvironmentRenderStateBuilder.build(environment: environment, runtime: nil)
        let exact = EnvironmentIBLStateComponent(
            dirty: false,
            needsRebuild: false,
            lastBuiltSignature: current.iblSignature,
            lastBuiltQuality: .final,
            phase: .finalReady,
            sourceGeneration: 9,
            lastBuiltGeneration: 9,
            lastBuiltTimeOfDay: current.finalTimeOfDay,
            lastBuiltSunDirection: current.sunDirection
        )
        let exactFreshness = EnvironmentIBLRebuildLifecycle.freshness(state: exact, current: current)
        #expect(exactFreshness.exactSignatureMatch)
        #expect(exactFreshness.finalQuality)
        #expect(exactFreshness.isCurrentFinal)
        #expect(exactFreshness.status == "final, exact, current")
        #expect(exactFreshness.sourceGeneration == 9)
        #expect(exactFreshness.representedGeneration == 9)

        var changedEnvironment = environment
        changedEnvironment.celestial.defaultTimeOfDay = 19.01
        let changed = EnvironmentRenderStateBuilder.build(environment: changedEnvironment, runtime: nil)
        let staleFreshness = EnvironmentIBLRebuildLifecycle.freshness(state: exact, current: changed)
        #expect(!staleFreshness.exactSignatureMatch)
        #expect(!staleFreshness.isCurrentFinal)
        #expect(staleFreshness.status.contains("lagging"))

        var interactive = exact
        interactive.lastBuiltQuality = .interactive
        interactive.phase = .interactiveReady
        let interactiveFreshness = EnvironmentIBLRebuildLifecycle.freshness(state: interactive, current: current)
        #expect(interactiveFreshness.exactSignatureMatch)
        #expect(!interactiveFreshness.finalQuality)
        #expect(!interactiveFreshness.isCurrentFinal)
    }
}
