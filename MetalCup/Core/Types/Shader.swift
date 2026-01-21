//
//  Shader.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/21/26.
//

import MetalKit

class Shader {
    
    var function: MTLFunction!
    
    init(name: String, functionName: String) {
        self.function = Engine.DefaultLibrary.makeFunction(name: functionName)
        self.function.label = name
    }
}
