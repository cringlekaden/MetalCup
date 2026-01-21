//
//  Camera.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/18/26.
//

import simd

enum CameraType {
    case Debug
}

protocol Camera {
    var cameraType: CameraType { get }
    var position: SIMD3<Float> { get set }
    var projectionMatrix: matrix_float4x4 { get }
    func update(delta: Float)
}

extension Camera {
    var viewMatrix: matrix_float4x4 {
        var viewMatrix = matrix_identity_float4x4
        viewMatrix.translate(direction: -position)
        return viewMatrix
    }
}
