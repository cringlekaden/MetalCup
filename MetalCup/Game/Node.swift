//
//  Node.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/18/26.
//

import MetalKit

class Node {
    
    func render(renderCommandEncoder: MTLRenderCommandEncoder) {
        if let renderable = self as? Renderable {
            renderable.doRender(renderCommandEncoder)
        }
    }
}
