//
//  PipelineDescriptorLibrary.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/17/26.
//

import MetalKit

enum RenderPipelineDescriptorType {
    case Basic
    case Instanced
}

class RenderPipelineDescriptorLibrary: Library<RenderPipelineDescriptorType, MTLRenderPipelineDescriptor> {
    
    private var _library: [RenderPipelineDescriptorType: RenderPipelineDescriptor] = [:]
    
    override func fillLibrary() {
        _library[.Basic] = BasicRenderPipelineDescriptor()
        _library[.Instanced] = InstancedRenderPipelineDescriptor()
    }
    
    override subscript(_ type: RenderPipelineDescriptorType)->MTLRenderPipelineDescriptor {
        return _library[type]!.renderPipelineDescriptor
    }
}

protocol RenderPipelineDescriptor {
    var name: String { get }
    var renderPipelineDescriptor: MTLRenderPipelineDescriptor! { get }
}

public struct BasicRenderPipelineDescriptor: RenderPipelineDescriptor {
    public var name: String = "Basic Render Pipeline Descriptor"
    public var renderPipelineDescriptor: MTLRenderPipelineDescriptor!
    init() {
        renderPipelineDescriptor = MTLRenderPipelineDescriptor()
        renderPipelineDescriptor.colorAttachments[0].pixelFormat = Preferences.defaultColorPixelFormat
        renderPipelineDescriptor.depthAttachmentPixelFormat = Preferences.defaultDepthPixelFormat
        renderPipelineDescriptor.vertexFunction = Graphics.VertexShaders[.Basic]
        renderPipelineDescriptor.fragmentFunction = Graphics.FragmentShaders[.Basic]
        renderPipelineDescriptor.vertexDescriptor = Graphics.VertexDescriptors[.Basic]
    }
}

public struct InstancedRenderPipelineDescriptor: RenderPipelineDescriptor {
    public var name: String = "Instanced Render Pipeline Descriptor"
    public var renderPipelineDescriptor: MTLRenderPipelineDescriptor!
    init() {
        renderPipelineDescriptor = MTLRenderPipelineDescriptor()
        renderPipelineDescriptor.colorAttachments[0].pixelFormat = Preferences.defaultColorPixelFormat
        renderPipelineDescriptor.depthAttachmentPixelFormat = Preferences.defaultDepthPixelFormat
        renderPipelineDescriptor.vertexFunction = Graphics.VertexShaders[.Instanced]
        renderPipelineDescriptor.fragmentFunction = Graphics.FragmentShaders[.Basic]
        renderPipelineDescriptor.vertexDescriptor = Graphics.VertexDescriptors[.Basic]
    }
}

