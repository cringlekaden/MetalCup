//
//  Player.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/18/26.
//

import MetalKit

class Player: Entity {
    
    init() {
        super.init(meshType: .TriangleCustom)
    }
    
    override func update(delta: Float) {
        self.rotation.z = -atan2f(Mouse.GetMouseViewportPosition().x - position.x, Mouse.GetMouseViewportPosition().y - position.y)
        super.update(delta: delta)
    }
}
