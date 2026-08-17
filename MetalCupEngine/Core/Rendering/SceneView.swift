/// SceneView.swift
/// Describes the camera/view parameters used for rendering a scene.
/// Created by Kaden Cringle.

import Foundation
import simd

public struct SceneViewExposureSettings: Equatable {
    public var cameraOverride: ExposurePolicyOverride
    public var volumeOverrides: [ExposureOverrideLayer]
    public var temporalEvent: ExposureTemporalEvent
    public var adaptationPaused: Bool

    public init(cameraOverride: ExposurePolicyOverride = .inheritAll,
                volumeOverrides: [ExposureOverrideLayer] = [],
                temporalEvent: ExposureTemporalEvent = .none,
                adaptationPaused: Bool = false) {
        self.cameraOverride = cameraOverride
        self.volumeOverrides = volumeOverrides
        self.temporalEvent = temporalEvent
        self.adaptationPaused = adaptationPaused
    }

    /// Source-compatible deterministic helper for older lower-level callers. The value is
    /// legacy gain-in-stops, not EV100, and is translated at this boundary only.
    public init(exposureEV legacyGainStops: Float,
                exposureCompensation: Float = 0) {
        self.init(cameraOverride: ExposurePolicyOverride(
            mode: .manualEV100,
            compensation: exposureCompensation,
            manualEV100: ExposureCalibration.ev100(fromLegacyGainStops: legacyGainStops)
        ))
    }

    public var autoExposureEnabled: UInt32 {
        cameraOverride.mode == .automaticHistogram ? 1 : 0
    }

    public var exposureEV: Float {
        ExposureCalibration.sceneEV100 - (cameraOverride.manualEV100 ?? ExposureCalibration.sceneEV100)
    }

    public var exposureCompensation: Float { cameraOverride.compensation ?? 0 }
    public var autoExposureMin: Float { cameraOverride.minimumEV100 ?? ExposurePolicyResolver.engineFallback.minimumEV100 }
    public var autoExposureMax: Float { cameraOverride.maximumEV100 ?? ExposurePolicyResolver.engineFallback.maximumEV100 }
    public var adaptationSpeed: Float { cameraOverride.darkAdaptationRate ?? ExposurePolicyResolver.engineFallback.darkAdaptationRate }
}

public struct SceneView {
    public var viewId: UInt64
    public var sceneId: UUID
    public var cameraId: UUID
    public var viewKind: ExposureViewKind
    public var viewMatrix: matrix_float4x4
    public var projectionMatrix: matrix_float4x4
    public var cameraPosition: SIMD3<Float>
    public var viewportSize: SIMD2<Float>
    public var viewportOrigin: SIMD2<Float>
    public var mousePositionInViewport: SIMD2<Float>?
    public var requestPick: Bool
    public var exposureSettings: SceneViewExposureSettings
    public var layerMask: LayerMask
    public var selectedEntityIds: [UUID]
    public var debugFlags: UInt32
    public var depthPrepassEnabled: Bool
    public var isEditorView: Bool

    public init(viewId: UInt64 = 0,
                sceneId: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                cameraId: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                viewKind: ExposureViewKind = .game,
                viewMatrix: matrix_float4x4 = matrix_identity_float4x4,
                projectionMatrix: matrix_float4x4 = matrix_identity_float4x4,
                cameraPosition: SIMD3<Float> = .zero,
                viewportSize: SIMD2<Float> = .zero,
                viewportOrigin: SIMD2<Float> = .zero,
                mousePositionInViewport: SIMD2<Float>? = nil,
                requestPick: Bool = false,
                exposureSettings: SceneViewExposureSettings = SceneViewExposureSettings(),
                layerMask: LayerMask = .all,
                selectedEntityIds: [UUID] = [],
                debugFlags: UInt32 = 0,
                depthPrepassEnabled: Bool = true,
                isEditorView: Bool = false) {
        self.viewId = viewId
        self.sceneId = sceneId
        self.cameraId = cameraId
        self.viewKind = viewKind
        self.viewMatrix = viewMatrix
        self.projectionMatrix = projectionMatrix
        self.cameraPosition = cameraPosition
        self.viewportSize = viewportSize
        self.viewportOrigin = viewportOrigin
        self.mousePositionInViewport = mousePositionInViewport
        self.requestPick = requestPick
        self.exposureSettings = exposureSettings
        self.layerMask = layerMask
        self.selectedEntityIds = selectedEntityIds
        self.debugFlags = debugFlags
        self.depthPrepassEnabled = depthPrepassEnabled
        self.isEditorView = isEditorView
    }
}
