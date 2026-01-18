//
//  EngineView.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/17/26.
//

import MetalKit

class EngineView: MTKView {
    
    var renderer: Renderer!
    
    required init(coder: NSCoder) {
        super.init(coder: coder)
        self.device = MTLCreateSystemDefaultDevice()
        Engine.initialize(device: device!)
        self.clearColor = Preferences.clearColor
        self.colorPixelFormat = Preferences.defaultPixelFormat
        renderer = Renderer()
        self.delegate = renderer
    }
    
    //TODO: Handle inputs here
}
