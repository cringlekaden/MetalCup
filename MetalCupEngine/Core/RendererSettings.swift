/// RendererSettings.swift
/// Defines the RendererSettings types and helpers for the engine.
/// Created by Kaden Cringle.

import Foundation
import Metal

public enum TonemapType: UInt32 {
    case none = 0
    case reinhard = 1
    case aces = 2
    case metalCupCustom = 3
    case agx = 4
    case filmic = 5
}

public enum IBLQualityPreset: UInt32 {
    case low = 0
    case medium = 1
    case high = 2
    case ultra = 3
    case custom = 4
}

public enum AOMethod: UInt32 {
    case sao = 0
}

public enum AOQualityPreset: UInt32 {
    case low = 0
    case medium = 1
    case high = 2
    case ultra = 3
    case custom = 4
}

public enum FogColorMode: UInt32 {
    case manual = 0
    case matchActiveSky = 1
}

public struct RendererDiagnosticFlags: OptionSet {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let orientationSkybox = RendererDiagnosticFlags(rawValue: 1 << 0)
    public static let orientationGlobalIBL = RendererDiagnosticFlags(rawValue: 1 << 1)
    public static let orientationLocalProbe = RendererDiagnosticFlags(rawValue: 1 << 2)
}

public enum ShadowFilterMode: UInt32 {
    case hard = 0
    case pcf = 1
    case pcssExperimental = 2
}

public enum BloomQualityPreset: UInt32 {
    case low = 0
    case medium = 1
    case high = 2
    case ultra = 3
    case custom = 4
}

public enum BloomResolutionScale: UInt32 {
    case half = 2
    case quarter = 4
}

public enum ShadowPCFQualityPreset: UInt32 {
    case low = 0
    case medium = 1
    case high = 2
    case ultra = 3
    case custom = 4
}

public struct ShadowsSettings {
    public var enabled: UInt32 = 0
    public var directionalEnabled: UInt32 = 1
    public var shadowMapResolution: UInt32 = 2048
    public var cascadeCount: UInt32 = 3
    public var cascadeSplitLambda: Float = 0.65
    public var depthBias: Float = 0.0005
    public var normalBias: Float = 0.01
    public var pcfRadius: Float = 1.0
    public var pcfTapPreset: UInt32 = ShadowPCFQualityPreset.high.rawValue
    public var pcfTapsCascade0: UInt32 = 16
    public var pcfTapsCascade1: UInt32 = 9
    public var pcfTapsCascade2: UInt32 = 9
    public var pcfTapsCascade3: UInt32 = 4
    public var filterMode: UInt32 = ShadowFilterMode.pcf.rawValue
    public var maxShadowDistance: Float = 100.0
    public var fadeOutDistance: Float = 10.0
    public var pcssLightWorldSize: Float = 1.0
    public var pcssMinFilterRadiusTexels: Float = 1.0
    public var pcssMaxFilterRadiusTexels: Float = 6.0
    public var pcssBlockerSearchRadiusTexels: Float = 3.0
    public var pcssBlockerSamples: UInt32 = 8
    public var pcssPCFSamples: UInt32 = 12
    public var pcssNoiseEnabled: UInt32 = 0
    public var pcssPadding: UInt32 = 0

    public init() {}

    public mutating func applyPCFPreset(_ preset: ShadowPCFQualityPreset) {
        pcfTapPreset = preset.rawValue
        switch preset {
        case .low:
            pcfTapsCascade0 = 4
            pcfTapsCascade1 = 4
            pcfTapsCascade2 = 4
            pcfTapsCascade3 = 4
        case .medium:
            pcfTapsCascade0 = 9
            pcfTapsCascade1 = 9
            pcfTapsCascade2 = 4
            pcfTapsCascade3 = 4
        case .high:
            pcfTapsCascade0 = 16
            pcfTapsCascade1 = 9
            pcfTapsCascade2 = 9
            pcfTapsCascade3 = 4
        case .ultra:
            pcfTapsCascade0 = 25
            pcfTapsCascade1 = 16
            pcfTapsCascade2 = 9
            pcfTapsCascade3 = 9
        case .custom:
            break
        }
    }

    public mutating func refreshPCFPreset() {
        let preset: ShadowPCFQualityPreset
        switch (pcfTapsCascade0, pcfTapsCascade1, pcfTapsCascade2, pcfTapsCascade3) {
        case (4, 4, 4, 4):
            preset = .low
        case (9, 9, 4, 4):
            preset = .medium
        case (16, 9, 9, 4):
            preset = .high
        case (25, 16, 9, 9):
            preset = .ultra
        default:
            preset = .custom
        }
        pcfTapPreset = preset.rawValue
    }
}

public typealias BloomUniforms = RendererSettings
public typealias RendererUniforms = RendererSettings

public struct RendererSettings: sizeable {
    public static let expectedMetalStride: Int = 464

    public init() {}

    public var bloomThreshold: Float = 1.65
    public var bloomKnee: Float = 0.16
    public var bloomIntensity: Float = 0.12
    // Reserved to preserve Swift/Metal uniform ABI for legacy bloom fields that are no longer consumed.
    public var reservedBloom0: Float = 1.0
    public var reservedBloom1: Float = 0.0
    public var bloomEnabled: UInt32 = 1

    public var bloomTexelSize: SIMD2<Float> = .zero
    public var bloomMipLevel: Float = 0
    public var bloomMaxMips: UInt32 = 4
    public var bloomQualityPreset: UInt32 = BloomQualityPreset.high.rawValue
    public var bloomResolutionScale: UInt32 = BloomResolutionScale.half.rawValue

    public var reservedBloom2: UInt32 = 6
    // Reserved legacy authoring field. Normal output is always MetalCup Filmic v1.
    public var tonemap: UInt32 = TonemapType.filmic.rawValue
    // Numerical conditioning only. Camera exposure is resolved per view and applied in final output.
    public var renderPreExposure: Float = 1.0
    // Reserved legacy authoring field. SDR is encoded to sRGB exactly once.
    public var gamma: Float = 2.2

    public var iblEnabled: UInt32 = 1
    // Reserved legacy authoring field. Captured environment radiance is sampled at gain 1.
    public var iblIntensity: Float = 1.0
    // Reserved to preserve Swift/Metal uniform ABI for an unused IBL override slot.
    public var reservedIBL0: UInt32 = 0

    public mutating func applySceneLinearHDROutputInvariants() {
        tonemap = TonemapType.filmic.rawValue
        gamma = 2.2
        iblIntensity = 1.0
    }

    public var effectiveGlobalIBLSamplingGain: Float {
        iblEnabled != 0 ? 1.0 : 0.0
    }


    public var perfFlags: UInt32 = 0

    // Reserved legacy IBL clamp controls. Production convolution preserves source radiance.
    public var iblFireflyClamp: Float = 100.0
    public var iblFireflyClampEnabled: UInt32 = 0
    public var iblSampleMultiplier: Float = 1.0
    public var skyboxMipBias: Float = 0.0
    // Reserved legacy fields. Production prefilter generation and sampling use
    // the same linear perceptual-roughness-to-mip mapping.
    public var iblSpecularLodExponent: Float = 1.5
    public var iblSpecularLodBias: Float = 0.0
    public var iblSpecularGrazingLodBias: Float = 0.35
    public var iblSpecularMinRoughness: Float = 0.06
    public var specularAAStrength: Float = 1.0
    public var normalMapMipBias: Float = 0.0
    public var normalMapMipBiasGrazing: Float = 0.6
    public var shadingDebugMode: UInt32 = 0
    public var iblQualityPreset: UInt32 = IBLQualityPreset.high.rawValue
    public var ssaoEnabled: UInt32 = 1
    public var ssaoReserved0: UInt32 = 0
    public var ssaoRadius: Float = 0.35
    public var ssaoIntensity: Float = 1.25
    public var ssaoPower: Float = 1.0
    public var ssaoBias: Float = 0.008
    // Stored only for scene compatibility with older SSAO/GTAO-era settings payloads.
    // The active SAO path ignores this, and normal editor/bridge surfaces should not expose it.
    public var ssaoThickness: Float = 0.22
    public var ssaoBlurSharpness: Float = 24.0

    // Phase 5 scene-linear local-medium GPU contract. Names are retained to preserve the
    // existing Swift/Metal ABI; the explicit meanings below replace the Phase 4 fog heuristics.
    public var heightFogEnabled: UInt32 = 0
    // World-space Y level where the exponential density is 1.
    public var heightFogBaseHeight: Float = 0.0
    // sigmaT at base height, in inverse world units.
    public var heightFogDensity: Float = 0.02
    // Exponential density scale height in world units.
    public var heightFogHeightFalloff: Float = 12.0
    // Component-wise sigmaS / sigmaT in scene-linear RGB.
    public var heightFogColor: SIMD3<Float> = SIMD3<Float>(repeating: 0.9)
    // Reserved legacy start-distance slot; local fog starts at the camera.
    public var heightFogStartDistance: Float = 0.0
    // Henyey-Greenstein anisotropy in [-0.9, 0.9].
    public var heightFogDistanceDensity: Float = 0.2
    // Reserved legacy fog metadata storage.
    public var heightFogPadding: SIMD2<Float> = .zero

    public var outlineEnabled: UInt32 = 1
    public var outlineThickness: UInt32 = 1
    public var outlineOpacity: Float = 1.0
    public var outlinePadding: Float = 0.0
    public var outlineColor: SIMD3<Float> = SIMD3<Float>(1.0, 0.9, 0.2)
    public var outlineColorPadding: Float = 0.0
    public var gridEnabled: UInt32 = 1
    public var gridOpacity: Float = 0.85
    public var gridFadeDistance: Float = 120.0
    public var gridMajorLineEvery: Float = 10.0
    // Reserved to preserve Swift/Metal uniform ABI for removed UV debug controls.
    public var reservedDebug0: SIMD2<UInt32> = .zero
    public var shadows: ShadowsSettings = ShadowsSettings()
    public var padding0: SIMD4<Float> = .zero
    public var padding1: SIMD4<Float> = .zero
    /// xyz = authoritative world-space direction toward the Sun; w reserved.
    public var aerialFogSunDirectionAndNight: SIMD4<Float> = SIMD4<Float>(0.0, 1.0, 0.0, 0.0)
    /// rgb = authoritative ground-level analytic Sun irradiance; w reserved.
    public var aerialFogSunColorAndStrength: SIMD4<Float> = .zero
    /// Reserved legacy aerial-fog tuning slots; production local fog ignores them.
    public var aerialFogParams: SIMD4<Float> = .zero
}

public extension RendererSettings {
    var diagnosticFlags: RendererDiagnosticFlags {
        get { RendererDiagnosticFlags(rawValue: reservedDebug0.y) }
        set { reservedDebug0.y = newValue.rawValue }
    }

    mutating func setDiagnosticFlag(_ flag: RendererDiagnosticFlags, enabled: Bool) {
        var flags = diagnosticFlags
        if enabled {
            flags.insert(flag)
        } else {
            flags.remove(flag)
        }
        diagnosticFlags = flags
    }
}

public struct RendererPerfFlags: OptionSet {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let halfResBloom = RendererPerfFlags(rawValue: 1 << 0)
    public static let useAsyncIBLGen = RendererPerfFlags(rawValue: 1 << 1)
    public static let disableSpecularAA = RendererPerfFlags(rawValue: 1 << 2)
    public static let disableClearcoat = RendererPerfFlags(rawValue: 1 << 3)
    public static let disableSheen = RendererPerfFlags(rawValue: 1 << 4)
    public static let skipSpecIBLHighRoughness = RendererPerfFlags(rawValue: 1 << 5)
    public static let forwardPlusEnabled = RendererPerfFlags(rawValue: 1 << 6)
    public static let disableLocalProbeParallaxCorrection = RendererPerfFlags(rawValue: 1 << 7)
}

public enum ForwardPlusConfig {
    public static let abiVersion: UInt32 = 1
    public static let tileSizeX: UInt32 = 16
    public static let tileSizeY: UInt32 = 16
    public static let zSliceCount: UInt32 = 24
    public static let maxLightsPerTile: UInt32 = 128
    public static let maxLightsPerCluster: UInt32 = 64
    public static let configVersion: UInt32 = 2
}

public extension RendererSettings {
    private static let aoQualityMask: UInt32 = 0x00000F00
    private static let aoQualityShift: UInt32 = 8
    private static let aoMethodMask: UInt32 = 0x000F0000
    private static let aoMethodShift: UInt32 = 16

    var isBloomEnabled: Bool { bloomEnabled != 0 }
    var isIBLEnabled: Bool { iblEnabled != 0 }
    var isShadowsEnabled: Bool { shadows.enabled != 0 }
    var isDirectionalShadowsEnabled: Bool { shadows.directionalEnabled != 0 }
    var isAOEnabled: Bool { ssaoEnabled != 0 }
    // Deprecated alias retained for legacy call sites still using SSAO terminology.
    var isSSAOEnabled: Bool { ssaoEnabled != 0 }
    var isHeightFogEnabled: Bool { heightFogEnabled != 0 }
    var localFogParameters: LocalFogTransport.Parameters {
        get {
            LocalFogTransport.Parameters(
                enabled: isHeightFogEnabled,
                extinction: heightFogDensity,
                scatteringAlbedo: heightFogColor,
                baseHeight: heightFogBaseHeight,
                scaleHeight: heightFogHeightFalloff,
                anisotropy: heightFogDistanceDensity
            )
        }
        set {
            setHeightFogEnabled(newValue.enabled)
            heightFogDensity = newValue.extinction
            heightFogColor = newValue.scatteringAlbedo
            heightFogBaseHeight = newValue.baseHeight
            heightFogHeightFalloff = newValue.scaleHeight
            heightFogStartDistance = 0
            heightFogDistanceDensity = newValue.anisotropy
        }
    }
    var heightFogColorMode: FogColorMode {
        get {
            FogColorMode(rawValue: UInt32(max(0, Int(heightFogPadding.x.rounded())))) ?? .manual
        }
        set {
            heightFogPadding.x = Float(newValue.rawValue)
        }
    }
    var fogAmount: Float {
        get { heightFogDensity }
        set { heightFogDensity = max(0.0, min(newValue, 1.0)) }
    }
    var fogHeight: Float {
        get { heightFogBaseHeight }
        set { heightFogBaseHeight = newValue }
    }
    var fogDistance: Float {
        get { heightFogStartDistance }
        set { heightFogStartDistance = max(0.0, newValue) }
    }
    var fogManualColor: SIMD3<Float> {
        get { heightFogColor }
        set { heightFogColor = newValue }
    }
    var fogSkyMatchColor: SIMD3<Float> {
        get { SIMD3<Float>(padding0.x, padding0.y, padding0.z) }
        set { padding0 = SIMD4<Float>(newValue, padding0.w) }
    }
    var fogSkyHorizonColor: SIMD3<Float> {
        get { SIMD3<Float>(padding1.x, padding1.y, padding1.z) }
        set { padding1 = SIMD4<Float>(newValue, padding1.w) }
    }
    var fogSkySunScatterStrength: Float {
        get { padding1.w }
        set { padding1.w = max(0.0, min(newValue, 1.0)) }
    }
    var aerialFogSunDirection: SIMD3<Float> {
        get { SIMD3<Float>(aerialFogSunDirectionAndNight.x, aerialFogSunDirectionAndNight.y, aerialFogSunDirectionAndNight.z) }
        set { aerialFogSunDirectionAndNight = SIMD4<Float>(newValue, aerialFogSunDirectionAndNight.w) }
    }
    var aerialFogNightScale: Float {
        get { aerialFogSunDirectionAndNight.w }
        set { aerialFogSunDirectionAndNight.w = max(0.0, min(newValue, 1.0)) }
    }
    var aerialFogSunColor: SIMD3<Float> {
        get { SIMD3<Float>(aerialFogSunColorAndStrength.x, aerialFogSunColorAndStrength.y, aerialFogSunColorAndStrength.z) }
        set { aerialFogSunColorAndStrength = SIMD4<Float>(newValue, aerialFogSunColorAndStrength.w) }
    }
    var aerialFogForwardScatteringStrength: Float {
        get { aerialFogSunColorAndStrength.w }
        set { aerialFogSunColorAndStrength.w = max(0.0, min(newValue, 2.0)) }
    }
    var aerialFogInscatteringStrength: Float {
        get { aerialFogParams.x }
        set { aerialFogParams.x = max(0.0, min(newValue, 2.0)) }
    }
    var aerialFogHeightExtinctionScale: Float {
        get { aerialFogParams.y }
        set { aerialFogParams.y = max(0.0, min(newValue, 4.0)) }
    }
    var aerialFogAnisotropy: Float {
        get { aerialFogParams.z }
        set { aerialFogParams.z = max(0.0, min(newValue, 0.95)) }
    }
    var aerialFogMaxDistance: Float {
        get { aerialFogParams.w }
        set { aerialFogParams.w = max(1.0, newValue) }
    }
    var aoMethod: AOMethod {
        get {
            let rawValue = (ssaoReserved0 & Self.aoMethodMask) >> Self.aoMethodShift
            return AOMethod(rawValue: rawValue) ?? .sao
        }
        set {
            let cleared = ssaoReserved0 & ~Self.aoMethodMask
            ssaoReserved0 = cleared | ((newValue.rawValue << Self.aoMethodShift) & Self.aoMethodMask)
        }
    }
    var aoQuality: AOQualityPreset {
        get {
            let rawValue = (ssaoReserved0 & Self.aoQualityMask) >> Self.aoQualityShift
            return AOQualityPreset(rawValue: rawValue) ?? .high
        }
        set {
            let cleared = ssaoReserved0 & ~Self.aoQualityMask
            ssaoReserved0 = cleared | ((newValue.rawValue << Self.aoQualityShift) & Self.aoQualityMask)
        }
    }

    mutating func setPerfFlag(_ flag: RendererPerfFlags, enabled: Bool) {
        if enabled {
            perfFlags |= flag.rawValue
        } else {
            perfFlags &= ~flag.rawValue
        }
    }

    func hasPerfFlag(_ flag: RendererPerfFlags) -> Bool {
        (perfFlags & flag.rawValue) != 0
    }

    static func clampAORadius(_ value: Float) -> Float {
        min(max(value, 0.10), 1.00)
    }

    static func clampAOIntensity(_ value: Float) -> Float {
        min(max(value, 0.0), 3.0)
    }

    static func clampAOBias(_ value: Float) -> Float {
        min(max(value, 0.0), 0.05)
    }

    static func clampAOSharpness(_ value: Float) -> Float {
        min(max(value, 4.0), 40.0)
    }

    static func clampAOPower(_ value: Float) -> Float {
        min(max(value, 0.5), 2.0)
    }

    mutating func setAOEnabled(_ enabled: Bool) {
        ssaoEnabled = enabled ? 1 : 0
    }

    mutating func setHeightFogEnabled(_ enabled: Bool) {
        heightFogEnabled = enabled ? 1 : 0
    }

    mutating func setHeightFogColorMode(_ mode: FogColorMode) {
        heightFogColorMode = mode
    }

    mutating func setFogAmount(_ value: Float) {
        fogAmount = value
    }

    mutating func setFogHeight(_ value: Float) {
        fogHeight = value
    }

    mutating func setFogDistance(_ value: Float) {
        fogDistance = value
    }

    mutating func setFogManualColor(_ value: SIMD3<Float>) {
        fogManualColor = value
    }

    mutating func setFogSkyMatchColor(_ value: SIMD3<Float>) {
        fogSkyMatchColor = value
    }

    mutating func setFogSkyHorizonColor(_ value: SIMD3<Float>) {
        fogSkyHorizonColor = value
    }

    mutating func setFogSkySunScatterStrength(_ value: Float) {
        fogSkySunScatterStrength = value
    }

    mutating func setAORadius(_ value: Float) {
        ssaoRadius = Self.clampAORadius(value)
    }

    mutating func setAOIntensity(_ value: Float) {
        ssaoIntensity = Self.clampAOIntensity(value)
    }

    mutating func setAOBias(_ value: Float) {
        ssaoBias = Self.clampAOBias(value)
    }

    mutating func setAOSharpness(_ value: Float) {
        ssaoBlurSharpness = Self.clampAOSharpness(value)
    }

    mutating func setAOPower(_ value: Float) {
        ssaoPower = Self.clampAOPower(value)
    }

    mutating func applyAOQuality(_ preset: AOQualityPreset) {
        // This is currently stored project metadata only.
        // SAO v1 does not materially switch shader/sample quality based on this preset yet.
        aoQuality = preset
    }
}


public final class RendererProfiler {
    public enum Scope: String, CaseIterable {
        case frame
        case update
        case sceneUpdate
        case fixedUpdate
        case lateUpdate
        case snapshotExtract
        case renderGraphEncode
        case scriptFixed
        case characterFixed
        case physicsStep
        case physicsEvents
        case scriptPhysicsDispatch
        case scene
        case render
        case renderBatches
        case bloom
        case bloomExtract
        case bloomDownsample
        case bloomBlur
        case composite
        case overlays
        case present
        case gpu
    }

    public enum GpuPass: String, CaseIterable {
        case shadows
        case depthPrepass
        case scene
        case grid
        case picking
        case outline
        case bloomExtract
        case bloomBlur
        case finalComposite
    }

    private final class RollingAverage {
        private var values: [Double]
        private var index: Int = 0
        private var count: Int = 0

        init(capacity: Int) {
            values = Array(repeating: 0, count: capacity)
        }

        func add(_ value: Double) {
            values[index] = value
            index = (index + 1) % values.count
            count = min(count + 1, values.count)
        }

        var average: Double {
            guard count > 0 else { return 0 }
            let sum = values.prefix(count).reduce(0, +)
            return sum / Double(count)
        }
    }

    private let queue = DispatchQueue(label: "RendererProfiler.queue")
    private var averages: [Scope: RollingAverage] = [:]
    private var gpuPassAverages: [GpuPass: RollingAverage] = [:]
    private var gpuPassProfilingEnabled: Bool = false
    private let gpuCounterLock = NSLock()
    private var gpuCounterSampleBuffer: MTLCounterSampleBuffer?
    private var gpuCounterResolveBuffer: MTLBuffer?
    private var gpuCounterSamplesPerFrame: Int = 0
    private var gpuCounterBytesPerSample: Int = 0
    private var gpuCounterBytesPerFrame: Int = 0
    private var gpuCounterInFlightFrames: Int = 0
    private var gpuCounterBeginMask: [UInt32] = []
    private var gpuCounterEndMask: [UInt32] = []
    private var gpuCounterFrameIds: [UInt64] = []
    private var gpuCounterSupported: Bool = false
    private var gpuCounterSupportReason: String = ""
    private var gpuCounterSetName: String = ""
    private var gpuCounterSamplingPointName: String = ""

    public init(sampleCount: Int = 120) {
        for scope in Scope.allCases {
            averages[scope] = RollingAverage(capacity: sampleCount)
        }
        for pass in GpuPass.allCases {
            gpuPassAverages[pass] = RollingAverage(capacity: sampleCount)
        }
    }

    public func record(_ scope: Scope, seconds: Double) {
        queue.async {
            self.averages[scope]?.add(seconds * 1000.0)
        }
    }

    public func averageMs(_ scope: Scope) -> Float {
        var result: Double = 0
        queue.sync {
            result = self.averages[scope]?.average ?? 0
        }
        return Float(result)
    }

    public func recordGpuPass(_ pass: GpuPass, seconds: Double) {
        queue.async {
            self.gpuPassAverages[pass]?.add(seconds * 1000.0)
        }
    }

    public func averageGpuPassMs(_ pass: GpuPass) -> Float {
        var result: Double = 0
        queue.sync {
            result = self.gpuPassAverages[pass]?.average ?? 0
        }
        return Float(result)
    }

    public func setGpuPassTimingsEnabled(_ enabled: Bool) {
        queue.async {
            self.gpuPassProfilingEnabled = enabled
        }
    }

    public func gpuPassTimingsEnabled() -> Bool {
        var result = false
        queue.sync {
            result = gpuPassProfilingEnabled
        }
        return result
    }

    public func gpuCounterSamplingSupported(device: MTLDevice) -> Bool {
        guard #available(macOS 11.0, *) else { return false }
        updateGpuCounterSupport(device: device)
        return gpuCounterSupported
    }

    public func prepareGpuCounterSampling(device: MTLDevice, inFlightFrames: Int) -> Bool {
        guard gpuCounterSamplingSupported(device: device) else { return false }
        guard #available(macOS 11.0, *) else { return false }
        let passCount = GpuPass.allCases.count
        let samplesPerFrame = passCount * 2
        let totalSamples = samplesPerFrame * max(1, inFlightFrames)
        if gpuCounterSampleBuffer != nil,
           gpuCounterSamplesPerFrame == samplesPerFrame,
           gpuCounterInFlightFrames == inFlightFrames {
            return true
        }

        guard let counterSet = resolveTimestampCounterSet(device: device) else { return false }
        let descriptor = MTLCounterSampleBufferDescriptor()
        descriptor.counterSet = counterSet
        descriptor.sampleCount = totalSamples
        descriptor.storageMode = .shared
        descriptor.label = "GpuPassCounters"
        let sampleBuffer: MTLCounterSampleBuffer
        do {
            sampleBuffer = try device.makeCounterSampleBuffer(descriptor: descriptor)
        } catch {
            return false
        }

        let bytesPerSample = counterBytesPerSample(counterSet: counterSet)
        let bytesPerFrame = bytesPerSample * samplesPerFrame
        let totalBytes = bytesPerFrame * max(1, inFlightFrames)
        guard let resolveBuffer = device.makeBuffer(length: totalBytes, options: .storageModeShared) else { return false }
        resolveBuffer.label = "GpuPassCounters.Resolve"

        gpuCounterLock.lock()
        gpuCounterSampleBuffer = sampleBuffer
        gpuCounterResolveBuffer = resolveBuffer
        gpuCounterSamplesPerFrame = samplesPerFrame
        gpuCounterBytesPerSample = bytesPerSample
        gpuCounterBytesPerFrame = bytesPerFrame
        gpuCounterInFlightFrames = inFlightFrames
        gpuCounterBeginMask = Array(repeating: 0, count: inFlightFrames)
        gpuCounterEndMask = Array(repeating: 0, count: inFlightFrames)
        gpuCounterFrameIds = Array(repeating: 0, count: inFlightFrames)
        gpuCounterLock.unlock()
        return true
    }

    public func beginGpuCounterFrame(frameIndex: Int, frameId: UInt64) {
        gpuCounterLock.lock()
        guard gpuCounterSampleBuffer != nil,
              gpuCounterInFlightFrames > 0,
              frameIndex < gpuCounterInFlightFrames else {
            gpuCounterLock.unlock()
            return
        }
        gpuCounterBeginMask[frameIndex] = 0
        gpuCounterEndMask[frameIndex] = 0
        gpuCounterFrameIds[frameIndex] = frameId
        gpuCounterLock.unlock()
    }

    public func sampleGpuPassBegin(_ pass: GpuPass, encoder: MTLRenderCommandEncoder, frameIndex: Int) {
        guard #available(macOS 11.0, *) else { return }
        guard let sampleBuffer = gpuCounterSampleBuffer,
              gpuCounterInFlightFrames > 0,
              frameIndex < gpuCounterInFlightFrames else { return }
        let passIndex = gpuPassIndex(pass)
        let sampleIndex = frameIndex * gpuCounterSamplesPerFrame + (passIndex * 2)
        encoder.sampleCounters(sampleBuffer: sampleBuffer, sampleIndex: sampleIndex, barrier: true)
        gpuCounterLock.lock()
        gpuCounterBeginMask[frameIndex] |= UInt32(1 << passIndex)
        gpuCounterLock.unlock()
    }

    public func sampleGpuPassEnd(_ pass: GpuPass, encoder: MTLRenderCommandEncoder, frameIndex: Int) {
        guard #available(macOS 11.0, *) else { return }
        guard let sampleBuffer = gpuCounterSampleBuffer,
              gpuCounterInFlightFrames > 0,
              frameIndex < gpuCounterInFlightFrames else { return }
        let passIndex = gpuPassIndex(pass)
        let sampleIndex = frameIndex * gpuCounterSamplesPerFrame + (passIndex * 2) + 1
        encoder.sampleCounters(sampleBuffer: sampleBuffer, sampleIndex: sampleIndex, barrier: true)
        gpuCounterLock.lock()
        gpuCounterEndMask[frameIndex] |= UInt32(1 << passIndex)
        gpuCounterLock.unlock()
    }

    public func encodeGpuCounterResolve(commandBuffer: MTLCommandBuffer, frameIndex: Int) {
        guard #available(macOS 11.0, *) else { return }
        guard let sampleBuffer = gpuCounterSampleBuffer,
              let resolveBuffer = gpuCounterResolveBuffer,
              gpuCounterSamplesPerFrame > 0,
              gpuCounterInFlightFrames > 0,
              frameIndex < gpuCounterInFlightFrames else { return }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        let startSample = frameIndex * gpuCounterSamplesPerFrame
        let destinationOffset = frameIndex * gpuCounterBytesPerFrame
        let range = startSample..<(startSample + gpuCounterSamplesPerFrame)
        blit.resolveCounters(sampleBuffer, range: range, destinationBuffer: resolveBuffer, destinationOffset: destinationOffset)
        blit.endEncoding()
    }

    public func processResolvedGpuCounters(frameIndex: Int, frameId: UInt64, commandBuffer: MTLCommandBuffer) {
        guard let resolveBuffer = gpuCounterResolveBuffer,
              gpuCounterSamplesPerFrame > 0,
              gpuCounterBytesPerSample > 0,
              gpuCounterInFlightFrames > 0,
              frameIndex < gpuCounterInFlightFrames else { return }

        var beginMask: UInt32 = 0
        var endMask: UInt32 = 0
        gpuCounterLock.lock()
        if gpuCounterFrameIds[frameIndex] == frameId {
            beginMask = gpuCounterBeginMask[frameIndex]
            endMask = gpuCounterEndMask[frameIndex]
        }
        gpuCounterLock.unlock()

        let activeMask = beginMask & endMask
        if activeMask == 0 { return }

        let basePointer = resolveBuffer.contents().advanced(by: frameIndex * gpuCounterBytesPerFrame)
        var earliest: UInt64 = .max
        var latest: UInt64 = 0
        let passCount = GpuPass.allCases.count

        for passIndex in 0..<passCount {
            let mask = UInt32(1 << passIndex)
            if activeMask & mask == 0 { continue }
            let begin = readCounterSample(basePointer: basePointer, sampleIndex: passIndex * 2)
            let end = readCounterSample(basePointer: basePointer, sampleIndex: passIndex * 2 + 1)
            if end >= begin {
                earliest = min(earliest, begin)
                latest = max(latest, end)
            }
        }

        let gpuDuration = max(0.0, commandBuffer.gpuEndTime - commandBuffer.gpuStartTime)
        if gpuDuration > 0 {
            record(.gpu, seconds: gpuDuration)
        }
        guard earliest != .max, latest > earliest, gpuDuration > 0 else { return }

        let scale = gpuDuration / Double(latest - earliest)
        for passIndex in 0..<passCount {
            let mask = UInt32(1 << passIndex)
            if activeMask & mask == 0 { continue }
            let begin = readCounterSample(basePointer: basePointer, sampleIndex: passIndex * 2)
            let end = readCounterSample(basePointer: basePointer, sampleIndex: passIndex * 2 + 1)
            if end >= begin {
                let seconds = Double(end - begin) * scale
                recordGpuPass(GpuPass.allCases[passIndex], seconds: seconds)
            }
        }
    }

    @available(macOS 11.0, *)
    private func resolveTimestampCounterSet(device: MTLDevice) -> MTLCounterSet? {
        guard let counterSets = device.counterSets else { return nil }
        return counterSets.first(where: { $0.name.localizedCaseInsensitiveContains("timestamp") })
    }

    @available(macOS 11.0, *)
    private func counterBytesPerSample(counterSet: MTLCounterSet) -> Int {
        let counterCount = max(1, counterSet.counters.count)
        return counterCount * MemoryLayout<UInt64>.stride
    }

    private func readCounterSample(basePointer: UnsafeMutableRawPointer, sampleIndex: Int) -> UInt64 {
        let offset = sampleIndex * gpuCounterBytesPerSample
        return basePointer.advanced(by: offset).bindMemory(to: UInt64.self, capacity: 1).pointee
    }

    private func gpuPassIndex(_ pass: GpuPass) -> Int {
        return GpuPass.allCases.firstIndex(of: pass) ?? 0
    }

    public func gpuCounterSupportInfo() -> (supported: Bool, reason: String, counterSet: String, samplingPoint: String) {
        gpuCounterLock.lock()
        let info = (gpuCounterSupported, gpuCounterSupportReason, gpuCounterSetName, gpuCounterSamplingPointName)
        gpuCounterLock.unlock()
        return info
    }

    public func gpuCounterDebugInfo() -> String {
        let info = gpuCounterSupportInfo()
        if info.supported {
            return "GPU counters: supported (\(info.counterSet), \(info.samplingPoint))."
        }
        if info.reason.isEmpty {
            return "GPU counters: unsupported."
        }
        return "GPU counters: unsupported (\(info.reason))."
    }

    private func updateGpuCounterSupport(device: MTLDevice) {
        guard #available(macOS 11.0, *) else {
            setGpuCounterSupport(false, reason: "Requires macOS 11.0+.", counterSet: "", samplingPoint: "")
            return
        }
        guard let counterSets = device.counterSets else {
            setGpuCounterSupport(false, reason: "Device exposes no counter sets.", counterSet: "", samplingPoint: "")
            return
        }
        guard let timestampSet = counterSets.first(where: { $0.name.localizedCaseInsensitiveContains("timestamp") }) else {
            setGpuCounterSupport(false, reason: "No timestamp counter set available.", counterSet: "", samplingPoint: "")
            return
        }
        guard device.supportsCounterSampling(.atDrawBoundary) else {
            setGpuCounterSupport(false, reason: "Device does not support counter sampling at draw boundary.", counterSet: timestampSet.name, samplingPoint: "")
            return
        }
        setGpuCounterSupport(true, reason: "", counterSet: timestampSet.name, samplingPoint: "draw boundary")
    }

    private func setGpuCounterSupport(_ supported: Bool, reason: String, counterSet: String, samplingPoint: String) {
        gpuCounterLock.lock()
        gpuCounterSupported = supported
        gpuCounterSupportReason = reason
        gpuCounterSetName = counterSet
        gpuCounterSamplingPointName = samplingPoint
        gpuCounterLock.unlock()
    }

}
