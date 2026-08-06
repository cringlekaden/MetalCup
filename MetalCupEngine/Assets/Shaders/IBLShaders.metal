//
//  IBLShaders.metal
//  MetalCup
//
//  Created by Kaden Cringle on 1/27/26.
//

#include <metal_stdlib>
#include "PBR.metal"
#include "Shared.metal"
using namespace metal;


inline float3 cubemapOrientationDiagnosticColor(uint face, float2 uv) {
    float2 st = uv * 2.0 - 1.0;
    float2 absSt = abs(st);
    float3 faceColor;
    switch (face) {
        case 0u: faceColor = float3(1.0, 0.0, 0.0); break; // +X red
        case 1u: faceColor = float3(0.0, 1.0, 1.0); break; // -X cyan
        case 2u: faceColor = float3(0.0, 1.0, 0.0); break; // +Y green
        case 3u: faceColor = float3(1.0, 0.0, 1.0); break; // -Y magenta
        case 4u: faceColor = float3(0.0, 0.15, 1.0); break; // +Z blue
        default: faceColor = float3(1.0, 1.0, 0.0); break; // -Z yellow
    }

    float3 dir = cubeDirectionFromFaceUV(face, uv);
    float grid = step(0.965, max(abs(fract(uv.x * 8.0) * 2.0 - 1.0),
                                  abs(fract(uv.y * 8.0) * 2.0 - 1.0)));
    float border = step(0.94, max(absSt.x, absSt.y));
    float upStripe = (uv.y < 0.16 && abs(st.x) < 0.78) ? 1.0 : 0.0;
    float cornerDot = (distance(uv, float2(0.82, 0.24)) < 0.075) ? 1.0 : 0.0;
    float equator = 1.0 - smoothstep(0.006, 0.022, abs(dir.y));
    float3 sunDir = normalize(float3(1.0, 0.25, -1.0));
    float sunMarker = smoothstep(0.9991, 0.9998, dot(dir, sunDir));

    float3 color = faceColor * 0.82;
    color = mix(color, float3(0.02), grid * 0.30);
    color = mix(color, float3(1.0), border);
    color = mix(color, float3(1.0), upStripe);
    color = mix(color, float3(0.0), cornerDot);
    color = mix(color, float3(1.0), equator * 0.85);
    color = mix(color, float3(8.0, 6.5, 1.5), sunMarker);
    return color;
}

vertex CubemapRasterizerData vertex_cubemap(const SimpleVertex vert [[ stage_in ]],
                                            constant float4x4 &vp [[ buffer(VertexBufferIndexCubemapVP) ]]) {
    CubemapRasterizerData rd;
    float3 pos = vert.position;
    rd.localPosition = pos;
    rd.position = vp * float4(pos, 1.0);
    return rd;
}

fragment float4 fragment_cubemap(CubemapRasterizerData rd [[ stage_in ]],
                                 constant float2 &cubemapParams [[ buffer(FragmentBufferIndexSkyIntensity) ]],
                                 texture2d<float> hdri [[ texture(IBLTextureIndexEnvironment) ]],
                                 sampler samp [[ sampler(FragmentSamplerIndexLinearClamp) ]]) {
    float2 uv = rd.localPosition.xy * float2(0.5, -0.5) + 0.5;
    uint face = uint(cubemapParams.y + 0.5);
    float intensity = cubemapParams.x;
    float3 dir = cubeDirectionFromFaceUV(face, uv);
    // Canonical mapping: treat -Z as forward for lat-long conversion.
    dir.z = -dir.z;
    // φ in [0, 2π), +X at φ=0 (u=0), -Z at φ=3π/2 (u=0.75)
    float phi = atan2(-dir.z, dir.x);
    if (phi < 0.0) phi += 2.0 * PBR::PI;
    float u = phi / (2.0 * PBR::PI);
    // Map +Y to top of the HDRI (v = 0) for consistent cubemap orientation.
    float v = 0.5 - (asin(dir.y) / PBR::PI);
    float3 color = hdri.sample(samp, float2(u, v)).rgb * max(intensity, 0.0);
    return float4(color, 1.0);
}

fragment float4 fragment_cubemap_orientation_diagnostic(CubemapRasterizerData rd [[ stage_in ]],
                                                        constant float2 &cubemapParams [[ buffer(FragmentBufferIndexSkyIntensity) ]]) {
    float2 uv = rd.localPosition.xy * float2(0.5, -0.5) + 0.5;
    uint face = uint(cubemapParams.y + 0.5);
    return float4(cubemapOrientationDiagnosticColor(face, uv), 1.0);
}

fragment float4 fragment_irradiance(CubemapRasterizerData rd [[ stage_in ]],
                                    constant IBLIrradianceParams &params [[ buffer(FragmentBufferIndexIBLParams) ]],
                                    texturecube<float> envMap [[ texture(IBLTextureIndexEnvironment) ]],
                                    sampler samp [[ sampler(FragmentSamplerIndexLinearClamp) ]]) {
    float2 uv = rd.localPosition.xy * float2(0.5, -0.5) + 0.5;
    uint face = uint(params.padding + 0.5);
    float3 N = cubeDirectionFromFaceUV(face, uv);
    // Build TBN to orient cosine-weighted samples around N
    float3 T, B;
    PBR::buildOrthonormalBasis(N, T, B);
    uint res = envMap.get_width();
    uint mipCount = envMap.get_num_mip_levels();
    float omegaTexel = 4.0 * PBR::PI / (6.0 * float(res) * float(res));
    float3 sum = float3(0.0);
    uint sampleCount = max(params.sampleCount, 1u);
    for (uint i = 0u; i < sampleCount; ++i) {
        float2 Xi = PBR::hammersley(i, sampleCount);
        float3 L_local = PBR::cosineSampleHemisphere(Xi);
        float cosTheta = max(L_local.y, 1e-4);
        float3 L = normalize(T * L_local.x + N * L_local.y + B * L_local.z);
        float pdf = cosTheta / PBR::PI;
        float omegaS = 1.0 / (float(sampleCount) * pdf);
        float lod = 0.5 * log2(omegaS / omegaTexel);
        lod = clamp(lod, 0.0, float(mipCount - 1));
        float3 c = envMap.sample(samp, L, level(lod)).rgb;
        // Firefly clamp: limits extreme HDR spikes during precompute to stabilize rough materials.
        if (params.fireflyClampEnabled != 0u) {
            float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
            if (lum > params.fireflyClamp && lum > 0.0) {
                c *= params.fireflyClamp / lum;
            }
        }
        sum += c;
    }
    float3 irradiance = (PBR::PI / float(sampleCount)) * sum;
    return float4(irradiance, 1.0);
}

fragment float4 fragment_prefiltered(CubemapRasterizerData rd [[ stage_in ]],
                                     constant IBLPrefilterParams &params [[ buffer(FragmentBufferIndexIBLParams) ]],
                                     texturecube<float> envMap [[ texture(IBLTextureIndexEnvironment) ]],
                                     sampler samp [[ sampler(FragmentSamplerIndexLinearClamp) ]]) {
    float2 uv = rd.localPosition.xy * float2(0.5, -0.5) + 0.5;
    uint face = uint(params.padding + 0.5);
    float3 N = cubeDirectionFromFaceUV(face, uv);
    float3 R = N;
    float3 V = R;
    float3 prefilteredColor = float3(0.0);
    float totalWeight = 0.0;
    uint sampleCount = max(params.sampleCount, 1u);
    float roughness = clamp(params.roughness, 0.0, 1.0);
    float resolution = float(envMap.get_width());
    float saTexel = 4.0 * PBR::PI / (6.0 * resolution * resolution);
    float mipCount = max(params.envMipCount, 1.0);
    for(uint i = 0; i < sampleCount; i++) {
        float2 Xi = PBR::hammersley(i, sampleCount);
        float3 H = PBR::importanceSampleGGX(Xi, roughness, N);
        float3 L = normalize(2.0 * dot(V, H) * H - V);
        float NoL = max(dot(N, L), 0.0);
        if(NoL > 0.0) {
            float NoH = max(dot(N, H), 0.0);
            float VoH = max(dot(V, H), 1e-4);
            float D = PBR::DistributionGGX(N, H, roughness);
            float pdf = max((D * NoH) / (4.0 * VoH), 1e-5);
            float saSample = 1.0 / (float(sampleCount) * pdf);
            float mipLevel = roughness == 0.0 ? 0.0 : 0.5 * log2(saSample / saTexel);
            mipLevel = clamp(mipLevel, 0.0, mipCount - 1.0);
            // Cubemap convention: no axis flip for prefilter sampling (matches runtime reflection + skybox).
            float3 sampleColor = envMap.sample(samp, L, level(mipLevel)).rgb;
            // Firefly clamp: prevents tiny HDR highlights from dominating prefiltered mips.
            if (params.fireflyClampEnabled != 0u) {
                float lum = dot(sampleColor, float3(0.2126, 0.7152, 0.0722));
                if (lum > params.fireflyClamp && lum > 0.0) {
                    sampleColor *= params.fireflyClamp / lum;
                }
            }
            prefilteredColor += sampleColor * NoL;
            totalWeight += NoL;
        }
    }
    prefilteredColor /= max(totalWeight, 1e-4);
    return float4(prefilteredColor, 1.0);
}

fragment float fragment_hdri_luminance(SimpleRasterizerData rd [[ stage_in ]],
                                       texture2d<float> hdri [[ texture(IBLTextureIndexEnvironment) ]],
                                       sampler samp [[ sampler(FragmentSamplerIndexLinearClamp) ]]) {
    float2 uv = rd.texCoord;
    float3 color = hdri.sample(samp, uv).rgb;
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

fragment float2 fragment_brdf(SimpleRasterizerData rd [[ stage_in ]]) {
    float2 texCoord = rd.texCoord;
    float NdotV = texCoord.x;
    float roughness = clamp(texCoord.y, 0.0, 1.0);
    const uint SAMPLE_COUNT = 2048;
    return PBR::integrateBRDF(NdotV, roughness, SAMPLE_COUNT);
}
