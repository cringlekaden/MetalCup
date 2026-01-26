//
//  Renderer.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/17/26.
//

import MetalKit

class Renderer: NSObject {
    
    public static var ScreenSize = SIMD2<Float>(0, 0)
    public static var AspectRatio: Float {
        return ScreenSize.y.isZero ? 1 : ScreenSize.x / ScreenSize.y
    }
    
    init(_ mtkView: MTKView) {
        super.init()
        updateScreenSize(view: mtkView)
        SceneManager.SetScene(Preferences.initialSceneType)
    }
}

extension Renderer: MTKViewDelegate {
    
    public func updateScreenSize(view: MTKView) {
        Renderer.ScreenSize = SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height))
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        updateScreenSize(view: view)
    }
    
    func draw(in view: MTKView) {
        SceneManager.Update(deltaTime: 1.0 / Float(view.preferredFramesPerSecond))
        let commandBuffer = Engine.CommandQueue.makeCommandBuffer()
        commandBuffer?.label = "MetalCup Command Buffer"
        
        guard let sceneRenderPassDescriptor = view.currentRenderPassDescriptor else { return }
        let renderCommandEncoder = commandBuffer?.makeRenderCommandEncoder(descriptor: sceneRenderPassDescriptor)
        renderCommandEncoder?.label = "MetalCup Render Command Encoder"
        renderCommandEncoder?.pushDebugGroup("Rendering Scene")
        SceneManager.Render(renderCommandEncoder: renderCommandEncoder!)
        renderCommandEncoder?.popDebugGroup()
        renderCommandEncoder?.endEncoding()
        
        commandBuffer?.present(view.currentDrawable!)
        commandBuffer?.commit()
    }
}
