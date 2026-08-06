//
//  FinalShaders.metal
//  MetalCup
//
//  Created by Kaden Cringle on 1/21/26.
//

#include <metal_stdlib>
#include "Shared.metal"
using namespace metal;

// Shared fullscreen quad vertex entry point used by post/fullscreen passes.
vertex SimpleRasterizerData vertex_quad(const SimpleVertex vert [[ stage_in ]]) {
    SimpleRasterizerData rd;
    rd.position = float4(vert.position, 1.0);
    rd.texCoord = float2(vert.position.x, -vert.position.y) * 0.5 + 0.5;
    return rd;
}

static inline float3 tonemap_reinhard(float3 x) {
    return x / (x + 1.0);
}

static inline float3 tonemap_uncharted2(float3 x) {
    const float A = 0.15;
    const float B = 0.50;
    const float C = 0.10;
    const float D = 0.20;
    const float E = 0.02;
    const float F = 0.30;
    return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F;
}

static inline float3 tonemap_hazel(float3 x) {
    const float exposureBias = 2.0;
    float3 color = tonemap_uncharted2(x * exposureBias);
    float3 whiteScale = 1.0 / tonemap_uncharted2(float3(11.2));
    return color * whiteScale;
}

static inline float3x3 agxInsetMatrix() {
    return float3x3(
        float3(0.842479062253094, 0.0784335999999992, 0.0792237451477643),
        float3(0.0423282422610123, 0.878468636469772, 0.0791661274605434),
        float3(0.0423756549057051, 0.0784336, 0.879142973793104)
    );
}

static inline float3x3 agxOutsetMatrix() {
    return float3x3(
        float3(1.19687900512017, -0.0980208811401368, -0.0990297440797205),
        float3(-0.0528968517574562, 1.15190312990417, -0.0989611768448433),
        float3(-0.0529716355144438, -0.0980434501171241, 1.15107367264116)
    );
}

static inline float3 agxContrastApprox(float3 x) {
    float3 x2 = x * x;
    float3 x4 = x2 * x2;
    return 15.5 * x4 * x2
         - 40.14 * x4 * x
         + 31.96 * x4
         - 6.868 * x2 * x
         + 0.4298 * x2
         + 0.1191 * x
         - 0.00232;
}

static inline float3 tonemap_agx(float3 color) {
    const float minEv = -12.47393;
    const float maxEv = 4.026069;

    color = agxInsetMatrix() * max(color, 0.0);
    color = clamp((log2(max(color, 1e-6)) - minEv) / (maxEv - minEv), 0.0, 1.0);
    color = agxContrastApprox(color);
    color = agxOutsetMatrix() * color;
    return max(color, 0.0);
}

// Renderer-calibrated filmic default: keeps the softer Hable-style rolloff,
// but restores more chroma at moderate highlight intensities than the AgX path.
static inline float3 tonemap_filmic_default(float3 color) {
    float3 base = tonemap_uncharted2(max(color, 0.0));
    float3 whiteScale = 1.0 / tonemap_uncharted2(float3(16.0));
    base *= whiteScale;

    float inputLuminance = dot(max(color, 0.0), float3(0.2126, 0.7152, 0.0722));
    float outputLuminance = dot(max(base, 0.0), float3(0.2126, 0.7152, 0.0722));
    float3 chromaPreserved = (inputLuminance > 1e-6)
        ? max(color, 0.0) * (outputLuminance / inputLuminance)
        : base;

    float highlight = smoothstep(1.5, 24.0, inputLuminance);
    float preserveAmount = mix(0.82, 0.28, highlight);
    return max(mix(base, chromaPreserved, preserveAmount), 0.0);
}

static inline float srgb_encode_channel(float x) {
    return (x <= 0.0031308) ? (12.92 * x) : (1.055 * pow(x, 1.0 / 2.4) - 0.055);
}

static inline float3 linear_to_srgb(float3 color) {
    color = max(color, 0.0);
    return float3(
        srgb_encode_channel(color.r),
        srgb_encode_channel(color.g),
        srgb_encode_channel(color.b)
    );
}

static inline float luminance(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

static inline float highlight_signal(float3 color) {
    float l = luminance(color);
    float peak = max(color.r, max(color.g, color.b));

    // Hybrid threshold source: keep luminance as the base signal, but let
    // saturated peaks contribute more naturally than pure luminance would.
    return mix(l, peak, 0.35);
}

// Soft threshold (filmic-ish) to avoid harsh cutoff.
// threshold: point where bloom starts
// knee: softness range (0..threshold)
static inline float3 soft_threshold(float3 color, float threshold, float knee) {
    float signal = highlight_signal(max(color, 0.0));
    float t = threshold;
    float k = max(t * knee, 1e-6);

    // Soft knee curve:
    // https://catlikecoding.com/unity/tutorials/advanced-rendering/bloom/
    float soft = clamp((signal - t + k) / (2.0 * k), 0.0, 1.0);
    float contrib = max(signal - t, 0.0) + soft * soft * k;

    // Scale original HDR color by the threshold contribution so hue is preserved
    // while saturated peaks are not underrepresented by luminance alone.
    return (signal > 1e-6) ? (max(color, 0.0) * (contrib / signal)) : float3(0.0);
}

static inline float3 dualTent13(texture2d<float> tex, sampler s, float2 uv, float2 texel, float mipLevel) {
    float3 c = float3(0.0);
    c += tex.sample(s, uv, level(mipLevel)).rgb * 0.125;
    c += tex.sample(s, uv + texel * float2(1.0, 0.0), level(mipLevel)).rgb * 0.0625;
    c += tex.sample(s, uv + texel * float2(-1.0, 0.0), level(mipLevel)).rgb * 0.0625;
    c += tex.sample(s, uv + texel * float2(0.0, 1.0), level(mipLevel)).rgb * 0.0625;
    c += tex.sample(s, uv + texel * float2(0.0, -1.0), level(mipLevel)).rgb * 0.0625;
    c += tex.sample(s, uv + texel * float2(1.0, 1.0), level(mipLevel)).rgb * 0.125;
    c += tex.sample(s, uv + texel * float2(-1.0, 1.0), level(mipLevel)).rgb * 0.125;
    c += tex.sample(s, uv + texel * float2(1.0, -1.0), level(mipLevel)).rgb * 0.125;
    c += tex.sample(s, uv + texel * float2(-1.0, -1.0), level(mipLevel)).rgb * 0.125;
    c += tex.sample(s, uv + texel * float2(2.0, 0.0), level(mipLevel)).rgb * 0.03125;
    c += tex.sample(s, uv + texel * float2(-2.0, 0.0), level(mipLevel)).rgb * 0.03125;
    c += tex.sample(s, uv + texel * float2(0.0, 2.0), level(mipLevel)).rgb * 0.03125;
    c += tex.sample(s, uv + texel * float2(0.0, -2.0), level(mipLevel)).rgb * 0.03125;
    return c;
}

static inline float3 dualUpsampleTent9(texture2d<float> tex, sampler s, float2 uv, float2 texel, float mipLevel) {
    float3 c = float3(0.0);
    c += tex.sample(s, uv, level(mipLevel)).rgb * 4.0;
    c += tex.sample(s, uv + texel * float2(1.0, 0.0), level(mipLevel)).rgb * 2.0;
    c += tex.sample(s, uv + texel * float2(-1.0, 0.0), level(mipLevel)).rgb * 2.0;
    c += tex.sample(s, uv + texel * float2(0.0, 1.0), level(mipLevel)).rgb * 2.0;
    c += tex.sample(s, uv + texel * float2(0.0, -1.0), level(mipLevel)).rgb * 2.0;
    c += tex.sample(s, uv + texel * float2(1.0, 1.0), level(mipLevel)).rgb;
    c += tex.sample(s, uv + texel * float2(-1.0, 1.0), level(mipLevel)).rgb;
    c += tex.sample(s, uv + texel * float2(1.0, -1.0), level(mipLevel)).rgb;
    c += tex.sample(s, uv + texel * float2(-1.0, -1.0), level(mipLevel)).rgb;
    return c / 16.0;
}

static inline float bloom_upsample_weight(float highMip, float highLum, float lowLum, uint maxMips) {
    float mipSpan = max(float(maxMips) - 1.0, 1.0);
    float mipProgress = saturate((highMip + 1.0) / mipSpan);

    float totalLum = max(highLum + lowLum, 1e-5);
    float lowShare = saturate(lowLum / totalLum);

    float radiusBlend = mix(0.36, 0.68, mipProgress);
    float detailPreservation = 1.0 - 0.45 * smoothstep(0.22, 0.9, lowShare);
    return radiusBlend * detailPreservation;
}

static inline float2 ssao_project_view_position_to_uv(float3 viewPosition,
                                                      constant SceneConstants &sceneConstants) {
    float4 clipPosition = sceneConstants.projectionMatrix * float4(viewPosition, 1.0);
    float safeW = (fabs(clipPosition.w) > 1e-6) ? clipPosition.w : 1.0;
    float2 ndc = clipPosition.xy / safeW;
    return float2(ndc.x * 0.5 + 0.5, 1.0 - (ndc.y * 0.5 + 0.5));
}

static inline void ssao_build_basis(float3 normal,
                                    thread float3 &tangent,
                                    thread float3 &bitangent) {
    float3 up = (fabs(normal.z) < 0.999) ? float3(0.0, 0.0, 1.0) : float3(0.0, 1.0, 0.0);
    tangent = normalize(cross(up, normal));
    bitangent = normalize(cross(normal, tangent));
}

static inline uint2 ssao_pixel_from_uv(float2 uv, texture2d<float> texture) {
    float2 textureSize = float2(texture.get_width(), texture.get_height());
    float2 scaled = clamp(uv, 0.0, 0.999999) * textureSize;
    return uint2(min(uint(scaled.x), texture.get_width() - 1),
                 min(uint(scaled.y), texture.get_height() - 1));
}

static inline float ssao_sample_depth_nearest(texture2d<float> depthTexture,
                                              float2 uv) {
    return depthTexture.read(ssao_pixel_from_uv(uv, depthTexture)).r;
}

static inline float3 ssao_sample_normal_nearest(texture2d<float> normalTexture,
                                                float2 uv) {
    float2 encodedNormal = normalTexture.read(ssao_pixel_from_uv(uv, normalTexture)).rg;
    return decodeOctahedralNormal(encodedNormal);
}

static inline float ao_cross_bilateral_weight(float2 sampleUV,
                                                float centerLinearDepth,
                                                float3 centerViewNormal,
                                                float blurSharpness,
                                                texture2d<float> depthTexture,
                                                texture2d<float> normalTexture,
                                                sampler s,
                                                constant SceneConstants &sceneConstants) {
    if (any(sampleUV < 0.0) || any(sampleUV > 1.0)) {
        return 0.0;
    }

    float sampleRawDepth = sampleSceneDepth(depthTexture, s, sampleUV);
    if (sampleRawDepth >= 0.999999) {
        return 0.0;
    }

    float sampleLinearDepth = linearDepthFromRawDepth(sampleUV, sampleRawDepth, sceneConstants);
    float relativeDepthDelta = abs(sampleLinearDepth - centerLinearDepth) / max(centerLinearDepth, 1e-3);
    float depthWeight = exp(-relativeDepthDelta * max(blurSharpness, 1.0));

    float3 sampleViewNormal = sampleSceneNormal(normalTexture, s, sampleUV);
    float normalSimilarity = saturate(dot(centerViewNormal, sampleViewNormal));
    float normalWeight = pow(normalSimilarity, 24.0);
    return depthWeight * normalWeight;
}

// AO textures store visibility: 1.0 = unoccluded, 0.0 = fully occluded.
static inline float ao_cross_bilateral_blur(float2 uv,
                                            float2 axisStep,
                                            float blurSharpness,
                                            texture2d<float> aoTexture,
                                            texture2d<float> depthTexture,
                                            texture2d<float> normalTexture,
                                            sampler s,
                                            constant SceneConstants &sceneConstants) {
    float centerRawDepth = sampleSceneDepth(depthTexture, s, uv);
    if (centerRawDepth >= 0.999999) {
        return 1.0;
    }

    float centerLinearDepth = linearDepthFromRawDepth(uv, centerRawDepth, sceneConstants);
    float3 centerViewNormal = sampleSceneNormal(normalTexture, s, uv);

    constexpr uint kRadiusTaps = 3;
    const float kernelWeights[kRadiusTaps + 1] = { 0.38, 0.2, 0.07, 0.015 };

    float centerVisibility = aoTexture.sample(s, uv).r;
    float weightedVisibility = centerVisibility * kernelWeights[0];
    float totalWeight = kernelWeights[0];

    for (uint tapIndex = 1; tapIndex <= kRadiusTaps; ++tapIndex) {
        float2 offset = axisStep * float(tapIndex);
        float2 sampleUV0 = uv + offset;
        float2 sampleUV1 = uv - offset;
        float kernelWeight = kernelWeights[tapIndex];

        float bilateralWeight0 = kernelWeight * ao_cross_bilateral_weight(
            sampleUV0,
            centerLinearDepth,
            centerViewNormal,
            blurSharpness,
            depthTexture,
            normalTexture,
            s,
            sceneConstants
        );
        float bilateralWeight1 = kernelWeight * ao_cross_bilateral_weight(
            sampleUV1,
            centerLinearDepth,
            centerViewNormal,
            blurSharpness,
            depthTexture,
            normalTexture,
            s,
            sceneConstants
        );

        if (bilateralWeight0 > 0.0) {
            weightedVisibility += aoTexture.sample(s, sampleUV0).r * bilateralWeight0;
            totalWeight += bilateralWeight0;
        }
        if (bilateralWeight1 > 0.0) {
            weightedVisibility += aoTexture.sample(s, sampleUV1).r * bilateralWeight1;
            totalWeight += bilateralWeight1;
        }
    }

    return (totalWeight > 1e-5) ? (weightedVisibility / totalWeight) : centerVisibility;
}

// Integrates an exponential height-density field along a world-space view ray segment.
// Density profile: density * exp(-falloff * (worldY - baseHeight)).
static inline float heightFogOpticalDepth(float3 cameraPosition,
                                          float3 rayDirection,
                                          float segmentStart,
                                          float segmentEnd,
                                          constant RendererSettings &settings) {
    float density = max(settings.heightFogDensity, 0.0) * max(settings.aerialFogParams.y, 0.0);
    float falloff = max(settings.heightFogHeightFalloff, 0.0);
    if (density <= 0.0 || segmentEnd <= segmentStart) {
        return 0.0;
    }

    float baseHeight = settings.heightFogBaseHeight;
    float rayY = rayDirection.y;
    float startY = cameraPosition.y + rayY * segmentStart;
    float segmentLength = segmentEnd - segmentStart;

    if (falloff <= 1e-5 || fabs(rayY) <= 1e-5) {
        float referenceHeight = startY - baseHeight;
        float uniformDensity = density * exp(-falloff * referenceHeight);
        return uniformDensity * segmentLength;
    }

    float cameraTerm = density * exp(-falloff * (cameraPosition.y - baseHeight));
    float startExp = exp(-falloff * rayY * segmentStart);
    float endExp = exp(-falloff * rayY * segmentEnd);
    float denominator = falloff * rayY;
    return cameraTerm * (startExp - endExp) / denominator;
}

static inline float2 evaluateHeightFogTransmittance(float2 uv,
                                                    texture2d<float> depthTexture,
                                                    sampler s,
                                                    constant RendererSettings &settings,
                                                    constant SceneConstants &sceneConstants) {
    if (settings.heightFogEnabled == 0u) {
        return float2(1.0, 0.0);
    }

    float rawDepth = sampleSceneDepth(depthTexture, s, uv);
    if (rawDepth >= 0.999999) {
        return float2(1.0, 0.0);
    }

    float3 worldPosition = reconstructWorldPosition(uv, rawDepth, sceneConstants);
    float3 cameraPosition = sceneConstants.cameraPositionAndIBL.xyz;
    float3 cameraToSurface = worldPosition - cameraPosition;
    float rayDistance = length(cameraToSurface);
    if (rayDistance <= 1e-5) {
        return float2(1.0, 0.0);
    }

    float segmentStart = max(settings.heightFogStartDistance, 0.0);
    if (rayDistance <= segmentStart) {
        return float2(1.0, 0.0);
    }

    float3 rayDirection = cameraToSurface / rayDistance;
    float heightOpticalDepth = heightFogOpticalDepth(
        cameraPosition,
        rayDirection,
        segmentStart,
        rayDistance,
        settings
    );

    float distanceDensity = max(settings.heightFogDistanceDensity, 0.0);
    float distanceOpticalDepth = distanceDensity * (rayDistance - segmentStart);
    float opticalDepth = max(heightOpticalDepth + distanceOpticalDepth, 0.0);
    float transmittance = exp(-opticalDepth);
    float fogFactor = 1.0 - transmittance;
    return float2(transmittance, fogFactor);
}

static inline float3 backgroundFogRayDirection(float2 uv,
                                                  constant SceneConstants &sceneConstants) {
    float4 farClip = float4(uv * 2.0 - 1.0, 0.999999, 1.0);
    farClip.y *= -1.0;
    float4 farWorld = sceneConstants.inverseViewProjectionMatrix * farClip;
    float safeW = (fabs(farWorld.w) > 1e-6) ? farWorld.w : 1.0;
    float3 cameraPosition = sceneConstants.cameraPositionAndIBL.xyz;
    float3 farWorldPosition = farWorld.xyz / safeW;
    float3 rayDirection = normalize(farWorldPosition - cameraPosition);
    if (any(!isfinite(rayDirection))) {
        return float3(0.0, 0.0, -1.0);
    }
    return rayDirection;
}

static inline float backgroundFogHorizonWeight(float3 rayDirection) {
    return pow(clamp(1.0 - max(rayDirection.y, 0.0), 0.0, 1.0), 1.5);
}

static inline float2 evaluateBackgroundHeightFogTransmittance(float2 uv,
                                                              constant RendererSettings &settings,
                                                              constant SceneConstants &sceneConstants) {
    if (settings.heightFogEnabled == 0u) {
        return float2(1.0, 0.0);
    }

    float3 cameraPosition = sceneConstants.cameraPositionAndIBL.xyz;
    float3 rayDirection = backgroundFogRayDirection(uv, sceneConstants);
    float segmentStart = max(settings.heightFogStartDistance, 0.0);

    // Background fog should read like aerial perspective: dense and hazy at the horizon,
    // but much less destructive toward the zenith so sky gradients and cloud structure survive.
    float horizonWeight = backgroundFogHorizonWeight(rayDirection);
    float maxAerialDistance = max(settings.aerialFogParams.w, 1.0);
    float segmentEnd = max(segmentStart + 1.0, mix(maxAerialDistance * 0.22, maxAerialDistance, horizonWeight));

    float heightOpticalDepth = heightFogOpticalDepth(
        cameraPosition,
        rayDirection,
        segmentStart,
        segmentEnd,
        settings
    );
    float distanceDensity = max(settings.heightFogDistanceDensity, 0.0);
    float distanceOpticalDepth = distanceDensity * (segmentEnd - segmentStart);
    float opticalDepth = max(heightOpticalDepth + distanceOpticalDepth, 0.0);
    float transmittance = exp(-opticalDepth);
    float baseFogFactor = 1.0 - transmittance;

    float zenithWeight = clamp(max(rayDirection.y, 0.0), 0.0, 1.0);
    float directionalFog = baseFogFactor * mix(0.18, 1.0, horizonWeight);
    directionalFog *= mix(1.0, 0.55, zenithWeight);
    directionalFog = min(directionalFog, mix(0.35, 0.94, horizonWeight));
    return float2(1.0 - directionalFog, directionalFog);
}

static inline float3 resolvedHeightFogColor(constant RendererSettings &settings) {
    uint colorMode = uint(max(settings.heightFogPadding.x, 0.0));
    if (colorMode == 1u) {
        return max(settings.padding0.xyz, 0.0);
    }
    return max(settings.heightFogColor, 0.0);
}

static inline float3 resolvedHeightFogHorizonColor(constant RendererSettings &settings) {
    uint colorMode = uint(max(settings.heightFogPadding.x, 0.0));
    if (colorMode == 1u) {
        return max(settings.padding1.xyz, 0.0);
    }
    return max(settings.heightFogColor, 0.0);
}

static inline float resolvedHeightFogSunScatterStrength(constant RendererSettings &settings) {
    uint colorMode = uint(max(settings.heightFogPadding.x, 0.0));
    return (colorMode == 1u) ? clamp(settings.padding1.w, 0.0, 1.0) : 0.0;
}

static inline float3 resolvedAerialFogSunDirection(constant RendererSettings &settings) {
    float3 sunDirection = settings.aerialFogSunDirectionAndNight.xyz;
    if (dot(sunDirection, sunDirection) <= 1e-5) {
        return float3(0.0, 1.0, 0.0);
    }
    return normalize(sunDirection);
}

static inline float aerialFogHGPhase(float cosTheta, float g) {
    float gg = g * g;
    float denom = max(1.0 + gg - 2.0 * g * cosTheta, 0.045);
    return (1.0 - gg) / pow(denom, 1.5);
}

static inline float3 aerialFogInscatterColor(float3 rayDirection,
                                             float horizonWeight,
                                             constant RendererSettings &settings) {
    float3 bodyColor = resolvedHeightFogColor(settings);
    float3 horizonColor = resolvedHeightFogHorizonColor(settings);
    float3 sunColor = max(settings.aerialFogSunColorAndStrength.xyz, 0.0);
    float3 sunDirection = resolvedAerialFogSunDirection(settings);
    float sunCos = clamp(dot(rayDirection, sunDirection), -1.0, 1.0);
    float forwardStrength = max(settings.aerialFogSunColorAndStrength.w, 0.0);
    float legacyForward = resolvedHeightFogSunScatterStrength(settings);
    float g = clamp(settings.aerialFogParams.z, 0.0, 0.95);
    float hgForward = aerialFogHGPhase(sunCos, g) * 0.035;
    float forwardLobe = pow(saturate(sunCos), mix(14.0, 5.0, forwardStrength));
    float sunScatter = (hgForward + forwardLobe) * (forwardStrength + legacyForward * 0.45);

    float sunBelowHorizon = saturate((-sunDirection.y - 0.05) / 0.35);
    float nightScale = clamp(settings.aerialFogSunDirectionAndNight.w, 0.0, 1.0);
    float inscatteringStrength = max(settings.aerialFogParams.x, 0.0);
    float3 ambientAerial = mix(bodyColor, horizonColor, saturate(horizonWeight * (0.62 + 0.24 * forwardStrength)));
    ambientAerial *= mix(1.0, nightScale, sunBelowHorizon);
    float3 directionalAerial = sunColor * sunScatter * (0.35 + 0.65 * horizonWeight);
    return max((ambientAerial + directionalAerial) * inscatteringStrength, 0.0);
}

static inline float3 objectFogRayDirection(float2 uv,
                                           texture2d<float> depthTexture,
                                           sampler s,
                                           constant SceneConstants &sceneConstants) {
    float rawDepth = sampleSceneDepth(depthTexture, s, uv);
    float3 worldPosition = reconstructWorldPosition(uv, rawDepth, sceneConstants);
    float3 cameraPosition = sceneConstants.cameraPositionAndIBL.xyz;
    float3 ray = worldPosition - cameraPosition;
    if (dot(ray, ray) <= 1e-8) {
        return float3(0.0, 0.0, -1.0);
    }
    return normalize(ray);
}

static inline float3 applyHeightFog(float3 sceneColor,
                                    float2 uv,
                                    texture2d<float> depthTexture,
                                    sampler s,
                                    constant RendererSettings &settings,
                                    constant SceneConstants &sceneConstants) {
    float2 fog = evaluateHeightFogTransmittance(uv, depthTexture, s, settings, sceneConstants);
    float transmittance = fog.x;
    float fogFactor = fog.y;
    float3 rayDirection = objectFogRayDirection(uv, depthTexture, s, sceneConstants);
    float horizonWeight = backgroundFogHorizonWeight(rayDirection);
    float3 inscatter = aerialFogInscatterColor(rayDirection, horizonWeight, settings);
    return sceneColor * transmittance + inscatter * fogFactor;
}

static inline float3 applyBackgroundHeightFog(float3 sceneColor,
                                              float2 uv,
                                              constant RendererSettings &settings,
                                              constant SceneConstants &sceneConstants) {
    float2 fog = evaluateBackgroundHeightFogTransmittance(uv, settings, sceneConstants);
    float fogFactor = fog.y;
    float3 rayDirection = backgroundFogRayDirection(uv, sceneConstants);
    float horizonWeight = backgroundFogHorizonWeight(rayDirection);
    float zenithWeight = clamp(max(rayDirection.y, 0.0), 0.0, 1.0);
    float skyFogFactor = fogFactor * mix(0.28, 0.86, horizonWeight) * mix(1.0, 0.42, zenithWeight);
    float3 inscatter = aerialFogInscatterColor(rayDirection, horizonWeight, settings);
    return sceneColor * (1.0 - skyFogFactor) + inscatter * skyFogFactor;
}

vertex SimpleRasterizerData vertex_final(const SimpleVertex vert [[ stage_in ]]) {
    SimpleRasterizerData rd;
    rd.position = float4(vert.position, 1.0);
    rd.texCoord = float2(vert.position.x, -vert.position.y) * 0.5 + 0.5;
    return rd;
}

fragment float4 fragment_height_fog(const SimpleRasterizerData rd [[ stage_in ]],
                                  constant RendererSettings &settings [[ buffer(FragmentBufferIndexRendererSettings) ]],
                                  constant SceneConstants &sceneConstants [[ buffer(FragmentBufferIndexPostProcessSceneConstants) ]],
                                  texture2d<float> renderTexture [[ texture(PostProcessTextureIndexSource) ]],
                                  texture2d<float> depthTexture [[ texture(PostProcessTextureIndexDepth) ]],
                                  sampler s [[ sampler(FragmentSamplerIndexLinearClamp) ]]) {
    float2 uv = rd.texCoord;
    if (settings.uvDebug.x != 0) {
        return float4(uv, 0.0, 1.0);
    }

    float3 sceneColor = max(renderTexture.sample(s, uv).rgb, 0.0);
    float rawDepth = sampleSceneDepth(depthTexture, s, uv);
    float3 foggedColor = (rawDepth >= 0.999999)
        ? applyBackgroundHeightFog(sceneColor, uv, settings, sceneConstants)
        : applyHeightFog(sceneColor, uv, depthTexture, s, settings, sceneConstants);
    return float4(foggedColor, 1.0);
}

fragment float4 fragment_bloom_extract(const SimpleRasterizerData rd [[ stage_in ]],
                                       constant RendererSettings &settings [[ buffer(FragmentBufferIndexRendererSettings) ]],
                                       texture2d<float> renderTexture [[ texture(PostProcessTextureIndexSource) ]],
                                       sampler s [[ sampler(FragmentSamplerIndexLinearClamp) ]]) {
    float2 uv = rd.texCoord;
    if (settings.uvDebug.x != 0) {
        return float4(uv, 0.0, 1.0);
    }
    float2 sourceTexel = float2(1.0 / float(renderTexture.get_width()), 1.0 / float(renderTexture.get_height()));
    float3 scene = dualTent13(renderTexture, s, uv, sourceTexel, 0.0);
    float3 bloom = soft_threshold(scene, settings.bloomThreshold, settings.bloomKnee);
    return float4(bloom, 1.0);
}

fragment float4 fragment_auto_exposure_extract(const SimpleRasterizerData rd [[ stage_in ]],
                                               constant RendererSettings &settings [[ buffer(FragmentBufferIndexRendererSettings) ]],
                                               texture2d<float> renderTexture [[ texture(PostProcessTextureIndexSource) ]],
                                               sampler s [[ sampler(FragmentSamplerIndexLinearClamp) ]]) {
    float2 uv = rd.texCoord;
    if (settings.uvDebug.x != 0) {
        return float4(uv, 0.0, 1.0);
    }
    float3 scene = max(renderTexture.sample(s, uv).rgb, 0.0);
    float sceneLuminance = max(luminance(scene), 1e-4);
    float logLuminance = log2(sceneLuminance);
    return float4(logLuminance, logLuminance, logLuminance, 1.0);
}

fragment float4 fragment_bloom_downsample(const SimpleRasterizerData rd [[ stage_in ]],
                                          constant RendererSettings &settings [[ buffer(FragmentBufferIndexRendererSettings) ]],
                                          texture2d<float> renderTexture [[ texture(PostProcessTextureIndexSource) ]],
                                          sampler s [[ sampler(FragmentSamplerIndexLinearClamp) ]]) {
    float2 uv = rd.texCoord;
    if (settings.uvDebug.x != 0) {
        return float4(uv, 0.0, 1.0);
    }
    float mip = settings.bloomMipLevel;
    uint level = uint(max(mip, 0.0));
    float2 texel = float2(
        1.0 / float(renderTexture.get_width(level)),
        1.0 / float(renderTexture.get_height(level))
    );
    float3 result = dualTent13(renderTexture, s, uv, texel, mip);
    return float4(result, 1.0);
}

fragment float4 fragment_blur_h(const SimpleRasterizerData rd [[ stage_in ]],
                                constant RendererSettings &settings [[ buffer(FragmentBufferIndexRendererSettings) ]],
                                texture2d<float> renderTexture [[ texture(PostProcessTextureIndexSource) ]],
                                texture2d<float> bloomTexture [[ texture(PostProcessTextureIndexBloom) ]],
                                sampler s [[ sampler(FragmentSamplerIndexLinearClamp) ]]) {
    float2 uv = rd.texCoord;
    if (settings.uvDebug.x != 0) {
        return float4(uv, 0.0, 1.0);
    }

    float highMip = settings.bloomMipLevel;
    uint highLevel = uint(max(highMip, 0.0));
    uint lowLevel = highLevel + 1u;

    float2 lowTexel = float2(
        1.0 / float(bloomTexture.get_width(lowLevel)),
        1.0 / float(bloomTexture.get_height(lowLevel))
    );

    float3 high = max(renderTexture.sample(s, uv, level(highMip)).rgb, 0.0);
    float3 low = max(dualUpsampleTent9(bloomTexture, s, uv, lowTexel, float(lowLevel)), 0.0);

    float highLum = luminance(high);
    float lowLum = luminance(low);
    float upsampleWeight = bloom_upsample_weight(highMip, highLum, lowLum, settings.bloomMaxMips);

    float3 combined = high + low * upsampleWeight;
    return float4(max(combined, 0.0), 1.0);
}

fragment float4 fragment_blur_v(const SimpleRasterizerData rd [[ stage_in ]],
                                constant RendererSettings &settings [[ buffer(FragmentBufferIndexRendererSettings) ]],
                                texture2d<float> renderTexture [[ texture(PostProcessTextureIndexSource) ]],
                                sampler s [[ sampler(FragmentSamplerIndexLinearClamp) ]]) {
    float2 uv = rd.texCoord;
    if (settings.uvDebug.x != 0) {
        return float4(uv, 0.0, 1.0);
    }
    return float4(renderTexture.sample(s, uv, level(settings.bloomMipLevel)).rgb, 1.0);
}

fragment float4 fragment_outline_mask(const SimpleRasterizerData rd [[ stage_in ]],
                                      constant OutlineParams &params [[ buffer(FragmentBufferIndexOutlineParams) ]],
                                      texture2d<uint, access::read> pickIdTexture [[ texture(PostProcessTextureIndexSource) ]]) {
    if (params.selectedId == 0) {
        return float4(0.0);
    }
    int width = pickIdTexture.get_width();
    int height = pickIdTexture.get_height();
    float2 uv = rd.texCoord;
    int2 basePixel = int2(uv * float2(width, height));
    basePixel.x = clamp(basePixel.x, 0, width - 1);
    basePixel.y = clamp(basePixel.y, 0, height - 1);
    uint center = pickIdTexture.read(uint2(basePixel)).r;
    bool isSelectedCenter = (center == params.selectedId);
    int thickness = clamp((int)params.thickness, 1, 4);
    bool edge = false;

    for (int i = 1; i <= thickness && !edge; ++i) {
        int2 offsets[4] = { int2(i, 0), int2(-i, 0), int2(0, i), int2(0, -i) };
        for (int j = 0; j < 4; ++j) {
            int2 p = basePixel + offsets[j];
            p.x = clamp(p.x, 0, width - 1);
            p.y = clamp(p.y, 0, height - 1);
            uint neighbor = pickIdTexture.read(uint2(p)).r;
            if (isSelectedCenter) {
                if (neighbor != center) { edge = true; break; }
            } else {
                if (neighbor == params.selectedId) { edge = true; break; }
            }
        }
    }

    float mask = edge ? 1.0 : 0.0;
    return float4(mask, 0.0, 0.0, 1.0);
}

static inline float gridLine(float2 coord) {
    float2 grid = abs(fract(coord - 0.5) - 0.5);
    float2 deriv = max(fwidth(coord), float2(1e-5));
    float2 line = grid / (deriv * 3.5);
    return 1.0 - min(min(line.x, line.y), 1.0);
}

static inline float axisLine(float coord) {
    float width = max(fwidth(coord), 1e-5) * 5.0;
    return 1.0 - smoothstep(0.0, width, abs(coord));
}

fragment float4 fragment_grid(const SimpleRasterizerData rd [[ stage_in ]],
                              constant RendererSettings &settings [[ buffer(FragmentBufferIndexRendererSettings) ]],
                              constant GridParams &gridParams [[ buffer(FragmentBufferIndexGridParams) ]],
                              texture2d<float> depthTexture [[ texture(PostProcessTextureIndexDepth) ]],
                              sampler s [[ sampler(FragmentSamplerIndexLinearClamp) ]]) {
    float2 uv = rd.texCoord;
    if (settings.uvDebug.x != 0) {
        return float4(uv, 0.0, 1.0);
    }
    float2 ndc = float2(uv.x, 1.0 - uv.y) * 2.0 - 1.0;

    float3 rayOrigin = gridParams.cameraPosition;
    float4 worldNear = gridParams.inverseViewProjection * float4(ndc, 0.0, 1.0);
    worldNear /= max(worldNear.w, 1e-5);
    float4 worldFar = gridParams.inverseViewProjection * float4(ndc, 1.0, 1.0);
    worldFar /= max(worldFar.w, 1e-5);
    float3 rayDir = normalize(worldFar.xyz - worldNear.xyz);

    if (fabs(rayDir.y) < 1e-4) {
        return float4(0.0);
    }

    float t = -rayOrigin.y / rayDir.y;
    if (t <= 0.0) {
        return float4(0.0);
    }
    float3 worldPos = rayOrigin + rayDir * t;

    float depthSample = depthTexture.sample(s, uv).r;
    if (depthSample < 0.9999) {
        float ndcZ = depthSample;
        float4 sceneClip = float4(ndc, ndcZ, 1.0);
        float4 sceneWorld = gridParams.inverseViewProjection * sceneClip;
        sceneWorld /= max(sceneWorld.w, 1e-5);
        float sceneDist = length(sceneWorld.xyz - rayOrigin);
        float gridDist = length(worldPos - rayOrigin);
        float heightOffset = sceneWorld.y - worldPos.y;
        if (sceneDist < gridDist - 0.05 && heightOffset > 0.01) {
            return float4(0.0);
        }
    }

    float majorStep = max(settings.gridMajorLineEvery, 1.0);
    float minorLine = gridLine(worldPos.xz);
    float majorLine = gridLine(worldPos.xz / majorStep);
    float axisX = axisLine(worldPos.x);
    float axisZ = axisLine(worldPos.z);

    float dist = length(worldPos.xz - rayOrigin.xz);
    float fade = 1.0 - saturate(dist / max(settings.gridFadeDistance, 1.0));
    fade = pow(fade, 1.1);
    float viewDot = abs(dot(normalize(rayOrigin - worldPos), float3(0.0, 1.0, 0.0)));
    float angleFade = smoothstep(0.02, 0.25, viewDot);
    fade *= angleFade;

    float minorIntensity = minorLine * 2.0;
    float majorIntensity = majorLine * 2.6;
    float axisIntensityX = axisX * 2.8;
    float axisIntensityZ = axisZ * 2.8;

    float3 minorColor = float3(0.22, 0.26, 0.32);
    float3 majorColor = float3(0.45, 0.62, 0.78);
    float3 color = minorColor * minorIntensity + majorColor * majorIntensity;
    color += float3(1.0, 0.24, 0.22) * axisIntensityX;
    color += float3(0.22, 0.52, 1.0) * axisIntensityZ;

    float alpha = max(max(minorIntensity, majorIntensity), max(axisIntensityX, axisIntensityZ));
    color *= fade;
    alpha = saturate(alpha * fade * 1.5);

    return float4(color, alpha);
}

fragment float4 fragment_depth_hierarchy_seed(const SimpleRasterizerData rd [[ stage_in ]],
                                             constant RendererSettings &settings [[ buffer(FragmentBufferIndexRendererSettings) ]],
                                             constant SceneConstants &sceneConstants [[ buffer(FragmentBufferIndexPostProcessSceneConstants) ]],
                                             texture2d<float> depthTexture [[ texture(PostProcessTextureIndexDepth) ]],
                                             sampler s [[ sampler(FragmentSamplerIndexLinearClamp) ]]) {
    constexpr float kDepthHierarchyFar = 1.0e6;
    float2 uv = rd.texCoord;
    if (settings.uvDebug.x != 0) {
        return float4(uv, 0.0, 1.0);
    }

    float rawDepth = sampleSceneDepth(depthTexture, s, uv);
    float linearDepth = (rawDepth >= 0.999999) ? kDepthHierarchyFar : linearDepthFromRawDepth(uv, rawDepth, sceneConstants);
    return float4(linearDepth, 0.0, 0.0, 1.0);
}

fragment float4 fragment_depth_hierarchy_reduce(const SimpleRasterizerData rd [[ stage_in ]],
                                               constant DepthHierarchyReduceParams &params [[ buffer(FragmentBufferIndexPostProcessParams) ]],
                                               texture2d<float, access::read> depthHierarchy [[ texture(PostProcessTextureIndexSource) ]]) {
    uint sourceMip = uint(params.sourceMipLevel);
    uint sourceWidth = depthHierarchy.get_width(sourceMip);
    uint sourceHeight = depthHierarchy.get_height(sourceMip);
    uint2 targetSize = uint2(max(sourceWidth >> 1, 1u), max(sourceHeight >> 1, 1u));
    uint2 targetCoord = min(uint2(rd.texCoord * float2(targetSize)), targetSize - 1u);
    uint2 baseCoord = min(targetCoord * 2u, uint2(sourceWidth - 1u, sourceHeight - 1u));
    uint2 coordX = uint2(min(baseCoord.x + 1u, sourceWidth - 1u), baseCoord.y);
    uint2 coordY = uint2(baseCoord.x, min(baseCoord.y + 1u, sourceHeight - 1u));
    uint2 coordXY = uint2(min(baseCoord.x + 1u, sourceWidth - 1u), min(baseCoord.y + 1u, sourceHeight - 1u));

    float minDepth = depthHierarchy.read(baseCoord, sourceMip).r;
    minDepth = min(minDepth, depthHierarchy.read(coordX, sourceMip).r);
    minDepth = min(minDepth, depthHierarchy.read(coordY, sourceMip).r);
    minDepth = min(minDepth, depthHierarchy.read(coordXY, sourceMip).r);
    return float4(minDepth, 0.0, 0.0, 1.0);
}

fragment float4 fragment_sao_evaluate(const SimpleRasterizerData rd [[ stage_in ]],
                                       constant RendererSettings &settings [[ buffer(FragmentBufferIndexRendererSettings) ]],
                                       constant SceneConstants &sceneConstants [[ buffer(FragmentBufferIndexPostProcessSceneConstants) ]],
                                       texture2d<float> depthTexture [[ texture(PostProcessTextureIndexDepth) ]],
                                       texture2d<float> normalTexture [[ texture(PostProcessTextureIndexNormals) ]],
                                       sampler s [[ sampler(FragmentSamplerIndexLinearClamp) ]]) {
    float2 uv = rd.texCoord;
    if (settings.uvDebug.x != 0) {
        return float4(uv, 0.0, 1.0);
    }

    constexpr uint kSampleCount = 16;
    constexpr float kGoldenAngle = 2.39996323;
    constexpr float kMinSampleRadius = 0.05;

    float centerRawDepth = ssao_sample_depth_nearest(depthTexture, uv);
    if (centerRawDepth >= 0.999999) {
        return float4(1.0);
    }

    float3 centerViewPosition = reconstructViewPosition(uv, centerRawDepth, sceneConstants);
    float3 centerViewNormal = ssao_sample_normal_nearest(normalTexture, uv);
    float centerLinearDepth = linearDepthFromViewPosition(centerViewPosition);
    if (centerLinearDepth <= 1e-5) {
        return float4(1.0);
    }

    // Contact-first tuning: keep the effective radius modest so nearby inter-object
    // contacts dominate the result instead of being averaged into broad ambient darkening.
    float radius = max(settings.ssaoRadius, 1e-3);
    float effectiveRadius = radius * 0.9;
    float radiusSquared = effectiveRadius * effectiveRadius;
    float bias = max(settings.ssaoBias, 0.0);
    float intensity = max(settings.ssaoIntensity, 0.0);
    float power = max(settings.ssaoPower, 0.1);

    float3 tangent;
    float3 bitangent;
    ssao_build_basis(centerViewNormal, tangent, bitangent);

    uint2 pixelCoord = ssao_pixel_from_uv(uv, depthTexture);
    float rotationSeed = fract(sin(dot(float2(pixelCoord), float2(12.9898, 78.233))) * 43758.5453);
    float angleOffset = rotationSeed * 6.2831853;

    float obscurance = 0.0;
    float totalWeight = 0.0;

    for (uint sampleIndex = 0; sampleIndex < kSampleCount; ++sampleIndex) {
        float tapFraction = (float(sampleIndex) + 0.5) / float(kSampleCount);
        float nearFieldBias = tapFraction * tapFraction;
        float diskRadius = mix(kMinSampleRadius, 1.0, nearFieldBias);
        float angle = angleOffset + float(sampleIndex) * kGoldenAngle;
        float2 disk = float2(cos(angle), sin(angle)) * diskRadius;

        // Offset the sample in the receiver tangent plane using a modest view-space radius,
        // then project that point back to screen space so the kernel scales with depth.
        float3 sampleOffset = (tangent * disk.x + bitangent * disk.y) * effectiveRadius;
        float3 sampleProbePosition = centerViewPosition + sampleOffset;
        float2 sampleUV = ssao_project_view_position_to_uv(sampleProbePosition, sceneConstants);
        if (any(sampleUV <= 0.0) || any(sampleUV >= 1.0)) {
            continue;
        }

        float sampleRawDepth = ssao_sample_depth_nearest(depthTexture, sampleUV);
        if (sampleRawDepth >= 0.999999) {
            continue;
        }

        float3 sampleViewPosition = reconstructViewPosition(sampleUV, sampleRawDepth, sceneConstants);
        float3 delta = sampleViewPosition - centerViewPosition;
        float distanceSquared = dot(delta, delta);
        if (distanceSquared <= 1e-6 || distanceSquared >= radiusSquared) {
            continue;
        }

        float distance = sqrt(distanceSquared);
        float3 directionToSample = delta / distance;

        // Restore the previous contact-capable weighting model. It is not a pure hemisphere
        // obscurance test, but it produced the inter-object grounding we want to preserve.
        float receiverHeight = dot(centerViewNormal, delta);
        float receiverLift = saturate((receiverHeight + bias) / (distance + bias));
        float lateralContact = 1.0 - saturate(abs(receiverHeight) / (distance + bias));
        float receiverWeight = max(receiverLift, lateralContact * 0.45);
        if (receiverWeight <= 1e-4) {
            continue;
        }

        float3 sampleViewNormal = ssao_sample_normal_nearest(normalTexture, sampleUV);
        float occluderFacing = saturate(dot(sampleViewNormal, -directionToSample));
        float rangeFalloff = 1.0 - saturate(distanceSquared / radiusSquared);
        rangeFalloff *= rangeFalloff;
        float nearFieldWeight = mix(1.2, 0.55, tapFraction);
        float tapWeight = nearFieldWeight * mix(0.55, 1.0, occluderFacing);

        obscurance += receiverWeight * rangeFalloff * tapWeight;
        totalWeight += tapWeight;
    }

    float normalizedObscurance = (totalWeight > 0.0) ? (obscurance / totalWeight) : 0.0;
    // In this restored formulation the accumulated term behaves more like local
    // accessibility / visibility than true obscurance. Preserve the contact signal,
    // but stop inverting it at the end so stored AO remains: 1 = visible, 0 = occluded.
    float visibility = saturate(normalizedObscurance * intensity);
    visibility = pow(max(visibility, 1e-4), power);
    return float4(visibility, visibility, visibility, 1.0);
}

fragment float4 fragment_ao_blur_h(const SimpleRasterizerData rd [[ stage_in ]],
                                     constant RendererSettings &settings [[ buffer(FragmentBufferIndexRendererSettings) ]],
                                     constant SceneConstants &sceneConstants [[ buffer(FragmentBufferIndexPostProcessSceneConstants) ]],
                                     texture2d<float> aoTexture [[ texture(PostProcessTextureIndexSource) ]],
                                     texture2d<float> depthTexture [[ texture(PostProcessTextureIndexDepth) ]],
                                     texture2d<float> normalTexture [[ texture(PostProcessTextureIndexNormals) ]],
                                     sampler s [[ sampler(FragmentSamplerIndexLinearClamp) ]]) {
    float2 uv = rd.texCoord;
    float2 axisStep = float2(1.0 / float(aoTexture.get_width()), 0.0);
    float visibility = ao_cross_bilateral_blur(
        uv,
        axisStep,
        settings.ssaoBlurSharpness,
        aoTexture,
        depthTexture,
        normalTexture,
        s,
        sceneConstants
    );
    return float4(visibility, visibility, visibility, 1.0);
}

fragment float4 fragment_ao_blur_v(const SimpleRasterizerData rd [[ stage_in ]],
                                     constant RendererSettings &settings [[ buffer(FragmentBufferIndexRendererSettings) ]],
                                     constant SceneConstants &sceneConstants [[ buffer(FragmentBufferIndexPostProcessSceneConstants) ]],
                                     texture2d<float> aoTexture [[ texture(PostProcessTextureIndexSource) ]],
                                     texture2d<float> depthTexture [[ texture(PostProcessTextureIndexDepth) ]],
                                     texture2d<float> normalTexture [[ texture(PostProcessTextureIndexNormals) ]],
                                     sampler s [[ sampler(FragmentSamplerIndexLinearClamp) ]]) {
    float2 uv = rd.texCoord;
    float2 axisStep = float2(0.0, 1.0 / float(aoTexture.get_height()));
    float visibility = ao_cross_bilateral_blur(
        uv,
        axisStep,
        settings.ssaoBlurSharpness,
        aoTexture,
        depthTexture,
        normalTexture,
        s,
        sceneConstants
    );
    return float4(visibility, visibility, visibility, 1.0);
}

fragment float4 fragment_final(const SimpleRasterizerData rd [[ stage_in ]],
                               constant RendererSettings &settings [[ buffer(FragmentBufferIndexRendererSettings) ]],
                               constant SceneConstants &sceneConstants [[ buffer(FragmentBufferIndexPostProcessSceneConstants) ]],
                               constant ViewExposureSettings &viewExposure [[ buffer(FragmentBufferIndexViewExposure) ]],
                               constant PostProcessDebugFlags &debugFlags [[ buffer(FragmentBufferIndexPostProcessDebugFlags) ]],
                               texture2d<float> sceneTexture [[ texture(PostProcessTextureIndexSource) ]],
                               texture2d<float> bloomTexture [[ texture(PostProcessTextureIndexBloom) ]],
                               texture2d<float> outlineMask [[ texture(PostProcessTextureIndexOutlineMask) ]],
                               texture2d<float> depthTexture [[ texture(PostProcessTextureIndexDepth) ]],
                               texture2d<float> gridTexture [[ texture(PostProcessTextureIndexGrid) ]],
                               texture2d<float> autoExposureTexture [[ texture(PostProcessTextureIndexAutoExposure) ]],
                               texture2d<float> sceneNormalsTexture [[ texture(PostProcessTextureIndexNormals) ]],
                               texture2d<float> ssaoRawTexture [[ texture(PostProcessTextureIndexSSAORaw) ]],
                               texture2d<float> ssaoFilteredTexture [[ texture(PostProcessTextureIndexSSAOFiltered) ]],
                               texture2d<float> aoNormalsTexture [[ texture(PostProcessTextureIndexAONormals) ]],
                               texture2d<float> worldDebugTexture [[ texture(PostProcessTextureIndexWorldDebug) ]],
                               sampler s [[ sampler(FragmentSamplerIndexLinearClamp) ]]) {
    float2 uv = rd.texCoord;
    if (settings.uvDebug.x != 0) {
        return float4(uv, 0.0, 1.0);
    }
    if (settings.shadingDebugMode == DebugSceneDepth) {
        float rawDepth = depthTexture.sample(s, uv).r;
        float linearDepth = linearDepthFromRawDepth(uv, rawDepth, sceneConstants);
        float farPlane = projectionFarPlane(sceneConstants);
        return float4(visualizeLinearDepth(linearDepth, farPlane), 1.0);
    }
    if (settings.shadingDebugMode == DebugSceneNormals) {
        if (debugFlags.hasSceneNormals == 0u) {
            return float4(1.0, 0.0, 1.0, 1.0);
        }
        float3 sceneNormal = sampleSceneNormal(sceneNormalsTexture, s, uv);
        return float4(visualizeSceneNormal(sceneNormal), 1.0);
    }
    if (settings.shadingDebugMode == DebugSceneWorldNormals) {
        if (debugFlags.hasSceneNormals == 0u) {
            return float4(1.0, 0.0, 1.0, 1.0);
        }
        float3 sceneNormal = sampleSceneNormal(sceneNormalsTexture, s, uv);
        float3 worldNormal = viewNormalToWorld(sceneNormal, sceneConstants);
        return float4(visualizeSceneNormal(worldNormal), 1.0);
    }
    if (settings.shadingDebugMode == DebugSSAORaw) {
        if (debugFlags.hasSSAO == 0u) {
            return float4(1.0, 0.0, 1.0, 1.0);
        }
        // Debug views show stored visibility directly: white = open, dark = occluded.
        float visibility = ssaoRawTexture.sample(s, uv).r;
        return float4(float3(visibility), 1.0);
    }
    if (settings.shadingDebugMode == DebugSSAOFiltered) {
        if (debugFlags.hasSSAO == 0u) {
            return float4(1.0, 0.0, 1.0, 1.0);
        }
        float visibility = ssaoFilteredTexture.sample(s, uv).r;
        return float4(float3(visibility), 1.0);
    }
    if (settings.shadingDebugMode == DebugAONormals) {
        if (debugFlags.hasAONormals == 0u) {
            return float4(1.0, 0.0, 1.0, 1.0);
        }
        float3 aoNormal = sampleSceneNormal(aoNormalsTexture, s, uv);
        return float4(visualizeSceneNormal(aoNormal), 1.0);
    }
    if (settings.shadingDebugMode == DebugReconstructedViewPosition) {
        float rawDepth = depthTexture.sample(s, uv).r;
        float3 viewPosition = reconstructViewPosition(uv, rawDepth, sceneConstants);
        return float4(visualizeViewPosition(viewPosition, sceneConstants), 1.0);
    }
    if (settings.shadingDebugMode == DebugFogFactor) {
        float fogFactor = evaluateHeightFogTransmittance(uv, depthTexture, s, settings, sceneConstants).y;
        return float4(float3(fogFactor), 1.0);
    }
    if (settings.shadingDebugMode == DebugFogTransmittance) {
        float transmittance = evaluateHeightFogTransmittance(uv, depthTexture, s, settings, sceneConstants).x;
        return float4(float3(transmittance), 1.0);
    }
    // Scene and bloom are in linear HDR; tonemap + gamma only here.
    float3 scene = sceneTexture.sample(s, uv).rgb;
    float3 bloom = float3(0.0);
    if (settings.bloomEnabled != 0) {
        bloom = max(bloomTexture.sample(s, uv, level(0.0)).rgb, 0.0);
    }
    float bloomIntensity = (settings.bloomEnabled != 0) ? settings.bloomIntensity : 0.0;
    float3 color = scene + bloom * bloomIntensity;

    float4 gridSample = gridTexture.sample(s, uv);
    if (settings.gridEnabled != 0) {
        color = mix(color, gridSample.rgb, gridSample.a * settings.gridOpacity);
    }

    float4 worldDebugSample = worldDebugTexture.sample(s, uv);
    float worldDebugAlpha = saturate(worldDebugSample.a);
    // Debug lines accumulate into the intermediate overlay target with alpha blending,
    // so the stored RGB is effectively premultiplied by coverage/alpha.
    color = color * (1.0 - worldDebugAlpha) + max(worldDebugSample.rgb, 0.0);

    if (settings.outlineEnabled != 0) {
        float mask = outlineMask.sample(s, uv).r;
        float outlineAlpha = saturate(mask * settings.outlineOpacity);
        color = mix(color, settings.outlineColor, outlineAlpha);
    }

    float resolvedExposure = max(viewExposure.manualExposure, 1e-4);
    if (viewExposure.autoExposureEnabled != 0) {
        uint exposureMip = max(autoExposureTexture.get_num_mip_levels(), 1u) - 1u;
        float avgLogLuminance = autoExposureTexture.sample(s, float2(0.5), level(float(exposureMip))).r;
        float avgLuminance = exp2(avgLogLuminance);
        float compensatedExposure = (0.18 / max(avgLuminance, 1e-4)) * exp2(viewExposure.exposureCompensation);
        float minExposure = max(viewExposure.autoExposureMin, 1e-4);
        float maxExposure = max(viewExposure.autoExposureMax, minExposure);
        resolvedExposure = clamp(compensatedExposure, minExposure, maxExposure);
    }
    color = max(color, 0.0) * resolvedExposure;

    if (settings.tonemap == TonemapType::TonemapReinhard) {
        color = tonemap_reinhard(color);
    } else if (settings.tonemap == TonemapType::TonemapACES) {
        color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
    } else if (settings.tonemap == TonemapType::TonemapHazel) {
        color = tonemap_hazel(color);
    } else if (settings.tonemap == TonemapType::TonemapAgX) {
        color = tonemap_agx(color);
    } else if (settings.tonemap == TonemapType::TonemapFilmic) {
        color = tonemap_filmic_default(color);
    }

    color = linear_to_srgb(saturate(color));
    float gammaTrim = max(settings.gamma, 1e-4) / 2.2;
    color = pow(color, 1.0 / gammaTrim);
    return float4(color, 1.0);
}
