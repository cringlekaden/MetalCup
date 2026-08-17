# Runtime systems

## Physics and controllers

`Game/Physics` integrates Jolt. Physics world/system state is engine-owned. Components include rigid-body/collider and character-controller data; `CharacterControllerSystem` applies controller movement. Configuration is editor-exposed but game-ready authoring remains early-stage.

## Animation

Animation runtime support is in `Game/Animation` and uses Ozz at runtime. Animator components can evaluate a clip or a compiled animation graph. Graph assets use `.mcanimgraph`; clips include `.anim`, `.animclip`, and `.mcanim` classifications. Graph evaluation, validation and authoring are implemented, but asset-import and authoring combinations should be treated as version-sensitive.

## Scripting and input

Lua is embedded in `Bridge/LuaBridge.mm`; it invokes optional global `onCreate`, `onStart`, and `onUpdate` callbacks. It publishes `Time.deltaTime`, `Log`, `Input`, `Key`, and a bound `Entity` API. For example, a controller script can use `Input.IsKeyDown(Key.W)`, `Entity:Move({ x = 0, z = 1 })`, and `Entity:Jump()`; these names are registered by the bridge. Scripts are project assets (`.lua`, `.mcscript`, or `.cs` are classified as scripts), not a stable sandboxed public API.

## Serialization

`SceneSerializationService` and `SerializedScene` load/save scene DTOs. Asset metadata is separate from source assets. Project-local `Cache`, `Intermediate`, and `Saved` directories are generated/runtime output and should not be relied on as portable source content.
