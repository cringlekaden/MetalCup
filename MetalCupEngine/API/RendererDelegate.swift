/// RendererDelegate.swift
/// Defines the RendererDelegate types and helpers for the engine.
/// Created by Kaden Cringle.

import MetalKit

public protocol RendererDelegate: AnyObject {
    func update(frame: FrameContext)
    func renderScene(into encoder: MTLRenderCommandEncoder, frameContext: RendererFrameContext)
    func renderOverlays(view: MTKView, commandBuffer: MTLCommandBuffer, frameContext: RendererFrameContext)
    func activeScene() -> EngineScene?
    func buildSceneView(renderer: Renderer) -> SceneView
    func handlePickResult(_ result: PickResult)
}

public extension RendererDelegate {
    func activeScene() -> EngineScene? {
        nil
    }

    func buildSceneView(renderer: Renderer) -> SceneView {
        let viewport = (renderer.viewportSize.x > 1 && renderer.viewportSize.y > 1)
            ? renderer.viewportSize
            : renderer.drawableSize
        let scene = activeScene()
        let matrices = scene.map { SceneRenderer.cameraMatrices(scene: $0) }
        let cameraPosition = scene.map { SceneRenderer.cameraPosition(scene: $0) } ?? .zero
        let exposureSettings = scene.map { SceneRenderer.cameraExposure(scene: $0) } ?? SceneViewExposureSettings()
        return SceneView(viewMatrix: matrices?.view ?? matrix_identity_float4x4,
                         projectionMatrix: matrices?.projection ?? matrix_identity_float4x4,
                         cameraPosition: cameraPosition,
                         viewportSize: viewport,
                         exposureSettings: exposureSettings)
    }

    func handlePickResult(_ result: PickResult) {}
}
