//
//  ProceduralSky.metal
//  MetalCup
//
//  Created by Codex on 2/10/26.
//

#include <metal_stdlib>
#include "Shared.metal"
using namespace metal;

// Shared baseline gain for the procedural sky radiance model.
// Keep this near unit scale so the visible sky and captured IBL start from the
// same plausible HDR baseline instead of baking in a large global over-brightness bias.
static constant float kProceduralSkyRadianceScale = 1.0;
// Local proof switch for validating the bound moon texture. Keep false for normal rendering and IBL generation.
static constant bool kMoonTextureProofDiagnostic = false;
static constant bool kUseLegacyProceduralClouds = false;
static constant bool kUseTextureBackedCloudAtlas = false;

static inline float saturate1(float value) {
    return clamp(value, 0.0, 1.0);
}

static inline float3 positive3(float3 value) {
    return max(value, float3(0.0));
}

static inline float sky_luminance(float3 value) {
    return dot(value, float3(0.2126, 0.7152, 0.0722));
}

static inline float3 perez(float cosTheta, float gamma, float cosGamma, float3 A, float3 B, float3 C, float3 D, float3 E) {
    float3 term1 = 1.0 + A * exp(B / max(cosTheta, 0.01));
    float3 term2 = 1.0 + C * exp(D * gamma) + E * cosGamma * cosGamma;
    return term1 * term2;
}

static inline float3 hosek_wilkie_sky(float3 dir, float3 sunDir, float turbidity, float3 sunTint) {
    float cosTheta = clamp(dir.y, 0.0, 1.0);
    float cosGamma = clamp(dot(dir, sunDir), -1.0, 1.0);
    float gamma = acos(cosGamma);

    // Hosek–Wilkie style fit using extended Perez distribution (RGB-tinted).
    float t = clamp(turbidity, 1.0, 10.0);
    float3 A = (float3(0.1787) * t - 1.4630) * sunTint;
    float3 B = (float3(-0.3554) * t + 0.4275);
    float3 C = (float3(-0.0227) * t + 5.3251);
    float3 D = (float3(0.1206) * t - 2.5771);
    float3 E = (float3(-0.0670) * t + 0.3703);

    float3 zenith = float3(1.0, 1.0, 1.0);
    float3 sky = perez(cosTheta, gamma, cosGamma, A, B, C, D, E) * zenith;
    return max(sky, float3(0.0));
}

static inline float rayleighPhase(float cosTheta) {
    return 0.75 * (1.0 + cosTheta * cosTheta);
}

static inline float miePhaseHG(float cosTheta, float g) {
    float gg = g * g;
    float denom = max(1.0 + gg - 2.0 * g * cosTheta, 0.04);
    return (1.0 - gg) / pow(denom, 1.5);
}

static inline float airMassApprox(float mu) {
    return 1.0 / max(mu + 0.08, 0.06);
}

static inline float horizonOpticalDepthApprox(float3 dir, constant SkyParams &params) {
    float horizon = 1.0 - saturate1(dir.y);
    float horizonShape = pow(horizon, 1.35);
    return max(params.atmosphereOpticalParams.x, 0.0) * (0.10 + 0.90 * horizonShape) * airMassApprox(saturate1(dir.y)) * 0.22;
}

static inline float3 evaluateAnalyticSkyBody(float3 dir,
                                             float3 sunDir,
                                             constant SkyParams &params,
                                             thread float3 &resolvedHazeColor) {
    float cosTheta = saturate1(dir.y);
    float horizon = 1.0 - cosTheta;
    float upperSky = pow(cosTheta, 0.42);
    float sunForwardSigned = clamp(dot(dir, sunDir), -1.0, 1.0);
    float sunForward = saturate1(sunForwardSigned);
    float twilight = saturate1(params.twilightFactor);
    float night = saturate1(params.nightFactor);
    float dayVisibility = saturate1(params.dayNightFactor + twilight * 0.38);

    float4 scattering = params.atmosphereScatteringParams;
    float rayleighStrength = max(scattering.x, 0.0);
    float mieStrength = max(scattering.y, 0.0);
    float mieAnisotropy = clamp(scattering.z, 0.20, 0.95);
    float aerosolDensity = saturate1(scattering.w);
    float ozoneAmount = saturate1(params.atmosphereOpticalParams.y);
    float skyRadianceScale = max(params.atmosphereOpticalParams.z, 0.0);
    float groundBounce = max(params.sunAureoleParams.y, 0.0);

    float opticalDepth = horizonOpticalDepthApprox(dir, params);
    float3 zenithTint = positive3(params.zenithTint);
    float3 horizonTint = positive3(params.horizonTint);
    float3 solarTint = positive3(params.solarExtinctionTint);
    float3 antiSolarTint = positive3(params.antiSolarTint);

    float3 physicalZenith = mix(float3(0.13, 0.32, 0.86), zenithTint, 0.24);
    float3 physicalHorizon = mix(float3(0.72, 0.80, 0.90), horizonTint, 0.26);
    float3 extinctionTint = mix(float3(1.0, 0.92, 0.82), solarTint, 0.30 + twilight * 0.42);

    float3 wavelengthExtinction = exp(-opticalDepth * mix(float3(0.10, 0.18, 0.34),
                                                          float3(0.16, 0.22, 0.30),
                                                          aerosolDensity));
    float lowSun = saturate1((1.0 - params.dayNightFactor) * (1.0 - night) + twilight * 0.72);
    float rayleigh = rayleighPhase(sunForwardSigned) * rayleighStrength;
    float mie = miePhaseHG(sunForwardSigned, mieAnisotropy) * mieStrength * (0.060 + lowSun * 0.018);
    float nearSun = pow(sunForward, mix(8.0, 3.2, aerosolDensity));

    float3 rayleighBody = mix(physicalHorizon, physicalZenith, upperSky) * float3(0.36, 0.62, 1.0) * rayleigh;
    float3 mieBody = extinctionTint * mie * (0.58 + horizon * 0.50 + lowSun * 0.18);
    float3 sky = rayleighBody * wavelengthExtinction + mieBody;

    float horizonWash = smoothstep(0.18, 1.0, horizon) * (0.16 + aerosolDensity * 0.34 + twilight * 0.16 + lowSun * 0.10);
    resolvedHazeColor = mix(physicalHorizon, extinctionTint, 0.24 + nearSun * 0.36 + twilight * 0.20 + lowSun * 0.12);
    sky = mix(sky, resolvedHazeColor, saturate1(horizonWash));

    float warmHorizonGate = smoothstep(0.18, 0.96, horizon) * nearSun * lowSun * (0.55 + aerosolDensity * 0.45);
    float3 goldenHorizon = mix(extinctionTint, positive3(params.duskTint), 0.22 + twilight * 0.18);
    sky += goldenHorizon * warmHorizonGate * (0.16 + mieStrength * 0.12);

    float antiSolar = saturate1(-sunForwardSigned * 0.5 + 0.5);
    sky += antiSolarTint * antiSolar * twilight * (0.032 + upperSky * 0.052);
    sky += physicalHorizon * groundBounce * (0.38 + 0.72 * horizon + lowSun * 0.20);

    float ozoneMask = ozoneAmount * upperSky * (0.35 + twilight * 0.45);
    sky *= mix(float3(1.0), float3(0.82, 0.92, 1.08), saturate1(ozoneMask));
    sky *= mix(0.16, 1.0, dayVisibility) * mix(1.0, 0.72, night);
    sky *= skyRadianceScale;

    return max(sky, float3(0.0));
}

static inline float solarAngularDistance(float3 dir, float3 sunDir) {
    return acos(clamp(dot(dir, sunDir), -1.0, 1.0));
}

static inline float solarRelativeRadiance(constant SkyParams &params) {
    float authoredIntensity = max(params.intensity, 0.001);
    float derivedDiskRadiance = max(params.atmosphereOpticalParams.w / authoredIntensity, 0.0);
    return max(params.sunIntensity, derivedDiskRadiance);
}

static inline float3 solarTransmittanceTint(constant SkyParams &params) {
    float twilight = saturate1(params.twilightFactor);
    float visibility = saturate1(params.solarVisibility);
    float3 solarTint = positive3(params.solarExtinctionTint);
    float3 diskWhite = float3(1.0, 0.985, 0.94);
    return mix(diskWhite, solarTint, 0.28 + twilight * 0.46 + (1.0 - visibility) * 0.18);
}

static inline float3 evaluateSolarDisk(float sunAngle, constant SkyParams &params) {
    float sunRadius = max(params.sunAngularRadius, 0.0001);
    float visibility = saturate1(params.solarVisibility) * (1.0 - saturate1(params.nightFactor));
    float edgeSoftness = mix(0.11, 0.22, saturate1(params.atmosphereScatteringParams.w));
    float disk = 1.0 - smoothstep(sunRadius * (1.0 - edgeSoftness),
                                  sunRadius * (1.0 + edgeSoftness),
                                  sunAngle);
    float core = exp(-pow(sunAngle / max(sunRadius * 0.62, 0.0001), 2.0));
    float radiance = solarRelativeRadiance(params) * visibility;
    float3 tint = solarTransmittanceTint(params);
    return tint * radiance * (disk * 0.82 + core * 0.34);
}

static inline float3 evaluateSolarAureole(float sunCos, float sunAngle, constant SkyParams &params) {
    float sunRadius = max(params.sunAngularRadius, 0.0001);
    float visibility = saturate1(params.solarVisibility) * (1.0 - saturate1(params.nightFactor));
    float aerosolDensity = saturate1(params.atmosphereScatteringParams.w);
    float lowSun = saturate1((1.0 - params.dayNightFactor) * (1.0 - saturate1(params.nightFactor)) + saturate1(params.twilightFactor) * 0.72);
    float aureoleStrength = max(params.sunAureoleParams.x, 0.0) * max(params.sunHaloIntensity, 0.0);
    float angularFalloff = exp(-sunAngle / max(sunRadius * max(params.sunHaloSize, 0.1) * mix(1.25, 1.75, lowSun), 0.0001));
    float mieForward = miePhaseHG(sunCos, clamp(params.atmosphereScatteringParams.z, 0.20, 0.95)) * (0.018 + lowSun * 0.008);
    float nearSunGate = smoothstep(0.12, 1.0, sunCos);
    float lowSunBoost = 0.78 + saturate1(params.twilightFactor) * 0.62 + aerosolDensity * 0.34 + lowSun * 0.26;
    float3 tint = mix(solarTransmittanceTint(params), positive3(params.solarExtinctionTint), 0.28 + saturate1(params.twilightFactor) * 0.24);
    return tint * visibility * aureoleStrength * lowSunBoost * nearSunGate * (angularFalloff * 0.86 + mieForward);
}

static inline float3 evaluateSolarForwardScatter(float sunCos, constant SkyParams &params) {
    float visibility = saturate1(params.solarVisibility) * (1.0 - saturate1(params.nightFactor));
    float aerosolDensity = saturate1(params.atmosphereScatteringParams.w);
    float mieStrength = max(params.atmosphereScatteringParams.y, 0.0);
    float aureoleStrength = max(params.sunAureoleParams.x, 0.0);
    float forward = pow(saturate1(sunCos), mix(18.0, 7.0, aerosolDensity));
    float twilightBoost = 0.55 + saturate1(params.twilightFactor) * 0.55;
    return positive3(params.solarExtinctionTint) * visibility * forward * mieStrength * aureoleStrength * twilightBoost * 0.10;
}

static inline float3 evaluateSolarRadiance(float3 dir, float3 sunDir, constant SkyParams &params) {
    float sunCos = clamp(dot(dir, sunDir), -1.0, 1.0);
    float sunAngle = solarAngularDistance(dir, sunDir);
    float3 disk = evaluateSolarDisk(sunAngle, params);
    float3 aureole = evaluateSolarAureole(sunCos, sunAngle, params);
    float3 forwardScatter = evaluateSolarForwardScatter(sunCos, params);
    return max(disk + aureole + forwardScatter, float3(0.0));
}

static inline float hash31(float3 p) {
    float n = sin(dot(p, float3(127.1, 311.7, 74.7)));
    return fract(n * 43758.5453123);
}

static inline float noise3d(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    float3 u = f * f * (3.0 - 2.0 * f);

    float n000 = hash31(i);
    float n100 = hash31(i + float3(1.0, 0.0, 0.0));
    float n010 = hash31(i + float3(0.0, 1.0, 0.0));
    float n110 = hash31(i + float3(1.0, 1.0, 0.0));
    float n001 = hash31(i + float3(0.0, 0.0, 1.0));
    float n101 = hash31(i + float3(1.0, 0.0, 1.0));
    float n011 = hash31(i + float3(0.0, 1.0, 1.0));
    float n111 = hash31(i + float3(1.0, 1.0, 1.0));

    float nx00 = mix(n000, n100, u.x);
    float nx10 = mix(n010, n110, u.x);
    float nx01 = mix(n001, n101, u.x);
    float nx11 = mix(n011, n111, u.x);
    float nxy0 = mix(nx00, nx10, u.y);
    float nxy1 = mix(nx01, nx11, u.y);
    return mix(nxy0, nxy1, u.z);
}

static inline float fbm3d(float3 p) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < 4; ++i) {
        value += amplitude * noise3d(p);
        p *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

static inline float2 noiseVec2(float3 p) {
    return float2(
        noise3d(p + float3(17.0, 3.0, 11.0)),
        noise3d(p + float3(29.0, 7.0, 19.0))
    ) * 2.0 - 1.0;
}

struct StarLayerSample {
    float intensity;
    float3 color;
};

static inline float3 star_color_from_seed(float seed) {
    float cool = smoothstep(0.06, 0.34, seed) * (1.0 - smoothstep(0.56, 0.82, seed));
    float warm = smoothstep(0.74, 0.98, seed);
    float3 neutralColor = float3(0.92, 0.95, 1.0);
    float3 coolColor = float3(0.54, 0.70, 1.0);
    float3 warmColor = float3(1.0, 0.80, 0.54);
    return mix(mix(neutralColor, coolColor, cool * 0.52), warmColor, warm * 0.40);
}

static inline StarLayerSample sample_star_layer(float3 dir,
                                                float scale,
                                                float threshold,
                                                float faintRadiance,
                                                float brightRadiance,
                                                float coreRadius,
                                                float haloRadius,
                                                float twinklePhase) {
    float3 p = normalize(dir) * scale;
    float3 cell = floor(p);
    float presenceSeed = hash31(cell);

    StarLayerSample sample;
    sample.intensity = 0.0;
    sample.color = float3(1.0);
    if (presenceSeed < threshold) {
        return sample;
    }

    float3 local = fract(p) - 0.5;
    float3 jitter = float3(hash31(cell + float3(11.7, 3.1, 29.4)),
                          hash31(cell + float3(5.3, 41.9, 13.8)),
                          hash31(cell + float3(23.6, 17.2, 7.5))) - 0.5;
    float dist = length(local - jitter * 0.46);
    float brightSeed = hash31(cell + float3(19.7, 41.3, 7.1));
    float colorSeed = hash31(cell + float3(3.1, 23.9, 61.7));
    float magnitude = saturate1((presenceSeed - threshold) / max(1.0 - threshold, 0.0001));
    float brightMagnitude = pow(magnitude, 3.1);
    float heroMagnitude = pow(magnitude, 8.0);

    float resolvedCoreRadius = mix(coreRadius * 0.72, coreRadius * 1.22, brightMagnitude);
    float core = exp(-(dist * dist) / max(resolvedCoreRadius * resolvedCoreRadius, 0.0001));
    float halo = exp(-(dist * dist) / max(haloRadius * haloRadius, 0.0001)) * brightMagnitude;

    float faintBody = faintRadiance * mix(0.45, 1.18, pow(magnitude, 0.55));
    float brightPeak = brightRadiance * (0.22 + brightSeed * 0.78) * brightMagnitude;
    float heroPeak = brightRadiance * 1.35 * heroMagnitude;
    float twinkle = 0.90 + 0.10 * sin(twinklePhase + presenceSeed * 37.0 + brightSeed * 17.0);

    sample.intensity = (core * (faintBody + brightPeak + heroPeak) + halo * brightRadiance * 0.055) * twinkle;
    sample.color = star_color_from_seed(colorSeed);
    return sample;
}

static inline StarLayerSample sample_star_field(float3 dir, float twinklePhase, float starRichness) {
    float richness = clamp(starRichness, 0.0, 3.0);
    float density = saturate1((richness - 0.55) / 2.0);
    float radianceGain = mix(0.82, 1.30, saturate1(richness / 2.0));
    StarLayerSample a = sample_star_layer(dir, 96.0, mix(0.925, 0.872, density), 0.105 * radianceGain, 0.68 * radianceGain, 0.058, 0.160, twinklePhase);
    StarLayerSample b = sample_star_layer(dir.yzx, 190.0, mix(0.960, 0.925, density), 0.135 * radianceGain, 1.25 * radianceGain, 0.052, 0.145, twinklePhase * 1.47 + 2.3);
    StarLayerSample c = sample_star_layer(dir.zxy, 360.0, mix(0.982, 0.958, density), 0.165 * radianceGain, 2.20 * radianceGain, 0.047, 0.122, twinklePhase * 2.1 + 5.7);
    StarLayerSample d = sample_star_layer(normalize(dir + float3(0.17, -0.11, 0.23)), 660.0, mix(0.994, 0.982, density), 0.170 * radianceGain, 3.15 * radianceGain, 0.041, 0.104, twinklePhase * 2.8 + 8.9);
    StarLayerSample e = sample_star_layer(normalize(dir + float3(-0.09, 0.07, 0.14)), 42.0, mix(0.986, 0.970, density), 0.080 * radianceGain, 4.15 * radianceGain, 0.078, 0.205, twinklePhase * 0.73 + 4.1);

    float3 weightedColor = a.color * a.intensity
                         + b.color * b.intensity
                         + c.color * c.intensity
                         + d.color * d.intensity
                         + e.color * e.intensity;
    float intensity = a.intensity + b.intensity + c.intensity + d.intensity + e.intensity;

    StarLayerSample result;
    result.intensity = intensity;
    result.color = (intensity > 0.00001) ? weightedColor / intensity : float3(1.0);
    return result;
}

static inline float moon_surface_detail(float2 moonUV, float3 moonDir) {
    float radial = length(moonUV);
    float maria = fbm3d(float3(moonUV * 2.15, 0.37) + moonDir * 1.8);
    float fine = fbm3d(float3(moonUV * 9.5 + float2(4.7, -2.9), 2.1));
    float craterSeed = noise3d(float3(moonUV * 5.8, 6.4));
    float craterRing = smoothstep(0.18, 0.03, abs(fract(craterSeed * 9.0) - 0.5));
    craterRing *= 1.0 - smoothstep(0.15, 0.95, radial);
    float detail = 0.76 + maria * 0.28 + fine * 0.12 - craterRing * 0.10;
    return clamp(detail, 0.54, 1.22);
}

static inline float2 moon_equirect_uv(float2 moonUV) {
    float r2 = dot(moonUV, moonUV);
    float z = sqrt(max(1.0 - r2, 0.0));
    float longitude = atan2(moonUV.x, z);
    float latitude = asin(clamp(moonUV.y, -1.0, 1.0));
    return float2(fract(0.5 + longitude / (2.0 * M_PI_F)), clamp(0.5 - latitude / M_PI_F, 0.0, 1.0));
}

static constexpr sampler moonSampler(coord::normalized,
                                      address::repeat,
                                      filter::linear,
                                      mip_filter::linear);

static constexpr sampler skyMapSampler(coord::normalized,
                                        address::repeat,
                                        filter::linear,
                                        mip_filter::linear);

static inline float2 sky_equirect_uv(float3 dir) {
    float longitude = atan2(dir.x, dir.z);
    float latitude = asin(clamp(dir.y, -1.0, 1.0));
    return float2(fract(0.5 + longitude / (2.0 * M_PI_F)), clamp(0.5 - latitude / M_PI_F, 0.0, 1.0));
}

static inline float3 rotate_galaxy_direction(float3 dir, float authoredRotationTurns) {
    float yaw = -0.42 + authoredRotationTurns * 2.0 * M_PI_F;
    float pitch = 0.18;
    float cy = cos(yaw);
    float sy = sin(yaw);
    float cp = cos(pitch);
    float sp = sin(pitch);
    float3 yawed = float3(dir.x * cy - dir.z * sy, dir.y, dir.x * sy + dir.z * cy);
    return normalize(float3(yawed.x, yawed.y * cp - yawed.z * sp, yawed.y * sp + yawed.z * cp));
}

static inline float3 raw_moon_albedo(float2 moonUV, texture2d<float> moonAlbedoTexture) {
    return moonAlbedoTexture.sample(moonSampler, moon_equirect_uv(moonUV)).rgb;
}

static inline float3 textured_moon_albedo(float2 moonUV,
                                          float proceduralDetail,
                                          texture2d<float> moonAlbedoTexture) {
    float2 uv = moon_equirect_uv(moonUV);
    float3 textureAlbedo = moonAlbedoTexture.sample(moonSampler, uv).rgb;
    float3 neighborX = moonAlbedoTexture.sample(moonSampler, uv + float2(0.0020, 0.0)).rgb;
    float3 neighborY = moonAlbedoTexture.sample(moonSampler, uv + float2(0.0, 0.0020)).rgb;
    float textureLuma = max(sky_luminance(textureAlbedo), 0.0001);
    float relief = clamp((textureLuma - sky_luminance(neighborX)) * 2.4 + (textureLuma - sky_luminance(neighborY)) * 1.6 + 0.92, 0.72, 1.18);
    float3 contrastAlbedo = clamp((textureAlbedo - float3(0.36)) * 1.55 + float3(0.48), float3(0.04), float3(1.55));
    float3 lumaContrast = float3(clamp((textureLuma - 0.36) * 1.85 + 0.50, 0.06, 1.65));
    float3 detailPreserved = mix(lumaContrast, contrastAlbedo, 0.74);
    return detailPreserved * relief * mix(0.98, 1.04, proceduralDetail);
}

static inline float3 evaluate_galactic_band(float3 dir,
                                            float3 moonDir,
                                            float moonIntensity,
                                            constant SkyParams &params,
                                            float horizonClarity,
                                            float moonAngle,
                                            texture2d<float> galaxyTexture) {
    float galaxyStrength = clamp(params.celestialArtParams.y, 0.0, 3.0);
    if (galaxyStrength <= 0.0001) {
        return float3(0.0);
    }

    float starVisibility = max(params.starIntensity, 0.0) * saturate1(params.starVisibility);
    float starRichness = clamp(params.celestialArtParams.x, 0.0, 3.0);
    float galaxyChroma = clamp(params.celestialArtParams.z, 0.0, 3.0);
    float nightGate = smoothstep(0.05, 0.58, params.nightFactor);
    float horizonMask = smoothstep(-0.02, 0.18, dir.y) * mix(0.62, 1.0, horizonClarity);
    float moonMask = 1.0 - saturate1(exp(-pow(moonAngle / max(params.moonAngularRadius * 30.0, 0.0001), 2.0)) * moonIntensity * 0.18);

    float3 bandNormal = normalize(float3(0.30, 0.58, -0.76));
    float3 bandAxis = normalize(float3(0.88, -0.08, 0.47));
    float bandDistance = abs(dot(dir, bandNormal));
    float along = dot(dir, bandAxis);
    float broadBand = exp(-bandDistance * bandDistance * 18.0);
    float coreBand = exp(-bandDistance * bandDistance * 86.0);

    float structure = fbm3d(dir * 5.2 + float3(1.7, 3.1, 5.9));
    float fineDust = fbm3d(dir * 18.0 + float3(7.3, 2.1, 11.4));
    float darkLane = smoothstep(0.45, 0.88, fbm3d(dir * 8.5 + bandNormal * 3.4));
    float asymmetry = 0.72 + 0.28 * sin(along * 5.0 + structure * 2.4);
    float dustMask = broadBand * asymmetry * mix(0.55, 1.30, structure) * (1.0 - darkLane * coreBand * 0.58);

    float sparkleSeed = hash31(floor(normalize(dir + bandNormal * 0.13) * 760.0));
    float embeddedStars = smoothstep(0.986, 1.0, sparkleSeed) * coreBand * (0.18 + fineDust * 0.82);
    float3 bandColor = mix(float3(0.12, 0.17, 0.34), float3(0.62, 0.72, 1.0), 0.45 + structure * 0.35);
    bandColor = mix(bandColor, float3(0.86, 0.64, 0.42), darkLane * 0.12);

    float visibility = nightGate * horizonMask * moonMask * saturate1(params.starVisibility);
    float bandRadiance = dustMask * (0.075 + galaxyStrength * 0.075 + starRichness * 0.018);
    float starRadiance = embeddedStars * (0.18 + starVisibility * 0.12 + starRichness * 0.10);
    float3 proceduralGalaxy = bandColor * bandRadiance + float3(0.78, 0.84, 1.0) * starRadiance;

    float3 rotatedDir = rotate_galaxy_direction(dir, params.milkyWayParams.x);
    float2 galaxyUV = sky_equirect_uv(rotatedDir);
    float2 galaxyTexel = 1.0 / float2(max(galaxyTexture.get_width(), 1u), max(galaxyTexture.get_height(), 1u));
    float3 centerSample = max(galaxyTexture.sample(skyMapSampler, galaxyUV).rgb, float3(0.0));
    float3 wideSample = max(galaxyTexture.sample(skyMapSampler, galaxyUV + galaxyTexel * float2(2.0, 0.0)).rgb, float3(0.0))
                      + max(galaxyTexture.sample(skyMapSampler, galaxyUV + galaxyTexel * float2(-2.0, 0.0)).rgb, float3(0.0))
                      + max(galaxyTexture.sample(skyMapSampler, galaxyUV + galaxyTexel * float2(0.0, 2.0)).rgb, float3(0.0))
                      + max(galaxyTexture.sample(skyMapSampler, galaxyUV + galaxyTexel * float2(0.0, -2.0)).rgb, float3(0.0));
    float3 textureColor = centerSample * 0.48 + wideSample * 0.13;
    float textureLuma = sky_luminance(textureColor);
    float3 chroma = textureColor / max(textureLuma, 0.0001);
    chroma = mix(float3(0.78, 0.84, 1.0), clamp(chroma, float3(0.35), float3(2.35)), saturate1(galaxyChroma * 0.72));
    float lowFrequencyLuma = smoothstep(0.015, 0.72, textureLuma * 3.2);
    float structuredLuma = pow(lowFrequencyLuma, 0.72);
    float textureExposure = 0.16 + galaxyStrength * 0.13;
    float3 texturedGalaxy = chroma * structuredLuma * textureExposure;

    float textureEnabled = step(0.5, params.galaxyTextureEnabled);
    float3 galaxy = mix(proceduralGalaxy, max(texturedGalaxy, proceduralGalaxy * 0.35), textureEnabled);
    return min(galaxy * visibility * galaxyStrength, float3(0.85));
}

struct CloudLayerSample {
    float mask;
    float density;
    float edge;
    float forwardScatter;
    float directionalLight;
    float transmittance;
};

struct CloudCompositeSample {
    float3 sky;
    float3 sun;
};

struct PseudoVolumeCloudSample {
    float density;
    float edge;
    float topLight;
    float baseShadow;
    float height;
};

static inline float cloud_layer_band(float horizonCoord,
                                     float start,
                                     float thickness,
                                     float softness,
                                     float horizonBoost,
                                     float verticalBias) {
    float bandStart = clamp(start, 0.0, 1.0);
    float bandExtent = max(thickness, 0.05);
    float bandEnd = min(bandStart + bandExtent, 1.0);
    float lowerBand = smoothstep(bandStart,
                                 min(bandStart + 0.08 + softness * 0.12, 1.0),
                                 horizonCoord);
    float upperBand = 1.0 - smoothstep(bandEnd,
                                       min(bandEnd + 0.18 + softness * 0.12, 1.0),
                                       horizonCoord);
    float mask = lowerBand * upperBand;
    mask *= mix(0.78, 1.18, horizonBoost);
    mask *= verticalBias;
    return saturate1(mask);
}

static inline float hash21(float2 p) {
    float n = sin(dot(p, float2(127.1, 311.7)));
    return fract(n * 43758.5453123);
}

static inline float cellular2d(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float nearest = 8.0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            float2 cell = float2(float(x), float(y));
            float2 seed = float2(hash21(i + cell), hash21(i + cell + 19.37));
            float2 delta = cell + seed - f;
            nearest = min(nearest, dot(delta, delta));
        }
    }
    return saturate1(sqrt(nearest));
}

static inline float pseudo_volume_cloud_density(float3 p,
                                                float coverage,
                                                float softness,
                                                float thickness,
                                                float overcastSignal,
                                                float stormSignal) {
    float2 broadCoord = p.xz * 0.115;
    float2 weatherWarp = noiseVec2(float3(broadCoord * 0.74, 11.8)) * (4.5 + 2.8 * (1.0 - softness));
    float2 cloudCoord = p.xz * 0.30 + weatherWarp;

    float weather = fbm3d(float3(broadCoord + weatherWarp * 0.025, 6.2));
    float body = fbm3d(float3(cloudCoord * 0.68, p.y * 1.35 + 18.1));
    float billow = 1.0 - abs(fbm3d(float3(cloudCoord * 1.08 + 3.7, p.y * 2.1 + 27.4)) * 2.0 - 1.0);
    float cells = 1.0 - cellular2d(cloudCoord * 0.40 + weatherWarp * 0.018);
    float detail = fbm3d(float3(cloudCoord * 2.25 - weatherWarp * 0.05, p.y * 3.0 + 45.8));
    float erosion = fbm3d(float3(cloudCoord * 3.7 + weatherWarp * 0.08, p.y * 4.4 + 73.6));

    float verticalCore = smoothstep(0.02, 0.34, p.y) * (1.0 - smoothstep(0.68, 1.03, p.y));
    float verticalAnvil = smoothstep(0.34, 0.92, p.y) * (0.30 + 0.38 * overcastSignal + 0.22 * stormSignal);
    float verticalShape = saturate1(verticalCore + verticalAnvil);

    float shape = mix(body, weather, 0.30);
    shape += (billow - 0.5) * mix(0.36, 0.16, overcastSignal);
    shape += (cells - 0.45) * mix(0.22, 0.08, overcastSignal);
    shape += (detail - 0.5) * mix(0.20, 0.08, softness);
    shape -= smoothstep(0.48, 0.92, erosion) * mix(0.28, 0.09, coverage) * (1.0 - overcastSignal * 0.55);
    shape += overcastSignal * (0.18 + weather * 0.18) + stormSignal * 0.08;

    float threshold = mix(0.70, 0.22, coverage) - overcastSignal * 0.10 - stormSignal * 0.04;
    float edgeWidth = mix(0.052, 0.24, softness) + overcastSignal * 0.05;
    float density = smoothstep(threshold - edgeWidth, threshold + edgeWidth, shape);
    density *= verticalShape;
    density = saturate1(pow(density, mix(1.22, 0.72, coverage)) * (0.72 + 0.42 * body + 0.18 * stormSignal));
    return density;
}

static inline PseudoVolumeCloudSample sample_pseudo_volume_cloud_slab(float2 layerCoord,
                                                                      float2 flow,
                                                                      float coverage,
                                                                      float softness,
                                                                      float thickness,
                                                                      float overcastSignal,
                                                                      float stormSignal) {
    PseudoVolumeCloudSample sample;
    sample.density = 0.0;
    sample.edge = 0.0;
    sample.topLight = 0.0;
    sample.baseShadow = 0.0;
    sample.height = 0.0;

    float weightedDensity = 0.0;
    float weightSum = 0.0;
    const int sampleCount = 5;
    for (int i = 0; i < sampleCount; ++i) {
        float h = (float(i) + 0.5) / float(sampleCount);
        float depthOffset = (h - 0.5) * (26.0 + thickness * 34.0);
        float2 shear = float2(depthOffset * 0.38, depthOffset * -0.21);
        float3 p = float3(layerCoord + flow + shear, h);
        float density = pseudo_volume_cloud_density(p, coverage, softness, thickness, overcastSignal, stormSignal);
        float weight = mix(0.78, 1.22, h) * mix(1.0, 0.72 + h * 0.40, stormSignal);
        weightedDensity += density * weight;
        weightSum += weight;
        sample.topLight += density * h;
        sample.baseShadow += density * (1.0 - h);
        sample.height += density * h;
    }

    sample.density = saturate1(weightedDensity / max(weightSum, 0.0001) * (1.12 + thickness * 0.55));
    sample.height = sample.density > 0.0001 ? saturate1(sample.height / (sample.density * float(sampleCount))) : 0.0;
    sample.topLight = saturate1(sample.topLight / max(float(sampleCount), 1.0));
    sample.baseShadow = saturate1(sample.baseShadow / max(float(sampleCount), 1.0));
    sample.edge = saturate1(smoothstep(0.035, 0.32, sample.density) * (1.0 - smoothstep(0.52, 0.92, sample.density)));
    return sample;
}

static inline float select_cloud_atlas_channel(float4 atlasSample, float style) {
    float roundedStyle = floor(style + 0.5);
    if (roundedStyle < 0.5) {
        return 0.0;
    }
    if (roundedStyle < 1.5) {
        return atlasSample.r;
    }
    if (roundedStyle < 2.5) {
        return atlasSample.g;
    }
    if (roundedStyle < 3.5) {
        return max(atlasSample.b * 0.72, atlasSample.g * 0.42);
    }
    if (roundedStyle < 4.5) {
        return saturate1(atlasSample.b * 0.92 + 0.18);
    }
    if (roundedStyle < 5.5) {
        return max(atlasSample.a, atlasSample.b * 0.48);
    }
    return max(max(atlasSample.r * 0.32, atlasSample.g * 0.46), max(atlasSample.b * 0.56, atlasSample.a * 0.38));
}

static inline float sample_cloud_atlas_macro_mask(float2 layerCoord,
                                                  float2 wind,
                                                  float coverage,
                                                  float softness,
                                                  float horizonBand,
                                                  constant SkyParams &params,
                                                  texture2d<float> cloudAtlasTexture) {
    float style = params.cloudAtlasStyle;
    float baseScale = max(params.cloudsScale, 0.01);
    float2 uv = layerCoord * (0.0065 * baseScale);
    uv += wind * params.skyTime * params.cloudsSpeed * 0.018;

    float4 broad = cloudAtlasTexture.sample(skyMapSampler, uv);
    float4 offset = cloudAtlasTexture.sample(skyMapSampler, uv * 0.63 + float2(0.37, 0.19));
    float macro = select_cloud_atlas_channel(broad, style);
    float secondary = select_cloud_atlas_channel(offset, style);

    float roundedStyle = floor(style + 0.5);
    if (roundedStyle > 0.5 && roundedStyle < 1.5) {
        macro = max(macro, secondary * 0.42);
    } else if (roundedStyle > 2.5 && roundedStyle < 5.5) {
        macro = max(macro, secondary * 0.62);
    }

    float styleBias = 0.0;
    if (roundedStyle > 0.5 && roundedStyle < 1.5) {
        styleBias = 0.10;
    } else if (roundedStyle > 3.5 && roundedStyle < 4.5) {
        styleBias = -0.18;
    } else if (roundedStyle > 4.5 && roundedStyle < 5.5) {
        styleBias = -0.10;
    }

    float threshold = mix(0.74, 0.18, coverage) + styleBias;
    float edgeWidth = mix(0.055, 0.23, softness);
    float mask = smoothstep(threshold - edgeWidth, threshold + edgeWidth, macro);
    if (roundedStyle > 3.5 && roundedStyle < 4.5) {
        mask = max(mask, smoothstep(0.18, 0.54, macro) * mix(0.70, 1.0, coverage));
    }
    if (roundedStyle > 4.5 && roundedStyle < 5.5) {
        mask = pow(mask, 0.72);
    }
    return saturate1(mask * mix(0.92, 1.08, horizonBand));
}

static inline CloudLayerSample sample_cloud_layer(float2 domeUV,
                                                  float2 flow,
                                                  float layerScale,
                                                  float coverage,
                                                  float softness,
                                                  float densityBias,
                                                  float detailWeight,
                                                  float erosionWeight,
                                                  float normalStep,
                                                  float3 sunDir,
                                                  float sunForward,
                                                  float sunInfluence,
                                                  float horizonWeight) {
    CloudLayerSample sample;
    float2 baseUV = domeUV * layerScale;
    float3 broadWarpSeed = float3(baseUV * 0.24 + flow * 0.13, layerScale * 0.11);
    float2 broadWarp = noiseVec2(broadWarpSeed) * (0.20 + 0.16 * horizonWeight);
    float2 detailWarp = noiseVec2(float3(baseUV * 0.74 - flow * 0.31, 41.2)) * (0.035 + 0.055 * (1.0 - softness));
    float2 warpedUV = baseUV + broadWarp + detailWarp;

    float coverageField = fbm3d(float3(warpedUV * 0.34 + flow * 0.18, 13.7));
    float bodyField = fbm3d(float3(warpedUV * 0.86 + flow, 27.1));
    float billowField = 1.0 - abs(fbm3d(float3(warpedUV * 1.38 + flow * 0.62, 33.4)) * 2.0 - 1.0);
    float detailField = fbm3d(float3(warpedUV * 2.55 - flow * 1.45, 51.9));
    float erosionField = fbm3d(float3((warpedUV + broadWarp * 1.15) * 3.65 + flow * 1.8, 73.3));
    float voidField = fbm3d(float3(warpedUV * 1.72 - flow * 0.55, 91.6));

    float shapeField = mix(bodyField, coverageField, 0.44);
    shapeField += (coverageField - 0.5) * (0.20 + 0.14 * horizonWeight);
    shapeField += (pow(saturate1(billowField), mix(1.28, 0.76, coverage)) - 0.5) * (0.18 + 0.10 * (1.0 - softness));
    shapeField += (detailField - 0.5) * detailWeight;
    shapeField -= smoothstep(0.36, 0.86, erosionField) * erosionWeight * (0.62 + 0.38 * (1.0 - coverage));
    shapeField -= smoothstep(0.66, 0.96, voidField) * (0.045 + 0.075 * (1.0 - softness)) * (1.0 - coverage * 0.55);

    float threshold = mix(0.69, 0.19, saturate1(coverage)) + densityBias;
    float edgeSoftness = mix(0.045, 0.22, softness);
    float rawMask = smoothstep(threshold - edgeSoftness, threshold + edgeSoftness, shapeField);
    float coreMask = smoothstep(threshold + edgeSoftness * 0.20,
                                threshold + edgeSoftness * 1.48,
                                shapeField);
    sample.mask = rawMask;
    sample.density = saturate1(pow(rawMask, mix(1.16, 0.74, coverage)) * (0.46 + 0.54 * bodyField) + coreMask * 0.24);
    sample.edge = saturate1(rawMask * (1.0 - coreMask));

    float densityX = fbm3d(float3((warpedUV + float2(normalStep, 0.0)) * 0.86 + flow, 27.1));
    float densityY = fbm3d(float3((warpedUV + float2(0.0, normalStep)) * 0.86 + flow, 27.1));
    float3 cloudNormal = normalize(float3(-(densityX - bodyField) * 8.2,
                                          1.0,
                                          -(densityY - bodyField) * 8.2));
    float3 liftedSunDir = normalize(float3(sunDir.x, max(sunDir.y, 0.0) + 0.32, sunDir.z));
    sample.directionalLight = saturate1(dot(cloudNormal, liftedSunDir) * 0.92 + coreMask * 0.10);
    sample.forwardScatter = pow(sunForward, mix(13.5, 4.2, softness));
    sample.transmittance = saturate1(exp(-sample.density * mix(2.15, 4.15, sunInfluence)));
    return sample;
}

struct VisibleProceduralSkyRasterizerData {
    float4 position [[ position ]];
    float3 direction;
};

struct MoonDiskLayerSample {
    float opacity;
    float interior;
    float celestialOcclusion;
    float textureEnabled;
    float2 uv;
    float3 radiance;
};

static inline float3 evaluateAtmosphereLayer(float3 dir,
                                             float3 sunDir,
                                             constant SkyParams &params,
                                             thread float3 &resolvedHazeColor) {
    float3 sky = evaluateAnalyticSkyBody(dir, sunDir, params, resolvedHazeColor);
    return sky * mix(float3(1.0), positive3(params.skyTint), 0.22);
}

static inline float3 evaluateSunLayer(float3 dir, float3 sunDir, constant SkyParams &params) {
    return evaluateSolarRadiance(dir, sunDir, params);
}

static inline MoonDiskLayerSample evaluateMoonDiskLayer(float3 dir,
                                                       float3 moonDir,
                                                       float moonAngle,
                                                       float moonRadius,
                                                       float moonIntensity,
                                                       constant SkyParams &params,
                                                       texture2d<float> moonAlbedoTexture) {
    MoonDiskLayerSample layer;
    layer.interior = 1.0 - smoothstep(moonRadius * 0.975,
                                      moonRadius * 1.018,
                                      moonAngle);
    layer.opacity = 1.0 - smoothstep(moonRadius * 0.992,
                                     moonRadius * 1.060,
                                     moonAngle);
    layer.opacity *= saturate1(moonIntensity * 8.0);
    layer.celestialOcclusion = 1.0 - layer.interior;

    float3 moonUp = (abs(moonDir.y) < 0.92) ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
    float3 moonTangent = normalize(cross(moonUp, moonDir));
    float3 moonBitangent = cross(moonDir, moonTangent);
    layer.uv = float2(dot(dir, moonTangent), dot(dir, moonBitangent)) / moonRadius;

    float lunarDetail = moon_surface_detail(layer.uv, moonDir);
    float radialUV = length(layer.uv);
    float lunarLimb = mix(0.62, 1.0, 1.0 - smoothstep(0.44, 1.0, radialUV));
    layer.textureEnabled = step(0.5, params.moonTextureEnabled) * step(radialUV, 1.02);
    float3 proceduralAlbedo = float3(lunarDetail);
    float3 sampledAlbedo = textured_moon_albedo(layer.uv, lunarDetail, moonAlbedoTexture);
    float3 lunarAlbedo = mix(proceduralAlbedo, sampledAlbedo, layer.textureEnabled);
    float3 moonTint = mix(float3(1.0, 0.96, 0.86), positive3(params.moonColor), 0.24);
    layer.radiance = moonTint * lunarAlbedo * lunarLimb * moonIntensity * mix(2.35, 2.85, layer.textureEnabled);
    return layer;
}

static inline float3 evaluateMoonGlowLayer(float3 moonDir,
                                           float moonAngle,
                                           float moonRadius,
                                           float moonIntensity,
                                           float horizonClarity,
                                           float moonDiskInterior,
                                           constant SkyParams &params) {
    float moonAboveHorizon = smoothstep(-0.04, 0.22, moonDir.y);
    float moonInnerGlow = exp(-moonAngle / max(moonRadius * 4.8, 0.0001)) * (1.0 - moonDiskInterior);
    float moonOuterGlow = exp(-moonAngle / max(moonRadius * 28.0, 0.0001));
    float moonGlowStrength = moonIntensity * moonAboveHorizon * horizonClarity;
    float3 moonGlowColor = mix(float3(0.30, 0.42, 0.78), positive3(params.moonColor), 0.34);
    return moonGlowColor * moonGlowStrength * (moonInnerGlow * 0.34 + moonOuterGlow * 0.105);
}

static inline float3 evaluateNightBackgroundLayer(float cosTheta,
                                                  float moonCos,
                                                  float moonIntensity,
                                                  float horizonClarity,
                                                  constant SkyParams &params) {
    float nightGradient = smoothstep(-0.02, 0.72, cosTheta);
    float twilightHorizon = params.twilightFactor * (1.0 - smoothstep(0.05, 0.55, cosTheta));
    float nightBrightness = clamp(params.celestialArtParams.w, 0.0, 3.0);
    float3 deepZenith = mix(float3(0.006, 0.012, 0.038), float3(0.018, 0.032, 0.082), params.skyCoolness);
    float3 quietHorizon = mix(float3(0.012, 0.017, 0.036), positive3(params.duskTint) * 0.040, twilightHorizon);
    float moonForward = pow(saturate1(moonCos), 2.0);
    float3 moonlitTint = positive3(params.moonColor) * moonIntensity * (0.022 + 0.050 * moonForward + 0.018 * nightGradient) * horizonClarity;
    return (mix(quietHorizon, deepZenith, nightGradient) * nightBrightness + moonlitTint) * params.nightFactor;
}

static inline float3 evaluateStarLayer(float3 dir,
                                       float moonAngle,
                                       float moonRadius,
                                       float moonIntensity,
                                       float horizonClarity,
                                       float moonCelestialOcclusion,
                                       constant SkyParams &params) {
    float authoredIntensity = max(params.starIntensity, 0.0);
    if (authoredIntensity <= 0.0001) {
        return float3(0.0);
    }

    float starRichness = clamp(params.celestialArtParams.x, 0.0, 3.0);
    float twinklePhase = params.skyTime * 0.45;
    StarLayerSample stars = sample_star_field(dir, twinklePhase, starRichness);
    float horizonStarMask = smoothstep(-0.04, 0.16, dir.y);
    float upperSkyMask = smoothstep(0.10, 0.62, dir.y);
    float hazeMask = mix(0.58, 1.0, horizonClarity);
    float directionalHazeMask = mix(hazeMask, 1.0, upperSkyMask);
    float twilightStarMask = smoothstep(0.04, 0.58, params.nightFactor);
    float moonVicinity = exp(-pow(moonAngle / max(moonRadius * 15.0, 0.0001), 2.0));
    float moonStarMask = 1.0 - saturate1(moonVicinity * moonIntensity * 0.44);
    float visibility = saturate1(params.starVisibility);
    float starArt = pow(min(authoredIntensity, 10.0), 0.36);
    float richnessGain = mix(0.85, 1.65, saturate1(starRichness / 2.0));
    float starStrength = (0.28 + starArt * 4.80) * saturate1(authoredIntensity * 3.6) * richnessGain;
    float starMask = starStrength * visibility * horizonStarMask * directionalHazeMask * twilightStarMask * moonStarMask * moonCelestialOcclusion;
    return min(stars.color * stars.intensity * starMask, float3(8.0));
}

static inline float3 evaluateGalaxyLayer(float3 dir,
                                         float3 moonDir,
                                         float moonIntensity,
                                         float horizonClarity,
                                         float moonAngle,
                                         float moonCelestialOcclusion,
                                         constant SkyParams &params,
                                         texture2d<float> galaxyTexture) {
    return evaluate_galactic_band(dir, moonDir, moonIntensity, params, horizonClarity, moonAngle, galaxyTexture) * moonCelestialOcclusion;
}

static inline CloudCompositeSample evaluateLegacyProceduralClouds(float3 dir,
                                                           float3 sunDir,
                                                           float cosTheta,
                                                           float horizonBand,
                                                           float sunForward,
                                                           float3 baseSky,
                                                           float3 baseSun,
                                                           float3 hazeColor,
                                                           constant SkyParams &params,
                                                           texture2d<float> cloudAtlasTexture) {
    CloudCompositeSample composite;
    composite.sky = baseSky;
    composite.sun = baseSun;

    // Clouds use a 2-layer 2.5D shell model:
    // - a lower anchored weather deck provides mass, depth cues, and horizon presence,
    // - a higher veil layer filters the sun and breaks up the dome silhouette,
    // - both remain non-volumetric so the visible sky and captured IBL stay compatible.
    float cloudsEnabled = (params.cloudsEnabled != 0) ? 1.0 : 0.0;
    if (cloudsEnabled <= 0.5) {
        return composite;
    }

    float2 wind = normalize(params.cloudsWindDirection + float2(0.0001, 0.0));
    float speed = params.cloudsSpeed;
    float baseScale = max(params.cloudsScale, 0.01) * 2.2;
    float softness = clamp(params.cloudsSoftness, 0.01, 1.0);
    float coverage = clamp(params.cloudsCoverage, 0.0, 1.0);
    float coverageVisibility = smoothstep(0.001, 0.04, coverage);
    float sunInfluence = max(params.cloudsSunInfluence, 0.0);
    float brightness = max(params.cloudsBrightness, 0.0);
    float twilight = params.twilightFactor;
    float nightFactor = params.nightFactor;
    float solarVisibility = params.solarVisibility;
    float horizonDensity = params.horizonDensity;
    float overcastSignal = smoothstep(0.70, 0.92, coverage) * smoothstep(0.34, 0.72, params.cloudsThickness);
    float stormSignal = overcastSignal * saturate1((0.70 - brightness) * 1.35 + (0.58 - sunInfluence) * 0.85);
    float lowSunWarmth = saturate1((1.0 - params.dayNightFactor) * (1.0 - nightFactor) + twilight * 0.72);

    float horizonCoord = saturate1(1.0 - cosTheta);
    float cloudBandStart = clamp(params.cloudsHeight, 0.0, 1.0);
    float cloudBandExtent = max(params.cloudsThickness, 0.08);
    float verticalMask = smoothstep(-0.02, 0.08, dir.y);
    float lowerHeightMask = cloud_layer_band(horizonCoord,
                                             cloudBandStart,
                                             cloudBandExtent * mix(1.3, 1.0, softness),
                                             softness,
                                             horizonBand,
                                             verticalMask);
    float upperHeightMask = cloud_layer_band(horizonCoord,
                                             clamp(cloudBandStart + 0.18 + cloudBandExtent * 0.25, 0.0, 1.0),
                                             max(cloudBandExtent * 0.55, 0.05),
                                             min(1.0, softness * 0.9 + 0.12),
                                             mix(0.25, 0.7, horizonBand),
                                             verticalMask * 0.92);

    float perspectiveLift = mix(0.30, 0.11, horizonBand);
    float2 domeUV = dir.xz / max(dir.y + perspectiveLift, 0.16);
    float2 flow = wind * params.skyTime * speed * 0.32;
    float2 highFlow = wind * params.skyTime * speed * 0.48 + float2(0.37, -0.21);

    CloudLayerSample lowerLayer = sample_cloud_layer(domeUV,
                                                     flow,
                                                     baseScale,
                                                     mix(coverage, min(1.0, coverage + 0.14), 0.55),
                                                     softness,
                                                     -0.03,
                                                     mix(0.10, 0.22, 1.0 - softness),
                                                     mix(0.16, 0.33, 1.0 - softness),
                                                     0.04,
                                                     sunDir,
                                                     sunForward,
                                                     sunInfluence,
                                                     horizonBand);
    lowerLayer.mask *= lowerHeightMask;
    lowerLayer.density *= lowerHeightMask;

    CloudLayerSample upperLayer = sample_cloud_layer(domeUV + wind * 0.35,
                                                     highFlow,
                                                     baseScale * 0.58,
                                                     mix(coverage * 0.58, min(1.0, coverage + 0.10), 0.35),
                                                     min(1.0, softness * 0.85 + 0.18),
                                                     0.06,
                                                     0.08,
                                                     0.12,
                                                     0.06,
                                                     sunDir,
                                                     sunForward,
                                                     sunInfluence * 0.7,
                                                     horizonBand);
    upperLayer.mask *= upperHeightMask;
    upperLayer.density *= upperHeightMask;

    float ceilingField = fbm3d(float3(domeUV * baseScale * 0.24 + flow * 0.14, 118.6));
    float ceilingBreakup = fbm3d(float3(domeUV * baseScale * 0.92 - flow * 0.36, 134.2));
    float ceilingMask = smoothstep(mix(0.66, 0.34, coverage),
                                   mix(0.84, 0.52, coverage),
                                   ceilingField + ceilingBreakup * 0.16 + coverage * 0.12);
    ceilingMask *= lowerHeightMask * overcastSignal * coverageVisibility;
    lowerLayer.mask = saturate1(max(lowerLayer.mask, ceilingMask * (0.74 + 0.18 * softness)));
    lowerLayer.density = saturate1(max(lowerLayer.density, ceilingMask * (0.70 + 0.22 * overcastSignal + 0.08 * stormSignal)));

    float combinedMask = saturate1(lowerLayer.mask + upperLayer.mask * (1.0 - lowerLayer.mask * 0.35)) * coverageVisibility;
    float lowerDominance = saturate1(lowerLayer.mask / max(combinedMask, 0.0001));
    float upperDominance = saturate1(upperLayer.mask / max(combinedMask, 0.0001));
    float combinedDensity = saturate1(lowerLayer.density * 0.78 + upperLayer.density * 0.42 + ceilingMask * 0.18);
    float combinedTransmittance = saturate1(lowerLayer.transmittance * (1.0 - upperLayer.mask * 0.35)
                                            + upperLayer.transmittance * upperLayer.mask * 0.25);
    float nightOpacityLimit = mix(1.0, mix(0.48, 0.88, coverage), nightFactor);
    combinedMask *= nightOpacityLimit;

    float edgeSignal = saturate1(lowerLayer.edge * lowerDominance + upperLayer.edge * upperDominance + ceilingMask * 0.08);
    float lowerRim = lowerLayer.forwardScatter * (lowerLayer.edge * 0.80 + edgeSignal * 0.28);
    float upperRim = upperLayer.forwardScatter * (upperLayer.edge * 0.86 + edgeSignal * 0.20);
    float silverLining = (lowerRim * (0.20 + 0.38 * horizonBand)
                          + upperRim * (0.16 + 0.30 * (1.0 - horizonBand)));
    silverLining *= sunInfluence * (0.30 + 0.58 * solarVisibility) * (0.86 + lowSunWarmth * 0.32);
    silverLining *= mix(1.0, 0.34, nightFactor) * mix(1.0, 0.66, overcastSignal);
    silverLining = min(silverLining, 0.82);

    float sunFilter = saturate1(1.0 - combinedDensity * (0.46 + 0.26 * sunInfluence + 0.12 * overcastSignal));
    composite.sun *= mix(1.0, sunFilter, combinedMask * (0.35 + 0.4 * upperDominance));

    float3 lowerShadowColor = mix(composite.sky, hazeColor, 0.24 + 0.26 * horizonBand + horizonDensity * 0.08);
    lowerShadowColor *= mix(0.62, 0.92, lowerLayer.density);
    float3 upperShadowColor = mix(composite.sky, hazeColor, 0.16 + 0.18 * horizonBand);
    upperShadowColor *= mix(0.82, 0.98, upperLayer.density);

    float skyLuma = max(sky_luminance(composite.sky), 0.05);
    float3 warmCloudTint = mix(params.solarExtinctionTint, params.duskTint, saturate1(twilight * 0.38 + lowSunWarmth * 0.30));
    float3 lowerLightColor = mix(lowerShadowColor,
                                 mix(float3(1.0), warmCloudTint, 0.34 + twilight * 0.24 + lowSunWarmth * 0.12),
                                 lowerLayer.directionalLight * (0.42 + 0.36 * sunInfluence) * mix(1.0, 0.78, overcastSignal));
    float3 upperLightColor = mix(upperShadowColor,
                                 mix(float3(1.0), warmCloudTint, 0.22 + twilight * 0.18 + lowSunWarmth * 0.10),
                                 upperLayer.directionalLight * (0.25 + 0.23 * sunInfluence));

    lowerLightColor *= mix(0.86, 1.12, saturate1(skyLuma));
    upperLightColor *= mix(0.92, 1.08, saturate1(skyLuma));
    float brightnessScale = mix(0.70, 1.22, saturate1(brightness * 0.55));
    lowerLightColor *= brightnessScale;
    upperLightColor *= mix(brightnessScale, brightnessScale * 0.96, 0.5);

    float lowerAmbientWrap = (0.05 + 0.10 * horizonBand + horizonDensity * 0.05) * coverage;
    float upperAmbientWrap = (0.02 + 0.05 * (1.0 - horizonBand)) * coverage;
    float3 lowerColor = lowerLightColor
        + params.duskTint * lowerAmbientWrap * twilight * 0.25
        + hazeColor * lowerAmbientWrap;
    float3 upperColor = upperLightColor
        + params.antiSolarTint * upperAmbientWrap * params.skyCoolness * 0.18
        + hazeColor * upperAmbientWrap;

    float3 rimColor = mix(float3(1.0), warmCloudTint, 0.62 + 0.20 * twilight + 0.12 * lowSunWarmth);
    float rimStrength = silverLining * (0.72 + 0.28 * (1.0 - combinedDensity)) * mix(1.0, 0.72, overcastSignal);
    float layerSeparationLift = upperDominance * (0.05 + 0.08 * (1.0 - lowerDominance));

    float3 cloudColor = mix(lowerColor, upperColor, upperDominance * 0.42);
    cloudColor += rimColor * rimStrength;
    cloudColor += params.antiSolarTint * layerSeparationLift * params.skyCoolness * 0.22;

    float moonForward = pow(saturate1(dot(dir, normalize(params.moonDirection))), 5.5);
    float moonCloudLight = nightFactor * saturate1(params.moonIntensity * (0.18 + 0.38 * moonForward));
    float3 moonCloudColor = mix(float3(0.10, 0.14, 0.24), positive3(params.moonColor), 0.38) * (0.35 + 0.55 * combinedDensity);
    cloudColor = mix(cloudColor, moonCloudColor, moonCloudLight * mix(0.42, 0.72, coverage));

    float stormDarken = stormSignal * (0.18 + 0.24 * combinedDensity) + overcastSignal * 0.10;
    cloudColor *= mix(1.0, 0.68, saturate1(stormDarken));

    float hazeBlend = (1.0 - combinedTransmittance) * (0.10 + 0.12 * horizonBand);
    hazeBlend += smoothstep(0.52, 1.0, horizonCoord) * (0.08 + horizonDensity * 0.12 + overcastSignal * 0.10);
    cloudColor = mix(cloudColor, hazeColor, saturate1(hazeBlend));

    composite.sky = mix(composite.sky, cloudColor, combinedMask);
    return composite;
}

static inline CloudCompositeSample evaluateProceduralClouds(float3 dir,
                                                           float3 sunDir,
                                                           float cosTheta,
                                                           float horizonBand,
                                                           float sunForward,
                                                           float3 baseSky,
                                                           float3 baseSun,
                                                           float3 hazeColor,
                                                           constant SkyParams &params,
                                                           texture2d<float> cloudAtlasTexture) {
    if (kUseLegacyProceduralClouds) {
        return evaluateLegacyProceduralClouds(dir,
                                             sunDir,
                                             cosTheta,
                                             horizonBand,
                                             sunForward,
                                             baseSky,
                                             baseSun,
                                             hazeColor,
                                             params,
                                             cloudAtlasTexture);
    }

    CloudCompositeSample composite;
    composite.sky = baseSky;
    composite.sun = baseSun;

    float cloudsEnabled = (params.cloudsEnabled != 0) ? 1.0 : 0.0;
    float coverage = clamp(params.cloudsCoverage, 0.0, 1.0);
    float coverageVisibility = smoothstep(0.001, 0.04, coverage) * cloudsEnabled;
    if (coverageVisibility <= 0.0001) {
        return composite;
    }

    float softness = clamp(params.cloudsSoftness, 0.01, 1.0);
    float thickness = clamp(params.cloudsThickness, 0.08, 1.0);
    float brightness = max(params.cloudsBrightness, 0.0);
    float sunInfluence = max(params.cloudsSunInfluence, 0.0);
    float nightFactor = saturate1(params.nightFactor);
    float twilight = saturate1(params.twilightFactor);
    float horizonCoord = saturate1(1.0 - cosTheta);
    float overcastSignal = smoothstep(0.68, 0.90, coverage) * smoothstep(0.32, 0.72, thickness);
    float stormSignal = overcastSignal * saturate1((0.70 - brightness) * 1.35 + (0.58 - sunInfluence) * 0.85);
    float lowSunWarmth = saturate1((1.0 - params.dayNightFactor) * (1.0 - nightFactor) + twilight * 0.72);

    float2 wind = normalize(params.cloudsWindDirection + float2(0.0001, 0.0));
    float speed = params.cloudsSpeed;
    float layerHeight = mix(0.62, 1.16, clamp(params.cloudsHeight + thickness * 0.34, 0.0, 1.0));
    float viewLift = mix(0.20, 0.055, horizonBand);
    float rayDistance = layerHeight / max(dir.y + viewLift, 0.055);
    rayDistance = min(rayDistance, mix(34.0, 92.0, horizonBand));

    float baseScale = max(params.cloudsScale, 0.01);
    float2 layerCoord = dir.xz * rayDistance * (0.82 / baseScale);
    layerCoord += wind * params.skyTime * speed * 2.8;
    layerCoord += float2(params.skyTime * speed * 0.17, -params.skyTime * speed * 0.11);
    float2 flow = wind * params.skyTime * speed * (6.0 + 4.0 * thickness);

    PseudoVolumeCloudSample slab = sample_pseudo_volume_cloud_slab(layerCoord,
                                                                   flow,
                                                                   coverage,
                                                                   softness,
                                                                   thickness,
                                                                   overcastSignal,
                                                                   stormSignal);
    float horizonFade = smoothstep(-0.015, 0.09, dir.y) * mix(1.0, 0.82, smoothstep(0.72, 1.0, horizonCoord));
    float atlasEnabled = kUseTextureBackedCloudAtlas ? step(0.5, params.cloudAtlasEnabled) : 0.0;
    float atlasMacro = sample_cloud_atlas_macro_mask(layerCoord, wind, coverage, softness, horizonBand, params, cloudAtlasTexture);
    float proceduralDetail = mix(0.74, 1.18, slab.density) * mix(1.0, 0.82 + slab.edge * 0.34, atlasEnabled);
    float atlasDensity = saturate1(atlasMacro * proceduralDetail);
    float density = mix(slab.density, atlasDensity, atlasEnabled) * coverageVisibility * horizonFade;
    slab.height = mix(slab.height, saturate1(0.28 + atlasMacro * 0.46 + slab.height * 0.26), atlasEnabled);
    slab.edge = mix(slab.edge, saturate1(atlasMacro * (1.0 - atlasMacro) * 2.6 + slab.edge * 0.35), atlasEnabled);
    slab.topLight = mix(slab.topLight, saturate1(slab.topLight * 0.45 + atlasMacro * 0.55), atlasEnabled);
    slab.baseShadow = mix(slab.baseShadow, saturate1(slab.baseShadow * 0.55 + atlasMacro * (0.28 + stormSignal * 0.28)), atlasEnabled);
    float opticalDepth = density * mix(1.45, 3.85, thickness) * mix(1.0, 1.35, overcastSignal + stormSignal * 0.5);
    float opacity = saturate1(1.0 - exp(-opticalDepth));
    opacity *= mix(1.0, mix(0.46, 0.90, coverage), nightFactor);

    float densityAhead = pseudo_volume_cloud_density(float3(layerCoord + flow + sunDir.xz * (1.2 + thickness * 2.6),
                                                           saturate1(slab.height + 0.16)),
                                                     coverage,
                                                     softness,
                                                     thickness,
                                                     overcastSignal,
                                                     stormSignal);
    float densitySide = pseudo_volume_cloud_density(float3(layerCoord + flow + float2(1.4, -0.9), slab.height),
                                                    coverage,
                                                    softness,
                                                    thickness,
                                                    overcastSignal,
                                                    stormSignal);
    float gradientLight = saturate1((density - densityAhead) * 2.4 + 0.48 + slab.height * 0.32);
    float selfShadow = exp(-(densityAhead * 1.35 + slab.baseShadow * 1.10) * mix(0.9, 2.3, thickness));
    float topLight = saturate1(slab.height * 0.70 + slab.topLight * 0.62 + gradientLight * 0.42);
    float sideBreakup = saturate1(abs(density - densitySide) * 2.2 + slab.edge * 0.65);

    float phaseForward = pow(sunForward, mix(16.0, 5.2, softness));
    float silverLining = sideBreakup * phaseForward * sunInfluence * (0.34 + 0.58 * params.solarVisibility);
    silverLining *= (0.82 + lowSunWarmth * 0.36) * mix(1.0, 0.52, overcastSignal) * mix(1.0, 0.28, nightFactor);
    silverLining = min(silverLining, 0.78);

    float3 warmTint = mix(positive3(params.solarExtinctionTint), positive3(params.duskTint), saturate1(twilight * 0.40 + lowSunWarmth * 0.34));
    float3 shadowColor = mix(composite.sky, hazeColor, 0.20 + horizonBand * 0.30 + params.horizonDensity * 0.10);
    shadowColor *= mix(0.68, 0.42, stormSignal) * mix(1.0, 0.82, overcastSignal);
    float3 litColor = mix(shadowColor,
                          mix(float3(1.0), warmTint, 0.32 + twilight * 0.26 + lowSunWarmth * 0.16),
                          topLight * selfShadow * (0.42 + 0.36 * sunInfluence) * mix(1.0, 0.70, overcastSignal));

    float brightnessScale = mix(0.68, 1.20, saturate1(brightness * 0.55));
    float3 cloudColor = litColor * brightnessScale;
    cloudColor += warmTint * silverLining;
    cloudColor += hazeColor * coverage * (0.035 + horizonBand * 0.12 + overcastSignal * 0.08);

    float moonForward = pow(saturate1(dot(dir, normalize(params.moonDirection))), 5.5);
    float moonCloudLight = nightFactor * saturate1(params.moonIntensity * (0.16 + 0.42 * moonForward));
    float3 moonCloudColor = mix(float3(0.08, 0.12, 0.22), positive3(params.moonColor), 0.40) * (0.34 + 0.58 * density);
    cloudColor = mix(cloudColor, moonCloudColor, moonCloudLight * mix(0.38, 0.76, coverage));

    float stormDarken = stormSignal * (0.20 + 0.32 * density) + overcastSignal * 0.08;
    cloudColor *= mix(1.0, 0.62, saturate1(stormDarken));

    float hazeBlend = smoothstep(0.54, 1.0, horizonCoord) * (0.10 + params.horizonDensity * 0.14 + overcastSignal * 0.10);
    hazeBlend += (1.0 - exp(-opticalDepth)) * (0.035 + 0.09 * horizonBand);
    cloudColor = mix(cloudColor, hazeColor, saturate1(hazeBlend));

    float sunFilter = saturate1(1.0 - density * (0.36 + 0.34 * sunInfluence + 0.18 * overcastSignal));
    composite.sun *= mix(1.0, sunFilter, opacity * (0.36 + 0.28 * coverage));
    composite.sky = mix(composite.sky, cloudColor, opacity);
    return composite;
}

// Visible procedural sky and captured procedural sky intentionally share this
// same HDR radiance model so the camera background tracks the sky used for IBL.
static inline float3 evaluate_procedural_sky_radiance(float3 direction,
                                                      constant SkyParams &params,
                                                      texture2d<float> moonAlbedoTexture,
                                                      texture2d<float> galaxyTexture,
                                                      texture2d<float> cloudAtlasTexture) {
    float3 dir = normalize(direction);
    float3 sunDir = normalize(params.sunDirection);

    float cosTheta = saturate1(dir.y);
    float horizon = 1.0 - cosTheta;
    float horizonBand = smoothstep(0.02, 0.78, horizon);
    float sunForward = saturate1(dot(dir, sunDir));

    float3 hazeColor = float3(0.0);
    float3 sky = evaluateAtmosphereLayer(dir, sunDir, params, hazeColor);

    // Physically-inspired solar presentation: a compact HDR disk, a tight core,
    // and directional Mie aureole shared by the visible sky and procedural IBL capture.
    float3 sun = evaluateSunLayer(dir, sunDir, params);

    // Night/celestial layers are kept explicit so opaque bodies, background stars,
    // and glow contributions do not accidentally collapse into one additive pass.
    float nightFactor = params.nightFactor;
    if (nightFactor > 0.0001) {
        float3 moonDir = normalize(params.moonDirection);
        float moonCos = clamp(dot(dir, moonDir), -1.0, 1.0);
        float moonAngle = acos(moonCos);
        float moonRadius = max(params.moonAngularRadius, 0.0001);
        float moonIntensity = max(params.moonIntensity, 0.0);
        float aerosolDensity = saturate1(params.atmosphereScatteringParams.w);
        float horizonClarity = 1.0 - saturate1(aerosolDensity * 0.55 + params.horizonDensity * 0.26);

        MoonDiskLayerSample moonDisk = evaluateMoonDiskLayer(dir,
                                                             moonDir,
                                                             moonAngle,
                                                             moonRadius,
                                                             moonIntensity,
                                                             params,
                                                             moonAlbedoTexture);
        float3 moonGlow = evaluateMoonGlowLayer(moonDir,
                                                moonAngle,
                                                moonRadius,
                                                moonIntensity,
                                                horizonClarity,
                                                moonDisk.interior,
                                                params);

        if (kMoonTextureProofDiagnostic && moonDisk.textureEnabled > 0.5 && moonDisk.opacity > 0.001) {
            float3 proofAlbedo = raw_moon_albedo(moonDisk.uv, moonAlbedoTexture);
            return mix(float3(0.0), proofAlbedo * 3.0, moonDisk.opacity);
        }

        float3 nightBackground = evaluateNightBackgroundLayer(cosTheta,
                                                              moonCos,
                                                              moonIntensity,
                                                              horizonClarity,
                                                              params);
        sky = max(sky, nightBackground);

        sky += evaluateStarLayer(dir,
                                 moonAngle,
                                 moonRadius,
                                 moonIntensity,
                                 horizonClarity,
                                 moonDisk.celestialOcclusion,
                                 params);
        sky += evaluateGalaxyLayer(dir,
                                   moonDir,
                                   moonIntensity,
                                   horizonClarity,
                                   moonAngle,
                                   moonDisk.celestialOcclusion,
                                   params,
                                   galaxyTexture);
        sky = mix(sky, moonDisk.radiance, moonDisk.opacity);
        sky += moonGlow;
    }

    CloudCompositeSample clouds = evaluateProceduralClouds(dir,
                                                           sunDir,
                                                           cosTheta,
                                                           horizonBand,
                                                           sunForward,
                                                           sky,
                                                           sun,
                                                           hazeColor,
                                                           params,
                                                           cloudAtlasTexture);
    sky = clouds.sky;
    sun = clouds.sun;

    // Apply authored sky intensity once to the shared source radiance so the visible sky and
    // captured IBL stay matched without double-scaling the procedural sun contribution.
    return (sky + sun) * max(params.intensity, 0.0) * kProceduralSkyRadianceScale;
}

vertex VisibleProceduralSkyRasterizerData vertex_procedural_sky_visible(const SimpleVertex vert [[ stage_in ]],
                                                                        constant SceneConstants &sceneConstants [[ buffer(VertexBufferIndexSceneConstants) ]],
                                                                        constant ModelConstants &modelConstants [[ buffer(VertexBufferIndexModelConstants) ]]) {
    VisibleProceduralSkyRasterizerData rd;
    float4 clipPos = float4(vert.position.xy, 1.0, 1.0);
    rd.position = clipPos;

    float4 viewPos = sceneConstants.inverseProjectionMatrix * clipPos;
    float3 viewDir = normalize(viewPos.xyz / max(viewPos.w, 1e-6));
    float3x3 skyRotation = float3x3(
        sceneConstants.skyViewMatrix[0].xyz,
        sceneConstants.skyViewMatrix[1].xyz,
        sceneConstants.skyViewMatrix[2].xyz
    );
    float3x3 invSkyRotation = transpose(skyRotation);
    rd.direction = normalize(invSkyRotation * viewDir);
    return rd;
}

fragment float4 fragment_procedural_sky(CubemapRasterizerData rd [[ stage_in ]],
                                        constant SkyParams &params [[ buffer(FragmentBufferIndexSkyParams) ]],
                                        constant float &faceIndex [[ buffer(FragmentBufferIndexSkyFace) ]],
                                        texture2d<float> moonAlbedoTexture [[ texture(FragmentTextureIndexMoonAlbedo) ]],
                                        texture2d<float> galaxyTexture [[ texture(FragmentTextureIndexGalaxyBackground) ]],
                                        texture2d<float> cloudAtlasTexture [[ texture(FragmentTextureIndexCloudAtlas) ]]) {
    float2 uv = rd.localPosition.xy * float2(0.5, -0.5) + 0.5;
    float3 dir = cubeDirectionFromFaceUV(uint(faceIndex + 0.5), uv);
    return float4(evaluate_procedural_sky_radiance(dir, params, moonAlbedoTexture, galaxyTexture, cloudAtlasTexture), 1.0);
}

fragment float4 fragment_procedural_sky_visible(VisibleProceduralSkyRasterizerData rd [[ stage_in ]],
                                                constant SkyParams &params [[ buffer(FragmentBufferIndexSkyParams) ]],
                                                texture2d<float> moonAlbedoTexture [[ texture(FragmentTextureIndexMoonAlbedo) ]],
                                                texture2d<float> galaxyTexture [[ texture(FragmentTextureIndexGalaxyBackground) ]],
                                                texture2d<float> cloudAtlasTexture [[ texture(FragmentTextureIndexCloudAtlas) ]]) {
    return float4(evaluate_procedural_sky_radiance(rd.direction, params, moonAlbedoTexture, galaxyTexture, cloudAtlasTexture), 1.0);
}

fragment float4 fragment_procedural_sky_capture(VisibleProceduralSkyRasterizerData rd [[ stage_in ]],
                                                constant SkyParams &params [[ buffer(FragmentBufferIndexSkyParams) ]],
                                                texture2d<float> moonAlbedoTexture [[ texture(FragmentTextureIndexMoonAlbedo) ]],
                                                texture2d<float> galaxyTexture [[ texture(FragmentTextureIndexGalaxyBackground) ]],
                                                texture2d<float> cloudAtlasTexture [[ texture(FragmentTextureIndexCloudAtlas) ]]) {
    // Capture uses the same sky radiance seen by the camera so procedural IBL,
    // reflections, and the visible dome stay on the same brightness basis.
    return float4(evaluate_procedural_sky_radiance(rd.direction, params, moonAlbedoTexture, galaxyTexture, cloudAtlasTexture), 1.0);
}
