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
