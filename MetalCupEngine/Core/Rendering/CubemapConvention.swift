import simd

/// The single world-space cubemap contract used by MetalCup.
///
/// Coordinate system:
/// - World space is right-handed, +Y is up, and an unrotated camera/light looks
///   along local -Z.
/// - Metal cube slices are ordered +X, -X, +Y, -Y, +Z, -Z.
/// - A cube sample direction is always a world-space direction. Reflections use
///   `reflect(-V, N)`, where V points from the surface toward the camera.
/// - Equirectangular sources place world +Z at the horizontal center and world
///   +X three quarters across. Environment rotation is not currently authored;
///   when introduced it must be applied once before conversion/capture.
///
/// Metal's render-target origin and texture-cube face orientation require a
/// horizontal mirror in the 90-degree capture projection. The matching capture
/// pass therefore uses clockwise front faces. Keeping the face bases and this
/// projection together prevents scene-captured probes from needing sampling
/// flips that global procedural/HDRI cubemaps do not use.
public enum CubemapConvention {
    public enum Face: Int, CaseIterable, Sendable {
        case positiveX = 0
        case negativeX = 1
        case positiveY = 2
        case negativeY = 3
        case positiveZ = 4
        case negativeZ = 5
    }

    public struct FaceBasis: Equatable, Sendable {
        public let face: Face
        public let direction: SIMD3<Float>
        public let up: SIMD3<Float>

        public init(face: Face, direction: SIMD3<Float>, up: SIMD3<Float>) {
            self.face = face
            self.direction = direction
            self.up = up
        }
    }

    public static let faceBases: [FaceBasis] = [
        FaceBasis(face: .positiveX, direction: [ 1, 0, 0], up: [0, 1, 0]),
        FaceBasis(face: .negativeX, direction: [-1, 0, 0], up: [0, 1, 0]),
        FaceBasis(face: .positiveY, direction: [ 0, 1, 0], up: [0, 0,-1]),
        FaceBasis(face: .negativeY, direction: [ 0,-1, 0], up: [0, 0, 1]),
        FaceBasis(face: .positiveZ, direction: [ 0, 0, 1], up: [0, 1, 0]),
        FaceBasis(face: .negativeZ, direction: [ 0, 0,-1], up: [0, 1, 0])
    ]

    public static let captureViewMatrices: [matrix_float4x4] = faceBases.map {
        matrix_float4x4(lookAt: .zero, center: $0.direction, up: $0.up)
    }

    public static func captureProjection(nearZ: Float, farZ: Float) -> matrix_float4x4 {
        var projection = matrix_float4x4(
            perspectiveFov: .pi / 2,
            aspect: 1,
            nearZ: nearZ,
            farZ: farZ
        )
        projection.columns.0.x *= -1
        return projection
    }

    /// CPU reference for `cubeDirectionFromFaceUV` in `Shared.metal`.
    public static func direction(face: Face, uv: SIMD2<Float>) -> SIMD3<Float> {
        let st = uv * 2 - 1
        let faceUV = SIMD2<Float>(st.x, -st.y)
        let direction: SIMD3<Float>
        switch face {
        case .positiveX: direction = [1, faceUV.y, -faceUV.x]
        case .negativeX: direction = [-1, faceUV.y, faceUV.x]
        case .positiveY: direction = [faceUV.x, 1, -faceUV.y]
        case .negativeY: direction = [faceUV.x, -1, faceUV.y]
        case .positiveZ: direction = [faceUV.x, faceUV.y, 1]
        case .negativeZ: direction = [-faceUV.x, faceUV.y, -1]
        }
        return simd_normalize(direction)
    }

    /// Canonical equirectangular mapping shared by HDRI conversion diagnostics.
    public static func equirectangularUV(worldDirection: SIMD3<Float>) -> SIMD2<Float> {
        let direction = simd_normalize(worldDirection)
        let longitude = atan2(direction.x, direction.z)
        let latitude = asin(min(max(direction.y, -1), 1))
        return SIMD2<Float>(longitude / (2 * .pi) + 0.5, 0.5 - latitude / .pi)
    }
}
