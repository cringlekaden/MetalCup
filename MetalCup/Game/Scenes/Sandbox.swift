//
//  Sandbox.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/18/26.
//

class Sandbox: Scene {
    
    var debugCamera = DebugCamera()
    var well = Well()
    var light = PointLight()
    
    override func buildScene() {
        debugCamera.setPosition(0,3,10)
        addCamera(debugCamera)
        light.setPosition(0,50,50)
        light.setAmbientIntensity(0.1)
        addLight(light)
        addChild(well)
    }
    
    override func doUpdate() {
        if(Mouse.IsMouseButtonPressed(button: .left)){
            well.rotateX(Mouse.GetDY() * GameTime.DeltaTime)
            well.rotateY(Mouse.GetDX() * GameTime.DeltaTime)
        }
    }
}
