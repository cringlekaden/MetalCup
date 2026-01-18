//
//  GameObject.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/17/26.
//

import MetalKit

class Entity: Node {
    
    var modelConstants = ModelConstants()
    var mesh: Mesh!
    
    init(meshType: MeshType) {
        mesh = MeshLibrary.Mesh(meshType)
    }
    
    override func update(delta: Float) {
        modelConstants.modelMatrix = self.modelMatrix
    }
}

extension Entity: Renderable {
    func doRender(_ renderCommandEncoder: MTLRenderCommandEncoder) {
        renderCommandEncoder.setTriangleFillMode(Preferences.isWireframeEnabled ? .lines : .fill)
        renderCommandEncoder.setRenderPipelineState(RenderPipelineStateLibrary.State(.Basic))
        renderCommandEncoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
        renderCommandEncoder.setVertexBytes(&modelConstants, length: ModelConstants.stride, index: 1)
        renderCommandEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.vertexCount)
    }
}
