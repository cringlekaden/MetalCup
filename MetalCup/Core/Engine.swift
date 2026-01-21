//
//  Engine.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/17/26.
//

import MetalKit

class Engine {
    
    public static var Device: MTLDevice!
    public static var CommandQueue: MTLCommandQueue!
    
    public static func initialize(device: MTLDevice) {
        self.Device = device
        self.CommandQueue = device.makeCommandQueue()
        ShaderLibrary.initialize()
        VertexDescriptorLibrary.initialize()
        DepthStencilStateLibrary.initialize()
        RenderPipelineDescriptorLibrary.initialize()
        RenderPipelineStateLibrary.initialize()
        MeshLibrary.initialize()
        SceneManager.initialize(Preferences.initialSceneType)
    }
}
