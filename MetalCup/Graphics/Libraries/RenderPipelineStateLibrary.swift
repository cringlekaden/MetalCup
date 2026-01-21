//
//  RenderPipelineState.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/17/26.
//

import MetalKit

public enum RenderPipelineStateType {
    case Basic
    case Instanced
}

class RenderPipelineStateLibrary: Library<RenderPipelineStateType, MTLRenderPipelineState> {
    
    private var _library: [RenderPipelineStateType: RenderPipelineState] = [:]
    
    override func fillLibrary() {
        _library[.Basic] = RenderPipelineState(renderPipelineDescriptorType: .Basic)
        _library[.Instanced] = RenderPipelineState(renderPipelineDescriptorType: .Instanced)
    }
    
    override subscript(_ type: RenderPipelineStateType)->MTLRenderPipelineState {
        return _library[type]!.renderPipelineState
    }
}

class RenderPipelineState {
    
    var renderPipelineState: MTLRenderPipelineState!
    
    init(renderPipelineDescriptorType: RenderPipelineDescriptorType) {
        do {
            renderPipelineState = try Engine.Device.makeRenderPipelineState(descriptor: Graphics.RenderPipelineDescriptors[renderPipelineDescriptorType])
        } catch let error as NSError {
            print("ERROR::CREATE::RENDER_PIPELINE_STATE::__::\(error)")
        }
    }
}
