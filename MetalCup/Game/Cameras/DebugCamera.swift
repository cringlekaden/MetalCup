//
//  DebugCamera.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/18/26.
//

import simd

class DebugCamera: Camera {
    
    var cameraType = CameraType.Debug
    var position = SIMD3<Float>.zero
    var projectionMatrix: matrix_float4x4 {
        return matrix_float4x4.perspective(fovDegrees: 90.0, aspectRatio: Renderer.AspectRatio, near: 0.1, far: 1000.0)
    }
    
    func update(delta: Float) {
        if(Keyboard.IsKeyPressed(.leftArrow)) {
            position.x -= delta
        }
        if(Keyboard.IsKeyPressed(.rightArrow)) {
            position.x += delta
        }
        if(Keyboard.IsKeyPressed(.upArrow)) {
            position.y += delta
        }
        if(Keyboard.IsKeyPressed(.downArrow)) {
            position.y -= delta
        }
    }
}
