//
//  Player.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/18/26.
//

import MetalKit

class Pointer: Entity {
    
    private var camera: Camera!
    
    init(camera: Camera) {
        super.init(meshType: .TriangleCustom)
        self.camera = camera
    }
    
    override func update(delta: Float) {
        self.rotation.z = -atan2f(Mouse.GetMouseViewportPosition().x - position.x + camera.position.x, Mouse.GetMouseViewportPosition().y - position.y + camera.position.y)
        super.update(delta: delta)
    }
}
