//
//  Sandbox.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/18/26.
//

import MetalKit

class Sandbox: Scene {
    
    override func buildScene() {
        let count: Int = 5
        for y in -count..<count {
            for x in -count..<count {
                let player = Player()
                player.position.y = Float(Float(y) + 0.5) / Float(count)
                player.position.x = Float(Float(x) + 0.5) / Float(count)
                player.scale = SIMD3<Float>(0.1, 0.1, 0.1)
                addChild(player)
            }
        }
    }
    
    override func update(delta: Float) {
        for child in children {
            child.rotation.z += 0.02
        }
        super.update(delta: delta)
    }
}
