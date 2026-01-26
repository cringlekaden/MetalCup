//
//  VertexShaderLibrary.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/21/26.
//

import MetalKit

enum ShaderType {
    case BasicVertex
    case InstancedVertex
    case BasicFragment
    case SkysphereVertex
    case SkysphereFragment
}

class ShaderLibrary: Library<ShaderType, MTLFunction> {
    
    private var _library: [ShaderType: Shader] = [:]
    
    override func fillLibrary() {
        _library[.BasicVertex] = Shader(name: "Basic Vertex Shader", functionName: "vertex_basic")
        _library[.InstancedVertex] = Shader(name: "Instanced Vertex Shader", functionName: "vertex_instanced")
        _library[.BasicFragment] = Shader(name: "Basic Fragment Shader", functionName: "fragment_basic")
        _library[.SkysphereVertex] = Shader(name: "Skysphere Vertex Shader", functionName: "vertex_skysphere")
        _library[.SkysphereFragment] = Shader(name: "Skysphere Fragment Shader", functionName: "fragment_skysphere")
    }
    
    override subscript(_ type: ShaderType)->MTLFunction {
        return (_library[type]?.function)!
    }
}

class Shader {
    
    var function: MTLFunction!
    
    init(name: String, functionName: String) {
        self.function = Engine.DefaultLibrary.makeFunction(name: functionName)
        self.function.label = name
    }
}
