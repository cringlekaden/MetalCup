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

vertex RasterizerData vertex_main(const Vertex vert [[ stage_in ]]) {
    RasterizerData rd;
    rd.position = float4(vert.position, 1);
    rd.color = vert.color;
    return rd;
}

fragment half4 fragment_main(RasterizerData rd [[stage_in]]) {
    float4 color = rd.color;
    return half4(color.r, color.g, color.b, color.a);
}
