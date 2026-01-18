//
//  ShaderLibrary.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/17/26.
//

import MetalKit

public enum VertexShaderType {
    case Basic
}

public enum FragmentShaderType {
    case Basic
}

public class ShaderLibrary {
    
    public static var defaultLibrary: MTLLibrary!
    
    private static var vertexShaders: [VertexShaderType: Shader] = [:]
    private static var fragmentShaders: [FragmentShaderType: Shader] = [:]
    
    public static func initialize() {
        self.defaultLibrary = Engine.Device.makeDefaultLibrary()
        vertexShaders[.Basic] = BasicVertexShader()
        fragmentShaders[.Basic] = BasicFragmentShader()
    }
    
    public static func Vertex(_ vertexShaderType: VertexShaderType)->MTLFunction{
        return vertexShaders[vertexShaderType]!.function
    }
    
    public static func Fragment(_ fragmentShaderType: FragmentShaderType)->MTLFunction{
        return fragmentShaders[fragmentShaderType]!.function
    }
}

protocol Shader {
    var name: String { get }
    var functionName: String { get }
    var function: MTLFunction! { get }
}

public struct BasicVertexShader: Shader {
    public var name: String = "BasicVertexShader"
    public var functionName: String = "vertex_main"
    public var function: MTLFunction!
    init() {
        function = ShaderLibrary.defaultLibrary.makeFunction(name: functionName)
        function?.label = name
    }
}

public struct BasicFragmentShader: Shader {
    public var name: String = "BasicFragmentShader"
    public var functionName: String = "fragment_main"
    public var function: MTLFunction!
    init() {
        function = ShaderLibrary.defaultLibrary.makeFunction(name: functionName)
        function?.label = name
    }
}
