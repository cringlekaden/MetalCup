/// Pure policy helpers for the renderer-owned IBL rebuild lifecycle. GPU jobs
/// carry both an exact source signature and a monotonic generation so an older
/// completion can never publish over newer authored state.
public enum EnvironmentIBLRebuildLifecycle {
    public static func completionIsCurrent(
        activeEnvironmentMatches: Bool,
        desiredSignature: EnvironmentIBLSignature,
        state: EnvironmentIBLStateComponent,
        completedSignature: EnvironmentIBLSignature,
        completedGeneration: UInt64
    ) -> Bool {
        activeEnvironmentMatches
            && desiredSignature == completedSignature
            && state.sourceGeneration == completedGeneration
    }

    public static func requiresFinalBuild(
        state: EnvironmentIBLStateComponent,
        desiredSignature: EnvironmentIBLSignature,
        now: Double,
        settleDelay: Double
    ) -> Bool {
        state.phase == .interactiveReady
            && state.lastBuiltQuality == .interactive
            && state.lastBuiltSignature == desiredSignature
            && now - state.lastSourceChangeTime >= settleDelay
    }

    public static func selectedQuality(
        manualRebuild: Bool,
        resourcesMissing: Bool,
        finalBuildNeeded: Bool
    ) -> EnvironmentIBLRebuildQuality {
        (manualRebuild || resourcesMissing || finalBuildNeeded) ? .final : .interactive
    }
}
