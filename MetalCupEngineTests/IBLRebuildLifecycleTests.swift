import Testing
@testable import MetalCupEngine

struct IBLRebuildLifecycleTests {
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
        #expect(EnvironmentIBLSignature.currentVersion == 11)
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
}
