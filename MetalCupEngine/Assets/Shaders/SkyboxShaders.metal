//
//  SkysphereShaders.metal
//  MetalCup
//
//  Created by Kaden Cringle on 1/26/26.
//

#include <metal_stdlib>
#include "Shared.metal"
using namespace metal;

struct SkyboxRasterizerData {
    float4 position [[ position ]];
    float3 direction;
};

vertex SkyboxRasterizerData vertex_skybox(const SimpleVertex vert [[ stage_in ]], constant SceneConstants &sceneConstants [[ buffer(VertexBufferIndexSceneConstants) ]], constant ModelConstants &modelConstants [[ buffer(VertexBufferIndexModelConstants) ]]) {
    SkyboxRasterizerData rd;
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
    float3 worldDir = normalize(invSkyRotation * viewDir);
    rd.direction = worldDir;
    return rd;
}

fragment float4 fragment_skybox(SkyboxRasterizerData rd [[ stage_in ]],
                                constant RendererSettings &settings [[ buffer(FragmentBufferIndexRendererSettings) ]],
                                sampler sampler [[ sampler(FragmentSamplerIndexLinearClamp) ]],
                                texturecube<float> skyboxTexture [[ texture(FragmentTextureIndexSkybox) ]]) {
    float3 dir = normalize(rd.direction);
    float3 radiance = skyboxTexture.sample(sampler, dir, bias(settings.skyboxMipBias)).rgb;
    return float4(radiance * max(settings.renderPreExposure, 0.0), 1.0);
}
