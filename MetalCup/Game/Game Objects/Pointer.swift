//
//  Player.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/18/26.
//

import MetalKit

class Pointer: GameObject {
    
    private var camera: Camera!
    
    init(camera: Camera) {
        super.init(meshType: .TriangleCustom)
        self.camera = camera
        self.setName("Pointer")
    }
    
    override func doUpdate() {
        self.rotateZ(-atan2f(Mouse.GetMouseViewportPosition().x - getPositionX() + camera.getPositionX(), Mouse.GetMouseViewportPosition().y - getPositionY() + camera.getPositionY()))
    }
}
