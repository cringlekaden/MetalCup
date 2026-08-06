#include "Shared.metal"

struct CloudImpostorRasterizerData {
    float4 position [[position]];
    float2 uv;
    float fade;
    float3 viewDirection;
};

inline float4 cloudImpostorSeed(uint instanceID) {
    switch (instanceID % 6u) {
        case 0u: return float4(-0.72, 0.92, 0.92, 0.94);
        case 1u: return float4(-0.36, 1.05, 1.15, 1.06);
        case 2u: return float4( 0.02, 0.98, 1.02, 1.00);
        case 3u: return float4( 0.38, 1.10, 1.22, 0.96);
        case 4u: return float4( 0.70, 0.96, 0.88, 1.10);
        default: return float4( 0.18, 1.18, 1.35, 1.14);
    }
}

vertex CloudImpostorRasterizerData vertex_cloud_impostor(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant SceneConstants &sceneConstants [[buffer(VertexBufferIndexSceneConstants)]],
    constant CloudImpostorParams &params [[buffer(VertexBufferIndexCloudImpostorParams)]]) {
    float2 corners[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    float2 uvs[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };

    float3 cameraPosition = sceneConstants.cameraPositionAndIBL.xyz;
    float3 cameraForward = normalize(-sceneConstants.inverseViewMatrix[2].xyz);
    float3 forwardXZ = float3(cameraForward.x, 0.0, cameraForward.z);
    if (length(forwardXZ) < 0.01) {
        forwardXZ = float3(0.0, 0.0, -1.0);
    } else {
        forwardXZ = normalize(forwardXZ);
    }
    float3 worldUp = float3(0.0, 1.0, 0.0);
    float3 rightXZ = normalize(cross(forwardXZ, worldUp));

    float4 seed = cloudImpostorSeed(instanceID);
    float coverage = saturate(params.windOffsetCoverageAndCount.z);
    float2 wind = params.windOffsetCoverageAndCount.xy;
    float lateral = (seed.x + sin(wind.x + float(instanceID) * 1.37) * 0.055) * params.layout.x;
    float distance = params.layout.x * seed.y;
    float altitude = params.layout.y * seed.w + cos(wind.y + float(instanceID) * 0.91) * 5.0;
    float scale = params.layout.z * seed.z * mix(0.82, 1.12, coverage);
    float2 corner = corners[vertexID & 3u];

    float3 center = cameraPosition + forwardXZ * distance + rightXZ * lateral + worldUp * altitude;
    float3 worldPosition = center + rightXZ * (corner.x * scale * 1.65) + worldUp * (corner.y * scale * 0.55);

    CloudImpostorRasterizerData out;
    out.position = sceneConstants.projectionMatrix * sceneConstants.viewMatrix * float4(worldPosition, 1.0);
    out.uv = uvs[vertexID & 3u];
    float3 viewDirection = normalize(worldPosition - cameraPosition);
    out.viewDirection = viewDirection;
    out.fade = smoothstep(0.015, 0.16, viewDirection.y);
    return out;
}

fragment float4 fragment_cloud_impostor(
    CloudImpostorRasterizerData in [[stage_in]],
    constant CloudImpostorParams &params [[buffer(FragmentBufferIndexCloudImpostorParams)]],
    texture2d<float> cloudCard [[texture(FragmentTextureIndexCloudCard)]],
    sampler linearSampler [[sampler(FragmentSamplerIndexLinearClamp)]]) {
    // Keep the prototype on the source mip so generated low-alpha mips cannot turn
    // broad transparent rows into visible card-shaped haze.
    float4 texel = cloudCard.sample(linearSampler, in.uv, level(0.0));
    float sourceAlpha = saturate(texel.a);
    if (sourceAlpha < 0.16) {
        discard_fragment();
    }

    float mask = smoothstep(0.36, 0.78, sourceAlpha);
    mask *= mask;

    float borderDistance = min(min(in.uv.x, 1.0 - in.uv.x), min(in.uv.y, 1.0 - in.uv.y));
    float edgeFade = smoothstep(0.055, 0.20, borderDistance);
    float alpha = mask * edgeFade * in.fade * params.layout.w;
    if (alpha < 0.025) {
        discard_fragment();
    }

    float luminanceMask = saturate(max(texel.r, max(texel.g, texel.b)));
    float internalDetail = mix(0.86, 1.04, smoothstep(0.24, 0.88, luminanceMask));

    float3 sunDirection = normalize(params.sunDirectionAndNightFactor.xyz);
    float nightFactor = saturate(params.sunDirectionAndNightFactor.w);
    float sunHeight = saturate(sunDirection.y * 0.5 + 0.5);
    float forwardLight = 0.62 + 0.38 * saturate(dot(normalize(in.viewDirection), sunDirection) * 0.5 + 0.5);
    float3 lowSunTint = float3(1.0, 0.76, 0.50);
    float3 dayTint = mix(float3(0.78, 0.82, 0.88), float3(1.0, 0.97, 0.91), sunHeight);
    float3 nightTint = float3(0.08, 0.10, 0.16);
    float3 cloudColor = mix(mix(lowSunTint, dayTint, sunHeight), nightTint, nightFactor);
    cloudColor *= params.colorTintAndBrightness.rgb * params.colorTintAndBrightness.w * forwardLight * internalDetail;

    return float4(cloudColor, alpha);
}
