//
//  Skysphere.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/26/26.
//

import MetalKit

class Skysphere: GameObject {
    
    private var _skySphereTextureType: TextureType!
    
    override var renderPipelineState: RenderPipelineStateType { return .Skysphere }
    
    init(skySphereTextureType: TextureType) {
        super.init(name: "Skysphere", meshType: .Skysphere)
        _skySphereTextureType = skySphereTextureType
        setScale(999)
    }
    
    override func render(renderCommandEncoder: MTLRenderCommandEncoder) {
        renderCommandEncoder.setFragmentTexture(Assets.Textures[_skySphereTextureType], index: 10)
        super.render(renderCommandEncoder: renderCommandEncoder)
    }
}
