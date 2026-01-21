//
//  VertexShaderLibrary.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/21/26.
//

import MetalKit

enum VertexShaderType {
    case Basic
    case Instanced
}

class VertexShaderLibrary: Library<VertexShaderType, MTLFunction> {
    
    private var _library: [VertexShaderType: Shader] = [:]
    
    override func fillLibrary() {
        _library[.Basic] = Shader(name: "Basic Vertex Shader", functionName: "vertex_basic")
        _library[.Instanced] = Shader(name: "Instanced Vertex Shader", functionName: "vertex_instanced")
    }
    
    override subscript(_ type: VertexShaderType)->MTLFunction {
        return (_library[type]?.function)!
    }
}
