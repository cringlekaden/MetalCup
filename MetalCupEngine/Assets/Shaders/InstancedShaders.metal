//
//  InstancedShader.metal
//  MetalCup
//
//  Created by Kaden Cringle on 1/21/26.
//

#include <metal_stdlib>
#include "Shared.metal"
using namespace metal;

// Shared vertex path for main + depth prepass to guarantee identical clip-space depth.
vertex RasterizerData vertex_scene_instanced(const Vertex vert [[ stage_in ]],
                                             constant SceneConstants &sceneConstants [[ buffer(VertexBufferIndexSceneConstants) ]],
                                             const device InstanceData *instances [[ buffer(VertexBufferIndexInstances) ]],
                                             const device float4x4 *bonePalette [[ buffer(VertexBufferIndexBonePalette) ]],
                                             uint instanceId [[ instance_id ]]){
    RasterizerData rd;
    InstanceData instance = instances[instanceId];

    float4 localPosition = float4(vert.position, 1.0);
    float3 localNormal = vert.normal;
    float3 localTangent = vert.tangent.xyz;

    bool useSkinning = (instance.skinningFlags & 1u) != 0u && instance.bonePaletteCount > 0u;
    if (useSkinning) {
        uint4 joints = uint4(vert.jointIndices);
        float4 weights = vert.jointWeights;
        float weightSum = weights.x + weights.y + weights.z + weights.w;
        if (weightSum > 1e-6) {
            weights /= weightSum;
        } else {
            weights = float4(1.0, 0.0, 0.0, 0.0);
        }

        uint base = instance.bonePaletteOffset;
        uint maxIndex = max(instance.bonePaletteCount, 1u) - 1u;
        uint i0 = min(joints.x, maxIndex);
        uint i1 = min(joints.y, maxIndex);
        uint i2 = min(joints.z, maxIndex);
        uint i3 = min(joints.w, maxIndex);

        float4x4 skinMatrix =
            (bonePalette[base + i0] * weights.x) +
            (bonePalette[base + i1] * weights.y) +
            (bonePalette[base + i2] * weights.z) +
            (bonePalette[base + i3] * weights.w);

        localPosition = skinMatrix * localPosition;
        localNormal = (skinMatrix * float4(localNormal, 0.0)).xyz;
        localTangent = (skinMatrix * float4(localTangent, 0.0)).xyz;
    }

    float4 worldPosition = instance.modelMatrix * localPosition;
    float4 viewPosition = sceneConstants.viewMatrix * worldPosition;
    rd.position = sceneConstants.projectionMatrix * viewPosition;
    rd.texCoord = vert.texCoord;
    rd.viewDepth = -viewPosition.z;
    rd.worldPosition = worldPosition.xyz;
    rd.viewPosition = viewPosition.xyz;
    float3x3 normalMatrix = normalMatrixFromModel(instance.modelMatrix);
    float3x3 model3x3 = float3x3(instance.modelMatrix[0].xyz,
                                 instance.modelMatrix[1].xyz,
                                 instance.modelMatrix[2].xyz);
    float3 normal = normalize(normalMatrix * localNormal);
    float3 tangent = normalize(model3x3 * localTangent);
    float handedness = (abs(vert.tangent.w) > 0.5) ? ((vert.tangent.w > 0.0) ? 1.0 : -1.0) : 1.0;
    tangent = normalize(tangent - normal * dot(normal, tangent));
    float3 bitangent = cross(normal, tangent) * handedness;
    rd.surfaceNormal = normal;
    rd.surfaceTangent = tangent;
    rd.surfaceBitangent = bitangent;
    rd.toCamera = sceneConstants.cameraPositionAndIBL.xyz - worldPosition.xyz;
    rd.cameraPositionAndIBL = sceneConstants.cameraPositionAndIBL;
    return rd;
}

