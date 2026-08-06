import Testing
@testable import MetalCupEngine

struct EditorCameraExposurePersistenceTests {
    @Test
    func editorCameraExposurePersistsWhenEditorEntitiesAreIncluded() {
        let scene = EngineScene(
            name: "EditorExposureScene",
            prefabSystem: nil,
            engineContext: nil,
            shouldBuildScene: false
        )

        scene.ensureSceneCameraEntity()
        let editorCameraEntry = scene.ecs.activeCamera(allowEditor: true, preferEditor: true)
        #expect(editorCameraEntry != nil)
        guard let editorCameraEntity = editorCameraEntry?.0,
              var editorCamera = scene.ecs.get(CameraComponent.self, for: editorCameraEntity) else {
            return
        }

        editorCamera.autoExposureEnabled = false
        editorCamera.manualExposure = 2.25
        editorCamera.exposureCompensation = -1.0
        editorCamera.autoExposureMin = 0.15
        editorCamera.autoExposureMax = 3.5
        editorCamera.adaptationSpeed = 0.75
        scene.ecs.add(editorCamera, to: editorCameraEntity)

        let document = scene.toDocument(rendererSettingsOverride: nil, includeEditorEntities: true)

        let reloaded = EngineScene(
            name: "ReloadedEditorExposureScene",
            prefabSystem: nil,
            engineContext: nil,
            shouldBuildScene: false
        )
        reloaded.apply(document: document)

        let reloadedEditorCameraEntry = reloaded.ecs.activeCamera(allowEditor: true, preferEditor: true)
        #expect(reloadedEditorCameraEntry != nil)
        guard let reloadedEditorCamera = reloadedEditorCameraEntry.flatMap({ reloaded.ecs.get(CameraComponent.self, for: $0.0) }) else {
            return
        }

        #expect(reloadedEditorCamera.isEditor)
        #expect(reloadedEditorCamera.autoExposureEnabled == false)
        #expect(reloadedEditorCamera.manualExposure == 2.25)
        #expect(reloadedEditorCamera.exposureCompensation == -1.0)
        #expect(reloadedEditorCamera.autoExposureMin == 0.15)
        #expect(reloadedEditorCamera.autoExposureMax == 3.5)
        #expect(reloadedEditorCamera.adaptationSpeed == 0.75)
    }
}
