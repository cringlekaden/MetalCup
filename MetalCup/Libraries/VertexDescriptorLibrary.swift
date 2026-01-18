//
//  VertexDescriptorLibrary.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/17/26.
//

import MetalKit

enum VertexDescriptorType {
    case Basic
}

class VertexDescriptorLibrary {
    
    private static var vertexDescriptors: [VertexDescriptorType: VertexDescriptor] = [:]
    
    public static func initialize() {
        vertexDescriptors[.Basic] = BasicVertexDescriptor()
    }
    
    public static func Descriptor(_ vertexDescriptorType: VertexDescriptorType)->MTLVertexDescriptor {
        return vertexDescriptors[vertexDescriptorType]!.vertexDescriptor
    }
}

protocol VertexDescriptor {
    var name: String { get }
    var vertexDescriptor: MTLVertexDescriptor! { get }
}

public struct BasicVertexDescriptor: VertexDescriptor {
    var name: String = "BasicVertexDescriptor"
    var vertexDescriptor: MTLVertexDescriptor!
    init() {
        vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[1].format = .float4
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[1].offset = SIMD3<Float>.size
        vertexDescriptor.layouts[0].stride = Vertex.stride
    }
}
