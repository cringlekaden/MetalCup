// Shared.metal
// Shared shader types and binding indices.
// Created by Kaden Cringle


#ifndef SHARED_METAL
#define SHARED_METAL

#include <metal_stdlib>
using namespace metal;

// NOTE: Keep these binding indices mirrored in ShaderBindings.swift.

// Canonical MetalCup world-space cubemap contract. World space is right-handed,
// +Y is up, and unrotated authored forward is local -Z. Metal cube slices are
// +X, -X, +Y, -Y, +Z, -Z. Capture, convolution, global sampling, and local
// reflection probes all use this mapping without path-specific axis flips.
inline float3 cubeDirectionFromFaceUV(uint face, float2 uv) {
    float2 st = uv * 2.0 - 1.0;
    float2 faceUV = float2(st.x, -st.y);
    float3 dir;
    switch (face) {
        case 0u: dir = float3( 1.0,      faceUV.y, -faceUV.x); break; // +X
        case 1u: dir = float3(-1.0,      faceUV.y,  faceUV.x); break; // -X
        case 2u: dir = float3( faceUV.x, 1.0,     -faceUV.y); break; // +Y
        case 3u: dir = float3( faceUV.x,-1.0,      faceUV.y); break; // -Y
        case 4u: dir = float3( faceUV.x, faceUV.y, 1.0);      break; // +Z
        default: dir = float3(-faceUV.x, faceUV.y,-1.0);      break; // -Z
    }
    return normalize(dir);
}

inline float2 equirectangularUVFromWorldDirection(float3 worldDirection) {
    float3 direction = normalize(worldDirection);
    // Longitude is undefined at the poles. Pin it to the +Z meridian there so
    // HDRI conversion remains finite and agrees with the CPU convention.
    float longitude = dot(direction.xz, direction.xz) > 1e-12
        ? atan2(direction.x, direction.z)
        : 0.0;
    float latitude = asin(clamp(direction.y, -1.0, 1.0));
    return float2(longitude / (2.0 * M_PI_F) + 0.5,
                  0.5 - latitude / M_PI_F);
}

enum VertexBufferIndex {
    VertexBufferIndexVertices = 0,
    VertexBufferIndexSceneConstants = 1,
    VertexBufferIndexModelConstants = 2,
    VertexBufferIndexInstances = 3,
    VertexBufferIndexBonePalette = 4,
    VertexBufferIndexCloudImpostorParams = 5,
    VertexBufferIndexCubemapVP = 1
};

enum FragmentBufferIndex {
    FragmentBufferIndexMaterial = 1,
    FragmentBufferIndexRendererSettings = 2,
    FragmentBufferIndexLightCount = 3,
    FragmentBufferIndexLightData = 4,
    FragmentBufferIndexIBLParams = 0,
    FragmentBufferIndexSkyParams = 0,
    FragmentBufferIndexSkyIntensity = 0,
    FragmentBufferIndexSkyFace = 21,
    FragmentBufferIndexOutlineParams = 5,
    FragmentBufferIndexGridParams = 6,
    FragmentBufferIndexShadowConstants = 7,
    FragmentBufferIndexLightGrid = 8,
    FragmentBufferIndexLightIndexList = 9,
    FragmentBufferIndexLightIndexCount = 10,
    FragmentBufferIndexLightClusterParams = 11,
    FragmentBufferIndexTileLightGrid = 12,
    FragmentBufferIndexTileParams = 13,
    FragmentBufferIndexDirectionalLightCount = 14,
    FragmentBufferIndexDirectionalLightData = 15,
    FragmentBufferIndexViewExposure = 16,
    FragmentBufferIndexPostProcessDebugFlags = 17,
    FragmentBufferIndexPostProcessSceneConstants = 18,
    FragmentBufferIndexPostProcessParams = 19,
    FragmentBufferIndexLocalReflectionProbe = 20,
    FragmentBufferIndexCloudImpostorParams = 22,
    FragmentBufferIndexGlobalIBLBlend = 23
};

enum FragmentTextureIndex {
    FragmentTextureIndexAlbedo = 0,
    FragmentTextureIndexNormal = 1,
    FragmentTextureIndexMetallic = 2,
    FragmentTextureIndexRoughness = 3,
    FragmentTextureIndexMetalRoughness = 4,
    FragmentTextureIndexAO = 5,
    FragmentTextureIndexEmissive = 6,
    FragmentTextureIndexIrradiance = 7,
    FragmentTextureIndexPrefiltered = 8,
    FragmentTextureIndexBRDFLUT = 9,
    FragmentTextureIndexClearcoat = 10,
    FragmentTextureIndexClearcoatRoughness = 11,
    FragmentTextureIndexSheenColor = 12,
    FragmentTextureIndexSheenIntensity = 13,
    FragmentTextureIndexSkybox = 14,
    FragmentTextureIndexShadowMap = 15,
    FragmentTextureIndexShadowMapSample = 16,
    FragmentTextureIndexORM = 17,
    FragmentTextureIndexSceneAO = 18,
    FragmentTextureIndexLocalReflectionPrefiltered = 19,
    FragmentTextureIndexMoonAlbedo = 20,
    FragmentTextureIndexGalaxyBackground = 21,
    FragmentTextureIndexCloudAtlas = 22,
    FragmentTextureIndexCloudCard = 23,
    FragmentTextureIndexIncomingIrradiance = 24,
    FragmentTextureIndexIncomingPrefiltered = 25
};

enum FragmentSamplerIndex {
    FragmentSamplerIndexLinear = 0,
    FragmentSamplerIndexLinearClamp = 1,
    FragmentSamplerIndexShadowCompare = 2,
    FragmentSamplerIndexShadowDepth = 3
};

enum PostProcessTextureIndex {
    PostProcessTextureIndexSource = 0,
    PostProcessTextureIndexBloom = 1,
    PostProcessTextureIndexOutlineMask = 2,
    PostProcessTextureIndexDepth = 3,
    PostProcessTextureIndexGrid = 4,
    PostProcessTextureIndexReserved5 = 5,
    PostProcessTextureIndexNormals = 6,
    PostProcessTextureIndexSSAORaw = 7,
    PostProcessTextureIndexSSAOFiltered = 8,
    PostProcessTextureIndexDepthHierarchy = 9,
    PostProcessTextureIndexAONormals = 10,
    PostProcessTextureIndexWorldDebug = 11
};

enum IBLTextureIndex {
    IBLTextureIndexEnvironment = 0
};

enum ComputeBufferIndex {
    ComputeBufferIndexCullLights = 0,
    ComputeBufferIndexClusterParams = 1,
    ComputeBufferIndexIndexHeader = 2,
    ComputeBufferIndexCullUniforms = 3,
    ComputeBufferIndexLightGrid = 4,
    ComputeBufferIndexLightIndexList = 5,
    ComputeBufferIndexTileParams = 6,
    ComputeBufferIndexTileLightGrid = 7,
    ComputeBufferIndexTileLightIndexList = 8,
    ComputeBufferIndexTileLightIndexCount = 9,
    ComputeBufferIndexForwardPlusStats = 10,
    ComputeBufferIndexClearUniforms = 11,
    ComputeBufferIndexActiveTileList = 12,
    ComputeBufferIndexActiveTileCount = 13,
    ComputeBufferIndexDispatchThreadgroups = 14
};

enum ComputeTextureIndex {
    ComputeTextureIndexDepth = 0
};

inline float3x3 normalMatrixFromModel(float4x4 modelMatrix) {
    float3x3 M = float3x3(modelMatrix[0].xyz,
                          modelMatrix[1].xyz,
                          modelMatrix[2].xyz);
    float3 a = M[0];
    float3 b = M[1];
    float3 c = M[2];
    float3 r0 = cross(b, c);
    float3 r1 = cross(c, a);
    float3 r2 = cross(a, b);
    float det = dot(a, r0);
    if (fabs(det) <= 1e-8) {
        return float3x3(0.0);
    }
    float invDet = 1.0 / det;
    // Robust inverse-transpose handles non-uniform scale and shear
    return float3x3(r0, r1, r2) * invDet;
}

struct SimpleVertex {
    float3 position [[ attribute(0) ]];
};

struct DebugLineVertex {
    float3 position [[ attribute(0) ]];
    float4 color [[ attribute(1) ]];
    float2 uv [[ attribute(2) ]];
};

// TBN invariants:
// - normal is object space, transformed by normalMatrix in vertex shader.
// - tangent.xyz is object space, tangent.w is handedness (+1/-1).
// - bitangent is derived in shader: cross(N, T) * handedness.
// - normal maps assume +Y up unless NormalFlipY is set in material flags.
struct Vertex {
    float3 position [[ attribute(0) ]];
    float4 color [[ attribute(1) ]];
    float2 texCoord [[ attribute(2) ]];
    float3 normal [[ attribute(3) ]];
    float4 tangent [[ attribute(4) ]];
    ushort4 jointIndices [[ attribute(5) ]];
    float4 jointWeights [[ attribute(6) ]];
};

struct CubemapRasterizerData {
    float4 position [[ position ]];
    float3 localPosition;
};

struct RasterizerData {
    float4 position [[ position ]];
    float2 texCoord;
    float viewDepth;
    float3 worldPosition;
    float3 viewPosition;
    float3 surfaceNormal;
    float3 surfaceTangent;
    float3 surfaceBitangent;
    float3 toCamera;
    // xyz = camera world position. w = 1 when global IBL is available for this view, else 0.
    float4 cameraPositionAndIBL;
};

struct SimpleRasterizerData {
    float4 position [[ position ]];
    float2 texCoord;
};

struct DebugLineRasterizerData {
    float4 position [[ position ]];
    float4 color;
    float2 uv;
};

struct DepthRasterizerData {
    float4 position [[ position ]];
};

struct ModelConstants {
    float4x4 modelMatrix;
};

struct InstanceData {
    float4x4 modelMatrix;
    uint entityID;
    uint bonePaletteOffset;
    uint bonePaletteCount;
    uint skinningFlags;
    uint3 padding;
};

struct SceneConstants {
    float totalGameTime;
    float4x4 viewMatrix;
    float4x4 inverseViewMatrix;
    float4x4 skyViewMatrix;
    float4x4 projectionMatrix;
    float4x4 inverseProjectionMatrix;
    float4x4 inverseViewProjectionMatrix;
    // xyz = camera world position. w = 1 when global IBL is available for this view, else 0.
    float4 cameraPositionAndIBL;
};

struct LocalReflectionProbeUniform {
    float4 probePositionAndWeight;
    float4 boxExtentsAndBlendDistance;
    float4 intensityAndFlags;
    float4x4 worldToProbeMatrix;
};

struct GlobalIBLBlendUniform {
    float4 blendFactors;
};

struct CloudImpostorParams {
    float4 sunDirection;
    float4 moonDirection;
    float4 windOffsetCoverageAndCount;
    float4 skyRadianceAndMultipleScattering;
    float4 sunIrradiance;
    float4 moonIrradiance;
    float4 layout;
};

struct PostProcessDebugFlags {
    uint hasSceneNormals;
    uint hasSSAO;
    uint hasAONormals;
    uint padding;
};

inline float sampleSceneDepth(texture2d<float> sceneDepth,
                              sampler depthSampler,
                              float2 uv) {
    return sceneDepth.sample(depthSampler, uv).r;
}

inline float2 uvToNdc(float2 uv) {
    return float2(uv.x, 1.0 - uv.y) * 2.0 - 1.0;
}

inline float4 clipPositionFromDepth(float2 uv, float depth) {
    return float4(uvToNdc(uv), depth, 1.0);
}

inline float3 reconstructViewPosition(float2 uv,
                                      float rawDepth,
                                      constant SceneConstants &sceneConstants) {
    float4 clipPosition = clipPositionFromDepth(uv, rawDepth);
    float4 viewPosition = sceneConstants.inverseProjectionMatrix * clipPosition;
    float safeW = (fabs(viewPosition.w) > 1e-6) ? viewPosition.w : 1.0;
    return viewPosition.xyz / safeW;
}

inline float3 reconstructWorldPosition(float2 uv,
                                       float rawDepth,
                                       constant SceneConstants &sceneConstants) {
    float3 viewPosition = reconstructViewPosition(uv, rawDepth, sceneConstants);
    float4 worldPosition = sceneConstants.inverseViewMatrix * float4(viewPosition, 1.0);
    return worldPosition.xyz;
}

inline float linearDepthFromViewPosition(float3 viewPosition) {
    return max(-viewPosition.z, 0.0);
}

inline float linearDepthFromRawDepth(float2 uv,
                                     float rawDepth,
                                     constant SceneConstants &sceneConstants) {
    return linearDepthFromViewPosition(reconstructViewPosition(uv, rawDepth, sceneConstants));
}

inline float3 reconstructViewPositionFromLinearDepth(float2 uv,
                                                     float linearDepth,
                                                     constant SceneConstants &sceneConstants) {
    float2 ndc = float2(uv.x * 2.0 - 1.0,
                        (1.0 - uv.y) * 2.0 - 1.0);
    float4 farClip = float4(ndc, 1.0, 1.0);
    float4 viewFar = sceneConstants.inverseProjectionMatrix * farClip;
    float3 viewRay = viewFar.xyz / max(viewFar.w, 1e-6);
    float scale = linearDepth / max(-viewRay.z, 1e-6);
    return viewRay * scale;
}

inline float sampleLinearDepthHierarchy(texture2d<float> depthHierarchy,
                                        sampler depthSampler,
                                        float2 uv,
                                        float mipLevel) {
    return depthHierarchy.sample(depthSampler, uv, level(mipLevel)).r;
}

inline float2 signNotZero(float2 value) {
    return float2(value.x >= 0.0 ? 1.0 : -1.0,
                  value.y >= 0.0 ? 1.0 : -1.0);
}

inline float2 encodeOctahedralNormal(float3 normal) {
    float invL1Norm = 1.0 / max(abs(normal.x) + abs(normal.y) + abs(normal.z), 1e-6);
    float3 projected = normal * invL1Norm;
    float2 encoded = projected.xy;
    if (projected.z < 0.0) {
        encoded = (1.0 - abs(encoded.yx)) * signNotZero(encoded);
    }
    return clamp(encoded, -1.0, 1.0);
}

inline float3 decodeOctahedralNormal(float2 encodedNormal) {
    float3 normal = float3(encodedNormal.xy,
                           1.0 - abs(encodedNormal.x) - abs(encodedNormal.y));
    if (normal.z < 0.0) {
        normal.xy = (1.0 - abs(normal.yx)) * signNotZero(normal.xy);
    }
    return normalize(normal);
}

inline float3 sampleSceneNormal(texture2d<float> sceneNormals,
                                sampler normalSampler,
                                float2 uv) {
    float2 encodedNormal = sceneNormals.sample(normalSampler, uv).rg;
    return decodeOctahedralNormal(encodedNormal);
}

inline float3x3 inverseViewRotationMatrix(constant SceneConstants &sceneConstants) {
    return float3x3(sceneConstants.inverseViewMatrix[0].xyz,
                    sceneConstants.inverseViewMatrix[1].xyz,
                    sceneConstants.inverseViewMatrix[2].xyz);
}

inline float3 viewNormalToWorld(float3 viewNormal,
                                constant SceneConstants &sceneConstants) {
    return normalize(inverseViewRotationMatrix(sceneConstants) * viewNormal);
}

inline float3 worldNormalToView(float3 worldNormal,
                                constant SceneConstants &sceneConstants) {
    float3x3 viewRotation = float3x3(sceneConstants.viewMatrix[0].xyz,
                                     sceneConstants.viewMatrix[1].xyz,
                                     sceneConstants.viewMatrix[2].xyz);
    return normalize(viewRotation * worldNormal);
}

inline float3 visualizeSceneNormal(float3 normal) {
    return normal * 0.5 + 0.5;
}

inline float projectionFarPlane(constant SceneConstants &sceneConstants) {
    float m22 = sceneConstants.projectionMatrix[2][2];
    float m32 = sceneConstants.projectionMatrix[3][2];
    float denominator = m22 + 1.0;
    if (fabs(denominator) <= 1e-6) {
        return 1.0;
    }
    return max(-m32 / denominator, 1e-3);
}

inline float3 visualizeLinearDepth(float linearDepth, float maxDepth) {
    float normalizedDepth = clamp(linearDepth / max(maxDepth, 1e-6), 0.0, 1.0);
    return float3(normalizedDepth);
}

inline float3 visualizeViewPosition(float3 viewPosition,
                                    constant SceneConstants &sceneConstants) {
    float linearDepth = linearDepthFromViewPosition(viewPosition);
    float farPlane = projectionFarPlane(sceneConstants);
    float safeDepth = max(linearDepth, 1e-4);
    float2 normalizedXY = clamp(viewPosition.xy / safeDepth, -1.0, 1.0);
    float normalizedZ = clamp(linearDepth / farPlane, 0.0, 1.0);
    return float3(normalizedXY * 0.5 + 0.5, normalizedZ);
}

struct ShadowsSettings {
    uint enabled;
    uint directionalEnabled;
    uint shadowMapResolution;
    uint cascadeCount;
    float cascadeSplitLambda;
    float depthBias;
    float normalBias;
    float pcfRadius;
    uint pcfTapPreset;
    uint pcfTapsCascade0;
    uint pcfTapsCascade1;
    uint pcfTapsCascade2;
    uint pcfTapsCascade3;
    uint filterMode;
    float maxShadowDistance;
    float fadeOutDistance;
    float pcssLightWorldSize;
    float pcssMinFilterRadiusTexels;
    float pcssMaxFilterRadiusTexels;
    float pcssBlockerSearchRadiusTexels;
    uint pcssBlockerSamples;
    uint pcssPCFSamples;
    uint pcssNoiseEnabled;
    uint pcssPadding;
};

struct RendererSettings {
    float bloomThreshold;
    float bloomKnee;
    float bloomIntensity;
    float bloomUpsampleScale;
    float bloomDirtIntensity;
    uint bloomEnabled;
    float2 bloomTexelSize;
    float bloomMipLevel;
    uint bloomMaxMips;
    uint bloomQualityPreset;
    uint bloomResolutionScale;
    uint blurPasses;
    uint tonemap;
    float renderPreExposure;
    float gamma;
    uint iblEnabled;
    float iblIntensity;
    uint iblResolutionOverride;
    uint perfFlags;
    float iblFireflyClamp;
    uint iblFireflyClampEnabled;
    float iblSampleMultiplier;
    float skyboxMipBias;
    float iblSpecularLodExponent;
    float iblSpecularLodBias;
    float iblSpecularGrazingLodBias;
    float iblSpecularMinRoughness;
    float specularAAStrength;
    float normalMapMipBias;
    float normalMapMipBiasGrazing;
    uint shadingDebugMode;
    uint iblQualityPreset;
    uint ssaoEnabled;
    uint ssaoReserved0;
    float ssaoRadius;
    float ssaoIntensity;
    float ssaoPower;
    float ssaoBias;
    float ssaoThickness;
    float ssaoBlurSharpness;
    // Height fog settings are packed as one aligned block so Swift/Metal stay in lockstep.
    uint heightFogEnabled;
    float heightFogBaseHeight;
    float heightFogDensity;
    float heightFogHeightFalloff;
    float3 heightFogColor;
    float heightFogStartDistance;
    float heightFogDistanceDensity;
    float2 heightFogPadding;
    uint outlineEnabled;
    uint outlineThickness;
    float outlineOpacity;
    float outlinePadding;
    float3 outlineColor;
    float outlineColorPadding;
    uint gridEnabled;
    float gridOpacity;
    float gridFadeDistance;
    float gridMajorLineEvery;
    uint2 uvDebug;
    ShadowsSettings shadows;
    float4 padding0;
    float4 padding1;
    // xyz = world-space direction from the scene toward the visible sun, w = night fog scale.
    float4 aerialFogSunDirectionAndNight;
    // rgb = sun/transmittance inscattering color, w = forward scattering strength.
    float4 aerialFogSunColorAndStrength;
    // x = inscattering strength, y = height extinction scale, z = HG anisotropy, w = max aerial distance.
    float4 aerialFogParams;
    // rgb = current live hemispherical sky radiance, w = validity marker.
    float4 aerialFogAmbientRadiance;
};

struct ViewExposureSettings {
    float exposureGain;
    float currentEV100;
    float targetEV100;
    float meteredLuminance;
    float renderPreExposure;
    float inverseRenderPreExposure;
    float maximumStoredHDR;
    float outdoorPriorContribution;
    float compensation;
    float minimumEV100;
    float maximumEV100;
    uint adaptationState;
    uint mode;
    uint histogramSampleCount;
    uint fp16SaturationCount;
    uint flags;
};

struct ExposureMeteringUniforms {
    uint viewportWidth;
    uint viewportHeight;
    uint meteringMode;
    uint resetHistory;
    float histogramLogMin;
    float histogramLogMax;
    float lowPercentile;
    float highPercentile;
    float minimumEV100;
    float maximumEV100;
    float compensation;
    float targetKey;
    float darkAdaptationRate;
    float lightAdaptationRate;
    float deltaTime;
    float renderPreExposure;
    float skyInfluenceCap;
    float sceneEV100Calibration;
    float authoredEV100;
    uint exposureMode;
    uint exposureLocked;
    uint outdoorPriorEnabled;
    uint padding0;
    float outdoorPriorStrength;
    float fp16Maximum;
    float2 padding1;
};

struct DepthHierarchyReduceParams {
    float sourceMipLevel;
    float3 padding;
};

struct IBLIrradianceParams {
    uint sampleCount;
    float fireflyClamp;
    uint fireflyClampEnabled;
    float padding;
};

struct IBLPrefilterParams {
    float roughness;
    uint sampleCount;
    float fireflyClamp;
    uint fireflyClampEnabled;
    float envMipCount;
    float padding;
};

struct SkyParams {
    float3 sunDirection;
    float sunAngularRadius;
    float3 sunColor;
    float sunIntensity;
    float turbidity;
    float intensity;
    float skyTime;
    float3 skyTint;
    float3 zenithTint;
    float3 horizonTint;
    float gradientStrength;
    float hazeDensity;
    float hazeFalloff;
    float hazeHeight;
    float ozoneStrength;
    float3 ozoneTint;
    float sunHaloSize;
    float sunHaloIntensity;
    float sunHaloSoftness;
    float dayNightFactor;
    float twilightFactor;
    float nightFactor;
    float solarVisibility;
    float horizonDensity;
    float skyCoolness;
    float starVisibility;
    float moonPhase;
    float3 solarExtinctionTint;
    float moonIlluminatedFraction;
    float3 moonDirection;
    float moonAngularRadius;
    float3 moonColor;
    float moonIntensity;
    float3 duskTint;
    float celestialCaptureScale;
    float3 antiSolarTint;
    float moonIrradiance;
    float starIntensity;
    float moonTextureEnabled;
    float galaxyTextureEnabled;
    float _skyDerivedPadding4;
    // x = star richness, y = Milky Way intensity, z = Milky Way chroma, w = night background brightness.
    float4 celestialArtParams;
    // x = Milky Way rotation in turns, y/z/w reserved.
    float4 milkyWayParams;
    uint cloudsEnabled;
    float cloudsCoverage;
    float cloudsSoftness;
    float cloudsScale;
    float cloudsSpeed;
    float2 cloudsWindDirection;
    float cloudsHeight;
    float cloudsThickness;
    float cloudsBrightness;
    float cloudsSunInfluence;
    float cloudAtlasEnabled;
    float cloudAtlasStyle;
    // Phase 4 daytime: x = density, y = aerosol, z = Mie anisotropy, w = ozone.
    float4 atmosphereScatteringParams;
    // Phase 4 daytime: x = reference solar illuminance, y = multiple scattering, z = ground albedo, w reserved.
    float4 atmosphereOpticalParams;
    // Reserved for legacy/night ABI compatibility. Daytime aureole derives from Mie scattering.
    float4 sunAureoleParams;
    // Live scene-linear radiometric cloud inputs.
    float4 cloudSunIrradiance;
    float4 cloudMoonIrradiance;
    float4 cloudSkyRadiance;
    // x = extinction scale, y = phase anisotropy, z = bounded multiple scattering.
    float4 cloudOpticalParams;
};

struct OutlineParams {
    uint selectedId;
    uint thickness;
    uint2 padding;
    float2 texelSize;
};

struct GridParams {
    float4x4 inverseViewProjection;
    float3 cameraPosition;
    float padding;
};

struct ShadowConstants {
    float4x4 lightViewProj0;
    float4x4 lightViewProj1;
    float4x4 lightViewProj2;
    float4x4 lightViewProj3;
    float4 cascadeSplits;
    float4 shadowCasterDirectionAndEnabled;
    float4 shadowMapInvSizeAndCount;
    float4 cascadeWorldUnitsPerTexel;
    float4 cascadeNearZ;
    float4 cascadeFarZ;
    float4 shadowBiasParams;
    float4 shadowFadeParams;
    float4 pcssParams0;
    float4 pcssParams1;
    float4 pcfTapCounts;
};

inline float4x4 shadowLightViewProj(constant ShadowConstants &shadows, int index) {
    switch (index) {
    case 0: return shadows.lightViewProj0;
    case 1: return shadows.lightViewProj1;
    case 2: return shadows.lightViewProj2;
    case 3: return shadows.lightViewProj3;
    default: return shadows.lightViewProj0;
    }
}

enum TonemapType : uint {
    TonemapNone = 0,
    TonemapReinhard = 1,
    TonemapACES = 2,
    TonemapHazel = 3,
    TonemapAgX = 4,
    TonemapFilmic = 5
};

struct MetalCupMaterial {
    float3 baseColor;
    float baseColorAlpha;
    float metallicScalar;
    float roughnessScalar;
    float aoScalar;
    float3 emissiveColor;
    float emissiveScalar;
    float alphaCutoff;
    uint flags;
    float clearcoatFactor;
    float clearcoatRoughness;
    float sheenRoughness;
    uint pbrMaskMode;
    uint aoChannel;
    uint roughnessChannel;
    uint metallicChannel;
    float3 sheenColor;
    float padding2;
    float2 uvTiling;
    float2 uvOffset;
};

enum MetalCupMaterialFlags : uint {
    HasBaseColorMap =      1 << 0,
    HasNormalMap =         1 << 1,
    HasMetallicMap =       1 << 2,
    HasRoughnessMap =      1 << 3,
    HasMetalRoughnessMap = 1 << 4,
    HasAOMap =             1 << 5,
    HasEmissiveMap =       1 << 6,
    IsUnlit =              1 << 7,
    IsDoubleSided =        1 << 8,
    AlphaMasked =          1 << 9,
    AlphaBlended =         1 << 10,
    HasClearcoat =         1 << 11,
    HasSheen =             1 << 12,
    NormalFlipY =          1 << 13,
    HasClearcoatMap =      1 << 14,
    HasClearcoatRoughnessMap = 1 << 15,
    HasSheenColorMap =     1 << 16,
    HasSheenIntensityMap = 1 << 17,
    HasClearcoatGlossMap = 1 << 18,
    UsesFallbackMaterial = 1 << 19,
    HasORMMap = 1 << 20,
    AdditiveBlended = 1 << 21
};
    
inline bool hasFlag(uint flags, uint bit) { return (flags & bit) != 0u; }

enum LightType : uint {
    LightTypePoint = 0,
    LightTypeSpot = 1,
    LightTypeDirectional = 2
};

constant uint LightDataFlagDirectionalShadowCaster = 1u << 0;

enum RendererPerfFlags : uint {
    PerfHalfResBloom = 1 << 0,
    PerfUseAsyncIBLGen = 1 << 1,
    PerfDisableSpecularAA = 1 << 2,
    PerfDisableClearcoat = 1 << 3,
    PerfDisableSheen = 1 << 4,
    PerfSkipSpecIBLHighRoughness = 1 << 5,
    PerfForwardPlusEnabled = 1 << 6,
    PerfDisableLocalProbeParallaxCorrection = 1 << 7
};

enum ShadingDebugMode : uint {
    DebugOff = 0,
    DebugWorldNormal = 1,
    DebugReflection = 2,
    DebugRoughness = 3,
    DebugMetallic = 4,
    DebugNdotV = 5,
    DebugSpecularMip = 6,
    DebugDiffuseIBL = 7,
    DebugSpecularIBL = 8,
    DebugDirectLighting = 9,
    DebugRoughnessBeforeAA = 10,
    DebugRoughnessAfterAA = 11,
    DebugMaterialValidation = 12,
    DebugGeometricWorldNormal = 13,
    DebugNormalMismatch = 14,
    DebugToCameraMismatch = 15,
    DebugLightHeatmap = 16,
    DebugClusterZSlice = 17,
    DebugClusterGrid = 18,
    DebugTileLightCount = 19,
    DebugShadowCascadeIndex = 20,
    DebugShadowCascadeBlend = 21,
    DebugShadowFactor = 22,
    DebugShadowBiasStress = 23,
    DebugSceneDepth = 24,
    DebugSceneNormals = 25,
    DebugSceneWorldNormals = 26,
    DebugSSAORaw = 27,
    DebugSSAOFiltered = 28,
    DebugAONormals = 29,
    DebugReconstructedViewPosition = 30,
    DebugFogFactor = 31,
    DebugFogTransmittance = 32,
    DebugGlobalSpecularIBL = 33,
    DebugLocalSpecularIBL = 34,
    DebugLocalProbeWeight = 35,
    DebugDirectPlusGlobalSpecular = 36,
    DebugDirectPlusLocalSpecular = 37,
    DebugDirectPlusMixedSpecular = 38,
    DebugDirectSpecularOnly = 39,
    DebugSunVectorAlignment = 40,
    DebugFogOpticalDepth = 41,
    DebugFogInscattering = 42,
    DebugFogLinearDistance = 43,
    DebugFogDensity = 44,
    DebugFogAmbientScattering = 45,
    DebugFogDirectionalScattering = 46,
    DebugFogPixelClassification = 47,
    DebugAOValidSamples = 48,
    DebugAOObscurance = 49,
    DebugAOProductionDepth = 50,
    DebugAOIndirectFactor = 51
};

struct LightData {
    float3 position;
    uint type;
    // Direction the light rays travel (from the light toward the scene).
    float3 direction;
    float range;
    float3 color;
    float brightness;
    float ambientIntensity;
    float diffuseIntensity;
    float specularIntensity;
    float innerConeCos;
    float outerConeCos;
    uint flags;
    float padding;
};

struct ForwardPlusClusterParams {
    uint abiVersion;
    uint clusterCountX;
    uint clusterCountY;
    uint clusterCountZ;

    uint totalClusterCount;
    uint tileSizeX;
    uint tileSizeY;
    uint padding0;

    uint viewportWidth;
    uint viewportHeight;
    uint padding1;
    uint padding2;

    float nearPlane;
    float farPlane;
    float logDepthScale;
    float logDepthBias;
};

struct ForwardPlusIndexHeader {
    // Scalar fields keep atomic targets addressable in MSL.
    uint abiVersion;
    uint totalIndexCount;
    uint overflowClusterCount;
    uint maxIndexCapacity;
};

struct ForwardPlusTileParams {
    uint abiVersion;
    uint tileCountX;
    uint tileCountY;
    uint maxLightsPerTile;
    uint tileSizeX;
    uint tileSizeY;
    uint viewportWidth;
    uint viewportHeight;
};

struct ForwardPlusTileIndexHeader {
    uint abiVersion;
    uint totalIndexCount;
    uint overflowTileCount;
    uint maxIndexCapacity;
};

struct ForwardPlusStats {
    uint tileOverflowCount;
    uint clusterOverflowCount;
    uint tileIndicesWritten;
    uint clusterIndicesWritten;

    uint tileCountX;
    uint tileCountY;
    uint totalTiles;
    uint missingDepthFrames;

    uint clusterCountX;
    uint clusterCountY;
    uint clusterCountZ;
    uint totalClusters;

    uint activeTilesCount;
    uint reserved1;
    uint reserved2;
    uint reserved3;
};

struct ForwardPlusClearUniforms {
    uint abiVersion;
    uint tileCountX;
    uint tileCountY;
    uint maxLightsPerTile;

    uint tileSizeX;
    uint tileSizeY;
    uint viewportWidth;
    uint viewportHeight;

    uint clusterCountX;
    uint clusterCountY;
    uint clusterCountZ;
    uint maxLightsPerCluster;

    float nearPlane;
    float farPlane;
    float logDepthScale;
    float logDepthBias;
};

struct ForwardPlusCullLight {
    float4 positionAndRange;
    float4 directionAndType;
    float4 colorAndIntensity;
    float4 spotParams;
};

struct ForwardPlusCullUniforms {
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    uint4 params0;
    uint4 params1;
};

vertex DebugLineRasterizerData vertex_debug_line(DebugLineVertex in [[stage_in]],
                                                 constant SceneConstants &scene [[buffer(VertexBufferIndexSceneConstants)]]) {
    DebugLineRasterizerData out;
    float4 world = float4(in.position, 1.0);
    out.position = scene.projectionMatrix * scene.viewMatrix * world;
    out.color = in.color;
    out.uv = in.uv;
    return out;
}

fragment float4 fragment_debug_line(DebugLineRasterizerData in [[stage_in]]) {
    float2 p = in.uv * 2.0 - 1.0;
    float edgeDist = max(abs(p.x), abs(p.y));
    float aa = max(1e-4, fwidth(edgeDist) * 1.5);
    float alpha = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, edgeDist);
    return float4(in.color.rgb, in.color.a * alpha);
}

#endif
