//
//  Sandbox.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/18/26.
//

import MetalKit

class Sandbox: Scene {
    
    var debugCamera = DebugCamera()
    var quad = Quad()
    
    override func buildScene() {
        addCamera(debugCamera)
        debugCamera.setPositionZ(5)
        quad.setTexture(textureType: .PartyPirateParrot)
        addChild(quad)
    }
}
