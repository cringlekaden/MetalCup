/// SceneView.swift
/// Describes the camera/view parameters used for rendering a scene.
/// Created by Kaden Cringle.

import Foundation
import simd

public struct SceneViewExposureSettings: sizeable, Equatable {
    public static let expectedMetalStride: Int = 24

    public var autoExposureEnabled: UInt32
    public var manualExposure: Float
    public var exposureCompensation: Float
    public var autoExposureMin: Float
    public var autoExposureMax: Float
    public var adaptationSpeed: Float

    public init(autoExposureEnabled: UInt32 = 1,
                manualExposure: Float = 1.0,
                exposureCompensation: Float = 0.0,
                autoExposureMin: Float = 0.03,
                autoExposureMax: Float = 8.0,
                adaptationSpeed: Float = 2.0) {
        self.autoExposureEnabled = autoExposureEnabled
        self.manualExposure = manualExposure
        self.exposureCompensation = exposureCompensation
        self.autoExposureMin = autoExposureMin
        self.autoExposureMax = autoExposureMax
        self.adaptationSpeed = adaptationSpeed
    }
}

public struct SceneView {
    public var viewId: UInt64
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
