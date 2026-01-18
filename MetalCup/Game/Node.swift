//
//  Node.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/18/26.
//

import MetalKit
import simd

class Node {
    
    var position: SIMD3<Float> = .zero
    var rotation: SIMD3<Float> = .zero
    var scale: SIMD3<Float> = .one
    var children: [Node] = []
    var modelMatrix: matrix_float4x4 {
        var modelMatrix = matrix_identity_float4x4
        modelMatrix.translate(direction: position)
        modelMatrix.rotate(angle: rotation.x, axis: xAxis)
        modelMatrix.rotate(angle: rotation.y, axis: yAxis)
        modelMatrix.rotate(angle: rotation.z, axis: zAxis)
        modelMatrix.scale(axis: scale)
        return modelMatrix
    }
    
    func update(delta: Float) {
        for child in children {
            child.update(delta: delta)
        }
    }
    
    func render(renderCommandEncoder: MTLRenderCommandEncoder) {
        for child in children {
            child.render(renderCommandEncoder: renderCommandEncoder)
        }
        if let renderable = self as? Renderable {
            renderable.doRender(renderCommandEncoder)
        }
    }
    
    func addChild(_ child: Node) {
        children.append(child)
    }
}
