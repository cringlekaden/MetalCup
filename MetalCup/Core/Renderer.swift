//
//  Renderer.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/17/26.
//

import MetalKit

class Renderer: NSObject {
    
    var player = Player()
}

extension Renderer: MTKViewDelegate {
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        //TODO: Handle window resize
    }
    
    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let renderPassDescriptor = view.currentRenderPassDescriptor else { return }
        let commandBuffer = Engine.CommandQueue.makeCommandBuffer()!
        let renderCommandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        player.render(renderCommandEncoder: renderCommandEncoder!)
        renderCommandEncoder?.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
