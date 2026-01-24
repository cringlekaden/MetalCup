//
//  GameObject.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/17/26.
//

import MetalKit

class GameObject: Node {
    
    private var _material: Material? = nil
    private var _diffuseMapTextureType: TextureType = .None
    private var _normalMapTextureType: TextureType = .None
    private var _modelConstants = ModelConstants()
    private var _mesh: Mesh!
    
    init(name: String, meshType: MeshType) {
        super.init(name: name)
        _mesh = Assets.Meshes[meshType]
    }
    
    override func update() {
        _modelConstants.modelMatrix = self.modelMatrix
        super.update()
    }
}

extension GameObject: Renderable {
    func doRender(_ renderCommandEncoder: MTLRenderCommandEncoder) {
        renderCommandEncoder.setTriangleFillMode(Preferences.isWireframeEnabled ? .lines : .fill)
        renderCommandEncoder.setRenderPipelineState(Graphics.RenderPipelineStates[.Basic])
        renderCommandEncoder.setDepthStencilState(Graphics.DepthStencilStates[.Less])
        renderCommandEncoder.setVertexBytes(&_modelConstants, length: ModelConstants.stride, index: 2)
        _mesh.drawPrimitives(renderCommandEncoder, material: _material, diffuseMapTextureType: _diffuseMapTextureType, normalMapTextureType: _normalMapTextureType)
    }
}

extension GameObject {
    public func useMaterial(_ material: Material) {
        _material = material
    }

    public func useDiffuseMapTexture(_ textureType: TextureType) {
        _diffuseMapTextureType = textureType
    }
    
    public func useNormalMapTexture(_ textureType: TextureType) {
        _normalMapTextureType = textureType
    }
}
