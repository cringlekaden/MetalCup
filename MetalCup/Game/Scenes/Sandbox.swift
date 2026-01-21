//
//  Sandbox.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/18/26.
//

import MetalKit

class Sandbox: Scene {
    
    var debugCamera = DebugCamera()
    
    override func buildScene() {
        debugCamera.position.z = 5
        addCamera(debugCamera)
        for y in -5..<5 {
            let posY = Float(y) + 0.5
            for x in -8..<8 {
                let posX = Float(x) + 0.5
                let cube = Cube()
                cube.position.y = posY
                cube.position.x = posX
                cube.scale = SIMD3<Float>(0.3,0.3,0.3)
                cube.setColor(Color.randomColor)
                addChild(cube)
            }
        }
    }
}
