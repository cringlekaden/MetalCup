/// DebugDraw.swift
/// Provides a submission queue for debug rendering.
/// Created by Kaden Cringle.

import simd

public enum DebugDrawCategory: CaseIterable {
    case generic
    case physics
    case cameraFrustum
    case reflectionProbeInfluence
    case reflectionProbeBlendShell
    case reflectionProbeSelectionLink
}

private struct DebugDrawBucket {
    var lines: [DebugLine] = []
    var polylines: [DebugPolyline] = []

    mutating func removeAll(keepingCapacity keepCapacity: Bool) {
        lines.removeAll(keepingCapacity: keepCapacity)
        polylines.removeAll(keepingCapacity: keepCapacity)
    }

    var isEmpty: Bool {
        lines.isEmpty && polylines.isEmpty
    }
}

public final class DebugDraw {
    private var submittedGridParams: GridParams?
    private var submittedWorldDebug: [DebugDrawCategory: DebugDrawBucket] = [:]
    public var lineThickness: Float = 0.05

    public init() {
        for category in DebugDrawCategory.allCases {
            submittedWorldDebug[category] = DebugDrawBucket()
        }
    }

    public func beginFrame() {
        submittedGridParams = nil
        for category in DebugDrawCategory.allCases {
            submittedWorldDebug[category]?.removeAll(keepingCapacity: true)
        }
    }

    public func endFrame() {
        // Intentionally empty: submission queue persists until next beginFrame.
    }

    public func submitGridXZ(_ params: GridParams) {
        submittedGridParams = params
    }

    public func submitLine(_ start: SIMD3<Float>, _ end: SIMD3<Float>, color: SIMD4<Float>) {
        submitLine(category: .generic, start, end, color: color)
    }

    public func submitLine(category: DebugDrawCategory, _ start: SIMD3<Float>, _ end: SIMD3<Float>, color: SIMD4<Float>) {
        submittedWorldDebug[category, default: DebugDrawBucket()].lines.append(
            DebugLine(start: start, end: end, color: color)
        )
    }

    public func submitPolyline(_ points: [SIMD3<Float>], color: SIMD4<Float>, closed: Bool = false) {
        submitPolyline(category: .generic, points, color: color, closed: closed)
    }

    public func submitPolyline(category: DebugDrawCategory,
                               _ points: [SIMD3<Float>],
                               color: SIMD4<Float>,
                               closed: Bool = false) {
        let minimumPoints = closed ? 3 : 2
        guard points.count >= minimumPoints else { return }
        submittedWorldDebug[category, default: DebugDrawBucket()].polylines.append(
            DebugPolyline(points: points, color: color, closed: closed)
        )
    }

    public func submitWireBox(transform: matrix_float4x4, halfExtents: SIMD3<Float>, color: SIMD4<Float>) {
        submitWireBox(category: .generic, transform: transform, halfExtents: halfExtents, color: color)
    }

    public func submitWireBox(category: DebugDrawCategory,
                              transform: matrix_float4x4,
                              halfExtents: SIMD3<Float>,
                              color: SIMD4<Float>) {
        let points = boxPoints(halfExtents: halfExtents)
        let world = points.map { transformPoint(transform, $0) }
        submitPolyline(category: category, [world[0], world[1], world[2], world[3]], color: color, closed: true)
        submitPolyline(category: category, [world[4], world[5], world[6], world[7]], color: color, closed: true)
        let verticalEdges: [(Int, Int)] = [(0, 4), (1, 5), (2, 6), (3, 7)]
        for (a, b) in verticalEdges {
            submitLine(category: category, world[a], world[b], color: color)
        }
    }

    public func submitWireBoxShell(category: DebugDrawCategory,
                                   transform: matrix_float4x4,
                                   innerHalfExtents: SIMD3<Float>,
                                   outerHalfExtents: SIMD3<Float>,
                                   outerColor: SIMD4<Float>,
                                   connectorColor: SIMD4<Float>? = nil) {
        let clampedInner = max(innerHalfExtents, SIMD3<Float>(repeating: 0.001))
        let clampedOuter = max(outerHalfExtents, clampedInner)
        submitWireBox(category: category, transform: transform, halfExtents: clampedOuter, color: outerColor)

        let connectorTint = connectorColor ?? outerColor
        let innerCorners = boxPoints(halfExtents: clampedInner).map { transformPoint(transform, $0) }
        let outerCorners = boxPoints(halfExtents: clampedOuter).map { transformPoint(transform, $0) }
        for index in 0..<innerCorners.count {
            submitLine(category: category, innerCorners[index], outerCorners[index], color: connectorTint)
        }

        let innerFaceCenters = boxFaceCenters(halfExtents: clampedInner).map { transformPoint(transform, $0) }
        let outerFaceCenters = boxFaceCenters(halfExtents: clampedOuter).map { transformPoint(transform, $0) }
        for index in 0..<innerFaceCenters.count {
            submitLine(category: category, innerFaceCenters[index], outerFaceCenters[index], color: connectorTint)
        }
    }

    public func submitWireSphere(transform: matrix_float4x4, radius: Float, color: SIMD4<Float>, segments: Int = 16) {
        submitWireSphere(category: .generic, transform: transform, radius: radius, color: color, segments: segments)
    }

    public func submitWireSphere(category: DebugDrawCategory,
                                 transform: matrix_float4x4,
                                 radius: Float,
                                 color: SIMD4<Float>,
                                 segments: Int = 16) {
        if segments <= 3 { return }
        submitCircle(category: category, transform: transform, radius: radius, axis: 0, color: color, segments: segments)
        submitCircle(category: category, transform: transform, radius: radius, axis: 1, color: color, segments: segments)
        submitCircle(category: category, transform: transform, radius: radius, axis: 2, color: color, segments: segments)
    }

    public func submitWireCapsule(transform: matrix_float4x4, radius: Float, halfHeight: Float, color: SIMD4<Float>, segments: Int = 16) {
        submitWireCapsule(category: .generic, transform: transform, radius: radius, halfHeight: halfHeight, color: color, segments: segments)
    }

    public func submitWireCapsule(category: DebugDrawCategory,
                                  transform: matrix_float4x4,
                                  radius: Float,
                                  halfHeight: Float,
                                  color: SIMD4<Float>,
                                  segments: Int = 16) {
        if segments <= 3 { return }
        submitCircle(category: category, transform: transform, radius: radius, axis: 1, color: color, segments: segments)
        let top = transform * matrix_float4x4(translation: SIMD3<Float>(0.0, halfHeight, 0.0))
        let bottom = transform * matrix_float4x4(translation: SIMD3<Float>(0.0, -halfHeight, 0.0))
        submitCircle(category: category, transform: top, radius: radius, axis: 1, color: color, segments: segments)
        submitCircle(category: category, transform: bottom, radius: radius, axis: 1, color: color, segments: segments)

        let sidePoints = [
            (SIMD3<Float>(radius, halfHeight, 0.0), SIMD3<Float>(radius, -halfHeight, 0.0)),
            (SIMD3<Float>(-radius, halfHeight, 0.0), SIMD3<Float>(-radius, -halfHeight, 0.0)),
            (SIMD3<Float>(0.0, halfHeight, radius), SIMD3<Float>(0.0, -halfHeight, radius)),
            (SIMD3<Float>(0.0, halfHeight, -radius), SIMD3<Float>(0.0, -halfHeight, -radius))
        ]
        for (a, b) in sidePoints {
            submitLine(category: category, transformPoint(transform, a), transformPoint(transform, b), color: color)
        }
    }

    func gridParams() -> GridParams? {
        submittedGridParams
    }

    func hasWorldDebugPrimitives() -> Bool {
        DebugDrawCategory.allCases.contains { !(submittedWorldDebug[$0]?.isEmpty ?? true) }
    }

    func lines() -> [DebugLine] {
        DebugDrawCategory.allCases.flatMap { submittedWorldDebug[$0]?.lines ?? [] }
    }

    func polylines() -> [DebugPolyline] {
        DebugDrawCategory.allCases.flatMap { submittedWorldDebug[$0]?.polylines ?? [] }
    }

    func lines(category: DebugDrawCategory) -> [DebugLine] {
        submittedWorldDebug[category]?.lines ?? []
    }

    func polylines(category: DebugDrawCategory) -> [DebugPolyline] {
        submittedWorldDebug[category]?.polylines ?? []
    }

    private func submitCircle(category: DebugDrawCategory,
                              transform: matrix_float4x4,
                              radius: Float,
                              axis: Int,
                              color: SIMD4<Float>,
                              segments: Int) {
        let twoPi = Float.pi * 2.0
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(segments)
        for i in 0..<segments {
            let a0 = (Float(i) / Float(segments)) * twoPi
            let p0 = circlePoint(radius: radius, angle: a0, axis: axis)
            points.append(transformPoint(transform, p0))
        }
        submitPolyline(category: category, points, color: color, closed: true)
    }

    private func boxPoints(halfExtents: SIMD3<Float>) -> [SIMD3<Float>] {
        [
            SIMD3<Float>(-halfExtents.x, -halfExtents.y, -halfExtents.z),
            SIMD3<Float>(halfExtents.x, -halfExtents.y, -halfExtents.z),
            SIMD3<Float>(halfExtents.x, halfExtents.y, -halfExtents.z),
            SIMD3<Float>(-halfExtents.x, halfExtents.y, -halfExtents.z),
            SIMD3<Float>(-halfExtents.x, -halfExtents.y, halfExtents.z),
            SIMD3<Float>(halfExtents.x, -halfExtents.y, halfExtents.z),
            SIMD3<Float>(halfExtents.x, halfExtents.y, halfExtents.z),
            SIMD3<Float>(-halfExtents.x, halfExtents.y, halfExtents.z)
        ]
    }

    private func boxFaceCenters(halfExtents: SIMD3<Float>) -> [SIMD3<Float>] {
        [
            SIMD3<Float>(halfExtents.x, 0.0, 0.0),
            SIMD3<Float>(-halfExtents.x, 0.0, 0.0),
            SIMD3<Float>(0.0, halfExtents.y, 0.0),
            SIMD3<Float>(0.0, -halfExtents.y, 0.0),
            SIMD3<Float>(0.0, 0.0, halfExtents.z),
            SIMD3<Float>(0.0, 0.0, -halfExtents.z)
        ]
    }

    private func circlePoint(radius: Float, angle: Float, axis: Int) -> SIMD3<Float> {
        let c = cos(angle)
        let s = sin(angle)
        switch axis {
        case 0:
            return SIMD3<Float>(0.0, c * radius, s * radius)
        case 1:
            return SIMD3<Float>(c * radius, 0.0, s * radius)
        default:
            return SIMD3<Float>(c * radius, s * radius, 0.0)
        }
    }

    private func transformPoint(_ matrix: matrix_float4x4, _ point: SIMD3<Float>) -> SIMD3<Float> {
        let p = SIMD4<Float>(point.x, point.y, point.z, 1.0)
        let result = matrix * p
        return SIMD3<Float>(result.x, result.y, result.z)
    }
}

public struct DebugLine {
    public var start: SIMD3<Float>
    public var end: SIMD3<Float>
    public var color: SIMD4<Float>
}

public struct DebugPolyline {
    public var points: [SIMD3<Float>]
    public var color: SIMD4<Float>
    public var closed: Bool
}

extension matrix_float4x4 {
    init(translation: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1.0)
    }
}
