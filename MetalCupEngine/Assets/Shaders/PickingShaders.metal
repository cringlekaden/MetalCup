// PickingShaders.metal
// Defines picking pass shaders for instanced selection rendering.
// Created by Kaden Cringle.

#include <metal_stdlib>
#include "Shared.metal"
using namespace metal;

struct PickRasterizerData {
    float4 position [[ position ]];
    uint entityID [[ flat ]];
};

vertex PickRasterizerData vertex_pick_instanced(const Vertex vert [[ stage_in ]],
                                                constant SceneConstants &sceneConstants [[ buffer(VertexBufferIndexSceneConstants) ]],
                                                const device InstanceData *instances [[ buffer(VertexBufferIndexInstances) ]],
                                                const device float4x4 *bonePalette [[ buffer(VertexBufferIndexBonePalette) ]],
                                                uint instanceId [[ instance_id ]]) {
    PickRasterizerData rd;
    InstanceData instance = instances[instanceId];

    float4 localPosition = float4(vert.position, 1.0);
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
    }

    float4 worldPosition = instance.modelMatrix * localPosition;
    rd.position = sceneConstants.projectionMatrix * sceneConstants.viewMatrix * worldPosition;
    rd.entityID = instance.entityID;
    return rd;
}

fragment uint fragment_pick_id(PickRasterizerData in [[ stage_in ]]) {
    return in.entityID;
}
