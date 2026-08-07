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

## Phase 4 daytime atmosphere and solar-energy contract

`DaytimeAtmosphereModel` and the matching functions in `ProceduralSky.metal`
define the daytime source. The model uses an Earth-like 6360 km planet under a
6460 km atmosphere, 8 km Rayleigh and 1.2 km aerosol scale heights, normalized
Rayleigh/Henyey-Greenstein phase functions, explicit RGB optical depths, ozone,
ground albedo, and a documented multiple-scattering approximation. These values
are physically motivated, but the RGB energy normalization remains scene-relative.

The Phase 4B clear-day calibration uses neutral D65 top-of-atmosphere source RGB,
explicit Rayleigh optical-depth ratios `(0.025, 0.075, 0.220)`, neutral aerosol
extinction, and ozone optical depths `(0.003, 0.008, 0.002)`. Multiple scattering
inherits chromaticity from spectrally scattered solar energy rather than adding a
neutral or authored warm term. The neutral ground albedo is `0.08`; upper-sky
ground bounce uses transmitted sunlight, and the lower hemisphere is a bounded
Lambertian ground response rather than a scaled copy of horizon radiance. A narrow
direction-space blend from `y = -0.02` through `y = +0.02` keeps the mathematical
horizon finite and continuous. Camera fog and aerial perspective remain responsible
for the final visual horizon treatment in Phase 5.

At source EV 0, the unattenuated solar disk has projected Rec.709 illuminance
`2`. The disk radius is `0.266 degrees`, and its projected solid angle is
`pi * sin(radius)^2`. This normalization gives an order-one direct response while
keeping the disk finite in `RGBA16Float` through source EV +1. `sourceEV` scales
the complete daytime source once by `2^sourceEV`; it is distinct from camera EV.
The normalization remains `2` after Phase 4B: raising it to `2.2` would leave less
than one percent of half-float disk headroom at source EV +1, while camera EV +1
already provides the appropriate photographic output exposure without changing
sky, Sun, or IBL energy.

The visible sky is atmosphere body + scattered aureole + unscattered disk. The
procedural IBL capture is atmosphere body + aureole only. The generated analytic
directional Sun is the transmitted disk's projected RGB integral, decomposed as
`color * illuminance`; this prevents the disk from being integrated twice. Its
direction, the visible disk, and directional-shadow ray all derive from the same
environment render state. No environment, weather, IBL, material, exposure, or
output-stage gain compensates the result.
