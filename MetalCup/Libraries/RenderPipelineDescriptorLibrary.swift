//
//  PipelineDescriptorLibrary.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/17/26.
//

import MetalKit

enum RenderPipelineDescriptorType {
    case Basic
}

class RenderPipelineDescriptorLibrary {
    
    private static var pipelineDescriptors: [RenderPipelineDescriptorType: RenderPipelineDescriptor] = [:]
    
    public static func initialize() {
        pipelineDescriptors[.Basic] = BasicRenderPipelineDescriptor()
    }
    
    public static func Descriptor(_ pipelineDescriptorType: RenderPipelineDescriptorType)->MTLRenderPipelineDescriptor{
        return pipelineDescriptors[pipelineDescriptorType]!.pipelineDescriptor
    }
}

protocol RenderPipelineDescriptor {
    var name: String { get }
    var pipelineDescriptor: MTLRenderPipelineDescriptor! { get }
}

public struct BasicRenderPipelineDescriptor: RenderPipelineDescriptor {
    public var name: String = "BasicPipelineDescriptor"
    public var pipelineDescriptor: MTLRenderPipelineDescriptor!
    init() {
        pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.colorAttachments[0].pixelFormat = Preferences.defaultPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = Preferences.defaultDepthPixelFormat
        pipelineDescriptor.vertexFunction = ShaderLibrary.Vertex(.Basic)
        pipelineDescriptor.fragmentFunction = ShaderLibrary.Fragment(.Basic)
        pipelineDescriptor.vertexDescriptor = VertexDescriptorLibrary.Descriptor(.Basic)
    }
}
