/// RendererSettingsBridge.swift
/// Defines the RendererSettingsBridge types and helpers for the engine.
/// Created by Kaden Cringle.

import Foundation
import Metal

private func resolveEngineContext(_ contextPtr: UnsafeRawPointer?) -> EngineContext? {
    guard let contextPtr else { return nil }
    let raw = UInt(bitPattern: contextPtr)
    if raw < 0x1000 {
        #if DEBUG
        assertionFailure("Invalid EngineContext pointer (too small) passed to bridge.")
        #endif
        return nil
    }
    return Unmanaged<EngineContext>.fromOpaque(contextPtr).takeUnretainedValue()
}

private func getSettings(_ contextPtr: UnsafeRawPointer?) -> RendererSettings {
    guard let engineContext = resolveEngineContext(contextPtr) else { return RendererSettings() }
    return engineContext.rendererSettings
}

private func updateSettings(_ contextPtr: UnsafeRawPointer?, _ body: (inout RendererSettings) -> Void) {
    guard let engineContext = resolveEngineContext(contextPtr) else { return }
    var settings = engineContext.rendererSettings
    body(&settings)
    engineContext.rendererSettings = settings
}

private func profiler(_ contextPtr: UnsafeRawPointer?) -> RendererProfiler? {
    return resolveEngineContext(contextPtr)?.renderer?.profiler
}

private func getPreferences(_ contextPtr: UnsafeRawPointer?) -> Preferences? {
    resolveEngineContext(contextPtr)?.preferences
}

private func normalizedSceneMSAASampleCount(_ engineContext: EngineContext, requested value: UInt32) -> Int {
    if value >= 8 && engineContext.device.supportsTextureSampleCount(8) {
        return 8
    }
    if value >= 4 && engineContext.device.supportsTextureSampleCount(4) {
        return 4
    }
    return 1
}

private func getForwardPlusStats(_ contextPtr: UnsafeRawPointer?) -> ForwardPlusStats {
    resolveEngineContext(contextPtr)?.forwardPlusStats ?? ForwardPlusStats()
}

@_cdecl("MCERendererGetBloomEnabled")
public func MCERendererGetBloomEnabled(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).bloomEnabled
}

@_cdecl("MCERendererSetBloomEnabled")
public func MCERendererSetBloomEnabled(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.bloomEnabled = value != 0 ? 1 : 0
    }
}

@_cdecl("MCERendererGetBloomThreshold")
public func MCERendererGetBloomThreshold(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).bloomThreshold
}

@_cdecl("MCERendererSetBloomThreshold")
public func MCERendererSetBloomThreshold(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.bloomThreshold = value
    }
}

@_cdecl("MCERendererGetBloomKnee")
public func MCERendererGetBloomKnee(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).bloomKnee
}

@_cdecl("MCERendererSetBloomKnee")
public func MCERendererSetBloomKnee(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.bloomKnee = value
    }
}

@_cdecl("MCERendererGetBloomIntensity")
public func MCERendererGetBloomIntensity(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).bloomIntensity
}

@_cdecl("MCERendererSetBloomIntensity")
public func MCERendererSetBloomIntensity(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.bloomIntensity = value
    }
}

@_cdecl("MCERendererGetBloomQualityPreset")
public func MCERendererGetBloomQualityPreset(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).bloomQualityPreset
}

@_cdecl("MCERendererSetBloomQualityPreset")
public func MCERendererSetBloomQualityPreset(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.bloomQualityPreset = min(value, BloomQualityPreset.custom.rawValue)
    }
}

@_cdecl("MCERendererGetBloomResolutionScale")
public func MCERendererGetBloomResolutionScale(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).bloomResolutionScale
}

@_cdecl("MCERendererSetBloomResolutionScale")
public func MCERendererSetBloomResolutionScale(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.bloomResolutionScale = value <= BloomResolutionScale.half.rawValue
            ? BloomResolutionScale.half.rawValue
            : BloomResolutionScale.quarter.rawValue
    }
}

@_cdecl("MCERendererGetBloomMaxMips")
public func MCERendererGetBloomMaxMips(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).bloomMaxMips
}

@_cdecl("MCERendererSetBloomMaxMips")
public func MCERendererSetBloomMaxMips(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.bloomMaxMips = max(1, value)
    }
}

@_cdecl("MCERendererGetTonemap")
public func MCERendererGetTonemap(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    TonemapType.filmic.rawValue
}

@_cdecl("MCERendererSetTonemap")
public func MCERendererSetTonemap(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    // Reserved compatibility bridge. Normal output is fixed to MetalCup Filmic v1.
}

@_cdecl("MCERendererGetGamma")
public func MCERendererGetGamma(_ contextPtr: UnsafeRawPointer?) -> Float {
    2.2
}

@_cdecl("MCERendererSetGamma")
public func MCERendererSetGamma(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    // Reserved compatibility bridge. No post-sRGB gamma trim is authored.
}

@_cdecl("MCERendererGetSceneMSAASampleCount")
public func MCERendererGetSceneMSAASampleCount(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    UInt32(getPreferences(contextPtr)?.sceneMSAASampleCount ?? 4)
}

@_cdecl("MCERendererGetMaxSceneMSAASampleCount")
public func MCERendererGetMaxSceneMSAASampleCount(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    guard let engineContext = resolveEngineContext(contextPtr) else { return 1 }
    if engineContext.device.supportsTextureSampleCount(8) {
        return 8
    }
    if engineContext.device.supportsTextureSampleCount(4) {
        return 4
    }
    return 1
}

@_cdecl("MCERendererSetSceneMSAASampleCount")
public func MCERendererSetSceneMSAASampleCount(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    guard let engineContext = resolveEngineContext(contextPtr) else { return }
    engineContext.preferences.sceneMSAASampleCount = normalizedSceneMSAASampleCount(engineContext, requested: value)
}

@_cdecl("MCERendererGetIBLEnabled")
public func MCERendererGetIBLEnabled(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).iblEnabled
}

@_cdecl("MCERendererSetIBLEnabled")
public func MCERendererSetIBLEnabled(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.iblEnabled = value != 0 ? 1 : 0
    }
}

@_cdecl("MCERendererGetIBLIntensity")
public func MCERendererGetIBLIntensity(_ contextPtr: UnsafeRawPointer?) -> Float {
    1.0
}

@_cdecl("MCERendererSetIBLIntensity")
public func MCERendererSetIBLIntensity(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    // Reserved compatibility bridge. Captured environment radiance is sampled at unit gain.
}

@_cdecl("MCERendererGetIBLQualityPreset")
public func MCERendererGetIBLQualityPreset(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).iblQualityPreset
}

@_cdecl("MCERendererSetIBLQualityPreset")
public func MCERendererSetIBLQualityPreset(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.iblQualityPreset = value
    }
}

@_cdecl("MCERendererGetHalfResBloom")
public func MCERendererGetHalfResBloom(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).bloomResolutionScale <= BloomResolutionScale.half.rawValue ? 1 : 0
}

@_cdecl("MCERendererSetHalfResBloom")
public func MCERendererSetHalfResBloom(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.bloomResolutionScale = value != 0
            ? BloomResolutionScale.half.rawValue
            : BloomResolutionScale.quarter.rawValue
    }
}

@_cdecl("MCERendererGetDisableSpecularAA")
public func MCERendererGetDisableSpecularAA(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    (getSettings(contextPtr).perfFlags & RendererPerfFlags.disableSpecularAA.rawValue) != 0 ? 1 : 0
}

@_cdecl("MCERendererSetDisableSpecularAA")
public func MCERendererSetDisableSpecularAA(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.setPerfFlag(.disableSpecularAA, enabled: value != 0)
    }
}

@_cdecl("MCERendererGetDisableClearcoat")
public func MCERendererGetDisableClearcoat(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    (getSettings(contextPtr).perfFlags & RendererPerfFlags.disableClearcoat.rawValue) != 0 ? 1 : 0
}

@_cdecl("MCERendererSetDisableClearcoat")
public func MCERendererSetDisableClearcoat(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.setPerfFlag(.disableClearcoat, enabled: value != 0)
    }
}

@_cdecl("MCERendererGetDisableSheen")
public func MCERendererGetDisableSheen(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    (getSettings(contextPtr).perfFlags & RendererPerfFlags.disableSheen.rawValue) != 0 ? 1 : 0
}

@_cdecl("MCERendererSetDisableSheen")
public func MCERendererSetDisableSheen(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.setPerfFlag(.disableSheen, enabled: value != 0)
    }
}

@_cdecl("MCERendererGetSkipSpecIBLHighRoughness")
public func MCERendererGetSkipSpecIBLHighRoughness(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    (getSettings(contextPtr).perfFlags & RendererPerfFlags.skipSpecIBLHighRoughness.rawValue) != 0 ? 1 : 0
}

@_cdecl("MCERendererSetSkipSpecIBLHighRoughness")
public func MCERendererSetSkipSpecIBLHighRoughness(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.setPerfFlag(.skipSpecIBLHighRoughness, enabled: value != 0)
    }
}

@_cdecl("MCERendererGetForwardPlusEnabled")
public func MCERendererGetForwardPlusEnabled(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    (getSettings(contextPtr).perfFlags & RendererPerfFlags.forwardPlusEnabled.rawValue) != 0 ? 1 : 0
}

@_cdecl("MCERendererSetForwardPlusEnabled")
public func MCERendererSetForwardPlusEnabled(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.setPerfFlag(.forwardPlusEnabled, enabled: value != 0)
    }
}

@_cdecl("MCERendererGetDisableLocalProbeParallaxCorrection")
public func MCERendererGetDisableLocalProbeParallaxCorrection(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    (getSettings(contextPtr).perfFlags & RendererPerfFlags.disableLocalProbeParallaxCorrection.rawValue) != 0 ? 1 : 0
}

@_cdecl("MCERendererSetDisableLocalProbeParallaxCorrection")
public func MCERendererSetDisableLocalProbeParallaxCorrection(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.setPerfFlag(.disableLocalProbeParallaxCorrection, enabled: value != 0)
    }
}

@_cdecl("MCERendererGetForwardPlusMaxLightsPerCluster")
public func MCERendererGetForwardPlusMaxLightsPerCluster(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    _ = contextPtr
    return ForwardPlusConfig.maxLightsPerCluster
}

@_cdecl("MCERendererGetForwardPlusTileOverflowCount")
public func MCERendererGetForwardPlusTileOverflowCount(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getForwardPlusStats(contextPtr).tileOverflowCount
}

@_cdecl("MCERendererGetForwardPlusClusterOverflowCount")
public func MCERendererGetForwardPlusClusterOverflowCount(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getForwardPlusStats(contextPtr).clusterOverflowCount
}

@_cdecl("MCERendererGetForwardPlusTileIndicesWritten")
public func MCERendererGetForwardPlusTileIndicesWritten(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getForwardPlusStats(contextPtr).tileIndicesWritten
}

@_cdecl("MCERendererGetForwardPlusClusterIndicesWritten")
public func MCERendererGetForwardPlusClusterIndicesWritten(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getForwardPlusStats(contextPtr).clusterIndicesWritten
}

@_cdecl("MCERendererGetForwardPlusTotalTiles")
public func MCERendererGetForwardPlusTotalTiles(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getForwardPlusStats(contextPtr).totalTiles
}

@_cdecl("MCERendererGetForwardPlusTotalClusters")
public func MCERendererGetForwardPlusTotalClusters(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getForwardPlusStats(contextPtr).totalClusters
}

@_cdecl("MCERendererGetForwardPlusActiveTilesCount")
public func MCERendererGetForwardPlusActiveTilesCount(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getForwardPlusStats(contextPtr).activeTilesCount
}

@_cdecl("MCERendererGetForwardPlusMissingDepthFrames")
public func MCERendererGetForwardPlusMissingDepthFrames(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getForwardPlusStats(contextPtr).missingDepthFrames
}

@_cdecl("MCERendererGetForwardPlusCullingDepthSource")
public func MCERendererGetForwardPlusCullingDepthSource(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    resolveEngineContext(contextPtr)?.forwardPlusCullingDepthSource ?? ForwardPlusCullingDepthSource.none.rawValue
}

@_cdecl("MCERendererGetShadingDebugMode")
public func MCERendererGetShadingDebugMode(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).shadingDebugMode
}

@_cdecl("MCERendererSetShadingDebugMode")
public func MCERendererSetShadingDebugMode(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.shadingDebugMode = value
    }
}

@_cdecl("MCERendererGetDiagnosticOrientationSkyboxEnabled")
public func MCERendererGetDiagnosticOrientationSkyboxEnabled(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).diagnosticFlags.contains(.orientationSkybox) ? 1 : 0
}

@_cdecl("MCERendererSetDiagnosticOrientationSkyboxEnabled")
public func MCERendererSetDiagnosticOrientationSkyboxEnabled(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.setDiagnosticFlag(.orientationSkybox, enabled: value != 0)
    }
}

@_cdecl("MCERendererGetDiagnosticOrientationGlobalIBLEnabled")
public func MCERendererGetDiagnosticOrientationGlobalIBLEnabled(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).diagnosticFlags.contains(.orientationGlobalIBL) ? 1 : 0
}

@_cdecl("MCERendererSetDiagnosticOrientationGlobalIBLEnabled")
public func MCERendererSetDiagnosticOrientationGlobalIBLEnabled(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.setDiagnosticFlag(.orientationGlobalIBL, enabled: value != 0)
    }
}

@_cdecl("MCERendererGetDiagnosticOrientationLocalProbeEnabled")
public func MCERendererGetDiagnosticOrientationLocalProbeEnabled(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).diagnosticFlags.contains(.orientationLocalProbe) ? 1 : 0
}

@_cdecl("MCERendererSetDiagnosticOrientationLocalProbeEnabled")
public func MCERendererSetDiagnosticOrientationLocalProbeEnabled(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.setDiagnosticFlag(.orientationLocalProbe, enabled: value != 0)
    }
}

@_cdecl("MCERendererGetSSAOEnabled")
public func MCERendererGetSSAOEnabled(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).ssaoEnabled
}

// Deprecated compatibility aliases retained for older callers still using SSAO naming.
// New code should use the AO* entry points above instead of extending this legacy surface.
@_cdecl("MCERendererSetSSAOEnabled")
public func MCERendererSetSSAOEnabled(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.setAOEnabled(value != 0)
    }
}

@_cdecl("MCERendererGetAOEnabled")
public func MCERendererGetAOEnabled(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).isAOEnabled ? 1 : 0
}

@_cdecl("MCERendererSetAOEnabled")
public func MCERendererSetAOEnabled(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.setAOEnabled(value != 0)
    }
}

@_cdecl("MCERendererGetAOMethod")
public func MCERendererGetAOMethod(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).aoMethod.rawValue
}

@_cdecl("MCERendererSetAOMethod")
public func MCERendererSetAOMethod(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.aoMethod = AOMethod(rawValue: value) ?? .sao
    }
}

@_cdecl("MCERendererGetAOQuality")
public func MCERendererGetAOQuality(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).aoQuality.rawValue
}

@_cdecl("MCERendererSetAOQuality")
public func MCERendererSetAOQuality(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.applyAOQuality(AOQualityPreset(rawValue: value) ?? .high)
    }
}

@_cdecl("MCERendererGetSSAORadius")
public func MCERendererGetSSAORadius(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).ssaoRadius
}

@_cdecl("MCERendererSetSSAORadius")
public func MCERendererSetSSAORadius(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.setAORadius(value)
    }
}

@_cdecl("MCERendererGetAORadius")
public func MCERendererGetAORadius(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).ssaoRadius
}

@_cdecl("MCERendererSetAORadius")
public func MCERendererSetAORadius(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.setAORadius(value)
    }
}

@_cdecl("MCERendererGetSSAOIntensity")
public func MCERendererGetSSAOIntensity(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).ssaoIntensity
}

@_cdecl("MCERendererSetSSAOIntensity")
public func MCERendererSetSSAOIntensity(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.setAOIntensity(value)
    }
}

@_cdecl("MCERendererGetAOIntensity")
public func MCERendererGetAOIntensity(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).ssaoIntensity
}

@_cdecl("MCERendererSetAOIntensity")
public func MCERendererSetAOIntensity(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.setAOIntensity(value)
    }
}

@_cdecl("MCERendererGetSSAOPower")
public func MCERendererGetSSAOPower(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).ssaoPower
}

@_cdecl("MCERendererSetSSAOPower")
public func MCERendererSetSSAOPower(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.setAOPower(value)
    }
}

@_cdecl("MCERendererGetAOPower")
public func MCERendererGetAOPower(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).ssaoPower
}

@_cdecl("MCERendererSetAOPower")
public func MCERendererSetAOPower(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.setAOPower(value)
    }
}

@_cdecl("MCERendererGetSSAOBias")
public func MCERendererGetSSAOBias(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).ssaoBias
}

@_cdecl("MCERendererSetSSAOBias")
public func MCERendererSetSSAOBias(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.setAOBias(value)
    }
}

@_cdecl("MCERendererGetAOBias")
public func MCERendererGetAOBias(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).ssaoBias
}

@_cdecl("MCERendererSetAOBias")
public func MCERendererSetAOBias(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.setAOBias(value)
    }
}

@_cdecl("MCERendererGetSSAOThickness")
public func MCERendererGetSSAOThickness(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).ssaoThickness
}

@_cdecl("MCERendererSetSSAOThickness")
public func MCERendererSetSSAOThickness(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    _ = contextPtr
    _ = value
    // Deprecated compatibility stub.
    // Thickness belonged to an older AO path and no longer affects active SAO rendering.
}

@_cdecl("MCERendererGetSSAOBlurSharpness")
public func MCERendererGetSSAOBlurSharpness(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).ssaoBlurSharpness
}

@_cdecl("MCERendererSetSSAOBlurSharpness")
public func MCERendererSetSSAOBlurSharpness(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.setAOSharpness(value)
    }
}

@_cdecl("MCERendererGetAOSharpness")
public func MCERendererGetAOSharpness(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).ssaoBlurSharpness
}

@_cdecl("MCERendererSetAOSharpness")
public func MCERendererSetAOSharpness(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.setAOSharpness(value)
    }
}

@_cdecl("MCERendererGetIBLSpecularLodExponent")
public func MCERendererGetIBLSpecularLodExponent(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).iblSpecularLodExponent
}

@_cdecl("MCERendererSetIBLSpecularLodExponent")
public func MCERendererSetIBLSpecularLodExponent(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.iblSpecularLodExponent = max(0.01, value)
    }
}

@_cdecl("MCERendererGetIBLSpecularLodBias")
public func MCERendererGetIBLSpecularLodBias(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).iblSpecularLodBias
}

@_cdecl("MCERendererSetIBLSpecularLodBias")
public func MCERendererSetIBLSpecularLodBias(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.iblSpecularLodBias = value
    }
}

@_cdecl("MCERendererGetIBLSpecularGrazingLodBias")
public func MCERendererGetIBLSpecularGrazingLodBias(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).iblSpecularGrazingLodBias
}

@_cdecl("MCERendererSetIBLSpecularGrazingLodBias")
public func MCERendererSetIBLSpecularGrazingLodBias(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.iblSpecularGrazingLodBias = value
    }
}

@_cdecl("MCERendererGetIBLSpecularMinRoughness")
public func MCERendererGetIBLSpecularMinRoughness(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).iblSpecularMinRoughness
}

@_cdecl("MCERendererSetIBLSpecularMinRoughness")
public func MCERendererSetIBLSpecularMinRoughness(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.iblSpecularMinRoughness = max(0.0, value)
    }
}

@_cdecl("MCERendererGetSpecularAAStrength")
public func MCERendererGetSpecularAAStrength(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).specularAAStrength
}

@_cdecl("MCERendererSetSpecularAAStrength")
public func MCERendererSetSpecularAAStrength(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.specularAAStrength = max(0.0, value)
    }
}

@_cdecl("MCERendererGetNormalMapMipBias")
public func MCERendererGetNormalMapMipBias(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).normalMapMipBias
}

@_cdecl("MCERendererSetNormalMapMipBias")
public func MCERendererSetNormalMapMipBias(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.normalMapMipBias = value
    }
}

@_cdecl("MCERendererGetNormalMapMipBiasGrazing")
public func MCERendererGetNormalMapMipBiasGrazing(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).normalMapMipBiasGrazing
}

@_cdecl("MCERendererSetNormalMapMipBiasGrazing")
public func MCERendererSetNormalMapMipBiasGrazing(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.normalMapMipBiasGrazing = max(0.0, value)
    }
}

@_cdecl("MCERendererGetHeightFogEnabled")
public func MCERendererGetHeightFogEnabled(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).heightFogEnabled
}

@_cdecl("MCERendererSetHeightFogEnabled")
public func MCERendererSetHeightFogEnabled(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.setHeightFogEnabled(value != 0)
    }
}

@_cdecl("MCERendererGetFogAmount")
public func MCERendererGetFogAmount(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).fogAmount
}

@_cdecl("MCERendererSetFogAmount")
public func MCERendererSetFogAmount(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.setFogAmount(value)
    }
}

@_cdecl("MCERendererGetFogHeight")
public func MCERendererGetFogHeight(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).fogHeight
}

@_cdecl("MCERendererSetFogHeight")
public func MCERendererSetFogHeight(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.setFogHeight(value)
    }
}

@_cdecl("MCERendererGetFogDistance")
public func MCERendererGetFogDistance(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).fogDistance
}

@_cdecl("MCERendererSetFogDistance")
public func MCERendererSetFogDistance(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.setFogDistance(value)
    }
}

@_cdecl("MCERendererGetFogColorMode")
public func MCERendererGetFogColorMode(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).heightFogColorMode.rawValue
}

@_cdecl("MCERendererSetFogColorMode")
public func MCERendererSetFogColorMode(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.setHeightFogColorMode(FogColorMode(rawValue: value) ?? .manual)
    }
}

@_cdecl("MCERendererGetFogManualColor")
public func MCERendererGetFogManualColor(_ contextPtr: UnsafeRawPointer?,
                                         _ r: UnsafeMutablePointer<Float>?,
                                         _ g: UnsafeMutablePointer<Float>?,
                                         _ b: UnsafeMutablePointer<Float>?) {
    let color = getSettings(contextPtr).fogManualColor
    r?.pointee = color.x
    g?.pointee = color.y
    b?.pointee = color.z
}

@_cdecl("MCERendererSetFogManualColor")
public func MCERendererSetFogManualColor(_ contextPtr: UnsafeRawPointer?,
                                         _ r: Float,
                                         _ g: Float,
                                         _ b: Float) {
    updateSettings(contextPtr) { settings in
        settings.setFogManualColor(SIMD3<Float>(r, g, b))
    }
}

@_cdecl("MCERendererGetHeightFogBaseHeight")
public func MCERendererGetHeightFogBaseHeight(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).heightFogBaseHeight
}

@_cdecl("MCERendererSetHeightFogBaseHeight")
public func MCERendererSetHeightFogBaseHeight(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.heightFogBaseHeight = value
    }
}

@_cdecl("MCERendererGetHeightFogDensity")
public func MCERendererGetHeightFogDensity(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).heightFogDensity
}

@_cdecl("MCERendererSetHeightFogDensity")
public func MCERendererSetHeightFogDensity(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.heightFogDensity = max(0.0, value)
    }
}

@_cdecl("MCERendererGetHeightFogHeightFalloff")
public func MCERendererGetHeightFogHeightFalloff(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).heightFogHeightFalloff
}

@_cdecl("MCERendererSetHeightFogHeightFalloff")
public func MCERendererSetHeightFogHeightFalloff(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.heightFogHeightFalloff = max(0.0, value)
    }
}

@_cdecl("MCERendererGetHeightFogStartDistance")
public func MCERendererGetHeightFogStartDistance(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).heightFogStartDistance
}

@_cdecl("MCERendererSetHeightFogStartDistance")
public func MCERendererSetHeightFogStartDistance(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.heightFogStartDistance = max(0.0, value)
    }
}

@_cdecl("MCERendererGetHeightFogDistanceDensity")
public func MCERendererGetHeightFogDistanceDensity(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).heightFogDistanceDensity
}

@_cdecl("MCERendererSetHeightFogDistanceDensity")
public func MCERendererSetHeightFogDistanceDensity(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.heightFogDistanceDensity = max(0.0, value)
    }
}

@_cdecl("MCERendererGetHeightFogColor")
public func MCERendererGetHeightFogColor(_ contextPtr: UnsafeRawPointer?,
                                         _ r: UnsafeMutablePointer<Float>?,
                                         _ g: UnsafeMutablePointer<Float>?,
                                         _ b: UnsafeMutablePointer<Float>?) {
    let color = getSettings(contextPtr).heightFogColor
    r?.pointee = color.x
    g?.pointee = color.y
    b?.pointee = color.z
}

@_cdecl("MCERendererSetHeightFogColor")
public func MCERendererSetHeightFogColor(_ contextPtr: UnsafeRawPointer?,
                                         _ r: Float,
                                         _ g: Float,
                                         _ b: Float) {
    updateSettings(contextPtr) { settings in
        settings.heightFogColor = SIMD3<Float>(r, g, b)
    }
}

@_cdecl("MCERendererGetOutlineEnabled")
public func MCERendererGetOutlineEnabled(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).outlineEnabled
}

@_cdecl("MCERendererSetOutlineEnabled")
public func MCERendererSetOutlineEnabled(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.outlineEnabled = value != 0 ? 1 : 0
    }
}

@_cdecl("MCERendererGetOutlineThickness")
public func MCERendererGetOutlineThickness(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).outlineThickness
}

@_cdecl("MCERendererSetOutlineThickness")
public func MCERendererSetOutlineThickness(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.outlineThickness = max(1, min(4, value))
    }
}

@_cdecl("MCERendererGetOutlineOpacity")
public func MCERendererGetOutlineOpacity(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).outlineOpacity
}

@_cdecl("MCERendererSetOutlineOpacity")
public func MCERendererSetOutlineOpacity(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.outlineOpacity = max(0.0, min(1.0, value))
    }
}

@_cdecl("MCERendererGetOutlineColor")
public func MCERendererGetOutlineColor(
    _ contextPtr: UnsafeRawPointer?,
    _ r: UnsafeMutablePointer<Float>?,
    _ g: UnsafeMutablePointer<Float>?,
    _ b: UnsafeMutablePointer<Float>?
) {
    let color = getSettings(contextPtr).outlineColor
    r?.pointee = color.x
    g?.pointee = color.y
    b?.pointee = color.z
}

@_cdecl("MCERendererSetOutlineColor")
public func MCERendererSetOutlineColor(_ contextPtr: UnsafeRawPointer?, _ r: Float, _ g: Float, _ b: Float) {
    updateSettings(contextPtr) { settings in
        settings.outlineColor = SIMD3<Float>(
            max(0.0, r),
            max(0.0, g),
            max(0.0, b)
        )
    }
}

@_cdecl("MCERendererGetGridEnabled")
public func MCERendererGetGridEnabled(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).gridEnabled
}

@_cdecl("MCERendererSetGridEnabled")
public func MCERendererSetGridEnabled(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.gridEnabled = value != 0 ? 1 : 0
    }
}

@_cdecl("MCERendererGetGridOpacity")
public func MCERendererGetGridOpacity(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).gridOpacity
}

@_cdecl("MCERendererSetGridOpacity")
public func MCERendererSetGridOpacity(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.gridOpacity = max(0.0, min(1.0, value))
    }
}

@_cdecl("MCERendererGetGridFadeDistance")
public func MCERendererGetGridFadeDistance(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).gridFadeDistance
}

@_cdecl("MCERendererSetGridFadeDistance")
public func MCERendererSetGridFadeDistance(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.gridFadeDistance = max(0.0, value)
    }
}

@_cdecl("MCERendererGetGridMajorLineEvery")
public func MCERendererGetGridMajorLineEvery(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).gridMajorLineEvery
}

@_cdecl("MCERendererSetGridMajorLineEvery")
public func MCERendererSetGridMajorLineEvery(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.gridMajorLineEvery = max(1.0, value)
    }
}

@_cdecl("MCERendererGetIBLFireflyClampEnabled")
public func MCERendererGetIBLFireflyClampEnabled(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).iblFireflyClampEnabled
}

@_cdecl("MCERendererSetIBLFireflyClampEnabled")
public func MCERendererSetIBLFireflyClampEnabled(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.iblFireflyClampEnabled = value != 0 ? 1 : 0
    }
}

@_cdecl("MCERendererGetIBLFireflyClamp")
public func MCERendererGetIBLFireflyClamp(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).iblFireflyClamp
}

@_cdecl("MCERendererSetIBLFireflyClamp")
public func MCERendererSetIBLFireflyClamp(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.iblFireflyClamp = max(0.0, value)
    }
}

@_cdecl("MCERendererGetIBLSampleMultiplier")
public func MCERendererGetIBLSampleMultiplier(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).iblSampleMultiplier
}

@_cdecl("MCERendererSetIBLSampleMultiplier")
public func MCERendererSetIBLSampleMultiplier(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.iblSampleMultiplier = max(0.1, value)
    }
}

@_cdecl("MCERendererGetSkyboxMipBias")
public func MCERendererGetSkyboxMipBias(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).skyboxMipBias
}

@_cdecl("MCERendererSetSkyboxMipBias")
public func MCERendererSetSkyboxMipBias(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.skyboxMipBias = value
    }
}

@_cdecl("MCERendererGetShadowsEnabled")
public func MCERendererGetShadowsEnabled(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).shadows.enabled
}

@_cdecl("MCERendererSetShadowsEnabled")
public func MCERendererSetShadowsEnabled(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.shadows.enabled = value != 0 ? 1 : 0
    }
}

@_cdecl("MCERendererGetDirectionalShadowsEnabled")
public func MCERendererGetDirectionalShadowsEnabled(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).shadows.directionalEnabled
}

@_cdecl("MCERendererSetDirectionalShadowsEnabled")
public func MCERendererSetDirectionalShadowsEnabled(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.shadows.directionalEnabled = value != 0 ? 1 : 0
    }
}

@_cdecl("MCERendererGetShadowMapResolution")
public func MCERendererGetShadowMapResolution(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).shadows.shadowMapResolution
}

@_cdecl("MCERendererSetShadowMapResolution")
public func MCERendererSetShadowMapResolution(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        let options: [UInt32] = [1024, 2048, 4096]
        let chosen = options.min(by: { abs(Int($0) - Int(value)) < abs(Int($1) - Int(value)) }) ?? 2048
        settings.shadows.shadowMapResolution = chosen
    }
}

@_cdecl("MCERendererGetShadowCascadeCount")
public func MCERendererGetShadowCascadeCount(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).shadows.cascadeCount
}

@_cdecl("MCERendererSetShadowCascadeCount")
public func MCERendererSetShadowCascadeCount(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.shadows.cascadeCount = max(1, min(4, value))
    }
}

@_cdecl("MCERendererGetShadowSplitLambda")
public func MCERendererGetShadowSplitLambda(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).shadows.cascadeSplitLambda
}

@_cdecl("MCERendererSetShadowSplitLambda")
public func MCERendererSetShadowSplitLambda(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.shadows.cascadeSplitLambda = max(0.0, min(1.0, value))
    }
}

@_cdecl("MCERendererGetShadowDepthBias")
public func MCERendererGetShadowDepthBias(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).shadows.depthBias
}

@_cdecl("MCERendererSetShadowDepthBias")
public func MCERendererSetShadowDepthBias(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.shadows.depthBias = max(0.0, min(0.003, value))
    }
}

@_cdecl("MCERendererGetShadowNormalBias")
public func MCERendererGetShadowNormalBias(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).shadows.normalBias
}

@_cdecl("MCERendererSetShadowNormalBias")
public func MCERendererSetShadowNormalBias(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.shadows.normalBias = max(0.0, min(0.08, value))
    }
}

@_cdecl("MCERendererGetShadowPCFRadius")
public func MCERendererGetShadowPCFRadius(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).shadows.pcfRadius
}

@_cdecl("MCERendererSetShadowPCFRadius")
public func MCERendererSetShadowPCFRadius(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.shadows.pcfRadius = max(0.0, value)
    }
}

@_cdecl("MCERendererGetShadowPCFQualityPreset")
public func MCERendererGetShadowPCFQualityPreset(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).shadows.pcfTapPreset
}

@_cdecl("MCERendererSetShadowPCFQualityPreset")
public func MCERendererSetShadowPCFQualityPreset(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        let preset = ShadowPCFQualityPreset(rawValue: min(value, ShadowPCFQualityPreset.custom.rawValue)) ?? .high
        settings.shadows.applyPCFPreset(preset)
        settings.shadows.filterMode = ShadowFilterMode.pcf.rawValue
    }
}

@_cdecl("MCERendererGetShadowPCFTapsCascade0")
public func MCERendererGetShadowPCFTapsCascade0(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).shadows.pcfTapsCascade0
}

@_cdecl("MCERendererSetShadowPCFTapsCascade0")
public func MCERendererSetShadowPCFTapsCascade0(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.shadows.pcfTapsCascade0 = max(1, min(25, value))
        settings.shadows.refreshPCFPreset()
        settings.shadows.filterMode = ShadowFilterMode.pcf.rawValue
    }
}

@_cdecl("MCERendererGetShadowPCFTapsCascade1")
public func MCERendererGetShadowPCFTapsCascade1(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).shadows.pcfTapsCascade1
}

@_cdecl("MCERendererSetShadowPCFTapsCascade1")
public func MCERendererSetShadowPCFTapsCascade1(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.shadows.pcfTapsCascade1 = max(1, min(25, value))
        settings.shadows.refreshPCFPreset()
        settings.shadows.filterMode = ShadowFilterMode.pcf.rawValue
    }
}

@_cdecl("MCERendererGetShadowPCFTapsCascade2")
public func MCERendererGetShadowPCFTapsCascade2(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).shadows.pcfTapsCascade2
}

@_cdecl("MCERendererSetShadowPCFTapsCascade2")
public func MCERendererSetShadowPCFTapsCascade2(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.shadows.pcfTapsCascade2 = max(1, min(25, value))
        settings.shadows.refreshPCFPreset()
        settings.shadows.filterMode = ShadowFilterMode.pcf.rawValue
    }
}

@_cdecl("MCERendererGetShadowPCFTapsCascade3")
public func MCERendererGetShadowPCFTapsCascade3(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).shadows.pcfTapsCascade3
}

@_cdecl("MCERendererSetShadowPCFTapsCascade3")
public func MCERendererSetShadowPCFTapsCascade3(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.shadows.pcfTapsCascade3 = max(1, min(25, value))
        settings.shadows.refreshPCFPreset()
        settings.shadows.filterMode = ShadowFilterMode.pcf.rawValue
    }
}

@_cdecl("MCERendererGetShadowFilterMode")
public func MCERendererGetShadowFilterMode(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).shadows.filterMode
}

@_cdecl("MCERendererSetShadowFilterMode")
public func MCERendererSetShadowFilterMode(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.shadows.filterMode = min(value, 2)
    }
}

@_cdecl("MCERendererGetShadowMaxDistance")
public func MCERendererGetShadowMaxDistance(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).shadows.maxShadowDistance
}

@_cdecl("MCERendererSetShadowMaxDistance")
public func MCERendererSetShadowMaxDistance(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.shadows.maxShadowDistance = max(0.0, value)
    }
}

@_cdecl("MCERendererGetShadowFadeOutDistance")
public func MCERendererGetShadowFadeOutDistance(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).shadows.fadeOutDistance
}

@_cdecl("MCERendererSetShadowFadeOutDistance")
public func MCERendererSetShadowFadeOutDistance(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.shadows.fadeOutDistance = max(0.0, value)
    }
}

@_cdecl("MCERendererGetShadowPCSSLightWorldSize")
public func MCERendererGetShadowPCSSLightWorldSize(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).shadows.pcssLightWorldSize
}

@_cdecl("MCERendererSetShadowPCSSLightWorldSize")
public func MCERendererSetShadowPCSSLightWorldSize(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.shadows.pcssLightWorldSize = max(0.0, value)
    }
}

@_cdecl("MCERendererGetShadowPCSSMinRadius")
public func MCERendererGetShadowPCSSMinRadius(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).shadows.pcssMinFilterRadiusTexels
}

@_cdecl("MCERendererSetShadowPCSSMinRadius")
public func MCERendererSetShadowPCSSMinRadius(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.shadows.pcssMinFilterRadiusTexels = max(0.0, value)
    }
}

@_cdecl("MCERendererGetShadowPCSSMaxRadius")
public func MCERendererGetShadowPCSSMaxRadius(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).shadows.pcssMaxFilterRadiusTexels
}

@_cdecl("MCERendererSetShadowPCSSMaxRadius")
public func MCERendererSetShadowPCSSMaxRadius(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.shadows.pcssMaxFilterRadiusTexels = max(0.0, value)
    }
}

@_cdecl("MCERendererGetShadowPCSSBlockerRadius")
public func MCERendererGetShadowPCSSBlockerRadius(_ contextPtr: UnsafeRawPointer?) -> Float {
    getSettings(contextPtr).shadows.pcssBlockerSearchRadiusTexels
}

@_cdecl("MCERendererSetShadowPCSSBlockerRadius")
public func MCERendererSetShadowPCSSBlockerRadius(_ contextPtr: UnsafeRawPointer?, _ value: Float) {
    updateSettings(contextPtr) { settings in
        settings.shadows.pcssBlockerSearchRadiusTexels = max(0.0, value)
    }
}

@_cdecl("MCERendererGetShadowPCSSBlockerSamples")
public func MCERendererGetShadowPCSSBlockerSamples(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).shadows.pcssBlockerSamples
}

@_cdecl("MCERendererSetShadowPCSSBlockerSamples")
public func MCERendererSetShadowPCSSBlockerSamples(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.shadows.pcssBlockerSamples = max(1, value)
    }
}

@_cdecl("MCERendererGetShadowPCSSFilterSamples")
public func MCERendererGetShadowPCSSFilterSamples(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).shadows.pcssPCFSamples
}

@_cdecl("MCERendererSetShadowPCSSFilterSamples")
public func MCERendererSetShadowPCSSFilterSamples(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.shadows.pcssPCFSamples = max(1, value)
    }
}

@_cdecl("MCERendererGetShadowPCSSNoiseEnabled")
public func MCERendererGetShadowPCSSNoiseEnabled(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    getSettings(contextPtr).shadows.pcssNoiseEnabled
}

@_cdecl("MCERendererSetShadowPCSSNoiseEnabled")
public func MCERendererSetShadowPCSSNoiseEnabled(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    updateSettings(contextPtr) { settings in
        settings.shadows.pcssNoiseEnabled = value != 0 ? 1 : 0
    }
}


@_cdecl("MCERendererGetFrameMs")
public func MCERendererGetFrameMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.frame) ?? 0
}

@_cdecl("MCERendererGetUpdateMs")
public func MCERendererGetUpdateMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.update) ?? 0
}

@_cdecl("MCERendererGetSceneUpdateMs")
public func MCERendererGetSceneUpdateMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.sceneUpdate) ?? 0
}

@_cdecl("MCERendererGetFixedUpdateMs")
public func MCERendererGetFixedUpdateMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.fixedUpdate) ?? 0
}

@_cdecl("MCERendererGetLateUpdateMs")
public func MCERendererGetLateUpdateMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.lateUpdate) ?? 0
}

@_cdecl("MCERendererGetSnapshotExtractMs")
public func MCERendererGetSnapshotExtractMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.snapshotExtract) ?? 0
}

@_cdecl("MCERendererGetRenderGraphEncodeMs")
public func MCERendererGetRenderGraphEncodeMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.renderGraphEncode) ?? 0
}

@_cdecl("MCERendererGetScriptFixedMs")
public func MCERendererGetScriptFixedMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.scriptFixed) ?? 0
}

@_cdecl("MCERendererGetCharacterFixedMs")
public func MCERendererGetCharacterFixedMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.characterFixed) ?? 0
}

@_cdecl("MCERendererGetPhysicsStepMs")
public func MCERendererGetPhysicsStepMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.physicsStep) ?? 0
}

@_cdecl("MCERendererGetPhysicsEventsMs")
public func MCERendererGetPhysicsEventsMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.physicsEvents) ?? 0
}

@_cdecl("MCERendererGetScriptPhysicsDispatchMs")
public func MCERendererGetScriptPhysicsDispatchMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.scriptPhysicsDispatch) ?? 0
}

@_cdecl("MCERendererGetSceneMs")
public func MCERendererGetSceneMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.scene) ?? 0
}

@_cdecl("MCERendererGetRenderMs")
public func MCERendererGetRenderMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.render) ?? 0
}

@_cdecl("MCERendererGetRenderBatchMs")
public func MCERendererGetRenderBatchMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.renderBatches) ?? 0
}

@_cdecl("MCERendererGetBloomMs")
public func MCERendererGetBloomMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.bloom) ?? 0
}

@_cdecl("MCERendererGetBloomExtractMs")
public func MCERendererGetBloomExtractMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.bloomExtract) ?? 0
}

@_cdecl("MCERendererGetBloomDownsampleMs")
public func MCERendererGetBloomDownsampleMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.bloomDownsample) ?? 0
}

@_cdecl("MCERendererGetBloomBlurMs")
public func MCERendererGetBloomBlurMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.bloomBlur) ?? 0
}

@_cdecl("MCERendererGetCompositeMs")
public func MCERendererGetCompositeMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.composite) ?? 0
}

@_cdecl("MCERendererGetOverlaysMs")
public func MCERendererGetOverlaysMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.overlays) ?? 0
}

@_cdecl("MCERendererGetPresentMs")
public func MCERendererGetPresentMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.present) ?? 0
}

@_cdecl("MCERendererGetGpuPassTimingsEnabled")
public func MCERendererGetGpuPassTimingsEnabled(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    profiler(contextPtr)?.gpuPassTimingsEnabled() == true ? 1 : 0
}

@_cdecl("MCERendererGetGpuPassTimingsSupported")
public func MCERendererGetGpuPassTimingsSupported(_ contextPtr: UnsafeRawPointer?) -> UInt32 {
    guard let engineContext = resolveEngineContext(contextPtr),
          let rendererProfiler = engineContext.renderer?.profiler else { return 0 }
    return rendererProfiler.gpuCounterSamplingSupported(device: engineContext.device) ? 1 : 0
}

@_cdecl("MCERendererCopyGpuPassTimingDebugInfo")
public func MCERendererCopyGpuPassTimingDebugInfo(
    _ contextPtr: UnsafeRawPointer?,
    _ buffer: UnsafeMutablePointer<CChar>?,
    _ bufferLength: Int32
) {
    guard let buffer, bufferLength > 0 else { return }
    let info = profiler(contextPtr)?.gpuCounterDebugInfo() ?? "GPU counters: unavailable."
    info.withCString { cString in
        strncpy(buffer, cString, Int(bufferLength - 1))
        buffer[Int(bufferLength - 1)] = 0
    }
}

@_cdecl("MCERendererSetGpuPassTimingsEnabled")
public func MCERendererSetGpuPassTimingsEnabled(_ contextPtr: UnsafeRawPointer?, _ value: UInt32) {
    profiler(contextPtr)?.setGpuPassTimingsEnabled(value != 0)
}

@_cdecl("MCERendererGetGpuShadowPassMs")
public func MCERendererGetGpuShadowPassMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageGpuPassMs(.shadows) ?? 0
}

@_cdecl("MCERendererGetGpuDepthPrepassMs")
public func MCERendererGetGpuDepthPrepassMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageGpuPassMs(.depthPrepass) ?? 0
}

@_cdecl("MCERendererGetGpuScenePassMs")
public func MCERendererGetGpuScenePassMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageGpuPassMs(.scene) ?? 0
}

@_cdecl("MCERendererGetGpuGridPassMs")
public func MCERendererGetGpuGridPassMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageGpuPassMs(.grid) ?? 0
}

@_cdecl("MCERendererGetGpuPickingPassMs")
public func MCERendererGetGpuPickingPassMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageGpuPassMs(.picking) ?? 0
}

@_cdecl("MCERendererGetGpuOutlinePassMs")
public func MCERendererGetGpuOutlinePassMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageGpuPassMs(.outline) ?? 0
}

@_cdecl("MCERendererGetGpuBloomExtractPassMs")
public func MCERendererGetGpuBloomExtractPassMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageGpuPassMs(.bloomExtract) ?? 0
}

@_cdecl("MCERendererGetGpuBloomBlurPassMs")
public func MCERendererGetGpuBloomBlurPassMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageGpuPassMs(.bloomBlur) ?? 0
}

@_cdecl("MCERendererGetGpuFinalCompositePassMs")
public func MCERendererGetGpuFinalCompositePassMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageGpuPassMs(.finalComposite) ?? 0
}

@_cdecl("MCERendererGetGpuMs")
public func MCERendererGetGpuMs(_ contextPtr: UnsafeRawPointer?) -> Float {
    profiler(contextPtr)?.averageMs(.gpu) ?? 0
}

// MCESky* APIs removed: SkyLight is edited via EditorECSBridge only.
