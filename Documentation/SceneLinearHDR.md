# MetalCup scene-linear HDR contract

Phase 1 establishes the following exposure-relative rendering convention. It is a
pipeline contract, not yet a claim of real-world lux or candela calibration.

- Working RGB uses linear sRGB/Rec.709 primaries with a D65 white point.
- Scene, sky, fog, bloom inputs, emissive values, and environment resources remain
  scene-linear HDR until final output. HDR intermediates remain `RGBA16Float`.
- Environment maps and procedural captures contain incident radiance in
  scene-radiance units. Uniform environment radiance `1` produces irradiance `pi`,
  so a white Lambertian returns scene radiance `1`.
- Directional lighting will ultimately use incident illuminance. Its reference is
  `pi`, which produces scene radiance `1` from a white Lambertian at normal
  incidence.
- Exposure is never applied in sky evaluation, direct lighting, materials, fog,
  environment capture, irradiance generation, specular prefiltering, reflection
  probes, or bloom extraction. It is applied exactly once during final output.
- The Phase 1 SDR output path is: linear bloom/overlay composition, multiplication
  by `exp2(exposureEV)`, MetalCup Filmic v1, clamping, one linear-to-sRGB encoding,
  and a write to the existing `BGRA8Unorm` final target.
- MetalCup Filmic v1 is the existing chroma-preserving Hable-style curve normalized
  with a scene-linear white point of `16`. No post-sRGB gamma trim is applied.

The production uniform ownership is documented beside `SceneViewExposureSettings`.
The matching Swift reference math lives in `SceneLinearHDRContract`, while the
production GPU implementation lives in `FinalShaders.metal`.

## Phase 3 cubemap and split-sum IBL contract

`CubemapConvention` and `cubeDirectionFromFaceUV` are the matching CPU/GPU
authorities for all global-environment and reflection-probe paths. Metal cube
slices are ordered `+X`, `-X`, `+Y`, `-Y`, `+Z`, `-Z`; the exact face view and
up vectors live in that shared table. A world-space direction is sampled without
per-path axis compensation, and reflections use `reflect(-V, N)` where `V` is
surface-to-camera. Environment rotation, when authored by a source, belongs at
source evaluation and is not repeated during convolution or PBR sampling.

Diffuse convolution stores irradiance. Uniform incident radiance `C` therefore
produces `pi * C`; the Lambertian `1/pi` factor remains in PBR shading. Specular
prefilter mips use perceptual roughness `mip / (mipCount - 1)`, and runtime
sampling uses the inverse mapping `roughness * (mipCount - 1)`. The BRDF LUT's
red channel is the Fresnel scale `A` and green is the Fresnel bias `B`, consumed
as `F0 * A + B` under the same Smith/Schlick convention as production PBR.

Captured global and local texels remain the radiance source of truth. Normal
sampling gain is `1`; probe influence blends local and global radiance but does
not rescale either source. Legacy probe intensity and global LOD tuning fields
remain decode/ABI compatibility data and are inert in normal shading.

Interactive environment edits may publish reduced-sample resources temporarily.
After the exact source signature settles, the renderer automatically publishes a
final-quality generation. Every job carries its exact signature and monotonic
generation, so stale work cannot replace newer resources. On failure, the last
valid published resources remain active.
