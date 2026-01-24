//
//  Flowers.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/23/26.
//

import MetalKit

class Flowers: Node {
    init(flowerRedCount: Int, flowerPurpleCount: Int, flowerYellowCount: Int) {
        super.init(name: "Flowers")
        let flowerReds = InstancedGameObject(meshType: .Flower1, instanceCount: flowerRedCount)
        flowerReds.updateNodes(updateFlowerPosition)
        addChild(flowerReds)
        let flowerPurples = InstancedGameObject(meshType: .Flower2, instanceCount: flowerPurpleCount)
        flowerPurples.updateNodes(updateFlowerPosition)
        addChild(flowerPurples)
        let flowerYellows = InstancedGameObject(meshType: .Flower3, instanceCount: flowerYellowCount)
        flowerYellows.updateNodes(updateFlowerPosition)
        addChild(flowerYellows)
    }
    
    private func updateFlowerPosition(flower: Node, i: Int) {
        let radius: Float = Float.random(in: 0.9...70)
        let pos = SIMD3<Float>(cos(Float(i)) * radius, 0, sin(Float(i)) * radius)
        flower.setPosition(pos)
        flower.rotateY(Float.random(in: 0...360))
        flower.setScale(Float.random(in: 0.6...0.8))
    }
}
