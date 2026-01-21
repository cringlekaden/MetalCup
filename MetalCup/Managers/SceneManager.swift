//
//  SceneManager.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/18/26.
//

import MetalKit

enum SceneType {
    case Sandbox
}

class SceneManager {
    
    private static var currentScene: Scene!
    
    public static func initialize(_ sceneType: SceneType) {
        SetScene(sceneType)
    }
    
    public static func SetScene(_ sceneType: SceneType) {
        switch sceneType {
        case .Sandbox:
            currentScene = Sandbox()
        }
    }
    
    public static func TickScene(renderCommandEncoder: MTLRenderCommandEncoder, delta: Float) {
        currentScene.updateCameras(delta: delta)
        currentScene.update(delta: delta)
        currentScene.render(renderCommandEncoder: renderCommandEncoder)
    }
}
