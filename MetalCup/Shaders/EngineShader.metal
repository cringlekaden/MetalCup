//
//  EngineShader.metal
//  MetalCup
//
//  Created by Kaden Cringle on 1/17/26.
//

#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float3 position [[ attribute(0) ]];
    float4 color [[ attribute(1) ]];
};

struct RasterizerData {
    float4 position [[ position ]];
    float4 color;
};

struct ModelConstants {
    float4x4 modelMatrix;
};

struct SceneConstants {
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
};

struct Material {
    float4 color;
    bool useMaterialColor;
};

vertex RasterizerData vertex_main(const Vertex vert [[ stage_in ]], constant SceneConstants &sceneConstants [[ buffer(1) ]], constant ModelConstants &modelConstants [[ buffer(2) ]]) {
    RasterizerData rd;
    rd.position = sceneConstants.projectionMatrix * sceneConstants.viewMatrix * modelConstants.modelMatrix * float4(vert.position, 1);
    rd.color = vert.color;
    return rd;
}

fragment half4 fragment_main(RasterizerData rd [[stage_in]], constant Material &material [[ buffer(1) ]]) {
    float4 color = material.useMaterialColor ? material.color : rd.color;
    return half4(color.r, color.g, color.b, color.a);
}
