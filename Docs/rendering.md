# Rendering

## Stable pipeline

The renderer is Metal-based. `RenderGraph`, `RenderPasses`, `SceneRenderer`, and `RenderOutputs` coordinate pass scheduling; `SceneLinearHDRContract.swift` defines the scene-linear HDR boundary. Stable main shades PBR materials in scene-linear space, then applies post processing/output conversion (including configurable exposure, bloom, tone mapping and gamma/output handling). `SceneView` and renderer settings provide the editor view and controls.

## Lighting, shadows and IBL

Analytic lights and directional-shadow resources live in `Core/Rendering/Shadows`; direct-light, shadow and SSAO contracts have tests. IBL includes environment cubemaps, diffuse irradiance, prefiltered specular data and a BRDF LUT. Reflection probes can be queued for rebuild by the runtime, but continuous probe scheduling is not complete. Treat probe updates as explicit/rebuild-driven work on stable main.

## Materials, shaders and environment

Materials use a metal/roughness PBR workflow with texture handles and scalar fallbacks. Stable asset classification accepts common raster textures; HDR/EXR environment assets; and OBJ, USDZ, FBX, glTF, GLB and `.mcmesh` models. Canonical shaders are engine resources by default; project-local `Assets/Shaders` is only used when the project selects an override.

Stable environment controls include sky, fog and cloud settings exposed through the renderer/editor. Their exact visual fidelity is still under development; do not rely on the unmerged physical/celestial reconstruction work described in [development status](development-status.md).
