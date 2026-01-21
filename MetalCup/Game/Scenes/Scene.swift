//
//  Scene.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/18/26.
//

import MetalKit

class Scene: Node {
    
    var cameraManager = CameraManager()
    var sceneConstants = SceneConstants()
    
    init() {
        super.init(name: "Scene")
        buildScene()
    }
    
    override func update() {
        sceneConstants.viewMatrix = cameraManager.currentCamera.viewMatrix
        sceneConstants.projectionMatrix = cameraManager.currentCamera.projectionMatrix
        sceneConstants.totalGameTime = GameTime.TotalGameTime
        super.update()
    }
    
    override func render(renderCommandEncoder: MTLRenderCommandEncoder) {
        renderCommandEncoder.setVertexBytes(&sceneConstants, length: SceneConstants.stride, index: 1)
        super.render(renderCommandEncoder: renderCommandEncoder)
    }
    
    func updateCameras() {
        cameraManager.update()
    }
    
    func addCamera(_ camera: Camera, _ setCurrent: Bool = true) {
        cameraManager.registerCamera(camera: camera)
        if(setCurrent) {
            cameraManager.setCamera(camera.cameraType)
        }
    }
    
    func buildScene() {}
}
