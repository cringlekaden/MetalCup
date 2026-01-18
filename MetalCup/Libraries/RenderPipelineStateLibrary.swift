//
//  RenderPipelineState.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/17/26.
//

import MetalKit

public enum RenderPipelineStateType {
    case Basic
}

public class RenderPipelineStateLibrary {
    private static var pipelineStates: [RenderPipelineStateType: RenderPipelineState] = [:]
    
    public static func initialize() {
        pipelineStates[.Basic] = BasicRenderPipelineState()
    }
    
    public static func State(_ pipelineStateType: RenderPipelineStateType)->MTLRenderPipelineState {
        return pipelineStates[pipelineStateType]!.pipelineState
    }
}

protocol RenderPipelineState {
    var name: String { get }
    var pipelineState: MTLRenderPipelineState! { get }
}

public struct BasicRenderPipelineState: RenderPipelineState {
    public var name: String = "BasicPipelineState"
    public var pipelineState: MTLRenderPipelineState!
    init() {
        do {
            pipelineState = try Engine.Device.makeRenderPipelineState(descriptor: RenderPipelineDescriptorLibrary.Descriptor(.Basic))
        } catch let error as NSError {
            print("ERROR::CREATE::PIPELINE_STATE::__\(name)__::\(error)")
        }
    }
}
