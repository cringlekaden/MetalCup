//
//  FragmentShaderLibrary.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/21/26.
//

import MetalKit

enum FragmentShaderType {
    case Basic
}

class FragmentShaderLibrary: Library<FragmentShaderType, MTLFunction> {
    
    private var _library: [FragmentShaderType: Shader] = [:]
    
    override func fillLibrary() {
        _library[.Basic] = Shader(name: "Basic Fragment Shader", functionName: "fragment_basic")
    }
    
    override subscript(_ type: FragmentShaderType)->MTLFunction {
        return (_library[type]?.function)!
    }
    
}
