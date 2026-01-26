//
//  Forest.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/23/26.
//

import simd

class Forest: Scene{

    var debugCamera = DebugCamera()

    override func buildScene() {
        debugCamera.setPosition(0,1,3)
        debugCamera.setRotationX(Float(10).toRadians)
        addCamera(debugCamera)
        let sunColor = SIMD4<Float>(0.7, 0.5, 0, 1.0)
        var sunMaterial = Material()
        sunMaterial.isLit = false
        sunMaterial.color = sunColor
        let sun = LightObject(name: "Sun", meshType: .Sphere)
        sun.setScale(5)
        sun.setPosition(SIMD3<Float>(0, 100, 100))
        sun.useMaterial(sunMaterial)
        addLight(sun)
        let light = LightObject(name: "Light")
        light.setPosition(SIMD3<Float>(0, 100, -100))
        light.setBrightness(0.5)
        addLight(light)
        // Terrain
        let terrain = GameObject(name: "Terrain", meshType: .Terrain)
        terrain.setScale(200)
        addChild(terrain)
        // Tent
        let tent = GameObject(name: "Tent", meshType: .Tent)
        tent.rotateY(Float(20).toRadians)
        addChild(tent)
        // Trees
        let trees = Trees(treeACount: 10000, treeBCount: 10000, treeCCount: 10000)
        addChild(trees)
        // Flowers
        let flowers = Flowers(flowerRedCount: 15000, flowerPurpleCount: 15000, flowerYellowCount: 15000)
        addChild(flowers)
        //Sky Sphere
        let skySphere = Skysphere(skySphereTextureType: .CloudsSkysphere)
        addChild(skySphere)
    }
}
