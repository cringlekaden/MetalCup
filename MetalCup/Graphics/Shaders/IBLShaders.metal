//
//  IBLShaders.metal
//  MetalCup
//
//  Created by Kaden Cringle on 1/27/26.
//

#include <metal_stdlib>
#include "PBR.metal"
using namespace metal;

struct CubemapVertex {
    float3 position [[ attribute(0) ]];
};

struct CubemapRasterizerData {
    float4 position [[ position ]];
    float3 localPosition;
};

vertex CubemapRasterizerData vertex_cubemap(const CubemapVertex vert [[ stage_in ]],
                                            constant float4x4 &vp [[ buffer(1) ]]) {
    CubemapRasterizerData rd;
    float3 pos = vert.position;
    rd.localPosition = pos;
    rd.position = vp * float4(pos, 1.0);
    return rd;
}

fragment float4 fragment_cubemap(CubemapRasterizerData rd [[ stage_in ]],
                                 texture2d<float> hdri [[ texture(0) ]],
                                 sampler samp [[ sampler(0) ]]) {
    float3 dir = normalize(rd.localPosition);
    // φ in [0, 2π), +X at φ=0 (u=0), -Z at φ=3π/2 (u=0.75)
    float phi = atan2(-dir.z, dir.x);
    if (phi < 0.0) phi += 2.0 * PBR::PI;
    float u = phi / (2.0 * PBR::PI);
    float v = asin(dir.y) / PBR::PI + 0.5;
    float3 color = hdri.sample(samp, float2(u, v)).rgb;
    return float4(color, 1.0);
}

// --- Importance sampling utilities for cosine convolution ---
inline float radicalInverse_VdC(uint bits) {
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return float(bits) * 2.3283064365386963e-10; // / 2^32
}

inline float2 hammersley(uint i, uint N) {
    return float2(float(i) / float(N), radicalInverse_VdC(i));
}

inline float hash11(float n) { return fract(sin(n) * 43758.5453123); }

inline float2 hash22(float3 p) {
    float n1 = dot(p, float3(12.9898,78.233,37.719));
    float n2 = dot(p, float3(39.3467,11.1351,83.1559));
    return fract(sin(float2(n1, n2)) * 43758.5453123);
}

inline void buildOrthonormalBasis(float3 N, thread float3 &T, thread float3 &B) {
    float sign = copysign(1.0, N.z);
    float a = -1.0 / (sign + N.z);
    float b = N.x * N.y * a;
    T = float3(1.0 + sign * N.x * N.x * a, sign * b, -sign * N.x);
    B = float3(b, sign + N.y * N.y * a, -N.y);
}

inline float3 cosineSampleHemisphere(float2 Xi) {
    float r = sqrt(Xi.x);
    float phi = 2.0 * PBR::PI * Xi.y;
    float x = r * cos(phi);
    float z = r * sin(phi);
    float y = sqrt(max(0.0, 1.0 - Xi.x));
    return float3(x, y, z);
}

inline float3 importanceSampleGGX(float2 Xi, float roughness, float3 N) {
    float a = roughness * roughness;
    float phi = 2.0 * PBR::PI * Xi.x;
    float cosTheta = sqrt((1.0 - Xi.y) / (1.0 + (a * a - 1.0) * Xi.y));
    float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
    float3 H;
    H.x = cos(phi) * sinTheta;
    H.y = sin(phi) * sinTheta;
    H.z = cosTheta;
    float3 up = abs(N.z) < 0.999 ? float3(0.0,0.0,1.0) : float3(1.0,0.0,0.0);
    float3 T = normalize(cross(up, N));
    float3 B = cross(N, T);
    return normalize(T * H.x + B * H.y + N * H.z);
}

fragment float4 fragment_irradiance(CubemapRasterizerData rd [[ stage_in ]],
                                    texturecube<float> envMap [[ texture(0) ]],
                                    sampler samp [[ sampler(0) ]]) {
    // Output direction (normal) per texel of the irradiance cubemap face
    float3 N = normalize(rd.localPosition);
    // Build TBN to orient cosine-weighted samples around N
    float3 T, B;
    buildOrthonormalBasis(N, T, B);
    float seed = dot(N, float3(12.9898, 78.233, 37.719));
    float angle = 2.0 * PBR::PI * hash11(seed);
    float ca = cos(angle);
    float sa = sin(angle);
    float3 Trot = ca * T + sa * B;
    float3 Brot = -sa * T + ca * B;
    float2 cp = hash22(N);
    uint res = envMap.get_width();
    uint mipCount = envMap.get_num_mip_levels();
    float omegaTexel = 4.0 * PBR::PI / (6.0 * float(res) * float(res));
    const uint SAMPLE_COUNT = 2048u; // Adjust as needed (128–2048)
    float3 sum = float3(0.0);
    for (uint i = 0u; i < SAMPLE_COUNT; ++i) {
        float2 Xi = fract(hammersley(i, SAMPLE_COUNT) + cp);
        float3 L_local = cosineSampleHemisphere(Xi);
        float cosTheta = max(L_local.y, 1e-4);
        float3 L = normalize(Trot * L_local.x + N * L_local.y + Brot * L_local.z);
        float pdf = cosTheta / PBR::PI;
        float omegaS = 1.0 / (float(SAMPLE_COUNT) * pdf);
        float lod = 0.5 * log2(omegaS / omegaTexel);
        lod = clamp(lod, 0.0, float(mipCount - 1));
        float3 c = envMap.sample(samp, L, level(lod)).rgb;
        sum += c;
    }
    float3 irradiance = (PBR::PI / float(SAMPLE_COUNT)) * sum;
    return float4(irradiance, 1.0);
}

fragment float4 fragment_prefiltered(CubemapRasterizerData rd [[ stage_in ]],
                                     constant float &roughness [[ buffer(0) ]],
                                     texturecube<float> envMap [[ texture(0) ]],
                                     sampler samp [[ sampler(0) ]]) {
    float3 N = normalize(rd.localPosition);
    float3 R = N;
    float3 V = R;
    constexpr uint SAMPLE_COUNT = 1024u;
    float3 prefilteredColor = float3(0.0);
    float totalWeight = 0.0;
    for(uint i = 0; i < SAMPLE_COUNT; i++) {
        float2 Xi = hammersley(i, SAMPLE_COUNT);
        float3 H = importanceSampleGGX(Xi, roughness, N);
        float3 L = normalize(2.0 * dot(V, H) * H - V);
        float NoL = max(dot(N, L), 0.0);
        if(NoL > 0.0) {
            float3 sampleColor = envMap.sample(samp, L).rgb;
            prefilteredColor += sampleColor * NoL;
            totalWeight += NoL;
        }
    }
    prefilteredColor /= max(totalWeight, 1e-4);
    return float4(prefilteredColor, 1.0);
}

