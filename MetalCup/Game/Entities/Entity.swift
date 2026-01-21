//
//  GameObject.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/17/26.
//

import MetalKit

class Entity: Node {
    
    private var material = Material()
    
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
        renderCommandEncoder.setDepthStencilState(DepthStencilStateLibrary.DepthStencilState(.Less))
        renderCommandEncoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
        renderCommandEncoder.setVertexBytes(&modelConstants, length: ModelConstants.stride, index: 2)
        renderCommandEncoder.setFragmentBytes(&material, length: Material.stride, index: 1)
        renderCommandEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.vertexCount)
    }
}

extension Entity {
    public func setColor(_ color: SIMD4<Float>) {
        self.material.color = color
        self.material.useMaterialColor = true
    }
}
