//
//  BasicShaders.metal
//  MetalCup
//
//  Created by Kaden Cringle on 1/21/26.
//

#include <metal_stdlib>
#include "PBR.metal"
#include "Shared.metal"
using namespace metal;

constant bool kEnableDebug [[function_constant(0)]];
constant int kShadowFilterMode [[function_constant(1)]];

// Temporary shadow triage stage selector:
// 0 = normal evaluation
// 1 = force fully lit to verify the blackout is in shadow evaluation
// 2 = bypass compare sampler and use raw depth relationship
// 3 = bypass receiver depth bias to isolate bias sign/magnitude issues
constant int kShadowTriageMode = 0;

inline float channelValue(float3 value, uint channel) {
    if (channel == 0) { return value.r; }
    if (channel == 1) { return value.g; }
    return value.b;
}

inline int selectShadowCascadeByMetric(float metric, constant ShadowConstants &shadows) {
    int cascade = 0;
    if (metric > shadows.cascadeSplits.x) { cascade = 1; }
    if (metric > shadows.cascadeSplits.y) { cascade = 2; }
    if (metric > shadows.cascadeSplits.z) { cascade = 3; }
    int maxCascade = max(int(shadows.shadowMapInvSizeAndCount.z + 0.5) - 1, 0);
    return min(cascade, maxCascade);
}

inline float cascadeSplitDistance(constant ShadowConstants &shadows, int index) {
    switch (index) {
    case 0: return shadows.cascadeSplits.x;
    case 1: return shadows.cascadeSplits.y;
    case 2: return shadows.cascadeSplits.z;
    case 3: return shadows.cascadeSplits.w;
    default: return shadows.cascadeSplits.w;
    }
}

inline float sampleShadowCompare(depth2d_array<float, access::sample> shadowMap,
                                 sampler shadowCompareSampler,
                                 float2 uv,
                                 uint layer,
                                 float depth) {
    // The compare sampler is intentionally point-filtered so hard mode stays hard
    // and PCF softness comes from the explicit tap kernel below rather than hidden
    // hardware bilinear compare filtering on every tap.
    return shadowMap.sample_compare(shadowCompareSampler, uv, layer, depth);
}

inline float sampleShadowDepthRaw(depth2d_array<float, access::sample> shadowMap,
                                 sampler shadowSampler,
                                 float2 uv,
                                 uint layer) {
    return shadowMap.sample(shadowSampler, uv, layer);
}

inline float hash12(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

constant float2 kPoissonDisk25[25] = {
    float2(-0.978698, -0.0884121),
    float2(-0.841121, 0.521165),
    float2(-0.717460, -0.503220),
    float2(-0.702933, 0.903134),
    float2(-0.663198, 0.154820),
    float2(-0.495102, -0.232887),
    float2(-0.364238, -0.961791),
    float2(-0.345866, -0.564379),
    float2(-0.325663, 0.640370),
    float2(-0.182714, 0.321329),
    float2(-0.142613, -0.0227363),
    float2(-0.0564287, -0.367290),
    float2(-0.0185858, 0.918882),
    float2(0.0381787, -0.728996),
    float2(0.165990, 0.093112),
    float2(0.253639, 0.719535),
    float2(0.369549, -0.655019),
    float2(0.423627, 0.429975),
    float2(0.530747, -0.364971),
    float2(0.566027, 0.940489),
    float2(0.639332, 0.0284127),
    float2(0.652089, 0.669668),
    float2(0.773797, 0.345012),
    float2(0.968871, 0.840449),
    float2(0.991882, -0.657338)
};

inline float cascadeWorldUnitsPerTexel(constant ShadowConstants &shadows, int index) {
    switch (index) {
    case 0: return shadows.cascadeWorldUnitsPerTexel.x;
    case 1: return shadows.cascadeWorldUnitsPerTexel.y;
    case 2: return shadows.cascadeWorldUnitsPerTexel.z;
    case 3: return shadows.cascadeWorldUnitsPerTexel.w;
    default: return shadows.cascadeWorldUnitsPerTexel.x;
    }
}

inline float cascadeNearZ(constant ShadowConstants &shadows, int index) {
    switch (index) {
    case 0: return shadows.cascadeNearZ.x;
    case 1: return shadows.cascadeNearZ.y;
    case 2: return shadows.cascadeNearZ.z;
    case 3: return shadows.cascadeNearZ.w;
    default: return shadows.cascadeNearZ.x;
    }
}

inline float shadowReceiverLightFacing(float3 normal, float3 surfaceToLight) {
    return saturate(dot(normalize(normal), normalize(surfaceToLight)));
}

inline float shadowReceiverDepthBiasScale(float3 normal, float3 surfaceToLight) {
    float slopeFactor = 1.0 - shadowReceiverLightFacing(normal, surfaceToLight);
    return mix(1.0, 1.6, slopeFactor * slopeFactor);
}

inline float analyticRangeFade(float distance, float range) {
    if (range <= 0.0) {
        return 1.0;
    }
    return 1.0 - smoothstep(0.8 * range, range, distance);
}

inline float analyticInverseSquareAttenuation(float distance, float range) {
    return analyticRangeFade(distance, range) / max(distance * distance, 1e-4);
}

inline float analyticSpotAngularFalloff(float spotCos,
                                        float innerConeCos,
                                        float outerConeCos) {
    float width = innerConeCos - outerConeCos;
    float smooth = width > 1e-6
        ? smoothstep(outerConeCos, innerConeCos, spotCos)
        : float(spotCos >= innerConeCos);
    return smooth * smooth;
}

inline float cascadeFarZ(constant ShadowConstants &shadows, int index) {
    switch (index) {
    case 0: return shadows.cascadeFarZ.x;
    case 1: return shadows.cascadeFarZ.y;
    case 2: return shadows.cascadeFarZ.z;
    case 3: return shadows.cascadeFarZ.w;
    default: return shadows.cascadeFarZ.x;
    }
}

inline float pcfRadiusTexelsForCascade(constant ShadowConstants &shadows, int cascadeIndex) {
    float baseRadiusTexels = max(shadows.shadowBiasParams.z, 0.5);
    float referenceUnitsPerTexel = max(cascadeWorldUnitsPerTexel(shadows, 0), 1e-6);
    float cascadeUnitsPerTexel = max(cascadeWorldUnitsPerTexel(shadows, cascadeIndex), 1e-6);
    float referenceWorldRadius = baseRadiusTexels * referenceUnitsPerTexel;
    float radiusTexels = referenceWorldRadius / cascadeUnitsPerTexel;
    return max(radiusTexels, 0.5);
}

inline float cascadeBlendWidth(constant ShadowConstants &shadows, int cascadeIndex) {
    uint cascadeCount = uint(shadows.shadowMapInvSizeAndCount.z + 0.5);
    if (cascadeIndex < 0 || cascadeIndex + 1 >= int(cascadeCount)) {
        return 0.0;
    }
    float splitFar = cascadeSplitDistance(shadows, cascadeIndex);
    float prevSplit = (cascadeIndex == 0) ? 0.0 : cascadeSplitDistance(shadows, cascadeIndex - 1);
    float cascadeSpan = max(splitFar - prevSplit, 0.0);
    float currentUnitsPerTexel = max(cascadeWorldUnitsPerTexel(shadows, cascadeIndex), 1e-6);
    float nextUnitsPerTexel = max(cascadeWorldUnitsPerTexel(shadows, cascadeIndex + 1), currentUnitsPerTexel);
    float transitionUnitsPerTexel = max(currentUnitsPerTexel, nextUnitsPerTexel);
    const float blendFraction = 0.02;
    const float minBlendTexels = 8.0;
    const float maxBlendFraction = 0.10;
    float fractionalBlendWidth = cascadeSpan * blendFraction;
    float texelBlendWidth = transitionUnitsPerTexel * minBlendTexels;
    float blendWidth = max(fractionalBlendWidth, texelBlendWidth);
    return min(blendWidth, cascadeSpan * maxBlendFraction);
}

inline float shadowBiasStressForCascade(float3 normal,
                                        float3 lightDir,
                                        int cascadeIndex,
                                        constant ShadowConstants &shadows) {
    float unitsPerTexel = max(cascadeWorldUnitsPerTexel(shadows, cascadeIndex), 1e-6);
    float nearZ = cascadeNearZ(shadows, cascadeIndex);
    float farZ = cascadeFarZ(shadows, cascadeIndex);
    float depthSpanAbs = max(abs(farZ - nearZ), 1e-4);
    float texelDepthBias = unitsPerTexel / depthSpanAbs;
    float normalBiasTexels = shadows.shadowBiasParams.y / unitsPerTexel;
    float depthBiasTexels = shadows.shadowBiasParams.x / max(texelDepthBias, 1e-6);
    return max(normalBiasTexels, depthBiasTexels);
}

inline float computeShadowVisibilityForCascade(float3 worldPosition,
                                              float3 normal,
                                              float3 lightDir,
                                              int cascadeIndex,
                                              constant ShadowConstants &shadows,
                                              depth2d_array<float, access::sample> shadowMap,
                                              sampler shadowSampler,
                                              sampler shadowCompareSampler,
                                              thread bool &isValid) {
    isValid = false;
    uint cascadeLayer = uint(cascadeIndex);
    float3 N = normalize(normal);
    float receiverNormalBias = shadows.shadowBiasParams.y;
    float3 biasedWorldPosition = worldPosition + N * receiverNormalBias;
    float4 shadowPos = shadowLightViewProj(shadows, cascadeIndex) * float4(biasedWorldPosition, 1.0);
    if (!all(isfinite(shadowPos)) || fabs(shadowPos.w) < 1e-6) {
        return 1.0;
    }
    float3 proj = shadowPos.xyz / shadowPos.w;
    if (!all(isfinite(proj))) {
        return 1.0;
    }
    float2 uv = proj.xy * 0.5 + 0.5;
    uv.y = 1.0 - uv.y; // Shadow map space is Y-flipped relative to clip space.
    float receiverDepth = proj.z;
    if (uv.x < 0.0 || uv.x >= 1.0 || uv.y < 0.0 || uv.y >= 1.0) {
        return 1.0;
    }
    if (receiverDepth < 0.0 || receiverDepth > 1.0) {
        return 1.0;
    }
    isValid = true;
    float unitsPerTexel = max(cascadeWorldUnitsPerTexel(shadows, cascadeIndex), 1e-6);
    float nearZ = cascadeNearZ(shadows, cascadeIndex);
    float farZ = cascadeFarZ(shadows, cascadeIndex);
    float depthSpanAbs = max(abs(farZ - nearZ), 1e-4);
    float depthBiasScale = shadowReceiverDepthBiasScale(N, lightDir);
    float receiverDepthBias = shadows.shadowBiasParams.x * depthBiasScale;
    float compareDepth = clamp(receiverDepth - receiverDepthBias, 0.0, 1.0);

    float2 invSize = shadows.shadowMapInvSizeAndCount.xy;

    float visibility = 1.0;
    if (kShadowTriageMode == 1) {
        return 1.0;
    }

    float rawDepth = sampleShadowDepthRaw(shadowMap, shadowSampler, uv, cascadeLayer);
    float triageCompareDepth = (kShadowTriageMode == 3) ? receiverDepth : compareDepth;
    if (kShadowTriageMode == 2) {
        return (rawDepth + 1e-4 < triageCompareDepth) ? 0.0 : 1.0;
    }

    int filterMode = kShadowFilterMode;
    if (filterMode == 0) {
        visibility = sampleShadowCompare(shadowMap, shadowCompareSampler, uv, cascadeLayer, triageCompareDepth);
    } else if (filterMode == 2) {
        uint blockerSamples = min(uint(shadows.pcssParams1.x + 0.5), 25u);
        uint pcfSamples = min(uint(shadows.pcssParams1.y + 0.5), 25u);
        uint blockerSamplesCount = max(blockerSamples, 1u);
        uint pcfSamplesCount = max(pcfSamples, 1u);
        bool useNoise = shadows.pcssParams1.z > 0.5;
        float2x2 rot = float2x2(1.0, 0.0, 0.0, 1.0);
        if (useNoise) {
            float2 stableNoiseCell = floor((uv / max(invSize * 4.0, float2(1e-6))) + float2(float(cascadeLayer) * 1.37));
            float angle = hash12(stableNoiseCell) * 6.2831853;
            float s = sin(angle);
            float c = cos(angle);
            rot = float2x2(c, -s, s, c);
        }
        float searchRadiusTexels = max(shadows.pcssParams0.w, 1.0);
        float2 searchRadiusUv = searchRadiusTexels * invSize;
        float avgBlockerDepth = 0.0;
        uint blockerCount = 0;
        for (uint i = 0; i < blockerSamplesCount; ++i) {
            float2 offset = kPoissonDisk25[i];
            if (useNoise) {
                offset = rot * offset;
            }
            float2 sampleUv = uv + offset * searchRadiusUv;
            if (sampleUv.x < 0.0 || sampleUv.x >= 1.0 || sampleUv.y < 0.0 || sampleUv.y >= 1.0) {
                continue;
            }
            float sampleDepth = sampleShadowDepthRaw(shadowMap, shadowSampler, sampleUv, cascadeLayer);
            if (sampleDepth < receiverDepth) {
                avgBlockerDepth += sampleDepth;
                blockerCount += 1;
            }
        }
        if (blockerCount == 0) {
            visibility = 1.0;
        } else {
            avgBlockerDepth /= float(blockerCount);
            float blockerConfidence = saturate((float(blockerCount) - 1.0) / max(float(blockerSamplesCount) - 1.0, 1.0));
            avgBlockerDepth = mix(receiverDepth, avgBlockerDepth, blockerConfidence);
            float receiverDepthDist = receiverDepth * depthSpanAbs;
            float blockerDepthDist = avgBlockerDepth * depthSpanAbs;
            float receiverMinusBlocker = max(receiverDepthDist - blockerDepthDist, 0.0);
            float penumbraWorld = receiverMinusBlocker * (shadows.pcssParams0.x / max(blockerDepthDist, 1e-4));
            float minFilterTexels = max(shadows.pcssParams0.y, 1.0);
            float maxFilterTexels = max(shadows.pcssParams0.z, minFilterTexels);
            float stableMaxFilterTexels = mix(minFilterTexels, maxFilterTexels, max(blockerConfidence, 0.35));
            float filterRadiusTexels = clamp(penumbraWorld / unitsPerTexel, minFilterTexels, stableMaxFilterTexels);
            float2 filterRadiusUv = filterRadiusTexels * invSize;
            float sum = 0.0;
            uint samples = 0;
            for (uint i = 0; i < pcfSamplesCount; ++i) {
                float2 offset = kPoissonDisk25[i];
                if (useNoise) {
                    offset = rot * offset;
                }
                float2 sampleUv = uv + offset * filterRadiusUv;
                if (sampleUv.x < 0.0 || sampleUv.x >= 1.0 || sampleUv.y < 0.0 || sampleUv.y >= 1.0) {
                    continue;
                }
                sum += sampleShadowCompare(shadowMap, shadowCompareSampler, sampleUv, cascadeLayer, triageCompareDepth);
                samples += 1;
            }
            visibility = (samples > 0) ? (sum / float(samples)) : 1.0;
        }
    } else {
        uint cascadeTapCount = 9u;
        if (cascadeIndex == 0) {
            cascadeTapCount = uint(shadows.pcfTapCounts.x + 0.5);
        } else if (cascadeIndex == 1) {
            cascadeTapCount = uint(shadows.pcfTapCounts.y + 0.5);
        } else if (cascadeIndex == 2) {
            cascadeTapCount = uint(shadows.pcfTapCounts.z + 0.5);
        } else {
            cascadeTapCount = uint(shadows.pcfTapCounts.w + 0.5);
        }
        cascadeTapCount = max(1u, min(cascadeTapCount, 25u));

        float radiusTexels = pcfRadiusTexelsForCascade(shadows, cascadeIndex);
        float2 radiusUv = radiusTexels * invSize;
        float sum = 0.0;
        uint samples = 0u;
        for (uint i = 0; i < cascadeTapCount; ++i) {
            float2 sampleUv = uv + kPoissonDisk25[i] * radiusUv;
            if (sampleUv.x < 0.0 || sampleUv.x >= 1.0 || sampleUv.y < 0.0 || sampleUv.y >= 1.0) {
                continue;
            }
            sum += sampleShadowCompare(shadowMap, shadowCompareSampler, sampleUv, cascadeLayer, triageCompareDepth);
            samples += 1u;
        }
        visibility = (samples > 0u) ? (sum / float(samples)) : 1.0;
    }
    return visibility;
}

inline float computeShadowFactor(float3 worldPosition,
                                 float3 normal,
                                 float3 lightDir,
                                 float viewDepth,
                                 constant ShadowConstants &shadows,
                                 depth2d_array<float, access::sample> shadowMap,
                                 sampler shadowSampler,
                                 sampler shadowCompareSampler) {
    uint cascadeCount = uint(shadows.shadowMapInvSizeAndCount.z + 0.5);
    if (shadows.shadowCasterDirectionAndEnabled.w < 0.5 || cascadeCount == 0) {
        return 1.0;
    }

    float metric = max(viewDepth, 0.0);
    if (metric <= 0.0) {
        metric = 0.001;
    }
    float maxShadowDistance = shadows.shadowBiasParams.w;
    if (maxShadowDistance > 0.0 && metric > maxShadowDistance) {
        return 1.0;
    }
    int cascadeIndex = selectShadowCascadeByMetric(metric, shadows);
    bool isValid = false;
    float visibility = computeShadowVisibilityForCascade(
        worldPosition,
        normal,
        lightDir,
        cascadeIndex,
        shadows,
        shadowMap,
        shadowSampler,
        shadowCompareSampler,
        isValid
    );
    if (!isValid) {
        bool foundValid = false;
        for (int offset = 1; offset < int(cascadeCount); ++offset) {
            int nextIndex = min(cascadeIndex + offset, int(cascadeCount) - 1);
            bool nextValid = false;
            float nextVisibility = computeShadowVisibilityForCascade(
                worldPosition,
                normal,
                lightDir,
                nextIndex,
                shadows,
                shadowMap,
                shadowSampler,
                shadowCompareSampler,
                nextValid
            );
            if (nextValid) {
                cascadeIndex = nextIndex;
                visibility = nextVisibility;
                foundValid = true;
                break;
            }
        }
        if (!foundValid) {
            return 1.0;
        }
    }

    if (cascadeIndex + 1 < int(cascadeCount)) {
        float splitFar = cascadeSplitDistance(shadows, cascadeIndex);
        float blendWidth = cascadeBlendWidth(shadows, cascadeIndex);
        if (blendWidth > 0.0 && metric > splitFar - blendWidth) {
            bool nextValid = false;
            float nextVisibility = computeShadowVisibilityForCascade(
                worldPosition,
                normal,
                lightDir,
                cascadeIndex + 1,
                shadows,
                shadowMap,
                shadowSampler,
                shadowCompareSampler,
                nextValid
            );
            if (nextValid) {
                float blendStart = splitFar - blendWidth;
                float t = smoothstep(blendStart, splitFar, metric);
                visibility = mix(visibility, nextVisibility, t);
            }
        }
    }

    float fadeOutDistance = shadows.shadowFadeParams.x;
    if (maxShadowDistance > 0.0 && fadeOutDistance > 0.0) {
        float fade = clamp((maxShadowDistance - metric) / max(fadeOutDistance, 0.001), 0.0, 1.0);
        visibility = mix(1.0, visibility, fade);
    }
    return visibility;
}

static inline bool isTransparentBlend(constant MetalCupMaterial &material) {
    return hasFlag(material.flags, MetalCupMaterialFlags::AlphaBlended)
        && !hasFlag(material.flags, MetalCupMaterialFlags::AdditiveBlended);
}

static inline bool isAdditiveBlend(constant MetalCupMaterial &material) {
    return hasFlag(material.flags, MetalCupMaterialFlags::AdditiveBlended);
}

constant bool kAlphaToCoverageEnabled [[function_constant(2)]];

static inline float4 shadedMaterialOutput(float3 color,
                                          float alpha,
                                          constant MetalCupMaterial &material) {
    alpha = clamp(alpha, 0.0, 1.0);
    if (isAdditiveBlend(material)) {
        return float4(color * alpha, 0.0);
    }
    if (isTransparentBlend(material)) {
        return float4(color * alpha, alpha);
    }
    if (kAlphaToCoverageEnabled && hasFlag(material.flags, MetalCupMaterialFlags::AlphaMasked)) {
        // Main scene color uses alpha output as coverage when the PSO enables alpha-to-coverage.
        return float4(color, alpha);
    }
    return float4(color, 1.0);
}

static inline float3 samplePrefilteredColor(texturecube<float> prefilteredMap,
                                            sampler iblSampler,
                                            float3 reflectionVector,
                                            float roughness,
                                            thread float &mipLevel,
                                            thread float &maxMip) {
    float mipCount = float(prefilteredMap.get_num_mip_levels());
    maxMip = max(mipCount - 1.0, 0.0);
    if (mipCount <= 1.0) {
        mipLevel = 0.0;
        return float3(0.0);
    }
    mipLevel = clamp(roughness * maxMip, 0.0, maxMip);
    float mip0 = floor(mipLevel);
    float mip1 = min(mip0 + 1.0, maxMip);
    float mipT = mipLevel - mip0;
    float3 prefilter0 = prefilteredMap.sample(iblSampler, reflectionVector, level(mip0)).rgb;
    float3 prefilter1 = prefilteredMap.sample(iblSampler, reflectionVector, level(mip1)).rgb;
    return mix(prefilter0, prefilter1, mipT);
}

static inline float3 computeSplitSumSpecularIBL(texturecube<float> prefilteredMap,
                                                texture2d<float> brdfLut,
                                                sampler iblSampler,
                                                float3 reflectionVector,
                                                float roughness,
                                                float NdotV,
                                                float3 F0,
                                                float intensity,
                                                thread float &mipLevel,
                                                thread float &maxMip) {
    if (intensity <= 0.0) {
        mipLevel = 0.0;
        maxMip = 0.0;
        return float3(0.0);
    }
    float3 prefilteredColor = samplePrefilteredColor(prefilteredMap, iblSampler, reflectionVector, roughness, mipLevel, maxMip);
    if (maxMip <= 0.0) {
        return float3(0.0);
    }
    float2 brdfUV = clamp(float2(clamp(NdotV, 0.0, 1.0), roughness), 0.001, 0.999);
    float2 brdfSample = brdfLut.sample(iblSampler, brdfUV).rg;
    float A = brdfSample.x;
    float B = brdfSample.y;
    float3 singleScatter = F0 * A + B;
    float3 specularIBL = prefilteredColor * singleScatter * intensity;
    float energyDenom = max(A + B, 1e-3);
    float3 energyCompRaw = 1.0 + F0 * (1.0 / energyDenom - 1.0);
    float3 energyComp = clamp(energyCompRaw, float3(1.0), float3(1.5));
    float energyCompWeight = roughness * roughness;
    specularIBL *= mix(float3(1.0), energyComp, energyCompWeight);
    return specularIBL;
}

static inline bool intersectLocalReflectionProbeBox(float3 rayOriginLocal,
                                                    float3 rayDirectionLocal,
                                                    float3 boxExtents,
                                                    thread float &hitDistance,
                                                    thread float3 &hitPointLocal) {
    const float epsilon = 1e-5;
    float tNear = -INFINITY;
    float tFar = INFINITY;

    for (uint axis = 0; axis < 3; ++axis) {
        float origin = rayOriginLocal[axis];
        float direction = rayDirectionLocal[axis];
        float minPlane = -boxExtents[axis];
        float maxPlane = boxExtents[axis];

        if (abs(direction) <= epsilon) {
            // Parallel rays only remain valid if the origin already lies within this slab.
            if (origin < minPlane || origin > maxPlane) {
                return false;
            }
            continue;
        }

        float invDirection = 1.0 / direction;
        float axisT0 = (minPlane - origin) * invDirection;
        float axisT1 = (maxPlane - origin) * invDirection;
        float axisTMin = min(axisT0, axisT1);
        float axisTMax = max(axisT0, axisT1);
        tNear = max(tNear, axisTMin);
        tFar = min(tFar, axisTMax);
        if (!isfinite(tNear) || !isfinite(tFar) || tNear > tFar) {
            return false;
        }
    }

    float candidateDistance = tNear > epsilon ? tNear : tFar;
    if (!isfinite(candidateDistance) || candidateDistance <= epsilon) {
        return false;
    }

    float3 candidatePoint = rayOriginLocal + rayDirectionLocal * candidateDistance;
    if (!all(isfinite(candidatePoint))) {
        return false;
    }

    // Keep the hit anchored to the probe box even when floating-point precision nudges an axis
    // slightly beyond the slab boundary near edges or corners.
    candidatePoint = clamp(candidatePoint, -boxExtents, boxExtents);

    hitDistance = candidateDistance;
    hitPointLocal = candidatePoint;
    return true;
}

static inline bool computeParallaxCorrectedLocalProbeDirection(constant LocalReflectionProbeUniform &localReflectionProbe,
                                                               float3 worldPosition,
                                                               float3 worldReflectionDirection,
                                                               thread float3 &localProbeDirection) {
    float4 localPosition4 = localReflectionProbe.worldToProbeMatrix * float4(worldPosition, 1.0);
    float4 localDirection4 = localReflectionProbe.worldToProbeMatrix * float4(worldReflectionDirection, 0.0);
    float3 localDirection = localDirection4.xyz;
    float localDirectionLengthSquared = dot(localDirection, localDirection);
    if (!all(isfinite(localPosition4.xyz)) || !all(isfinite(localDirection)) || localDirectionLengthSquared <= 1e-8) {
        return false;
    }

    localDirection *= rsqrt(localDirectionLengthSquared);
    float hitDistance = 0.0;
    float3 hitPointLocal = float3(0.0);
    float3 boxExtents = max(localReflectionProbe.boxExtentsAndBlendDistance.xyz, float3(0.001));
    if (!intersectLocalReflectionProbeBox(localPosition4.xyz, localDirection, boxExtents, hitDistance, hitPointLocal)) {
        return false;
    }

    float3x3 worldToProbeRotation = float3x3(localReflectionProbe.worldToProbeMatrix[0].xyz,
                                             localReflectionProbe.worldToProbeMatrix[1].xyz,
                                             localReflectionProbe.worldToProbeMatrix[2].xyz);
    // Probe capture stays in the renderer's world-basis cubemap convention. Use authored probe
    // rotation only for the box-space ray test, then rotate the hit vector back to world space.
    float3 worldHitVector = transpose(worldToProbeRotation) * hitPointLocal;
    float worldHitVectorLengthSquared = dot(worldHitVector, worldHitVector);
    if (!all(isfinite(worldHitVector)) || worldHitVectorLengthSquared <= 1e-8) {
        return false;
    }

    float3 worldLookupDirection = worldHitVector * rsqrt(worldHitVectorLengthSquared);
    localProbeDirection = worldLookupDirection;
    return all(isfinite(localProbeDirection));
}

fragment float4 fragment_basic(RasterizerData rd [[ stage_in ]],
                              constant MetalCupMaterial &material [[ buffer(FragmentBufferIndexMaterial) ]],
                              constant RendererSettings &settings [[ buffer(FragmentBufferIndexRendererSettings) ]],
                              constant int &lightCount [[ buffer(FragmentBufferIndexLightCount) ]],
                              constant LightData *lightDatas [[ buffer(FragmentBufferIndexLightData) ]],
                              constant int &directionalLightCount [[ buffer(FragmentBufferIndexDirectionalLightCount) ]],
                              constant LightData *directionalLightDatas [[ buffer(FragmentBufferIndexDirectionalLightData) ]],
                              constant uint2 *lightGrid [[ buffer(FragmentBufferIndexLightGrid) ]],
                              constant uint *lightIndexList [[ buffer(FragmentBufferIndexLightIndexList) ]],
                              constant ForwardPlusIndexHeader *lightIndexHeader [[ buffer(FragmentBufferIndexLightIndexCount) ]],
                              constant ForwardPlusClusterParams *clusterParams [[ buffer(FragmentBufferIndexLightClusterParams) ]],
                              constant uint2 *tileLightGrid [[ buffer(FragmentBufferIndexTileLightGrid) ]],
                              constant ForwardPlusTileParams *tileParams [[ buffer(FragmentBufferIndexTileParams) ]],
                              constant ShadowConstants &shadows [[ buffer(FragmentBufferIndexShadowConstants) ]],
                              constant LocalReflectionProbeUniform &localReflectionProbe [[ buffer(FragmentBufferIndexLocalReflectionProbe) ]],
                              sampler sam [[ sampler(FragmentSamplerIndexLinear) ]],
                              sampler iblSam [[ sampler(FragmentSamplerIndexLinearClamp) ]],
                              sampler shadowCompareSampler [[ sampler(FragmentSamplerIndexShadowCompare) ]],
                              sampler shadowDepthSampler [[ sampler(FragmentSamplerIndexShadowDepth) ]],
                              texture2d<float> albedoMap [[ texture(FragmentTextureIndexAlbedo) ]],
                              texture2d<float> normalMap [[ texture(FragmentTextureIndexNormal) ]],
                              texture2d<float> metallicMap [[ texture(FragmentTextureIndexMetallic) ]],
                              texture2d<float> roughnessMap [[ texture(FragmentTextureIndexRoughness) ]],
                              texture2d<float> metalRoughness [[ texture(FragmentTextureIndexMetalRoughness) ]],
                              texture2d<float> ormMap [[ texture(FragmentTextureIndexORM) ]],
                              texture2d<float> aoMap [[ texture(FragmentTextureIndexAO) ]],
                              texture2d<float> emissiveMap [[ texture(FragmentTextureIndexEmissive) ]],
                              texture2d<float> clearcoatMap [[ texture(FragmentTextureIndexClearcoat) ]],
                              texture2d<float> clearcoatRoughnessMap [[ texture(FragmentTextureIndexClearcoatRoughness) ]],
                              texture2d<float> sheenColorMap [[ texture(FragmentTextureIndexSheenColor) ]],
                              texture2d<float> sheenIntensityMap [[ texture(FragmentTextureIndexSheenIntensity) ]],
                              texture2d<float> sceneAOTexture [[ texture(FragmentTextureIndexSceneAO) ]],
                              texturecube<float> irradianceMap [[ texture(FragmentTextureIndexIrradiance) ]],
                              texturecube<float> prefilteredMap [[ texture(FragmentTextureIndexPrefiltered) ]],
                              texturecube<float> localReflectionPrefilteredMap [[ texture(FragmentTextureIndexLocalReflectionPrefiltered) ]],
                              texture2d<float> brdf_lut [[ texture(FragmentTextureIndexBRDFLUT) ]],
                              depth2d_array<float, access::sample> shadowMap [[ texture(FragmentTextureIndexShadowMap) ]])  {
    // ------------------------------------------------------------
    // Fallback scalars (material factors)
    // ------------------------------------------------------------
    float3 albedo = material.baseColor;
    float alpha = material.baseColorAlpha;
    float metallic = material.metallicScalar;
    float roughness = material.roughnessScalar;
    float ao = material.aoScalar;
    float emissiveScalar = material.emissiveScalar;
    
    // ------------------------------------------------------------
    // Texture overrides
    // ------------------------------------------------------------
    bool disableSpecularAA = hasFlag(settings.perfFlags, RendererPerfFlags::PerfDisableSpecularAA);
    bool disableClearcoat = hasFlag(settings.perfFlags, RendererPerfFlags::PerfDisableClearcoat);
    bool disableSheen = hasFlag(settings.perfFlags, RendererPerfFlags::PerfDisableSheen);
    float2 uv = rd.texCoord * material.uvTiling + material.uvOffset;

    if (hasFlag(material.flags, MetalCupMaterialFlags::HasBaseColorMap)) {
        half4 albedoSample = half4(albedoMap.sample(sam, uv));
        albedo = float3(albedoSample.rgb);
        alpha *= float(albedoSample.a);
    }
    if (hasFlag(material.flags, MetalCupMaterialFlags::HasORMMap)) {
        half3 ormSample = half3(ormMap.sample(sam, uv).rgb);
        float3 orm = float3(ormSample);
        ao = channelValue(orm, material.aoChannel) * material.aoScalar;
        roughness = channelValue(orm, material.roughnessChannel) * material.roughnessScalar;
        metallic = channelValue(orm, material.metallicChannel) * material.metallicScalar;
    } else if (hasFlag(material.flags, MetalCupMaterialFlags::HasMetalRoughnessMap)) {
        half3 mrSample = half3(metalRoughness.sample(sam, uv).rgb);
        float3 mr = float3(mrSample);
        roughness = channelValue(mr, material.roughnessChannel) * material.roughnessScalar;
        metallic  = channelValue(mr, material.metallicChannel) * material.metallicScalar;
        if (hasFlag(material.flags, MetalCupMaterialFlags::HasAOMap)) {
            ao = float(aoMap.sample(sam, uv).r) * material.aoScalar;
        }
    } else {
        if (hasFlag(material.flags, MetalCupMaterialFlags::HasMetallicMap)) {
            metallic = float(metallicMap.sample(sam, uv).r) * material.metallicScalar;
        }
        if (hasFlag(material.flags, MetalCupMaterialFlags::HasRoughnessMap)) {
            roughness = float(roughnessMap.sample(sam, uv).r) * material.roughnessScalar;
        }
        if (hasFlag(material.flags, MetalCupMaterialFlags::HasAOMap)) {
            ao = float(aoMap.sample(sam, uv).r) * material.aoScalar;
        }
    }
    float clearcoat = disableClearcoat ? 0.0 : clamp(material.clearcoatFactor, 0.0, 1.0);
    float clearcoatRoughness = clamp(material.clearcoatRoughness, 0.0, 1.0);
    if (!disableClearcoat) {
        if (hasFlag(material.flags, MetalCupMaterialFlags::HasClearcoatMap)) {
            clearcoat *= clearcoatMap.sample(sam, uv).r;
        }
        if (hasFlag(material.flags, MetalCupMaterialFlags::HasClearcoatGlossMap)) {
            clearcoatRoughness = 1.0 - clearcoatRoughnessMap.sample(sam, uv).r;
        } else if (hasFlag(material.flags, MetalCupMaterialFlags::HasClearcoatRoughnessMap)) {
            clearcoatRoughness = clearcoatRoughnessMap.sample(sam, uv).r;
        }
    }
    float3 sheenColor = disableSheen ? float3(0.0) : clamp(material.sheenColor, float3(0.0), float3(1.0));
    if (!disableSheen) {
        if (hasFlag(material.flags, MetalCupMaterialFlags::HasSheenColorMap)) {
            float3 sheenTex = sheenColorMap.sample(sam, uv).rgb;
            sheenColor = any(sheenColor > 0.0) ? sheenColor * sheenTex : sheenTex;
        }
        if (hasFlag(material.flags, MetalCupMaterialFlags::HasSheenIntensityMap)) {
            float sheenIntensity = sheenIntensityMap.sample(sam, uv).r;
            sheenColor *= sheenIntensity;
        }
    }
    // Clamp for stability (prevents NaNs / LUT edge artifacts / fireflies)
    metallic = clamp(metallic, 0.0, 1.0);
    // Phase 2 direct-shading contract: perceptual roughness is bounded once at
    // the supported 0.06 floor before GGX evaluation. Higher authored floors
    // remain available for compatibility.
    const float minRoughness = clamp(settings.iblSpecularMinRoughness, 0.06, 0.2);
    roughness = clamp(roughness, minRoughness, 1.0); // 0.0 can cause sparkle/instability
    albedo = max(albedo, float3(0.0));
    alpha = clamp(alpha, 0.0, 1.0);
    if (hasFlag(material.flags, MetalCupMaterialFlags::AlphaMasked)) {
        if (kAlphaToCoverageEnabled) {
            // Preserve the authored cutoff, but remap alpha around it so MSAA can derive per-sample coverage.
            float cutoff = clamp(material.alphaCutoff, 0.0, 1.0);
            float transitionWidth = max(fwidth(alpha), 1e-3);
            float coverageAlpha = smoothstep(cutoff - transitionWidth, cutoff + transitionWidth, alpha);
            if (coverageAlpha <= 0.0) {
                discard_fragment();
            }
            alpha = coverageAlpha;
        } else if (alpha < material.alphaCutoff) {
            discard_fragment();
        }
    }
    float roughnessBeforeSpecAA = roughness;

    // ------------------------------------------------------------
    // View vector (needed for normal filtering bias)
    // ------------------------------------------------------------
    float3 V = normalize(rd.toCamera);
    // ------------------------------------------------------------
    // Normal mapping
    // ------------------------------------------------------------
    float3 N = normalize(rd.surfaceNormal);
    if (hasFlag(material.flags, MetalCupMaterialFlags::HasNormalMap)) {
        float3 Traw = rd.surfaceTangent;
        float3 Braw = rd.surfaceBitangent;
        bool tangentFinite = all(isfinite(Traw)) && all(isfinite(Braw));
        bool tangentOrtho = abs(dot(N, Traw)) < 0.95;
        bool useVertexTangent = tangentFinite && (length(Traw) > 1e-4) && (length(Braw) > 1e-4) && tangentOrtho;
        bool useNormalMap = true;
        float3 T = float3(1.0, 0.0, 0.0);
        float3 B = float3(0.0, 1.0, 0.0);
        if (useVertexTangent) {
            T = Traw;
            B = Braw;
        } else {
            float3 dp1 = dfdx(rd.worldPosition);
            float3 dp2 = dfdy(rd.worldPosition);
            float2 duv1 = dfdx(uv);
            float2 duv2 = dfdy(uv);
            float det = duv1.x * duv2.y - duv1.y * duv2.x;
            if (abs(det) > 1e-6) {
                T = dp1 * duv2.y - dp2 * duv1.y;
                B = -dp1 * duv2.x + dp2 * duv1.x;
                if (length(T) < 1e-4 || length(B) < 1e-4 || !all(isfinite(T)) || !all(isfinite(B))) {
                    useNormalMap = false;
                }
            } else {
                useNormalMap = false;
            }
        }

        if (useNormalMap) {
            T = normalize(T - N * dot(N, T));
            float3 derivedB = cross(N, T);
            float handedness = useVertexTangent ? ((dot(derivedB, B) < 0.0) ? -1.0 : 1.0) : 1.0;
            float3 Bn = normalize(derivedB) * handedness;
            float3x3 TBN = float3x3(T, Bn, N);

            float NdotVBase = max(dot(N, V), 0.0);
            float normalBias = settings.normalMapMipBias + (1.0 - NdotVBase) * settings.normalMapMipBiasGrazing;
            float3 tangentNormal = normalMap.sample(sam, uv, bias(normalBias)).xyz * 2.0 - 1.0;
            if (hasFlag(material.flags, MetalCupMaterialFlags::NormalFlipY)) {
                tangentNormal.y = -tangentNormal.y;
            }
            N = normalize(TBN * tangentNormal);

            if (!disableSpecularAA) {
                // Specular AA (Toksvig-style) using world-space normal variance.
                float3 dndx = dfdx(N);
                float3 dndy = dfdy(N);
                float variance = max(dot(dndx, dndx), dot(dndy, dndy));
                float strength = max(settings.specularAAStrength, 0.0);
                roughness = clamp(sqrt(roughness * roughness + variance * strength), minRoughness, 1.0);
            }
        }
    }
    float roughnessAfterSpecAA = roughness;

    // ------------------------------------------------------------
    // View vector
    // ------------------------------------------------------------
    float NdotV = max(dot(N, V), 0.001);
    float perceptualRoughness = clamp(roughnessAfterSpecAA, minRoughness, 1.0);
    float3 R = normalize(reflect(-V, N));

    // Global IBL brightness now comes from the environment textures plus the single
    // renderer-level IBL intensity control. cameraPositionAndIBL.w is only an availability flag.
    float iblIntensity = (rd.cameraPositionAndIBL.w > 0.5f && settings.iblEnabled != 0)
        ? settings.iblIntensity
        : 0.0f;

    // ------------------------------------------------------------
    // Unlit shortcut
    // ------------------------------------------------------------
    if (hasFlag(material.flags, MetalCupMaterialFlags::IsUnlit)) {
        float3 emissive = material.emissiveColor;
        if (hasFlag(material.flags, MetalCupMaterialFlags::HasEmissiveMap)) {
            half3 emissiveSample = half3(emissiveMap.sample(sam, uv).rgb);
            float3 e = float3(emissiveSample);
            float luminance = dot(e, float3(0.2126, 0.7152, 0.0722));
            float mask = step(0.04, luminance);
            emissive += e * mask;
        }
        emissive *= material.emissiveScalar;
        return shadedMaterialOutput(albedo + emissive, alpha, material);
    }

    // ------------------------------------------------------------
    // Base reflectivity
    // ------------------------------------------------------------
    float3 F0 = mix(float3(0.04), albedo, metallic);
    clearcoat = clamp(clearcoat, 0.0, 1.0);
    clearcoatRoughness = clamp(clearcoatRoughness, minRoughness, 1.0);
    sheenColor = clamp(sheenColor, float3(0.0), float3(1.0));
    float sheenRoughness = clamp(material.sheenRoughness, minRoughness, 1.0);

    // ------------------------------------------------------------
    // Forward+ cluster resolve (3D clustered frustum)
    // ------------------------------------------------------------
    const uint forwardPlusAbiVersion = 1u;
    const uint maxLightsPerCluster = 64u;
    const bool hasForwardPlusBindings = hasFlag(settings.perfFlags, RendererPerfFlags::PerfForwardPlusEnabled)
        && lightGrid != nullptr
        && lightIndexList != nullptr
        && lightIndexHeader != nullptr
        && clusterParams != nullptr
        && clusterParams->abiVersion == forwardPlusAbiVersion
        && lightIndexHeader->abiVersion == forwardPlusAbiVersion;

    uint forwardPlusClusterOffset = 0u;
    uint forwardPlusClusterCount = 0u;
    bool forwardPlusOverflowed = false;
    bool useForwardPlus = false;
    uint forwardPlusClusterIndex = 0u;
    uint forwardPlusClusterZ = 0u;
    uint forwardPlusClusterCountZ = 1u;
    uint forwardPlusTileX = 0u;
    uint forwardPlusTileY = 0u;
    uint forwardPlusClusterCountX = 1u;
    uint forwardPlusClusterCountY = 1u;
    uint forwardPlusTileSizeX = 1u;
    uint forwardPlusTileSizeY = 1u;
    uint forwardPlusViewportX = 1u;
    uint forwardPlusViewportY = 1u;

    uint forwardPlusTileLightCount = 0u;
    uint forwardPlusMaxLightsPerTile = 1u;
    bool forwardPlusTileOverflowed = false;
    const bool hasTileDebugBindings = tileLightGrid != nullptr
        && tileParams != nullptr
        && tileParams->abiVersion == forwardPlusAbiVersion;

    if (hasForwardPlusBindings) {
        const uint clusterCountX = max(clusterParams->clusterCountX, 1u);
        const uint clusterCountY = max(clusterParams->clusterCountY, 1u);
        const uint clusterCountZ = max(clusterParams->clusterCountZ, 1u);
        const uint totalClusterCount = max(clusterParams->totalClusterCount, 1u);

        const uint tileSizeX = max(clusterParams->tileSizeX, 1u);
        const uint tileSizeY = max(clusterParams->tileSizeY, 1u);
        const uint viewportX = max(clusterParams->viewportWidth, 1u);
        const uint viewportY = max(clusterParams->viewportHeight, 1u);

        forwardPlusClusterCountX = clusterCountX;
        forwardPlusClusterCountY = clusterCountY;
        forwardPlusClusterCountZ = clusterCountZ;
        forwardPlusTileSizeX = tileSizeX;
        forwardPlusTileSizeY = tileSizeY;
        forwardPlusViewportX = viewportX;
        forwardPlusViewportY = viewportY;

        const float nearPlane = max(clusterParams->nearPlane, 0.001);
        const float farPlane = max(clusterParams->farPlane, nearPlane + 0.001);
        const float logDepthScale = max(clusterParams->logDepthScale, 1e-6);
        const float logDepthBias = clusterParams->logDepthBias;

        const bool finiteScreenPos = isfinite(rd.position.x) && isfinite(rd.position.y);
        const bool finiteDepth = isfinite(rd.viewDepth);
        if (totalClusterCount > 0u && finiteScreenPos && finiteDepth) {
            const uint pixelX = min(uint(max(rd.position.x, 0.0)), viewportX - 1u);
            const uint pixelY = min(uint(max(rd.position.y, 0.0)), viewportY - 1u);
            const uint tileX = min(pixelX / tileSizeX, clusterCountX - 1u);
            const uint tileY = min(pixelY / tileSizeY, clusterCountY - 1u);
            forwardPlusTileX = tileX;
            forwardPlusTileY = tileY;

            const float viewDepth = clamp(max(rd.viewDepth, nearPlane), nearPlane, farPlane);
            float clusterZf = log2(viewDepth * logDepthScale + logDepthBias);
            if (!isfinite(clusterZf)) {
                clusterZf = 0.0;
            }
            const uint clusterZ = min(uint(max(clusterZf, 0.0)), clusterCountZ - 1u);
            forwardPlusClusterZ = clusterZ;

            const uint sliceStride = clusterCountX * clusterCountY;
            const uint unclampedClusterIndex = tileX + tileY * clusterCountX + clusterZ * sliceStride;
            const uint clusterIndex = min(unclampedClusterIndex, totalClusterCount - 1u);
            forwardPlusClusterIndex = clusterIndex;

            const uint2 entry = lightGrid[clusterIndex];
            const uint maxCapacity = lightIndexHeader->maxIndexCapacity;
            const uint totalIndexCount = min(lightIndexHeader->totalIndexCount, maxCapacity);
            const uint clampedOffset = min(entry.x, totalIndexCount);
            const uint remainingCount = totalIndexCount - clampedOffset;
            const uint clampedCount = min(entry.y, min(remainingCount, maxLightsPerCluster));
            forwardPlusClusterOffset = clampedOffset;
            forwardPlusClusterCount = clampedCount;
            forwardPlusOverflowed = lightIndexHeader->overflowClusterCount > 0u;
            useForwardPlus = true;
        }
    }

    if (hasTileDebugBindings) {
        const uint tileCountX = max(tileParams->tileCountX, 1u);
        const uint tileCountY = max(tileParams->tileCountY, 1u);
        const uint tileSizeX = max(tileParams->tileSizeX, 1u);
        const uint tileSizeY = max(tileParams->tileSizeY, 1u);
        const uint viewportX = max(tileParams->viewportWidth, 1u);
        const uint viewportY = max(tileParams->viewportHeight, 1u);
        const uint maxLightsPerTile = max(tileParams->maxLightsPerTile, 1u);
        const uint pixelX = min(uint(max(rd.position.x, 0.0)), viewportX - 1u);
        const uint pixelY = min(uint(max(rd.position.y, 0.0)), viewportY - 1u);
        const uint tileX = min(pixelX / tileSizeX, tileCountX - 1u);
        const uint tileY = min(pixelY / tileSizeY, tileCountY - 1u);
        const uint tileIndex = tileX + tileY * tileCountX;
        const uint2 tileEntry = tileLightGrid[tileIndex];
        forwardPlusTileLightCount = min(tileEntry.y, maxLightsPerTile);
        forwardPlusMaxLightsPerTile = maxLightsPerTile;
        forwardPlusTileOverflowed = tileEntry.y > maxLightsPerTile;
    }

    // ------------------------------------------------------------
    // Direct lighting (Cook-Torrance BRDF)
    // ------------------------------------------------------------
    float3 Lo = float3(0.0);
    float3 directSpecularLo = float3(0.0);
    float sunVectorAlignment = 0.0;
    float sunVectorAlignmentWeight = -1.0;
    float debugShadowFactor = 1.0;
    float debugShadowCascadeWeight = 0.0;
    float debugShadowBlendWeight = 0.0;
    float debugShadowBiasStress = 0.0;
    bool hasShadowDebugData = false;
    auto accumulateDirectLight = [&](LightData light) {
        float3 L = float3(0.0);
        float attenuation = 1.0;

        if (light.type == LightTypeDirectional) {
            L = normalize(-light.direction);
            float alignmentWeight = max(light.brightness * light.specularIntensity * dot(max(light.color, float3(0.0)), float3(0.2126, 0.7152, 0.0722)), 0.0);
            if (alignmentWeight > sunVectorAlignmentWeight) {
                sunVectorAlignmentWeight = alignmentWeight;
                sunVectorAlignment = pow(saturate(dot(R, L)), 512.0);
            }
        } else {
            float3 toLight = light.position - rd.worldPosition;
            float distance = length(toLight);
            L = toLight / max(distance, 1e-4);
            attenuation = analyticInverseSquareAttenuation(distance, light.range);
            if (light.type == LightTypeSpot) {
                float3 lightDir = normalize(light.direction);
                float spotCos = dot(normalize(-toLight), lightDir);
                attenuation *= analyticSpotAngularFalloff(
                    spotCos,
                    light.innerConeCos,
                    light.outerConeCos
                );
            }
        }

        float3 H = normalize(V + L);
        float NdotL = max(dot(N, L), 0.0);
        float HdotV = max(dot(H, V), 0.0);
        float LdotH = max(dot(L, H), 0.0);

        float3 radiance = light.color * light.brightness * attenuation;

        // Cook-Torrance specular
        float D = PBR::DistributionGGX(N, H, roughness);
        float G = PBR::GeometrySmith(N, V, L, roughness);
        float3 F = PBR::FresnelSchlick(HdotV, F0);
        float3 specular = (D * G * F) / max(4.0 * NdotV * NdotL, 1e-4);

        // Diffuse term (Disney Burley)
        float3 kS_local = F;
        float3 kD_local = (1.0 - kS_local) * (1.0 - metallic);
        float fd90 = 0.5 + 2.0 * roughness * LdotH * LdotH;
        float lightScatter = 1.0 + (fd90 - 1.0) * pow(1.0 - NdotL, 5.0);
        float viewScatter = 1.0 + (fd90 - 1.0) * pow(1.0 - NdotV, 5.0);
        float3 diffuse = (albedo / PBR::PI) * kD_local * lightScatter * viewScatter;

        float3 directDiffuse = diffuse * light.diffuseIntensity;
        float3 directSpecular = specular * light.specularIntensity;
        float3 direct = directDiffuse + directSpecular;

        if (clearcoat > 0.0) {
            float Dcc = PBR::DistributionGGX(N, H, clearcoatRoughness);
            float Gcc = PBR::GeometrySmith(N, V, L, clearcoatRoughness);
            float3 Fcc = PBR::FresnelSchlick(HdotV, float3(0.04));
            float3 clearcoatSpec = (Dcc * Gcc * Fcc) / max(4.0 * NdotV * NdotL, 1e-4);
            // Energy conservation: clearcoat steals from base layer.
            float3 clearcoatEnergy = Fcc * clearcoat;
            direct *= (1.0 - clearcoatEnergy);
            direct += clearcoatSpec * clearcoat * light.specularIntensity;
            directSpecular *= (1.0 - clearcoatEnergy);
            directSpecular += clearcoatSpec * clearcoat * light.specularIntensity;
        }

        if (any(sheenColor > 0.0)) {
            float Dsheen = PBR::DistributionGGX(N, H, sheenRoughness);
            float3 sheenSpec = Dsheen * sheenColor * (1.0 - metallic);
            direct += sheenSpec * 0.5;
            directSpecular += sheenSpec * 0.5;
        }

        float shadowFactor = 1.0;
        bool ownsDirectionalShadowMap = light.type == LightTypeDirectional
            && (light.flags & LightDataFlagDirectionalShadowCaster) != 0u;
        if (ownsDirectionalShadowMap) {
            shadowFactor = computeShadowFactor(rd.worldPosition, N, L, rd.viewDepth, shadows, shadowMap, shadowDepthSampler, shadowCompareSampler);
            if (!hasShadowDebugData) {
                uint shadowCascadeCount = uint(shadows.shadowMapInvSizeAndCount.z + 0.5);
                float shadowMetric = max(rd.viewDepth, 0.001);
                int shadowCascadeIndex = (shadowCascadeCount > 0u) ? selectShadowCascadeByMetric(shadowMetric, shadows) : 0;
                float cascadeNormDenom = max(float(max(int(shadowCascadeCount), 1) - 1), 1.0);
                float cascadeNorm = float(shadowCascadeIndex) / cascadeNormDenom;
                float blendWeight = 0.0;
                if (shadowCascadeIndex + 1 < int(shadowCascadeCount)) {
                    float splitFar = cascadeSplitDistance(shadows, shadowCascadeIndex);
                    float blendWidth = cascadeBlendWidth(shadows, shadowCascadeIndex);
                    if (blendWidth > 0.0) {
                        float blendStart = splitFar - blendWidth;
                        blendWeight = smoothstep(blendStart, splitFar, shadowMetric);
                    }
                }
                debugShadowFactor = shadowFactor;
                debugShadowCascadeWeight = cascadeNorm;
                debugShadowBlendWeight = blendWeight;
                debugShadowBiasStress = shadowBiasStressForCascade(N, L, shadowCascadeIndex, shadows);
                hasShadowDebugData = true;
            }
        }
        Lo += direct * radiance * NdotL * shadowFactor;
        directSpecularLo += directSpecular * radiance * NdotL * shadowFactor;
    };

    if (useForwardPlus) {
        for (uint i = 0u; i < forwardPlusClusterCount; ++i) {
            const uint lightIndex = lightIndexList[forwardPlusClusterOffset + i];
            if (lightIndex >= uint(max(lightCount, 0))) {
                continue;
            }
            accumulateDirectLight(lightDatas[lightIndex]);
        }
    } else {
        for (int i = 0; i < lightCount; ++i) {
            accumulateDirectLight(lightDatas[i]);
        }
    }

    for (int i = 0; i < directionalLightCount; ++i) {
        accumulateDirectLight(directionalLightDatas[i]);
    }

    // ------------------------------------------------------------
    // Diffuse IBL
    // ------------------------------------------------------------
    float3 diffuseIBL = float3(0.0);
    if (iblIntensity > 0.0) {
        float3 irradiance = irradianceMap.sample(iblSam, N).rgb;
        diffuseIBL = irradiance * (albedo / PBR::PI) * iblIntensity;
    }

    // Energy conservation split
    float3 F_ibl = PBR::FresnelSchlick(NdotV, F0);
    // Conservative dielectric grazing behavior: keep physical rise to F90 with mild damping on very rough surfaces.
    float3 dielectricF = PBR::FresnelSchlick(NdotV, float3(0.04));
    float dielectricGrazingDamp = mix(1.0, 0.9, perceptualRoughness * perceptualRoughness);
    dielectricF = mix(float3(0.04), dielectricF, dielectricGrazingDamp);
    F_ibl = mix(dielectricF, F_ibl, metallic);

    float3 kS = F_ibl;
    float3 kD = (1.0 - kS) * (1.0 - metallic);

    float sceneAOVisibility = 1.0;
    if (settings.ssaoEnabled != 0u) {
        uint2 sceneAODim = uint2(sceneAOTexture.get_width(), sceneAOTexture.get_height());
        uint2 sceneAOPixel = uint2(clamp(rd.position.xy, float2(0.0), float2(sceneAODim) - 1.0));
        // sceneAOTexture stores visibility: 1.0 = open, 0.0 = occluded.
        sceneAOVisibility = sceneAOTexture.read(sceneAOPixel).r;
    }
    float combinedAOVisibility = saturate(ao * sceneAOVisibility);

    // Apply material AO and filtered screen-space AO visibility to indirect lighting only.
    float3 ambient = kD * diffuseIBL * combinedAOVisibility;

    // ------------------------------------------------------------
    // Specular IBL (prefilter + BRDF LUT)
    // ------------------------------------------------------------
    float3 specularIBL = float3(0.0);
    float maxMip = 0.0;
    float mipLevel = 0.0;
    float localProbeWeight = saturate(localReflectionProbe.probePositionAndWeight.w);
    bool localProbeEnabled = localReflectionProbe.intensityAndFlags.y > 0.5;
    bool localProbeParallaxCorrectionEnabled = !hasFlag(settings.perfFlags, RendererPerfFlags::PerfDisableLocalProbeParallaxCorrection);
    float brdfRoughness = clamp(perceptualRoughness, minRoughness, 1.0);
    float globalMipLevel = 0.0;
    float globalMaxMip = 0.0;
    float3 globalSpecularIBL = computeSplitSumSpecularIBL(
        prefilteredMap,
        brdf_lut,
        iblSam,
        R,
        brdfRoughness,
        NdotV,
        F0,
        iblIntensity,
        globalMipLevel,
        globalMaxMip
    );
    bool hasLocalProbeSpecular = iblIntensity > 0.0
        && localProbeEnabled
        && localProbeWeight > 0.0
        && localReflectionPrefilteredMap.get_num_mip_levels() > 1;
    float3 localSpecularIBL = float3(0.0);
    float3 localProbeSpecularR = R;
    if (hasLocalProbeSpecular) {
        if (localProbeParallaxCorrectionEnabled
            && !computeParallaxCorrectedLocalProbeDirection(localReflectionProbe,
                                                            rd.worldPosition,
                                                            R,
                                                            localProbeSpecularR)) {
            localProbeSpecularR = R;
        }
        float localProbeMipLevel = 0.0;
        float localProbeMaxMip = 0.0;
        localSpecularIBL = computeSplitSumSpecularIBL(
            localReflectionPrefilteredMap,
            brdf_lut,
            iblSam,
            localProbeSpecularR,
            brdfRoughness,
            NdotV,
            F0,
            1.0,
            localProbeMipLevel,
            localProbeMaxMip
        );
    }
    specularIBL = hasLocalProbeSpecular ? mix(globalSpecularIBL, localSpecularIBL, localProbeWeight) : globalSpecularIBL;
    mipLevel = globalMipLevel;
    maxMip = globalMaxMip;

    if (iblIntensity > 0.0 && globalMaxMip > 0.0) {
        // Clearcoat IBL lobe (same split-sum path, fixed dielectric F0).
        if (clearcoat > 0.0) {
            float ccRoughness = clamp(clearcoatRoughness, minRoughness, 1.0);
            float ccGlobalMipLevel = 0.0;
            float ccGlobalMaxMip = 0.0;
            float3 ccF0 = float3(0.04);
            float3 clearcoatIBLGlobal = computeSplitSumSpecularIBL(
                prefilteredMap,
                brdf_lut,
                iblSam,
                R,
                ccRoughness,
                NdotV,
                ccF0,
                iblIntensity * clearcoat,
                ccGlobalMipLevel,
                ccGlobalMaxMip
            );
            float3 clearcoatIBL = clearcoatIBLGlobal;
            if (hasLocalProbeSpecular) {
                float ccLocalMipLevel = 0.0;
                float ccLocalMaxMip = 0.0;
                float3 clearcoatIBLLocal = computeSplitSumSpecularIBL(
                    localReflectionPrefilteredMap,
                    brdf_lut,
                    iblSam,
                    localProbeSpecularR,
                    ccRoughness,
                    NdotV,
                    ccF0,
                    clearcoat,
                    ccLocalMipLevel,
                    ccLocalMaxMip
                );
                clearcoatIBL = mix(clearcoatIBLGlobal, clearcoatIBLLocal, localProbeWeight);
            }
            float3 FccIbl = PBR::FresnelSchlick(NdotV, ccF0);
            float3 clearcoatAttenuation = clamp(1.0 - FccIbl * clearcoat, 0.0, 1.0);
            ambient *= clearcoatAttenuation;
            specularIBL *= clearcoatAttenuation;
            specularIBL += clearcoatIBL;
        }

        // Sheen IBL contribution (subtle, non-metallic fabrics).
        if (any(sheenColor > 0.0)) {
            float sheenIblRoughness = clamp(sheenRoughness, minRoughness, 1.0);
            float sheenGlobalMipLevel = 0.0;
            float sheenGlobalMaxMip = 0.0;
            float3 sheenPrefilteredGlobal = samplePrefilteredColor(
                prefilteredMap,
                iblSam,
                R,
                sheenIblRoughness,
                sheenGlobalMipLevel,
                sheenGlobalMaxMip
            );
            float sheenRim = pow(1.0 - NdotV, 5.0);
            float sheenStrength = clamp((0.15 + 0.85 * sheenRim) * (1.0 - metallic), 0.0, 0.5);
            float3 sheenIBLGlobal = sheenPrefilteredGlobal * sheenColor * sheenStrength * iblIntensity;
            sheenIBLGlobal = min(sheenIBLGlobal, sheenPrefilteredGlobal * 0.25);
            float3 sheenIBL = sheenIBLGlobal;
            if (hasLocalProbeSpecular) {
                float sheenLocalMipLevel = 0.0;
                float sheenLocalMaxMip = 0.0;
                float3 sheenPrefilteredLocal = samplePrefilteredColor(
                    localReflectionPrefilteredMap,
                    iblSam,
                    localProbeSpecularR,
                    sheenIblRoughness,
                    sheenLocalMipLevel,
                    sheenLocalMaxMip
                );
                float3 sheenIBLLocal = sheenPrefilteredLocal * sheenColor * sheenStrength;
                sheenIBLLocal = min(sheenIBLLocal, sheenPrefilteredLocal * 0.25);
                sheenIBL = mix(sheenIBLGlobal, sheenIBLLocal, localProbeWeight);
            }
            specularIBL += sheenIBL;
        }
    }
    if (hasFlag(settings.perfFlags, RendererPerfFlags::PerfSkipSpecIBLHighRoughness) && roughness > 0.9) {
        specularIBL = float3(0.0);
    }

    // Specular occlusion (specular IBL only), stabilized to preserve smooth-metal reflections.
    float specOcclusion = 1.0;
    if (combinedAOVisibility < 1.0) {
        float occlusionBase = pow(max(NdotV + combinedAOVisibility, 1e-4), exp2(-16.0 * perceptualRoughness - 1.0));
        specOcclusion = saturate(occlusionBase - 1.0 + combinedAOVisibility);
        float smoothFactor = (1.0 - perceptualRoughness);
        smoothFactor *= smoothFactor;
        float metallicFactor = mix(0.4, 1.0, metallic);
        float minSpecOcclusion = mix(combinedAOVisibility, 1.0, smoothFactor * metallicFactor);
        specOcclusion = clamp(max(specOcclusion, minSpecOcclusion), 0.0, 1.0);
    }
    specularIBL *= specOcclusion;

    // ------------------------------------------------------------
    // Emissive (additive, unlit)
    // ------------------------------------------------------------
    float3 emissiveColor = material.emissiveColor;
    if (hasFlag(material.flags, MetalCupMaterialFlags::HasEmissiveMap)) {
        half3 emissiveSample = half3(emissiveMap.sample(sam, uv).rgb);
        float3 e = float3(emissiveSample);
        float luminance = dot(e, float3(0.2126, 0.7152, 0.0722));
        float mask = step(0.04, luminance);
        emissiveColor += e * mask;
    }
    emissiveColor *= emissiveScalar;

    // ------------------------------------------------------------
    // Debug Views
    // ------------------------------------------------------------
    bool applyDebug = kEnableDebug && settings.shadingDebugMode != DebugOff;

    if (applyDebug) {
        bool normalInvalid = !all(isfinite(N)) || length(N) < 1e-4;
        if (normalInvalid) {
            return float4(1.0, 0.0, 1.0, 1.0);
        }
        float3 debugColor = float3(0.0);
        auto saturate1 = [](float v) -> float { return clamp(v, 0.0, 1.0); };
        auto toGray = [&](float v) -> float3 { float s = saturate1(v); return float3(s, s, s); };
        auto heatmapColor = [&](float t) -> float3 {
            float x = saturate1(t);
            if (x <= 0.0) {
                return float3(0.0);
            }
            if (x < 0.25) {
                return mix(float3(0.0, 0.0, 0.0), float3(0.0, 0.2, 1.0), x / 0.25);
            }
            if (x < 0.5) {
                return mix(float3(0.0, 0.2, 1.0), float3(0.0, 1.0, 0.0), (x - 0.25) / 0.25);
            }
            if (x < 0.75) {
                return mix(float3(0.0, 1.0, 0.0), float3(1.0, 1.0, 0.0), (x - 0.5) / 0.25);
            }
            return mix(float3(1.0, 1.0, 0.0), float3(1.0, 0.0, 0.0), (x - 0.75) / 0.25);
        };
        auto computeGeometricWorldNormal = [&]() -> float3 {
            float3 dx = dfdx(rd.worldPosition);
            float3 dy = dfdy(rd.worldPosition);
            float3 n = normalize(cross(dx, dy));
            bool invalid = !all(isfinite(n)) || length(n) < 1e-4;
            if (invalid) {
                float3 dxView = dfdx(rd.viewPosition);
                float3 dyView = dfdy(rd.viewPosition);
                float3 nView = normalize(cross(dxView, dyView));
                if (all(isfinite(nView)) && length(nView) >= 1e-4) {
                    n = nView;
                }
            }
            if (!all(isfinite(n)) || length(n) < 1e-4) {
                n = float3(0.0, 0.0, 1.0);
            }
            // Ensure consistent orientation with shaded normal
            if (dot(n, N) < 0.0) n = -n;
            return n;
        };
        if (settings.shadingDebugMode == DebugWorldNormal) {
            debugColor = N * 0.5 + 0.5;
        } else if (settings.shadingDebugMode == DebugGeometricWorldNormal) {
            float3 N_geom = computeGeometricWorldNormal();
            debugColor = N_geom * 0.5 + 0.5;
        } else if (settings.shadingDebugMode == DebugNormalMismatch) {
            float3 N_geom = computeGeometricWorldNormal();
            float align = max(dot(normalize(N), normalize(N_geom)), 0.0);
            debugColor = toGray(align);
        } else if (settings.shadingDebugMode == DebugToCameraMismatch) {
            float3 V_a = normalize(rd.toCamera);
            float3 V_b = normalize(rd.cameraPositionAndIBL.xyz - rd.worldPosition);
            float d = dot(V_a, V_b);
            debugColor = toGray(d);
        } else if (settings.shadingDebugMode == DebugReflection) {
            debugColor = R * 0.5 + 0.5;
        } else if (settings.shadingDebugMode == DebugRoughness) {
            debugColor = float3(roughnessAfterSpecAA);
        } else if (settings.shadingDebugMode == DebugMetallic) {
            debugColor = float3(metallic);
        } else if (settings.shadingDebugMode == DebugNdotV) {
            debugColor = float3(NdotV);
        } else if (settings.shadingDebugMode == DebugSpecularMip) {
            float mipNorm = (maxMip > 0.0) ? (mipLevel / maxMip) : 0.0;
            debugColor = float3(mipNorm);
        } else if (settings.shadingDebugMode == DebugDiffuseIBL) {
            debugColor = ambient;
        } else if (settings.shadingDebugMode == DebugSpecularIBL) {
            debugColor = specularIBL;
        } else if (settings.shadingDebugMode == DebugGlobalSpecularIBL) {
            debugColor = globalSpecularIBL;
        } else if (settings.shadingDebugMode == DebugLocalSpecularIBL) {
            debugColor = hasLocalProbeSpecular ? localSpecularIBL : float3(0.0);
        } else if (settings.shadingDebugMode == DebugLocalProbeWeight) {
            debugColor = float3(hasLocalProbeSpecular ? localProbeWeight : 0.0);
        } else if (settings.shadingDebugMode == DebugDirectLighting) {
            debugColor = Lo;
        } else if (settings.shadingDebugMode == DebugDirectSpecularOnly) {
            debugColor = directSpecularLo;
        } else if (settings.shadingDebugMode == DebugSunVectorAlignment) {
            debugColor = float3(sunVectorAlignment);
        } else if (settings.shadingDebugMode == DebugDirectPlusGlobalSpecular) {
            debugColor = Lo + globalSpecularIBL;
        } else if (settings.shadingDebugMode == DebugDirectPlusLocalSpecular) {
            debugColor = Lo + (hasLocalProbeSpecular ? localSpecularIBL : float3(0.0));
        } else if (settings.shadingDebugMode == DebugDirectPlusMixedSpecular) {
            debugColor = Lo + specularIBL;
        } else if (settings.shadingDebugMode == DebugLightHeatmap) {
            const float maxPerCluster = max(float(maxLightsPerCluster), 1.0);
            const float normalizedCount = useForwardPlus
                ? min(float(forwardPlusClusterCount) / maxPerCluster, 1.0)
                : 0.0;
            debugColor = heatmapColor(normalizedCount);
            const bool nearOverflow = useForwardPlus && forwardPlusClusterCount + 2u >= maxLightsPerCluster;
            if (nearOverflow) {
                debugColor = max(debugColor, float3(1.0, 0.0, 0.0));
            }
            if (useForwardPlus && forwardPlusOverflowed) {
                debugColor = float3(1.0, 0.0, 1.0);
            }
        } else if (settings.shadingDebugMode == DebugClusterZSlice) {
            if (!useForwardPlus) {
                debugColor = float3(0.0);
            } else {
                float zNorm = (forwardPlusClusterCountZ > 1u)
                    ? (float(forwardPlusClusterZ) / float(forwardPlusClusterCountZ - 1u))
                    : 0.0;
                debugColor = heatmapColor(zNorm);
            }
        } else if (settings.shadingDebugMode == DebugClusterGrid) {
            if (!hasForwardPlusBindings) {
                debugColor = float3(0.0);
            } else {
                const float2 frag = float2(rd.position.x, rd.position.y);
                const float2 tileSize = float2(float(forwardPlusTileSizeX), float(forwardPlusTileSizeY));
                const float2 gridUV = frag / tileSize;
                const float2 gridFrac = fract(gridUV);
                const float2 edgeDist = min(gridFrac, 1.0 - gridFrac);
                const float2 edgeWidth = max(fwidth(gridUV), float2(1e-4));
                const float lineX = 1.0 - smoothstep(0.0, edgeWidth.x * 1.25, edgeDist.x);
                const float lineY = 1.0 - smoothstep(0.0, edgeWidth.y * 1.25, edgeDist.y);
                float gridLine = max(lineX, lineY);

                float majorLine = 0.0;
                if (((forwardPlusTileX + 1u) % 4u) == 0u) {
                    majorLine = max(majorLine, lineX);
                }
                if (((forwardPlusTileY + 1u) % 4u) == 0u) {
                    majorLine = max(majorLine, lineY);
                }

                float zNorm = (forwardPlusClusterCountZ > 1u)
                    ? (float(forwardPlusClusterZ) / float(forwardPlusClusterCountZ - 1u))
                    : 0.0;
                float3 base = heatmapColor(zNorm) * 0.2;
                float3 minor = float3(0.85);
                float3 major = float3(1.0, 0.85, 0.2);
                debugColor = base;
                debugColor = mix(debugColor, minor, saturate1(gridLine));
                debugColor = mix(debugColor, major, saturate1(majorLine));
            }
        } else if (settings.shadingDebugMode == DebugTileLightCount) {
            const float maxPerTile = max(float(forwardPlusMaxLightsPerTile), 1.0);
            const float normalizedCount = min(float(forwardPlusTileLightCount) / maxPerTile, 1.0);
            debugColor = heatmapColor(normalizedCount);
            const bool nearOverflow = forwardPlusTileLightCount + 2u >= forwardPlusMaxLightsPerTile;
            if (nearOverflow) {
                debugColor = max(debugColor, float3(1.0, 0.0, 0.0));
            }
            if (forwardPlusTileOverflowed) {
                debugColor = float3(1.0, 0.0, 1.0);
            }
        } else if (settings.shadingDebugMode == DebugShadowCascadeIndex) {
            debugColor = hasShadowDebugData ? heatmapColor(debugShadowCascadeWeight) : float3(0.0);
        } else if (settings.shadingDebugMode == DebugShadowCascadeBlend) {
            debugColor = hasShadowDebugData ? float3(debugShadowBlendWeight, 1.0 - debugShadowBlendWeight, 0.0) : float3(0.0);
        } else if (settings.shadingDebugMode == DebugShadowFactor) {
            debugColor = hasShadowDebugData ? toGray(1.0 - debugShadowFactor) : float3(0.0);
        } else if (settings.shadingDebugMode == DebugShadowBiasStress) {
            float normalizedStress = min(debugShadowBiasStress / 4.0, 1.0);
            debugColor = hasShadowDebugData ? heatmapColor(normalizedStress) : float3(0.0);
        } else if (settings.shadingDebugMode == DebugRoughnessBeforeAA) {
            debugColor = float3(roughnessBeforeSpecAA);
        } else if (settings.shadingDebugMode == DebugRoughnessAfterAA) {
            debugColor = float3(roughnessAfterSpecAA);
        } else if (settings.shadingDebugMode == DebugMaterialValidation) {
            float materialFallback = hasFlag(material.flags, MetalCupMaterialFlags::UsesFallbackMaterial) ? 1.0 : 0.0;
            float baseColorReal = hasFlag(material.flags, MetalCupMaterialFlags::HasBaseColorMap) ? 1.0 : 0.0;
            float iblReal = (iblIntensity > 0.0) ? 1.0 : 0.0;
            float shadowReal = (shadows.shadowCasterDirectionAndEnabled.w > 0.5 && shadows.shadowMapInvSizeAndCount.z > 0.5) ? 1.0 : 0.0;
            return float4(float3(materialFallback, baseColorReal, iblReal), shadowReal);
        }
        return shadedMaterialOutput(debugColor, alpha, material);
    }
    // ------------------------------------------------------------
    // Combine
    // ------------------------------------------------------------
    float3 color = Lo + ambient + specularIBL + emissiveColor;
    return shadedMaterialOutput(color, alpha, material);
}

static inline void applyAlphaClip(RasterizerData rd,
                                  constant MetalCupMaterial &material,
                                  sampler sam,
                                  texture2d<float> albedoMap) {
    // Depth prepass and shadow passes intentionally keep binary alpha clip for now.
    if (!hasFlag(material.flags, MetalCupMaterialFlags::AlphaMasked)) {
        return;
    }
    float2 uv = rd.texCoord * material.uvTiling + material.uvOffset;
    float alpha = clamp(material.baseColorAlpha, 0.0, 1.0);
    if (hasFlag(material.flags, MetalCupMaterialFlags::HasBaseColorMap)) {
        alpha *= albedoMap.sample(sam, uv).a;
    }
    if (alpha < material.alphaCutoff) {
        discard_fragment();
    }
}

static inline float3 geometricViewNormal(RasterizerData rd, bool frontFacing) {
    float3 dpdx = dfdx(rd.viewPosition);
    float3 dpdy = dfdy(rd.viewPosition);
    float3 normal = cross(dpdx, dpdy);
    float lengthSquared = dot(normal, normal);
    if (lengthSquared <= 1e-12) {
        normal = float3(0.0, 0.0, 1.0);
    } else {
        normal *= rsqrt(lengthSquared);
    }
    return frontFacing ? normal : -normal;
}

fragment float2 fragment_scene_normals(RasterizerData rd [[ stage_in ]],
                                       bool frontFacing [[ front_facing ]]) {
    return encodeOctahedralNormal(geometricViewNormal(rd, frontFacing));
}

fragment float2 fragment_scene_normals_alpha(RasterizerData rd [[ stage_in ]],
                                             bool frontFacing [[ front_facing ]],
                                             constant MetalCupMaterial &material [[ buffer(FragmentBufferIndexMaterial) ]],
                                             sampler sam [[ sampler(FragmentSamplerIndexLinear) ]],
                                             texture2d<float> albedoMap [[ texture(FragmentTextureIndexAlbedo) ]]) {
    applyAlphaClip(rd, material, sam, albedoMap);
    return encodeOctahedralNormal(geometricViewNormal(rd, frontFacing));
}

fragment float2 fragment_ao_normals(RasterizerData rd [[ stage_in ]],
                                      constant SceneConstants &sceneConstants [[ buffer(FragmentBufferIndexPostProcessSceneConstants) ]]) {
    float3 smoothViewNormal = worldNormalToView(normalize(rd.surfaceNormal), sceneConstants);
    return encodeOctahedralNormal(smoothViewNormal);
}

fragment float2 fragment_ao_normals_alpha(RasterizerData rd [[ stage_in ]],
                                            constant SceneConstants &sceneConstants [[ buffer(FragmentBufferIndexPostProcessSceneConstants) ]],
                                            constant MetalCupMaterial &material [[ buffer(FragmentBufferIndexMaterial) ]],
                                            sampler sam [[ sampler(FragmentSamplerIndexLinear) ]],
                                            texture2d<float> albedoMap [[ texture(FragmentTextureIndexAlbedo) ]]) {
    applyAlphaClip(rd, material, sam, albedoMap);
    float3 smoothViewNormal = worldNormalToView(normalize(rd.surfaceNormal), sceneConstants);
    return encodeOctahedralNormal(smoothViewNormal);
}

fragment void fragment_depth_alpha(RasterizerData rd [[ stage_in ]],
                                   constant MetalCupMaterial &material [[ buffer(FragmentBufferIndexMaterial) ]],
                                   sampler sam [[ sampler(FragmentSamplerIndexLinear) ]],
                                  texture2d<float> albedoMap [[ texture(FragmentTextureIndexAlbedo) ]]) {
    applyAlphaClip(rd, material, sam, albedoMap);
}

fragment void fragment_shadow_alpha(RasterizerData rd [[ stage_in ]],
                                   constant MetalCupMaterial &material [[ buffer(FragmentBufferIndexMaterial) ]],
                                   sampler sam [[ sampler(FragmentSamplerIndexLinear) ]],
                                   texture2d<float> albedoMap [[ texture(FragmentTextureIndexAlbedo) ]]) {
    applyAlphaClip(rd, material, sam, albedoMap);
}

/// Test-only ABI probe compiled through the canonical production shader path.
kernel void phase2_shadow_owner_samples(const device LightData *lights [[ buffer(0) ]],
                                        device float4 *results [[ buffer(1) ]],
                                        uint sampleIndex [[ thread_position_in_grid ]]) {
    LightData light = lights[sampleIndex];
    bool ownsMap = light.type == LightTypeDirectional
        && (light.flags & LightDataFlagDirectionalShadowCaster) != 0u;
    results[sampleIndex] = float4(ownsMap ? 1.0 : 0.0,
                                  float(light.flags),
                                  float(light.type),
                                  1.0);
}

struct Phase2ShadowTestVertexOutput {
    float4 position [[ position ]];
};

/// Minimal canonical-path depth writer used for offscreen shadow-map occupancy tests.
vertex Phase2ShadowTestVertexOutput phase2_shadow_test_vertex(
    const device float4 *positions [[ buffer(0) ]],
    uint vertexIndex [[ vertex_id ]]) {
    Phase2ShadowTestVertexOutput output;
    output.position = positions[vertexIndex];
    return output;
}

/// Hard-shadow reference using the same conventional-depth relationship as shadow triage.
kernel void phase2_hard_shadow_receiver_samples(
    depth2d_array<float, access::sample> shadowMap [[ texture(0) ]],
    sampler shadowSampler [[ sampler(0) ]],
    const device float4 *samples [[ buffer(0) ]],
    device float4 *results [[ buffer(1) ]],
    uint sampleIndex [[ thread_position_in_grid ]]) {
    float4 sample = samples[sampleIndex];
    uint layer = uint(max(sample.z, 0.0) + 0.5);
    float storedDepth = shadowMap.sample(shadowSampler, sample.xy, layer);
    float visibility = (storedDepth + 1e-4 < sample.w) ? 0.0 : 1.0;
    results[sampleIndex] = float4(storedDepth, sample.w, visibility, float(layer));
}

kernel void phase2_shadow_bias_and_cascade_samples(
    const device float4 *normals [[ buffer(0) ]],
    const device float4 *surfaceToLights [[ buffer(1) ]],
    const device float *viewDepths [[ buffer(2) ]],
    constant ShadowConstants &shadows [[ buffer(3) ]],
    device float4 *results [[ buffer(4) ]],
    uint sampleIndex [[ thread_position_in_grid ]]) {
    float3 normal = normals[sampleIndex].xyz;
    float3 surfaceToLight = surfaceToLights[sampleIndex].xyz;
    float facing = shadowReceiverLightFacing(normal, surfaceToLight);
    float biasScale = shadowReceiverDepthBiasScale(normal, surfaceToLight);
    int cascade = selectShadowCascadeByMetric(max(viewDepths[sampleIndex], 0.001), shadows);
    results[sampleIndex] = float4(facing, biasScale, float(cascade), 1.0);
}

kernel void phase2_analytic_light_contract_samples(
    const device float4 *samples [[ buffer(0) ]],
    const device float2 *coneCosines [[ buffer(1) ]],
    device float4 *results [[ buffer(2) ]],
    uint sampleIndex [[ thread_position_in_grid ]]) {
    float distance = samples[sampleIndex].x;
    float range = samples[sampleIndex].y;
    float spotCos = samples[sampleIndex].z;
    float illuminance = samples[sampleIndex].w;
    float2 cone = coneCosines[sampleIndex];
    float rangeFade = analyticRangeFade(distance, range);
    float attenuation = analyticInverseSquareAttenuation(distance, range);
    float spot = analyticSpotAngularFalloff(spotCos, cone.y, cone.x);
    float lambertian = max(illuminance, 0.0) / PBR::PI;
    results[sampleIndex] = float4(attenuation, rangeFade, spot, lambertian);
}

kernel void phase2_direct_pbr_reference_samples(
    const device float4 *samples [[ buffer(0) ]],
    const device float4 *baseColors [[ buffer(1) ]],
    device float4 *results [[ buffer(2) ]],
    uint sampleIndex [[ thread_position_in_grid ]]) {
    float normalDotHalf = samples[sampleIndex].x;
    float roughness = clamp(samples[sampleIndex].y, 0.06, 1.0);
    float metallic = saturate(samples[sampleIndex].z);
    float3 f0 = mix(float3(0.04), max(baseColors[sampleIndex].rgb, float3(0.0)), metallic);
    float distribution = PBR::DistributionGGX(
        float3(0.0, 1.0, 0.0),
        normalize(float3(sqrt(max(1.0 - normalDotHalf * normalDotHalf, 0.0)), normalDotHalf, 0.0)),
        roughness
    );
    results[sampleIndex] = float4(distribution, f0);
}
