# MetalCupEngine

MetalCupEngine is the Swift/Metal runtime behind [MetalCupEditor](https://github.com/cringlekaden/MetalCupEditor). It provides the ECS, scene and asset runtime, Metal renderer, Jolt physics bridge, animation runtime, and Lua scripting boundary used by the editor.

> **Early development:** stable `main` is the public baseline, not a production-ready SDK. APIs and serialized data can change. It is tested only on Apple-silicon Macs running macOS 26.2 with a current Xcode.

## What is here

- `MetalCupEngine/` — Swift framework source: renderer, ECS, scene runtime, serialization and bridges.
- `MetalCupEngineTests/` — renderer and runtime contract tests.
- `Vendor/` and `ThirdParty/` — checked-in dependencies and their notices.

Stable `main` implements scene-linear HDR rendering, PBR materials, shadows, SSAO, bloom and output tone mapping; IBL and reflection-probe rebuilds; model/texture/material assets; animation graphs; Jolt physics and character controllers; and Lua runtime hooks. See the [technical documentation](Docs/README.md) for exact boundaries and limitations.

## Build

Clone with submodules, then open `MetalCupEngine.xcodeproj` and build the shared **MetalCupEngine** scheme. `Vendor/JoltPhysics` is a required git submodule; a checkout without it cannot compile `JoltBridge.mm`. The editor project embeds the framework product; building the editor is the practical end-to-end smoke test.

```sh
git clone --recurse-submodules https://github.com/cringlekaden/MetalCupEngine.git
# Existing clone:
git submodule update --init --recursive
```

```sh
xcodebuild -project MetalCupEngine.xcodeproj -scheme MetalCupEngine -configuration Debug -destination 'platform=macOS' build
```

There is no supported package manager distribution, command-line game runner, or export/packaging pipeline on stable `main`.

## Documentation

- [Technical documentation](Docs/README.md)
- [Architecture](Docs/architecture.md)
- [Building, testing and contributing](Docs/development.md)
- [Stable and experimental status](Docs/development-status.md)
- [Editor handbook](https://github.com/cringlekaden/MetalCupEditor/tree/main/Docs)

## Relationship to the editor

The engine must not depend on editor types. MetalCupEditor owns the end-user project workflow and talks to engine state through framework APIs and C-callable bridges. Use the Editor repository for installing, creating projects, and authoring content.

## Limitations and roadmap

Stable `main` has no shipping/export workflow and no public compatibility guarantee. See [ROADMAP.md](ROADMAP.md) and [development status](Docs/development-status.md); the active environment reconstruction branches are deliberately unmerged.

## License and third-party material

No top-level license file is present in this repository, so its code license is not established by this README. Do not assume the historical MIT wording in earlier documentation applies. Dependency licenses remain in their own directories; see [third-party responsibilities](Docs/development.md#dependencies-and-licenses).

Contributions are welcome under [CONTRIBUTING.md](CONTRIBUTING.md). Please report vulnerabilities through [SECURITY.md](SECURITY.md).
