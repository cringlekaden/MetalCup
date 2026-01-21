//
//  CameraManager.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/18/26.
//

class CameraManager {
    
    private var cameras: [CameraType : Camera] = [:]
    
    public var currentCamera: Camera!
    
    public func registerCamera(camera: Camera) {
        cameras[camera.cameraType] = camera
    }
    
    public func setCamera(_ cameraType: CameraType) {
        currentCamera = cameras[cameraType]
    }
    
    internal func update(delta: Float) {
        for camera in cameras.values {
            camera.update(delta: delta)
        }
    }
}
