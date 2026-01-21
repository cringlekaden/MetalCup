//
//  Quad.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/21/26.
//

import simd

class Quad: GameObject {
    
    init() {
        super.init(meshType: .QuadCustom)
        self.setName("Quad")
    }
}
