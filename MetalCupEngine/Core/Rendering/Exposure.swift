/// Exposure.swift
/// Engine-wide exposure policy, override resolution, and renderer-facing diagnostics.

import Foundation
import Metal
import simd

public enum ExposureCalibration {
    /// Maps engine scene-linear radiance to EV100. A neutral gain is produced at EV100 15.
    /// Keep this centralized: calibration changes must update deterministic exposure references.
    public static let sceneEV100: Float = 15.0

    public static func physicalEV100(aperture: Float, shutterSeconds: Float, iso: Float) -> Float {
        let safeAperture = max(aperture, 0.1)
        let safeShutter = max(shutterSeconds, 0.000_001)
        let safeISO = max(iso, 1.0)
        return log2((safeAperture * safeAperture / safeShutter) * (100.0 / safeISO))
    }

    public static func exposureGain(ev100: Float, compensation: Float) -> Float {
        exp2(sceneEV100 - ev100 + compensation)
    }

    public static func ev100(fromLegacyGainStops gainStops: Float) -> Float {
        sceneEV100 - gainStops
    }
}

public enum ExposureMode: UInt32, Codable, CaseIterable, Sendable {
    case automaticHistogram = 0
    case manualEV100 = 1
    case physicalCamera = 2
}

public enum ExposureMeteringMode: UInt32, Codable, CaseIterable, Sendable {
    case average = 0
    case centerWeighted = 1
    case spot = 2
    case textureMask = 3
}

public enum ExposureViewKind: UInt32, Codable, CaseIterable, Sendable {
    case game = 0
    case editorScene = 1
    case cameraPreview = 2
    case reflectionProbeCapture = 3
    case iblCapture = 4

    public var isRadiometricCapture: Bool {
        self == .reflectionProbeCapture || self == .iblCapture
    }
}

public enum ExposureTemporalEvent: UInt32, Codable, Sendable {
    case none = 0
    case cameraCut = 1
    case cameraSwitch = 2
    case teleport = 3
    case sceneLoad = 4
    case timelineScrub = 5
    case reset = 6

    public var requiresImmediateSeed: Bool { self != .none }
}

public struct ExposureTargetKeyCurve: Codable, Equatable, Sendable {
    public var daylightKey: Float
    public var twilightKey: Float
    public var nightKey: Float
    public var daylightElevation: Float
    public var nightElevation: Float

    public init(daylightKey: Float = 0.18,
                twilightKey: Float = 0.09,
                nightKey: Float = 0.04,
                daylightElevation: Float = 6.0,
                nightElevation: Float = -10.0) {
        self.daylightKey = daylightKey
        self.twilightKey = twilightKey
        self.nightKey = nightKey
        self.daylightElevation = daylightElevation
        self.nightElevation = nightElevation
    }

    /// Interpolates in stops so authored keys remain perceptually smooth.
    public func key(solarElevationDegrees: Float?) -> Float {
        guard let elevation = solarElevationDegrees, elevation.isFinite else { return daylightKey }
        let safeDay = max(daylightKey, 0.000_001)
        let safeTwilight = max(twilightKey, 0.000_001)
        let safeNight = max(nightKey, 0.000_001)
        if elevation >= 0 {
            let t = Self.smoothstep(0, max(daylightElevation, 0.001), elevation)
            return exp2(Self.mix(log2(safeTwilight), log2(safeDay), t))
        }
        let t = Self.smoothstep(min(nightElevation, -0.001), 0, elevation)
        return exp2(Self.mix(log2(safeNight), log2(safeTwilight), t))
    }

    private static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    private static func smoothstep(_ a: Float, _ b: Float, _ value: Float) -> Float {
        let t = min(max((value - a) / max(b - a, 0.000_001), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

public struct ExposureSettings: Codable, Equatable, Sendable {
    public var mode: ExposureMode
    public var compensation: Float
    public var manualEV100: Float
    public var aperture: Float
    public var shutterSeconds: Float
    public var iso: Float
    public var meteringMode: ExposureMeteringMode
    /// Optional single-channel weighting texture for texture-mask metering. The renderer
    /// falls back to a uniform white mask when the handle cannot be resolved.
    public var meteringMaskHandle: AssetHandle?
    public var histogramLogMin: Float
    public var histogramLogMax: Float
    public var lowPercentile: Float
    public var highPercentile: Float
    public var minimumEV100: Float
    public var maximumEV100: Float
    /// Maximum gain increase per second when the scene becomes darker.
    public var darkAdaptationRate: Float
    /// Maximum gain decrease per second when the scene becomes brighter.
    public var lightAdaptationRate: Float
    public var skyInfluenceCap: Float
    public var targetKeyCurve: ExposureTargetKeyCurve
    public var useOutdoorPrior: Bool

    public init(mode: ExposureMode = .automaticHistogram,
                compensation: Float = 0,
                manualEV100: Float = 14,
                aperture: Float = 16,
                shutterSeconds: Float = 1.0 / 125.0,
                iso: Float = 100,
                meteringMode: ExposureMeteringMode = .centerWeighted,
                meteringMaskHandle: AssetHandle? = nil,
                histogramLogMin: Float = -20,
                histogramLogMax: Float = 16,
                lowPercentile: Float = 0.05,
                highPercentile: Float = 0.95,
                minimumEV100: Float = 2,
                maximumEV100: Float = 17,
                darkAdaptationRate: Float = 3,
                lightAdaptationRate: Float = 8,
                skyInfluenceCap: Float = 0.35,
                targetKeyCurve: ExposureTargetKeyCurve = ExposureTargetKeyCurve(),
                useOutdoorPrior: Bool = true) {
        self.mode = mode
        self.compensation = compensation
        self.manualEV100 = manualEV100
        self.aperture = aperture
        self.shutterSeconds = shutterSeconds
        self.iso = iso
        self.meteringMode = meteringMode
        self.meteringMaskHandle = meteringMaskHandle
        self.histogramLogMin = histogramLogMin
        self.histogramLogMax = histogramLogMax
        self.lowPercentile = lowPercentile
        self.highPercentile = highPercentile
        self.minimumEV100 = minimumEV100
        self.maximumEV100 = maximumEV100
        self.darkAdaptationRate = darkAdaptationRate
        self.lightAdaptationRate = lightAdaptationRate
        self.skyInfluenceCap = skyInfluenceCap
        self.targetKeyCurve = targetKeyCurve
        self.useOutdoorPrior = useOutdoorPrior
        sanitize()
    }

    public mutating func sanitize() {
        compensation = min(max(compensation.isFinite ? compensation : 0, -5), 5)
        manualEV100 = min(max(manualEV100.isFinite ? manualEV100 : 14, -8), 24)
        aperture = min(max(aperture.isFinite ? aperture : 16, 0.7), 64)
        shutterSeconds = min(max(shutterSeconds.isFinite ? shutterSeconds : 1.0 / 125.0, 0.000_01), 60)
        iso = min(max(iso.isFinite ? iso : 100, 1), 204_800)
        histogramLogMin = min(max(histogramLogMin.isFinite ? histogramLogMin : -20, -32), 0)
        histogramLogMax = min(max(histogramLogMax.isFinite ? histogramLogMax : 16, 1), 32)
        if histogramLogMax <= histogramLogMin + 1 { histogramLogMax = histogramLogMin + 1 }
        lowPercentile = min(max(lowPercentile.isFinite ? lowPercentile : 0.05, 0), 0.49)
        highPercentile = min(max(highPercentile.isFinite ? highPercentile : 0.95, 0.51), 1)
        if highPercentile <= lowPercentile { highPercentile = min(lowPercentile + 0.01, 1) }
        minimumEV100 = min(max(minimumEV100.isFinite ? minimumEV100 : 2, -8), 24)
        maximumEV100 = min(max(maximumEV100.isFinite ? maximumEV100 : 17, -8), 24)
        if maximumEV100 < minimumEV100 { swap(&minimumEV100, &maximumEV100) }
        darkAdaptationRate = min(max(darkAdaptationRate.isFinite ? darkAdaptationRate : 3, 0.01), 32)
        lightAdaptationRate = min(max(lightAdaptationRate.isFinite ? lightAdaptationRate : 8, 0.01), 32)
        skyInfluenceCap = min(max(skyInfluenceCap.isFinite ? skyInfluenceCap : 0.35, 0), 1)
    }

    public var authoredEV100: Float {
        switch mode {
        case .automaticHistogram: return manualEV100
        case .manualEV100: return manualEV100
        case .physicalCamera:
            return ExposureCalibration.physicalEV100(aperture: aperture, shutterSeconds: shutterSeconds, iso: iso)
        }
    }
}

/// Optional fields are deliberate: inheritance is field-level rather than an all-or-nothing camera toggle.
public struct ExposurePolicyOverride: Codable, Equatable, Sendable {
    public var mode: ExposureMode?
    public var compensation: Float?
    public var manualEV100: Float?
    public var aperture: Float?
    public var shutterSeconds: Float?
    public var iso: Float?
    public var meteringMode: ExposureMeteringMode?
    public var meteringMaskHandle: AssetHandle?
    public var histogramLogMin: Float?
    public var histogramLogMax: Float?
    public var lowPercentile: Float?
    public var highPercentile: Float?
    public var minimumEV100: Float?
    public var maximumEV100: Float?
    public var darkAdaptationRate: Float?
    public var lightAdaptationRate: Float?
    public var skyInfluenceCap: Float?
    public var targetKeyCurve: ExposureTargetKeyCurve?
    public var useOutdoorPrior: Bool?

    public init(mode: ExposureMode? = nil,
                compensation: Float? = nil,
                manualEV100: Float? = nil,
                aperture: Float? = nil,
                shutterSeconds: Float? = nil,
                iso: Float? = nil,
                meteringMode: ExposureMeteringMode? = nil,
                meteringMaskHandle: AssetHandle? = nil,
                histogramLogMin: Float? = nil,
                histogramLogMax: Float? = nil,
                lowPercentile: Float? = nil,
                highPercentile: Float? = nil,
                minimumEV100: Float? = nil,
                maximumEV100: Float? = nil,
                darkAdaptationRate: Float? = nil,
                lightAdaptationRate: Float? = nil,
                skyInfluenceCap: Float? = nil,
                targetKeyCurve: ExposureTargetKeyCurve? = nil,
                useOutdoorPrior: Bool? = nil) {
        self.mode = mode
        self.compensation = compensation
        self.manualEV100 = manualEV100
        self.aperture = aperture
        self.shutterSeconds = shutterSeconds
        self.iso = iso
        self.meteringMode = meteringMode
        self.meteringMaskHandle = meteringMaskHandle
        self.histogramLogMin = histogramLogMin
        self.histogramLogMax = histogramLogMax
        self.lowPercentile = lowPercentile
        self.highPercentile = highPercentile
        self.minimumEV100 = minimumEV100
        self.maximumEV100 = maximumEV100
        self.darkAdaptationRate = darkAdaptationRate
        self.lightAdaptationRate = lightAdaptationRate
        self.skyInfluenceCap = skyInfluenceCap
        self.targetKeyCurve = targetKeyCurve
        self.useOutdoorPrior = useOutdoorPrior
    }

    public static let inheritAll = ExposurePolicyOverride()
    public var isEmpty: Bool { self == .inheritAll }
}

public struct ExposureOverrideFieldMask: OptionSet, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let mode = Self(rawValue: 1 << 0)
    public static let compensation = Self(rawValue: 1 << 1)
    public static let manualEV100 = Self(rawValue: 1 << 2)
    public static let aperture = Self(rawValue: 1 << 3)
    public static let shutterSeconds = Self(rawValue: 1 << 4)
    public static let iso = Self(rawValue: 1 << 5)
    public static let meteringMode = Self(rawValue: 1 << 6)
    public static let percentiles = Self(rawValue: 1 << 7)
    public static let limits = Self(rawValue: 1 << 8)
    public static let adaptation = Self(rawValue: 1 << 9)
    public static let histogramRange = Self(rawValue: 1 << 10)
    public static let skyInfluence = Self(rawValue: 1 << 11)
    public static let targetKey = Self(rawValue: 1 << 12)
    public static let outdoorPrior = Self(rawValue: 1 << 13)
    public static let meteringMask = Self(rawValue: 1 << 14)

    public static func fields(in policy: ExposurePolicyOverride) -> Self {
        var result: Self = []
        if policy.mode != nil { result.insert(.mode) }
        if policy.compensation != nil { result.insert(.compensation) }
        if policy.manualEV100 != nil { result.insert(.manualEV100) }
        if policy.aperture != nil { result.insert(.aperture) }
        if policy.shutterSeconds != nil { result.insert(.shutterSeconds) }
        if policy.iso != nil { result.insert(.iso) }
        if policy.meteringMode != nil { result.insert(.meteringMode) }
        if policy.lowPercentile != nil || policy.highPercentile != nil { result.insert(.percentiles) }
        if policy.minimumEV100 != nil || policy.maximumEV100 != nil { result.insert(.limits) }
        if policy.darkAdaptationRate != nil || policy.lightAdaptationRate != nil { result.insert(.adaptation) }
        if policy.histogramLogMin != nil || policy.histogramLogMax != nil { result.insert(.histogramRange) }
        if policy.skyInfluenceCap != nil { result.insert(.skyInfluence) }
        if policy.targetKeyCurve != nil { result.insert(.targetKey) }
        if policy.useOutdoorPrior != nil { result.insert(.outdoorPrior) }
        if policy.meteringMaskHandle != nil { result.insert(.meteringMask) }
        return result
    }
}

public enum ExposureLockOperation: UInt32, Codable, Sendable {
    case lock = 1
    case unlock = 2
}

public struct ExposureOverrideLayer: Equatable, Sendable {
    public var policy: ExposurePolicyOverride
    public var weight: Float
    public var priority: Int
    public var source: String
    public var lockOperation: ExposureLockOperation?
    public var locksExposure: Bool { lockOperation == .lock }

    public init(policy: ExposurePolicyOverride,
                weight: Float = 1,
                priority: Int = 0,
                source: String,
                locksExposure: Bool = false,
                lockOperation: ExposureLockOperation? = nil) {
        self.policy = policy
        self.weight = weight
        self.priority = priority
        self.source = source
        self.lockOperation = lockOperation ?? (locksExposure ? .lock : nil)
    }
}

public struct ResolvedExposurePolicy: Equatable, Sendable {
    public var settings: ExposureSettings
    public var resolvedSource: String
    public var isLocked: Bool
}

public enum ExposurePolicyResolver {
    public static let engineFallback = ExposureSettings()

    public static func resolve(project: ExposureSettings,
                               camera: ExposurePolicyOverride = .inheritAll,
                               volumes: [ExposureOverrideLayer] = [],
                               gameplayAndCinematic: [ExposureOverrideLayer] = [],
                               viewport: ExposureOverrideLayer? = nil) -> ResolvedExposurePolicy {
        var settings = engineFallback
        settings = project
        var source = "Project Render Settings"
        apply(camera, weight: 1, to: &settings)
        if !camera.isEmpty { source = "Camera" }
        var locked = false
        let sortedVolumes = volumes.enumerated().sorted {
            ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset)
        }.map(\.element)
        for layer in sortedVolumes where layer.weight > 0 {
            apply(layer.policy, weight: layer.weight, to: &settings)
            source = layer.source
            if let operation = layer.lockOperation { locked = operation == .lock }
        }
        let sortedRuntime = gameplayAndCinematic.enumerated().sorted {
            ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset)
        }.map(\.element)
        for layer in sortedRuntime where layer.weight > 0 {
            apply(layer.policy, weight: layer.weight, to: &settings)
            source = layer.source
            if let operation = layer.lockOperation { locked = operation == .lock }
        }
        if let viewport, viewport.weight > 0 {
            apply(viewport.policy, weight: viewport.weight, to: &settings)
            source = viewport.source
            if let operation = viewport.lockOperation { locked = operation == .lock }
        }
        settings.sanitize()
        return ResolvedExposurePolicy(settings: settings, resolvedSource: source, isLocked: locked)
    }

    /// Numeric fields interpolate in stops/authoring space. Categories and booleans switch at 50%.
    public static func apply(_ override: ExposurePolicyOverride,
                             weight: Float,
                             to settings: inout ExposureSettings) {
        let w = min(max(weight, 0), 1)
        guard w > 0 else { return }
        func blend(_ current: Float, _ value: Float?) -> Float {
            guard let value, value.isFinite else { return current }
            return current + (value - current) * w
        }
        if let value = override.mode, w >= 0.5 { settings.mode = value }
        settings.compensation = blend(settings.compensation, override.compensation)
        settings.manualEV100 = blend(settings.manualEV100, override.manualEV100)
        settings.aperture = blend(settings.aperture, override.aperture)
        settings.shutterSeconds = blend(settings.shutterSeconds, override.shutterSeconds)
        settings.iso = blend(settings.iso, override.iso)
        if let value = override.meteringMode, w >= 0.5 { settings.meteringMode = value }
        if let value = override.meteringMaskHandle, w >= 0.5 { settings.meteringMaskHandle = value }
        settings.histogramLogMin = blend(settings.histogramLogMin, override.histogramLogMin)
        settings.histogramLogMax = blend(settings.histogramLogMax, override.histogramLogMax)
        settings.lowPercentile = blend(settings.lowPercentile, override.lowPercentile)
        settings.highPercentile = blend(settings.highPercentile, override.highPercentile)
        settings.minimumEV100 = blend(settings.minimumEV100, override.minimumEV100)
        settings.maximumEV100 = blend(settings.maximumEV100, override.maximumEV100)
        settings.darkAdaptationRate = blend(settings.darkAdaptationRate, override.darkAdaptationRate)
        settings.lightAdaptationRate = blend(settings.lightAdaptationRate, override.lightAdaptationRate)
        settings.skyInfluenceCap = blend(settings.skyInfluenceCap, override.skyInfluenceCap)
        if let curve = override.targetKeyCurve {
            settings.targetKeyCurve.daylightKey = blendStops(settings.targetKeyCurve.daylightKey, curve.daylightKey, w)
            settings.targetKeyCurve.twilightKey = blendStops(settings.targetKeyCurve.twilightKey, curve.twilightKey, w)
            settings.targetKeyCurve.nightKey = blendStops(settings.targetKeyCurve.nightKey, curve.nightKey, w)
            settings.targetKeyCurve.daylightElevation = blend(settings.targetKeyCurve.daylightElevation, curve.daylightElevation)
            settings.targetKeyCurve.nightElevation = blend(settings.targetKeyCurve.nightElevation, curve.nightElevation)
        }
        if let value = override.useOutdoorPrior, w >= 0.5 { settings.useOutdoorPrior = value }
    }

    private static func blendStops(_ current: Float, _ value: Float, _ weight: Float) -> Float {
        exp2(log2(max(current, 0.000_001)) + (log2(max(value, 0.000_001)) - log2(max(current, 0.000_001))) * weight)
    }
}

public enum ExposureHistogramReference {
    public static let binCount = 128

    public static func histogram(luminances: [Float],
                                 weights: [Float]? = nil,
                                 logMin: Float = -20,
                                 logMax: Float = 16) -> [UInt32] {
        var result = Array(repeating: UInt32(0), count: binCount)
        let range = max(logMax - logMin, 0.000_001)
        for (index, luminance) in luminances.enumerated() {
            let logValue = log2(max(luminance.isFinite ? luminance : 0, exp2(logMin)))
            let normalized = min(max((logValue - logMin) / range, 0), 1)
            let bin = min(Int(normalized * Float(binCount)), binCount - 1)
            let weight = weights.flatMap { index < $0.count ? $0[index] : nil } ?? 1
            let fixedWeight = UInt32(max(weight * 1024, 0).rounded())
            result[bin] &+= fixedWeight
        }
        return result
    }

    public static func percentileMeanLuminance(histogram: [UInt32],
                                               logMin: Float = -20,
                                               logMax: Float = 16,
                                               lowPercentile: Float = 0.05,
                                               highPercentile: Float = 0.95) -> Float {
        let bins = Array(histogram.prefix(binCount)) + Array(repeating: 0, count: max(0, binCount - histogram.count))
        let total = bins.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard total > 0 else { return 0 }
        let low = UInt64(Float(total) * min(max(lowPercentile, 0), 1))
        let high = max(UInt64(Float(total) * min(max(highPercentile, 0), 1)), low + 1)
        var cumulative: UInt64 = 0
        var included: UInt64 = 0
        var weightedLog: Double = 0
        for index in 0..<binCount {
            let count = UInt64(bins[index])
            let next = cumulative + count
            let begin = max(cumulative, low)
            let end = min(next, high)
            if end > begin {
                let accepted = end - begin
                let binLog = logMin + (Float(index) + 0.5) * ((logMax - logMin) / Float(binCount))
                weightedLog += Double(binLog) * Double(accepted)
                included += accepted
            }
            cumulative = next
        }
        guard included > 0 else { return 0 }
        return exp2(Float(weightedLog / Double(included)))
    }

    public static func targetEV100(meteredLuminance: Float,
                                   targetKey: Float,
                                   minimumEV100: Float,
                                   maximumEV100: Float) -> Float {
        let value = ExposureCalibration.sceneEV100
            - log2(max(targetKey, 0.000_001) / max(meteredLuminance, 0.000_001))
        return min(max(value, minimumEV100), maximumEV100)
    }

    public static func adaptedEV100(current: Float,
                                    target: Float,
                                    deltaTime: Float,
                                    darkAdaptationRate: Float,
                                    lightAdaptationRate: Float) -> Float {
        let delta = target - current
        guard abs(delta) > 0.000_1 else { return target }
        let rate = delta < 0 ? darkAdaptationRate : lightAdaptationRate
        let step = min(abs(delta), max(rate, 0) * max(deltaTime, 0))
        return current + (delta < 0 ? -step : step)
    }
}

public struct ExposureViewStateIdentity: Hashable, Codable, Sendable {
    public var sceneID: UUID
    public var cameraID: UUID
    public var viewportInstanceID: UInt64
    public var viewKind: ExposureViewKind

    public init(sceneID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                cameraID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                viewportInstanceID: UInt64 = 0,
                viewKind: ExposureViewKind = .game) {
        self.sceneID = sceneID
        self.cameraID = cameraID
        self.viewportInstanceID = viewportInstanceID
        self.viewKind = viewKind
    }
}

public struct ExposureDiagnostics: Equatable, Sendable {
    public var identity: ExposureViewStateIdentity
    public var histogram: [UInt32]
    public var meteredLuminance: Float
    public var targetEV100: Float
    public var currentEV100: Float
    public var effectiveGain: Float
    public var compensation: Float
    public var minimumEV100: Float
    public var maximumEV100: Float
    public var adaptationState: String
    public var renderPreExposure: Float
    public var resolvedSource: String
    public var outdoorPriorContribution: Float
    public var maximumStoredHDR: Float
    public var fp16SaturationCount: UInt32

    public init(identity: ExposureViewStateIdentity,
                histogram: [UInt32] = Array(repeating: 0, count: 128),
                meteredLuminance: Float = 0,
                targetEV100: Float = 15,
                currentEV100: Float = 15,
                effectiveGain: Float = 1,
                compensation: Float = 0,
                minimumEV100: Float = 2,
                maximumEV100: Float = 17,
                adaptationState: String = "Seeded",
                renderPreExposure: Float = 1,
                resolvedSource: String = "Engine Fallback",
                outdoorPriorContribution: Float = 0,
                maximumStoredHDR: Float = 0,
                fp16SaturationCount: UInt32 = 0) {
        self.identity = identity
        self.histogram = histogram
        self.meteredLuminance = meteredLuminance
        self.targetEV100 = targetEV100
        self.currentEV100 = currentEV100
        self.effectiveGain = effectiveGain
        self.compensation = compensation
        self.minimumEV100 = minimumEV100
        self.maximumEV100 = maximumEV100
        self.adaptationState = adaptationState
        self.renderPreExposure = renderPreExposure
        self.resolvedSource = resolvedSource
        self.outdoorPriorContribution = outdoorPriorContribution
        self.maximumStoredHDR = maximumStoredHDR
        self.fp16SaturationCount = fp16SaturationCount
    }
}

/// ABI mirrored by `ViewExposureSettings` in Shared.metal.
public struct ExposureOutputUniforms: sizeable {
    public static let expectedMetalStride = 64
    public var exposureGain: Float = 1
    public var currentEV100: Float = ExposureCalibration.sceneEV100
    public var targetEV100: Float = ExposureCalibration.sceneEV100
    public var meteredLuminance: Float = 0.18
    public var renderPreExposure: Float = 1
    public var inverseRenderPreExposure: Float = 1
    public var maximumStoredHDR: Float = 0
    public var outdoorPriorContribution: Float = 0
    public var compensation: Float = 0
    public var minimumEV100: Float = 2
    public var maximumEV100: Float = 17
    public var adaptationState: UInt32 = 0
    public var mode: UInt32 = ExposureMode.automaticHistogram.rawValue
    public var histogramSampleCount: UInt32 = 0
    public var fp16SaturationCount: UInt32 = 0
    public var flags: UInt32 = 0
}

struct ExposureMeteringUniforms: sizeable {
    static let expectedMetalStride = 112
    var viewportWidth: UInt32 = 1
    var viewportHeight: UInt32 = 1
    var meteringMode: UInt32 = ExposureMeteringMode.centerWeighted.rawValue
    var resetHistory: UInt32 = 0
    var histogramLogMin: Float = -20
    var histogramLogMax: Float = 16
    var lowPercentile: Float = 0.05
    var highPercentile: Float = 0.95
    var minimumEV100: Float = 2
    var maximumEV100: Float = 17
    var compensation: Float = 0
    var targetKey: Float = 0.18
    var darkAdaptationRate: Float = 3
    var lightAdaptationRate: Float = 8
    var deltaTime: Float = 0
    var renderPreExposure: Float = 1
    var skyInfluenceCap: Float = 0.35
    var sceneEV100Calibration: Float = ExposureCalibration.sceneEV100
    var authoredEV100: Float = 14
    var exposureMode: UInt32 = ExposureMode.automaticHistogram.rawValue
    var exposureLocked: UInt32 = 0
    var outdoorPriorEnabled: UInt32 = 0
    var padding0: UInt32 = 0
    var outdoorPriorStrength: Float = 0
    var fp16Maximum: Float = 65_504
    var padding1: SIMD2<Float> = .zero
}

public struct ExposureOverrideToken: Hashable, Sendable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

struct ExposureFrameResources {
    let identity: ExposureViewStateIdentity
    let resolvedPolicy: ResolvedExposurePolicy
    let histogramBuffer: MTLBuffer
    let outputBuffer: MTLBuffer
    var meteringUniforms: ExposureMeteringUniforms
    let generation: UInt64

    var automatic: Bool {
        resolvedPolicy.settings.mode == .automaticHistogram && !identity.viewKind.isRadiometricCapture
    }
}

/// Renderer-owned state. No environment or camera object holds temporal adaptation history.
final class ExposureSystem {
    private final class ViewState {
        let identity: ExposureViewStateIdentity
        let histogramBuffers: [MTLBuffer]
        let outputBuffers: [MTLBuffer]
        var currentEV100: Float
        var generation: UInt64 = 0
        var initialized = false
        var lastCameraPosition: SIMD3<Float>?
        var lastSolarElevationDegrees: Float?
        var latestDiagnostics: ExposureDiagnostics

        init(identity: ExposureViewStateIdentity,
             histogramBuffers: [MTLBuffer],
             outputBuffers: [MTLBuffer],
             seedEV100: Float) {
            self.identity = identity
            self.histogramBuffers = histogramBuffers
            self.outputBuffers = outputBuffers
            self.currentEV100 = seedEV100
            self.latestDiagnostics = ExposureDiagnostics(identity: identity, currentEV100: seedEV100)
        }
    }

    private let device: MTLDevice
    private let diagnosticsCommit: (ExposureDiagnostics) -> Void
    private let lock = NSLock()
    private var states: [ExposureViewStateIdentity: ViewState] = [:]
    private var runtimeOverrides: [(token: ExposureOverrideToken, layer: ExposureOverrideLayer)] = []
    private var viewportOverrides: [UInt64: ExposureOverrideLayer] = [:]
    private var pendingEvents: [ExposureViewStateIdentity: ExposureTemporalEvent] = [:]

    init(device: MTLDevice, diagnosticsCommit: @escaping (ExposureDiagnostics) -> Void) {
        self.device = device
        self.diagnosticsCommit = diagnosticsCommit
    }

    func pushRuntimeOverride(_ layer: ExposureOverrideLayer) -> ExposureOverrideToken {
        lock.lock()
        defer { lock.unlock() }
        let token = ExposureOverrideToken()
        runtimeOverrides.append((token, layer))
        return token
    }

    func removeRuntimeOverride(_ token: ExposureOverrideToken) {
        lock.lock()
        runtimeOverrides.removeAll { $0.token == token }
        lock.unlock()
    }

    func setViewportOverride(_ layer: ExposureOverrideLayer?, viewportID: UInt64) {
        lock.lock()
        viewportOverrides[viewportID] = layer
        lock.unlock()
    }

    func notify(_ event: ExposureTemporalEvent, identity: ExposureViewStateIdentity) {
        lock.lock()
        pendingEvents[identity] = event
        lock.unlock()
    }

    func resetAll() {
        lock.lock()
        states.removeAll(keepingCapacity: true)
        pendingEvents.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func reset(viewportID: UInt64) {
        lock.lock()
        states = states.filter { $0.key.viewportInstanceID != viewportID }
        pendingEvents = pendingEvents.filter { $0.key.viewportInstanceID != viewportID }
        lock.unlock()
    }

    func prepare(identity: ExposureViewStateIdentity,
                 projectDefaults: ExposureSettings,
                 viewSettings: SceneViewExposureSettings,
                 solarElevationDegrees: Float?,
                 cameraPosition: SIMD3<Float>? = nil,
                 unscaledDeltaTime: Float,
                 frameIndex: Int) -> ExposureFrameResources? {
        lock.lock()
        defer { lock.unlock() }

        let runtimeLayers = runtimeOverrides.map(\.layer)
        let viewportLayer = viewportOverrides[identity.viewportInstanceID]
        let resolved = ExposurePolicyResolver.resolve(
            project: projectDefaults,
            camera: viewSettings.cameraOverride,
            volumes: viewSettings.volumeOverrides,
            gameplayAndCinematic: runtimeLayers,
            viewport: viewportLayer
        )
        let policy = resolved.settings
        let seedEV = seedEV100(policy: policy, solarElevationDegrees: solarElevationDegrees)
        let state: ViewState
        if let existing = states[identity] {
            state = existing
        } else {
            guard let created = makeState(identity: identity, seedEV100: seedEV) else { return nil }
            states[identity] = created
            state = created
        }
        let explicitEvent = pendingEvents.removeValue(forKey: identity) ?? .none
        let event = viewSettings.temporalEvent != .none ? viewSettings.temporalEvent : explicitEvent
        let teleported: Bool = {
            guard let current = cameraPosition, let previous = state.lastCameraPosition else { return false }
            return simd_distance(current, previous) > 25
        }()
        let rapidEnvironmentChange: Bool = {
            guard let current = solarElevationDegrees, let previous = state.lastSolarElevationDegrees else { return false }
            return abs(current - previous) > 5
        }()
        state.lastCameraPosition = cameraPosition
        state.lastSolarElevationDegrees = solarElevationDegrees
        let reset = !state.initialized || event.requiresImmediateSeed || teleported || rapidEnvironmentChange
        if reset {
            state.currentEV100 = seedEV
            state.initialized = true
        }
        state.generation &+= 1

        let slot = max(0, frameIndex % state.outputBuffers.count)
        let targetEV: Float
        switch policy.mode {
        case .automaticHistogram:
            targetEV = state.currentEV100
        case .manualEV100, .physicalCamera:
            targetEV = min(max(policy.authoredEV100, policy.minimumEV100), policy.maximumEV100)
            state.currentEV100 = targetEV
        }
        let gain = identity.viewKind.isRadiometricCapture
            ? 1
            : ExposureCalibration.exposureGain(ev100: state.currentEV100, compensation: policy.compensation)
        // Pre-exposure is conditioning only. The conservative cap protects day cuts from stale night gain.
        let preExposure: Float = identity.viewKind.isRadiometricCapture ? 1 : min(max(gain, 1.0 / 1024.0), 32.0)
        var output = ExposureOutputUniforms()
        output.exposureGain = identity.viewKind.isRadiometricCapture ? 1 : gain
        output.currentEV100 = state.currentEV100
        output.targetEV100 = targetEV
        output.meteredLuminance = policy.targetKeyCurve.key(solarElevationDegrees: solarElevationDegrees)
        output.renderPreExposure = preExposure
        output.inverseRenderPreExposure = 1 / max(preExposure, 0.000_001)
        output.compensation = policy.compensation
        output.minimumEV100 = policy.minimumEV100
        output.maximumEV100 = policy.maximumEV100
        output.mode = policy.mode.rawValue
        output.flags = resolved.isLocked ? 1 : 0
        write(output, to: state.outputBuffers[slot])

        var uniforms = ExposureMeteringUniforms()
        uniforms.meteringMode = policy.meteringMode.rawValue
        uniforms.resetHistory = reset ? 1 : 0
        uniforms.histogramLogMin = policy.histogramLogMin
        uniforms.histogramLogMax = policy.histogramLogMax
        uniforms.lowPercentile = policy.lowPercentile
        uniforms.highPercentile = policy.highPercentile
        uniforms.minimumEV100 = policy.minimumEV100
        uniforms.maximumEV100 = policy.maximumEV100
        uniforms.compensation = policy.compensation
        let targetKey = policy.targetKeyCurve.key(solarElevationDegrees: solarElevationDegrees)
        uniforms.targetKey = targetKey
        uniforms.darkAdaptationRate = policy.darkAdaptationRate
        uniforms.lightAdaptationRate = policy.lightAdaptationRate
        uniforms.deltaTime = (viewSettings.adaptationPaused || resolved.isLocked)
            ? 0
            : min(max(unscaledDeltaTime, 0), 0.25)
        uniforms.renderPreExposure = preExposure
        uniforms.skyInfluenceCap = policy.skyInfluenceCap
        uniforms.authoredEV100 = targetEV
        uniforms.exposureMode = policy.mode.rawValue
        uniforms.exposureLocked = resolved.isLocked ? 1 : 0
        uniforms.outdoorPriorEnabled = (policy.useOutdoorPrior && solarElevationDegrees != nil) ? 1 : 0
        // Report the solar presentation prior in stops relative to histogram-only
        // daylight metering. It remains zero for HDRIs with no time metadata.
        uniforms.outdoorPriorStrength = (policy.useOutdoorPrior && solarElevationDegrees != nil)
            ? log2(max(policy.targetKeyCurve.daylightKey, 0.000_001) / max(targetKey, 0.000_001))
            : 0

        state.latestDiagnostics.currentEV100 = state.currentEV100
        state.latestDiagnostics.targetEV100 = targetEV
        state.latestDiagnostics.effectiveGain = gain
        state.latestDiagnostics.compensation = policy.compensation
        state.latestDiagnostics.minimumEV100 = policy.minimumEV100
        state.latestDiagnostics.maximumEV100 = policy.maximumEV100
        state.latestDiagnostics.renderPreExposure = preExposure
        state.latestDiagnostics.resolvedSource = resolved.resolvedSource
        state.latestDiagnostics.adaptationState = reset ? "Seeded" : (resolved.isLocked ? "Locked" : "Adapting")
        state.latestDiagnostics.outdoorPriorContribution = uniforms.outdoorPriorStrength
        if policy.mode != .automaticHistogram || identity.viewKind.isRadiometricCapture {
            diagnosticsCommit(state.latestDiagnostics)
        }
        return ExposureFrameResources(
            identity: identity,
            resolvedPolicy: resolved,
            histogramBuffer: state.histogramBuffers[slot],
            outputBuffer: state.outputBuffers[slot],
            meteringUniforms: uniforms,
            generation: state.generation
        )
    }

    func complete(_ resources: ExposureFrameResources) {
        lock.lock()
        defer { lock.unlock() }
        guard let state = states[resources.identity], state.generation >= resources.generation else { return }
        let output = resources.outputBuffer.contents().bindMemory(to: ExposureOutputUniforms.self, capacity: 1).pointee
        guard output.currentEV100.isFinite, output.exposureGain.isFinite else { return }
        state.currentEV100 = output.currentEV100
        let histogramPointer = resources.histogramBuffer.contents().bindMemory(to: UInt32.self, capacity: 130)
        let histogram = (0..<128).map { histogramPointer[$0] }
        state.latestDiagnostics.histogram = histogram
        state.latestDiagnostics.meteredLuminance = output.meteredLuminance
        state.latestDiagnostics.targetEV100 = output.targetEV100
        state.latestDiagnostics.currentEV100 = output.currentEV100
        state.latestDiagnostics.effectiveGain = output.exposureGain
        state.latestDiagnostics.maximumStoredHDR = output.maximumStoredHDR
        state.latestDiagnostics.fp16SaturationCount = output.fp16SaturationCount
        state.latestDiagnostics.adaptationState = output.adaptationState == 0 ? "Stable" : (output.adaptationState == 1 ? "Dark Adapting" : "Light Adapting")
        diagnosticsCommit(state.latestDiagnostics)
    }

    private func makeState(identity: ExposureViewStateIdentity, seedEV100: Float) -> ViewState? {
        var histograms: [MTLBuffer] = []
        var outputs: [MTLBuffer] = []
        for index in 0..<3 {
            guard let histogram = device.makeBuffer(length: 130 * MemoryLayout<UInt32>.stride, options: [.storageModeShared]),
                  let output = device.makeBuffer(length: ExposureOutputUniforms.stride, options: [.storageModeShared]) else {
                return nil
            }
            histogram.label = "Exposure.Histogram.\(identity.viewportInstanceID).\(index)"
            output.label = "Exposure.Output.\(identity.viewportInstanceID).\(index)"
            memset(histogram.contents(), 0, histogram.length)
            outputs.append(output)
            histograms.append(histogram)
        }
        return ViewState(identity: identity, histogramBuffers: histograms, outputBuffers: outputs, seedEV100: seedEV100)
    }

    private func seedEV100(policy: ExposureSettings, solarElevationDegrees: Float?) -> Float {
        if policy.mode != .automaticHistogram {
            return min(max(policy.authoredEV100, policy.minimumEV100), policy.maximumEV100)
        }
        guard policy.useOutdoorPrior, let elevation = solarElevationDegrees else {
            return min(max(ExposureCalibration.sceneEV100, policy.minimumEV100), policy.maximumEV100)
        }
        let seed: Float
        if elevation >= 6 { seed = 14 }
        else if elevation >= 0 { seed = 12 + elevation / 3 }
        else if elevation >= -6 { seed = 9 + (elevation + 6) * 0.5 }
        else { seed = 5 + min(max((elevation + 10) / 4, 0), 1) * 4 }
        return min(max(seed, policy.minimumEV100), policy.maximumEV100)
    }

    private func write(_ output: ExposureOutputUniforms, to buffer: MTLBuffer) {
        var value = output
        withUnsafeBytes(of: &value) { bytes in
            buffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: min(bytes.count, buffer.length))
        }
    }
}
