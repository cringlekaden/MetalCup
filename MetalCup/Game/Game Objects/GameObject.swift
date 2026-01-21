//
//  GameObject.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/17/26.
//

import MetalKit

class GameObject: Node {
    
    private var _material = Material()
    private var _textureType: TextureType = .None
    
    var modelConstants = ModelConstants()
    var mesh: Mesh!
    
    init(meshType: MeshType) {
        mesh = Entities.Meshes[meshType]
    }
    
    override func update() {
        modelConstants.modelMatrix = self.modelMatrix
        super.update()
    }
}

extension GameObject: Renderable {
    func doRender(_ renderCommandEncoder: MTLRenderCommandEncoder) {
        renderCommandEncoder.setTriangleFillMode(Preferences.isWireframeEnabled ? .lines : .fill)
        renderCommandEncoder.setRenderPipelineState(Graphics.RenderPipelineStates[.Basic])
        renderCommandEncoder.setDepthStencilState(Graphics.DepthStencilStates[.Less])
        renderCommandEncoder.setVertexBytes(&modelConstants, length: ModelConstants.stride, index: 2)
        renderCommandEncoder.setFragmentSamplerState(Graphics.SamplerStates[.Linear], index: 0)
        if _material.useTexture {
            renderCommandEncoder.setFragmentTexture(Entities.Textures[_textureType], index: 0)
        }
        renderCommandEncoder.setFragmentBytes(&_material, length: Material.stride, index: 1)
        mesh.drawPrimitives(renderCommandEncoder)
    }
}

extension GameObject {
    public func setColor(_ color: SIMD4<Float>) {
        self._material.color = color
        self._material.useMaterialColor = true
        self._material.useTexture = false
    }
    
    public func setTexture(textureType: TextureType) {
        self._material.useTexture = true
        self._material.useMaterialColor = false
        self._textureType = textureType
    }
}
