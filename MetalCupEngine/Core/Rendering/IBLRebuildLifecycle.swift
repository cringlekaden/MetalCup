import Foundation
import simd

/// Pure policy helpers for the renderer-owned IBL rebuild lifecycle. GPU jobs
/// carry both an exact source signature and a monotonic generation so an older
/// completion can never publish over newer authored state.
public enum EnvironmentIBLRebuildLifecycle {
    public struct Freshness: Equatable {
        public var status: String
        public var representedTimeOfDay: Float?
        public var timeLagHours: Float?
        public var angularLagDegrees: Float?
        public var lastBuildDuration: Double?
        public var exactSignatureMatch: Bool
        public var finalQuality: Bool
        public var isCurrentFinal: Bool
        public var sourceGeneration: UInt64
        public var representedGeneration: UInt64?
    }

    public static func freshness(state: EnvironmentIBLStateComponent,
                                 current: EnvironmentRenderState) -> Freshness {
        let representedTime = state.lastBuiltTimeOfDay
        let timeLag: Float? = representedTime.map {
            let raw = abs(current.finalTimeOfDay - $0).truncatingRemainder(dividingBy: 24)
            return min(raw, 24 - raw)
        }
        let angularLag: Float? = state.lastBuiltSunDirection.map {
            let a = simd_normalize($0)
            let b = simd_normalize(current.sunDirection)
            return acos(min(max(simd_dot(a, b), -1), 1)) * 180 / .pi
        }
        let exactSignatureMatch = state.lastBuiltSignature == current.iblSignature
        let finalQuality = state.lastBuiltQuality == .final
        let isCurrentFinal = exactSignatureMatch
            && finalQuality
            && !state.isRebuilding
            && !state.dirty
            && state.lastFailureMessage?.isEmpty != false
        let status: String
        if state.lastFailureMessage?.isEmpty == false {
            status = "error — retaining last valid IBL"
        } else if state.isRebuilding {
            status = state.currentRebuildQuality == .final ? "rebuilding final" : "rebuilding interactive"
        } else if state.lastBuiltSignature == nil {
            status = "no valid IBL"
        } else if !exactSignatureMatch || state.dirty {
            status = "lagging — interactive source changed"
        } else {
            status = finalQuality ? "final, exact, current" : "interactive, exact, current"
        }
        return Freshness(status: status,
                         representedTimeOfDay: representedTime,
                         timeLagHours: timeLag,
                         angularLagDegrees: angularLag,
                         lastBuildDuration: state.lastBuildDuration,
                         exactSignatureMatch: exactSignatureMatch,
                         finalQuality: finalQuality,
                         isCurrentFinal: isCurrentFinal,
                         sourceGeneration: state.sourceGeneration,
                         representedGeneration: state.lastBuiltGeneration)
    }

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

    /// A continuously animated procedural sky can change again while its reduced-
    /// quality command buffer is executing. Such a result may advance the last
    /// known-good interactive resource only if it is the currently in-flight job
    /// and newer than the resource already published. It remains explicitly dirty
    /// and lagging; final-quality publication still requires an exact signature.
    public static func mayPublishLaggingInteractive(
        state: EnvironmentIBLStateComponent,
        completedGeneration: UInt64,
        completedQuality: EnvironmentIBLRebuildQuality
    ) -> Bool {
        completedQuality == .interactive
            && state.inFlightGeneration == completedGeneration
            && completedGeneration > (state.lastBuiltGeneration ?? 0)
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
