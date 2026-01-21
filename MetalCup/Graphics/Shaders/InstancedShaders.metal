//
//  InstancedShader.metal
//  MetalCup
//
//  Created by Kaden Cringle on 1/21/26.
//

#include <metal_stdlib>
#include "Shared.metal"
using namespace metal;

vertex RasterizerData vertex_instanced(const Vertex vert [[ stage_in ]],
                                       constant SceneConstants &sceneConstants [[ buffer(1) ]],
                                       constant ModelConstants *modelConstants [[ buffer(2) ]],
                                       uint instanceId [[ instance_id ]]){
    RasterizerData rd;
    ModelConstants modelConstant = modelConstants[instanceId];
    rd.position = sceneConstants.projectionMatrix * sceneConstants.viewMatrix * modelConstant.modelMatrix * float4(vert.position, 1);
    rd.color = vert.color;
    rd.texCoord = vert.texCoord;
    return rd;
}
