# Development

## Build and test

Initialize the required `Vendor/JoltPhysics` git submodule before building: `git submodule update --init --recursive`. Open `MetalCupEngine.xcodeproj` in Xcode and select the shared `MetalCupEngine` or `MetalCupEngineTests` scheme. The deployment target is macOS 26.2. A command-line framework build is:

```sh
xcodebuild -project MetalCupEngine.xcodeproj -scheme MetalCupEngine -configuration Debug -destination 'platform=macOS' build
```

Run the test scheme from Xcode, or use `-scheme MetalCupEngineTests test`. Tests include GPU/reference checks and require a suitable Metal-capable host.

## Adding work safely

For a component, add the component definition, update its serialization DTO/bridge only when needed, establish its owner in the scene scheduler, and add a focused test. For a shader/pass, retain the scene-linear contract, declare resources/bindings, integrate the pass through `RenderGraph`/`RenderPasses`, and add a validation test or project. Do not add editor dependencies to the framework or silently change serialized formats.

## Dependencies and licenses

Jolt is vendored under `Vendor/JoltPhysics` with its `LICENSE`; Lua is under `Vendor/Lua/lua-5.5.0`; Ozz is under `ThirdParty/Ozz`. Their upstream terms apply independently. The repository has no top-level license file, so contributors must not assume a grant for MetalCup-owned code. Preserve notices when modifying or distributing dependency material.

## Documentation maintenance

When behavior changes, update the owning page and its “last verified” hash, check links with the documentation verifier, and keep tutorials limited to stable `main`. Describe branch-only work only in `development-status.md`.
