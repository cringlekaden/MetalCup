# Architecture

## Repository and boundary

`MetalCupEngine/` is a macOS framework target and `MetalCupEngineTests/` holds its tests. `Core/Rendering` contains render scheduling and GPU resources; `Game/ECS` holds components and systems; `Game/Scenes` coordinates the runtime and persistence; `Serialization` contains DTOs; `Bridge` exposes the editor-facing C surface. The editor may depend on the engine; the engine must never import editor types.

## ECS and frame ownership

`SceneECS` stores component data. `EngineScene`, `SceneRuntime`, `SceneUpdateScheduler`, and `TransformAuthorityService` establish update order and transform ownership. Components are declared in `Game/ECS/Components.swift`; scene DTOs in `Serialization/SceneSerialization.swift` preserve the supported scene data. Engine context owns renderer, assets, physics and runtime services; the editor only drives them through explicit context/bridge calls.

## Resource ownership

GPU state belongs to the renderer and `RenderResources`; assets are registered through engine asset services using handles rather than arbitrary runtime paths. Project assets are editor-owned files. The default project shader source is canonical engine resources; a project may explicitly select `Assets/Shaders` as an override. Do not treat any internal bridge or storage layout as a stable third-party API.

## Scene and project data

The editor writes `.mcp` project documents and `.mcscene` scene documents. Scene serialization carries entities, components, renderer settings and asset handles; it is versioned implementation data, not a promised interchange format. Prefabs and materials are project assets (`.prefab`, `.mcmat`).
