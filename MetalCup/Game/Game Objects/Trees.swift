//
//  Trees.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/23/26.
//

import MetalKit

class Trees: Node {
    init(treeACount: Int, treeBCount: Int, treeCCount: Int) {
        super.init(name: "Trees")
        let treeAs = InstancedGameObject(meshType: .Tree1, instanceCount: treeACount)
        treeAs.updateNodes(updateTreePosition)
        addChild(treeAs)
        let treeBs = InstancedGameObject(meshType: .Tree2, instanceCount: treeBCount)
        treeBs.updateNodes(updateTreePosition)
        addChild(treeBs)
        let treeCs = InstancedGameObject(meshType: .Tree3, instanceCount: treeCCount)
        treeCs.updateNodes(updateTreePosition)
        addChild(treeCs)
    }
    
    private func updateTreePosition(tree: Node, i: Int) {
        let radius: Float = Float.random(in: 8...70)
        let pos = SIMD3<Float>(cos(Float(i)) * radius, 0, sin(Float(i)) * radius)
        tree.setPosition(pos)
        tree.setScale(Float.random(in: 1...2))
        tree.rotateY(Float.random(in: 0...360))
    }
}
