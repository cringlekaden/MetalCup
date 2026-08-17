import Foundation
import simd

/// Pure policy helpers for the renderer-owned IBL rebuild lifecycle. GPU jobs
/// carry both an exact source signature and a monotonic generation so an older
/// completion can never publish over newer authored state.
public enum EnvironmentIBLRebuildLifecycle {
    public struct Thresholds: Equatable {
        public var minimumInteractiveInterval: Double = 0.20
        public var maximumInteractiveInterval: Double = 0.75
        public var sunAngleDegrees: Float = 1.5
        public var moonAngleDegrees: Float = 2.0
        public var skyLuminanceStops: Float = 0.20
        public var maximumTimeLagHours: Float = 1.0
        public var maximumRadiometricLagStops: Float = 1.0
        public var crossfadeDuration: Double = 0.50
        public var snapTimeDiscontinuityHours: Float = 4.0
        public var snapRadiometricDiscontinuityStops: Float = 3.0

        public init() {}
        public static let production = Thresholds()
    }

    public struct Lag: Equatable {
        public var timeHours: Float
        public var sunDegrees: Float
        public var moonDegrees: Float
        public var skyLuminanceStops: Float

        public var score: Float {
            max(timeHours, max(sunDegrees / 15, max(moonDegrees / 15, skyLuminanceStops)))
        }
    }

    public static func skyLogLuminance(_ current: EnvironmentRenderState) -> Float {
        let rgb = max(current.skyAmbientRadianceRGB, SIMD3<Float>(repeating: 0))
        let luminance = max(simd_dot(rgb, SIMD3<Float>(0.2126, 0.7152, 0.0722)), 1e-8)
        return log2(luminance)
    }

    public static func lag(current: EnvironmentRenderState,
                           representedTime: Float?,
                           representedSun: SIMD3<Float>?,
                           representedMoon: SIMD3<Float>?,
                           representedSkyLogLuminance: Float?) -> Lag {
        let timeHours = representedTime.map { circularHourDistance(current.finalTimeOfDay, $0) } ?? 24
        let sunDegrees = representedSun.map { angularDistanceDegrees($0, current.sunDirection) } ?? 180
        let moonDegrees = representedMoon.map { angularDistanceDegrees($0, current.moonDirection) } ?? 180
        let skyStops = representedSkyLogLuminance.map { abs(skyLogLuminance(current) - $0) } ?? .infinity
        return Lag(timeHours: timeHours,
                   sunDegrees: sunDegrees,
                   moonDegrees: moonDegrees,
                   skyLuminanceStops: skyStops)
    }

    public static func shouldScheduleInteractive(state: EnvironmentIBLStateComponent,
                                                 current: EnvironmentRenderState,
                                                 now: Double,
                                                 lastBuildStart: Double,
                                                 thresholds: Thresholds = .production) -> Bool {
        guard now - lastBuildStart >= thresholds.minimumInteractiveInterval else { return false }
        guard state.lastBuiltSignature != nil else { return true }
        let activeLag = lag(current: current,
                            representedTime: state.lastBuiltTimeOfDay,
                            representedSun: state.lastBuiltSunDirection,
                            representedMoon: state.lastBuiltMoonDirection,
                            representedSkyLogLuminance: state.lastBuiltSkyLogLuminance)
        return now - lastBuildStart >= thresholds.maximumInteractiveInterval
            || activeLag.sunDegrees >= thresholds.sunAngleDegrees
            || activeLag.moonDegrees >= thresholds.moonAngleDegrees
            || activeLag.skyLuminanceStops >= thresholds.skyLuminanceStops
    }

    public static func completionImprovesFreshness(state: EnvironmentIBLStateComponent,
                                                   current: EnvironmentRenderState,
                                                   completedGeneration: UInt64,
                                                   completedTime: Float,
                                                   completedSun: SIMD3<Float>,
                                                   completedMoon: SIMD3<Float>,
                                                   completedSkyLogLuminance: Float,
                                                   thresholds: Thresholds = .production) -> Bool {
        guard completedGeneration > (state.lastBuiltGeneration ?? 0) else { return false }
        let completedLag = lag(current: current,
                               representedTime: completedTime,
                               representedSun: completedSun,
                               representedMoon: completedMoon,
                               representedSkyLogLuminance: completedSkyLogLuminance)
        let activeLag = lag(current: current,
                            representedTime: state.lastBuiltTimeOfDay,
                            representedSun: state.lastBuiltSunDirection,
                            representedMoon: state.lastBuiltMoonDirection,
                            representedSkyLogLuminance: state.lastBuiltSkyLogLuminance)
        let withinDeclaredBound = completedLag.timeHours <= thresholds.maximumTimeLagHours
            && completedLag.skyLuminanceStops <= thresholds.maximumRadiometricLagStops
        return withinDeclaredBound && completedLag.score < activeLag.score
    }

    public static func shouldSnapCrossfade(current: EnvironmentRenderState,
                                           representedTime: Float,
                                           representedSkyLogLuminance: Float,
                                           thresholds: Thresholds = .production) -> Bool {
        circularHourDistance(current.finalTimeOfDay, representedTime) >= thresholds.snapTimeDiscontinuityHours
            || abs(skyLogLuminance(current) - representedSkyLogLuminance) >= thresholds.snapRadiometricDiscontinuityStops
    }

    private static func circularHourDistance(_ lhs: Float, _ rhs: Float) -> Float {
        let raw = abs(lhs - rhs).truncatingRemainder(dividingBy: 24)
        return min(raw, 24 - raw)
    }

    private static func angularDistanceDegrees(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Float {
        guard simd_length_squared(lhs) > 1e-10, simd_length_squared(rhs) > 1e-10 else { return 180 }
        return acos(min(max(simd_dot(simd_normalize(lhs), simd_normalize(rhs)), -1), 1)) * 180 / .pi
    }

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
