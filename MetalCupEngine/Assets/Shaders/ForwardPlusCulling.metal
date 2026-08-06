// ForwardPlusCulling.metal
// Two-stage clustered Forward+ light culling compute kernels

#include <metal_stdlib>
using namespace metal;

#include "Shared.metal"

struct ForwardPlusGridEntry {
    uint offset;
    uint count;
};

inline bool isFiniteFloat4(float4 v) {
    return all(isfinite(v));
}

inline bool sphereIntersectsAABB(float3 center, float radius, float3 aabbMin, float3 aabbMax) {
    float3 d = max(float3(0.0), max(aabbMin - center, center - aabbMax));
    return dot(d, d) <= radius * radius;
}

kernel void kernel_forward_plus_clear(
    constant ForwardPlusClearUniforms &clearUniforms [[buffer(ComputeBufferIndexClearUniforms)]],
    device ForwardPlusTileParams &tileParams [[buffer(ComputeBufferIndexTileParams)]],
    device ForwardPlusTileIndexHeader &tileIndexHeader [[buffer(ComputeBufferIndexTileLightIndexCount)]],
    device ForwardPlusIndexHeader &clusterIndexHeader [[buffer(ComputeBufferIndexIndexHeader)]],
    device ForwardPlusClusterParams &clusterParams [[buffer(ComputeBufferIndexClusterParams)]],
    device ForwardPlusGridEntry *tileLightGrid [[buffer(ComputeBufferIndexTileLightGrid)]],
    device ForwardPlusGridEntry *clusterLightGrid [[buffer(ComputeBufferIndexLightGrid)]],
    device uint &activeTileCount [[buffer(ComputeBufferIndexActiveTileCount)]],
    device uint3 &dispatchThreadgroups [[buffer(ComputeBufferIndexDispatchThreadgroups)]],
    device ForwardPlusStats &stats [[buffer(ComputeBufferIndexForwardPlusStats)]],
    uint threadIndex [[thread_position_in_grid]])
{
    const uint tileCountX = max(clearUniforms.tileCountX, 1u);
    const uint tileCountY = max(clearUniforms.tileCountY, 1u);
    const uint totalTiles = max(tileCountX * tileCountY, 1u);
    const uint clusterCountX = max(clearUniforms.clusterCountX, 1u);
    const uint clusterCountY = max(clearUniforms.clusterCountY, 1u);
    const uint clusterCountZ = max(clearUniforms.clusterCountZ, 1u);
    const uint totalClusters = max(clusterCountX * clusterCountY * clusterCountZ, 1u);

    if (threadIndex < totalTiles) {
        const uint offset = threadIndex * max(clearUniforms.maxLightsPerTile, 1u);
        tileLightGrid[threadIndex].offset = offset;
        tileLightGrid[threadIndex].count = 0u;
    }

    if (threadIndex < totalClusters) {
        clusterLightGrid[threadIndex].offset = 0u;
        clusterLightGrid[threadIndex].count = 0u;
    }

    if (threadIndex == 0u) {
        tileParams.abiVersion = clearUniforms.abiVersion;
        tileParams.tileCountX = tileCountX;
        tileParams.tileCountY = tileCountY;
        tileParams.maxLightsPerTile = max(clearUniforms.maxLightsPerTile, 1u);
        tileParams.tileSizeX = max(clearUniforms.tileSizeX, 1u);
        tileParams.tileSizeY = max(clearUniforms.tileSizeY, 1u);
        tileParams.viewportWidth = max(clearUniforms.viewportWidth, 1u);
        tileParams.viewportHeight = max(clearUniforms.viewportHeight, 1u);

        tileIndexHeader.abiVersion = clearUniforms.abiVersion;
        tileIndexHeader.totalIndexCount = 0u;
        tileIndexHeader.overflowTileCount = 0u;
        tileIndexHeader.maxIndexCapacity = totalTiles * max(clearUniforms.maxLightsPerTile, 1u);

        clusterIndexHeader.abiVersion = clearUniforms.abiVersion;
        clusterIndexHeader.totalIndexCount = 0u;
        clusterIndexHeader.overflowClusterCount = 0u;
        clusterIndexHeader.maxIndexCapacity = totalClusters * max(clearUniforms.maxLightsPerCluster, 1u);

        clusterParams.abiVersion = clearUniforms.abiVersion;
        clusterParams.clusterCountX = clusterCountX;
        clusterParams.clusterCountY = clusterCountY;
        clusterParams.clusterCountZ = clusterCountZ;
        clusterParams.totalClusterCount = totalClusters;
        clusterParams.tileSizeX = max(clearUniforms.tileSizeX, 1u);
        clusterParams.tileSizeY = max(clearUniforms.tileSizeY, 1u);
        clusterParams.padding0 = 0u;
        clusterParams.viewportWidth = max(clearUniforms.viewportWidth, 1u);
        clusterParams.viewportHeight = max(clearUniforms.viewportHeight, 1u);
        clusterParams.padding1 = 0u;
        clusterParams.padding2 = 0u;
        clusterParams.nearPlane = max(clearUniforms.nearPlane, 0.001);
        clusterParams.farPlane = max(clearUniforms.farPlane, clusterParams.nearPlane + 0.001);
        clusterParams.logDepthScale = max(clearUniforms.logDepthScale, 1e-6);
        clusterParams.logDepthBias = clearUniforms.logDepthBias;

        stats.tileOverflowCount = 0u;
        stats.clusterOverflowCount = 0u;
        stats.tileIndicesWritten = 0u;
        stats.clusterIndicesWritten = 0u;
        stats.tileCountX = tileCountX;
        stats.tileCountY = tileCountY;
        stats.totalTiles = totalTiles;
        stats.clusterCountX = clusterCountX;
        stats.clusterCountY = clusterCountY;
        stats.clusterCountZ = clusterCountZ;
        stats.totalClusters = totalClusters;
        stats.activeTilesCount = 0u;
        stats.reserved1 = 0u;
        stats.reserved2 = 0u;
        stats.reserved3 = 0u;
        activeTileCount = 0u;
        dispatchThreadgroups = uint3(0u, 1u, 1u);
    }
}

kernel void kernel_forward_plus_tile_bin(
    constant ForwardPlusCullLight *lights [[buffer(ComputeBufferIndexCullLights)]],
    constant ForwardPlusCullUniforms &uniforms [[buffer(ComputeBufferIndexCullUniforms)]],
    constant ForwardPlusTileParams &tileParams [[buffer(ComputeBufferIndexTileParams)]],
    device ForwardPlusGridEntry *tileLightGrid [[buffer(ComputeBufferIndexTileLightGrid)]],
    device uint *tileLightIndexList [[buffer(ComputeBufferIndexTileLightIndexList)]],
    device ForwardPlusTileIndexHeader &tileIndexHeader [[buffer(ComputeBufferIndexTileLightIndexCount)]],
    device ForwardPlusStats &stats [[buffer(ComputeBufferIndexForwardPlusStats)]],
    uint lightThreadIndex [[thread_position_in_grid]])
{
    const uint lightCount = uniforms.params0.z;
    if (lightThreadIndex >= lightCount) {
        return;
    }

    const ForwardPlusCullLight light = lights[lightThreadIndex];
    if (!isFiniteFloat4(light.positionAndRange) || !isFiniteFloat4(light.directionAndType)) {
        return;
    }

    const float radius = max(light.positionAndRange.w, 0.0);
    if (radius <= 0.0) {
        return;
    }

    const uint viewportWidth = max(tileParams.viewportWidth, 1u);
    const uint viewportHeight = max(tileParams.viewportHeight, 1u);
    const uint tileCountX = max(tileParams.tileCountX, 1u);
    const uint tileCountY = max(tileParams.tileCountY, 1u);
    const uint tileSizeX = max(tileParams.tileSizeX, 1u);
    const uint tileSizeY = max(tileParams.tileSizeY, 1u);
    const uint maxLightsPerTile = max(tileParams.maxLightsPerTile, 1u);

    const float4 world = float4(light.positionAndRange.xyz, 1.0);
    const float4 view = uniforms.viewMatrix * world;
    if (view.z > radius) {
        return;
    }

    const float viewDepth = max(-view.z, 1e-4);
    const float4 clip = uniforms.projectionMatrix * view;
    if (!all(isfinite(clip)) || clip.w <= 1e-5) {
        return;
    }

    const float2 ndcCenter = clip.xy / clip.w;
    if (!all(isfinite(ndcCenter))) {
        return;
    }

    const float projX = abs(uniforms.projectionMatrix[0][0]);
    const float projY = abs(uniforms.projectionMatrix[1][1]);
    if (projX <= 1e-6 || projY <= 1e-6) {
        return;
    }

    const float ndcRadiusX = (radius * projX) / viewDepth;
    const float ndcRadiusY = (radius * projY) / viewDepth;
    const float2 pixelCenter = float2(
        (ndcCenter.x * 0.5 + 0.5) * float(viewportWidth),
        (1.0 - (ndcCenter.y * 0.5 + 0.5)) * float(viewportHeight)
    );
    const float2 pixelRadius = float2(
        ndcRadiusX * 0.5 * float(viewportWidth),
        ndcRadiusY * 0.5 * float(viewportHeight)
    );

    float2 rectMin = pixelCenter - pixelRadius;
    float2 rectMax = pixelCenter + pixelRadius;
    if (rectMax.x < 0.0 || rectMax.y < 0.0 || rectMin.x >= float(viewportWidth) || rectMin.y >= float(viewportHeight)) {
        return;
    }

    rectMin = clamp(rectMin, float2(0.0), float2(float(viewportWidth - 1u), float(viewportHeight - 1u)));
    rectMax = clamp(rectMax, float2(0.0), float2(float(viewportWidth - 1u), float(viewportHeight - 1u)));

    const uint tileMinX = min(uint(rectMin.x) / tileSizeX, tileCountX - 1u);
    const uint tileMinY = min(uint(rectMin.y) / tileSizeY, tileCountY - 1u);
    const uint tileMaxX = min(uint(rectMax.x) / tileSizeX, tileCountX - 1u);
    const uint tileMaxY = min(uint(rectMax.y) / tileSizeY, tileCountY - 1u);

    for (uint ty = tileMinY; ty <= tileMaxY; ++ty) {
        for (uint tx = tileMinX; tx <= tileMaxX; ++tx) {
            const uint tileIndex = tx + ty * tileCountX;
            const uint tileOffset = tileLightGrid[tileIndex].offset;
            const uint localSlot = atomic_fetch_add_explicit((device atomic_uint *)&tileLightGrid[tileIndex].count,
                                                             1u,
                                                             memory_order_relaxed);
            if (localSlot < maxLightsPerTile) {
                tileLightIndexList[tileOffset + localSlot] = lightThreadIndex;
                atomic_fetch_add_explicit((device atomic_uint *)&tileIndexHeader.totalIndexCount,
                                          1u,
                                          memory_order_relaxed);
                atomic_fetch_add_explicit((device atomic_uint *)&stats.tileIndicesWritten,
                                          1u,
                                          memory_order_relaxed);
            } else {
                atomic_fetch_add_explicit((device atomic_uint *)&tileIndexHeader.overflowTileCount,
                                          1u,
                                          memory_order_relaxed);
                atomic_fetch_add_explicit((device atomic_uint *)&stats.tileOverflowCount,
                                          1u,
                                          memory_order_relaxed);
            }
        }
    }
}

kernel void kernel_forward_plus_build_active_tiles(
    constant ForwardPlusTileParams &tileParams [[buffer(ComputeBufferIndexTileParams)]],
    device const ForwardPlusGridEntry *tileLightGrid [[buffer(ComputeBufferIndexTileLightGrid)]],
    device uint *activeTileList [[buffer(ComputeBufferIndexActiveTileList)]],
    device uint &activeTileCount [[buffer(ComputeBufferIndexActiveTileCount)]],
    uint tileIndex [[thread_position_in_grid]])
{
    const uint tileCountX = max(tileParams.tileCountX, 1u);
    const uint tileCountY = max(tileParams.tileCountY, 1u);
    const uint totalTiles = max(tileCountX * tileCountY, 1u);
    if (tileIndex >= totalTiles) {
        return;
    }

    const uint count = tileLightGrid[tileIndex].count;
    if (count == 0u) {
        return;
    }

    const uint appendIndex = atomic_fetch_add_explicit((device atomic_uint *)&activeTileCount,
                                                        1u,
                                                        memory_order_relaxed);
    activeTileList[appendIndex] = tileIndex;
}

kernel void kernel_forward_plus_prepare_sparse_dispatch(
    constant ForwardPlusClusterParams &clusterParams [[buffer(ComputeBufferIndexClusterParams)]],
    device const uint &activeTileCount [[buffer(ComputeBufferIndexActiveTileCount)]],
    device uint3 &dispatchThreadgroups [[buffer(ComputeBufferIndexDispatchThreadgroups)]],
    device ForwardPlusStats &stats [[buffer(ComputeBufferIndexForwardPlusStats)]],
    uint threadIndex [[thread_position_in_grid]])
{
    if (threadIndex != 0u) {
        return;
    }

    const uint zSliceCount = max(clusterParams.clusterCountZ, 1u);
    const uint activeCount = activeTileCount;
    const uint totalSparseClusters = activeCount * zSliceCount;
    const uint threadsPerThreadgroupX = 64u;
    const uint threadgroupCountX = (totalSparseClusters + threadsPerThreadgroupX - 1u) / threadsPerThreadgroupX;

    dispatchThreadgroups = uint3(threadgroupCountX, 1u, 1u);
    stats.activeTilesCount = activeCount;
}

kernel void kernel_forward_plus_cull(
    constant ForwardPlusCullLight *lights [[buffer(ComputeBufferIndexCullLights)]],
    constant ForwardPlusClusterParams &clusterParams [[buffer(ComputeBufferIndexClusterParams)]],
    device ForwardPlusIndexHeader &indexHeader [[buffer(ComputeBufferIndexIndexHeader)]],
    constant ForwardPlusCullUniforms &uniforms [[buffer(ComputeBufferIndexCullUniforms)]],
    device ForwardPlusGridEntry *lightGrid [[buffer(ComputeBufferIndexLightGrid)]],
    device uint *lightIndexList [[buffer(ComputeBufferIndexLightIndexList)]],
    constant ForwardPlusTileParams &tileParams [[buffer(ComputeBufferIndexTileParams)]],
    device const ForwardPlusGridEntry *tileLightGrid [[buffer(ComputeBufferIndexTileLightGrid)]],
    device const uint *tileLightIndexList [[buffer(ComputeBufferIndexTileLightIndexList)]],
    device const ForwardPlusTileIndexHeader &tileIndexHeader [[buffer(ComputeBufferIndexTileLightIndexCount)]],
    device const uint *activeTileList [[buffer(ComputeBufferIndexActiveTileList)]],
    device const uint &activeTileCount [[buffer(ComputeBufferIndexActiveTileCount)]],
    device ForwardPlusStats &stats [[buffer(ComputeBufferIndexForwardPlusStats)]],
    uint sparseClusterThreadIndex [[thread_position_in_grid]])
{
    const uint clusterCountX = max(clusterParams.clusterCountX, 1u);
    const uint clusterCountY = max(clusterParams.clusterCountY, 1u);
    const uint clusterCountZ = max(clusterParams.clusterCountZ, 1u);
    const uint totalClusterCount = max(clusterParams.totalClusterCount, 1u);

    const uint activeCount = activeTileCount;
    const uint totalSparseClusters = activeCount * clusterCountZ;
    if (sparseClusterThreadIndex >= totalSparseClusters) {
        return;
    }

    const uint activeTileIndex = sparseClusterThreadIndex / clusterCountZ;
    const uint clusterZ = sparseClusterThreadIndex % clusterCountZ;
    if (activeTileIndex >= activeCount) {
        return;
    }

    const uint tileIndex = activeTileList[activeTileIndex];
    const uint totalTiles = max(clusterCountX * clusterCountY, 1u);
    if (tileIndex >= totalTiles) {
        return;
    }

    const uint tileY = min(tileIndex / clusterCountX, clusterCountY - 1u);
    const uint tileX = min(tileIndex - tileY * clusterCountX, clusterCountX - 1u);
    const uint clusterIndex = tileX + tileY * clusterCountX + clusterZ * totalTiles;
    if (clusterIndex >= totalClusterCount) {
        return;
    }

    const uint viewportWidth = max(clusterParams.viewportWidth, 1u);
    const uint viewportHeight = max(clusterParams.viewportHeight, 1u);
    const uint tileSizeX = max(clusterParams.tileSizeX, 1u);
    const uint tileSizeY = max(clusterParams.tileSizeY, 1u);

    const uint lightCount = uniforms.params0.z;
    const uint maxLightsPerCluster = max(uniforms.params0.w, 1u);
    const uint indexCapacity = max(uniforms.params1.w, 1u);

    const float nearPlane = max(clusterParams.nearPlane, 0.001);
    const float farPlane = max(clusterParams.farPlane, nearPlane + 0.001);
    const float logScale = max(clusterParams.logDepthScale, 1e-6);
    const float logBias = clusterParams.logDepthBias;

    const float sliceNearUnclamped = (exp2(float(clusterZ)) - logBias) / logScale;
    const float sliceFarUnclamped = (exp2(float(clusterZ + 1u)) - logBias) / logScale;
    float sliceNear = clamp(sliceNearUnclamped, nearPlane, farPlane);
    float sliceFar = clamp(sliceFarUnclamped, nearPlane, farPlane);
    if (sliceFar < sliceNear) {
        float t = sliceFar;
        sliceFar = sliceNear;
        sliceNear = t;
    }
    sliceFar = max(sliceFar, sliceNear + 1e-4);

    const float tileMinX = float(tileX * tileSizeX);
    const float tileMinY = float(tileY * tileSizeY);
    const float tileMaxX = min(tileMinX + float(tileSizeX), float(viewportWidth));
    const float tileMaxY = min(tileMinY + float(tileSizeY), float(viewportHeight));

    const float ndcMinX = (tileMinX / float(viewportWidth)) * 2.0 - 1.0;
    const float ndcMaxX = (tileMaxX / float(viewportWidth)) * 2.0 - 1.0;
    const float ndcMaxY = 1.0 - (tileMinY / float(viewportHeight)) * 2.0;
    const float ndcMinY = 1.0 - (tileMaxY / float(viewportHeight)) * 2.0;

    const float projX = uniforms.projectionMatrix[0][0];
    const float projY = uniforms.projectionMatrix[1][1];
    if (abs(projX) < 1e-6 || abs(projY) < 1e-6) {
        lightGrid[clusterIndex].offset = 0u;
        lightGrid[clusterIndex].count = 0u;
        return;
    }

    const float xNearMin = sliceNear * ndcMinX / projX;
    const float xNearMax = sliceNear * ndcMaxX / projX;
    const float xFarMin = sliceFar * ndcMinX / projX;
    const float xFarMax = sliceFar * ndcMaxX / projX;

    const float yNearMin = sliceNear * ndcMinY / projY;
    const float yNearMax = sliceNear * ndcMaxY / projY;
    const float yFarMin = sliceFar * ndcMinY / projY;
    const float yFarMax = sliceFar * ndcMaxY / projY;

    float3 clusterMin = float3(
        min(min(xNearMin, xNearMax), min(xFarMin, xFarMax)),
        min(min(yNearMin, yNearMax), min(yFarMin, yFarMax)),
        -sliceFar
    );
    float3 clusterMax = float3(
        max(max(xNearMin, xNearMax), max(xFarMin, xFarMax)),
        max(max(yNearMin, yNearMax), max(yFarMin, yFarMax)),
        -sliceNear
    );

    uint localIndices[64];
    uint localCount = 0u;
    bool clusterOverflow = false;

    const uint tileCountX = max(tileParams.tileCountX, 1u);
    const uint tileCountY = max(tileParams.tileCountY, 1u);
    const uint tileMaxLights = max(tileParams.maxLightsPerTile, 1u);
    const uint tileIndexCapacity = max(tileIndexHeader.maxIndexCapacity, 1u);
    const uint safeTileX = min(tileX, tileCountX - 1u);
    const uint safeTileY = min(tileY, tileCountY - 1u);
    const uint tileLinearIndex = safeTileX + safeTileY * tileCountX;
    const uint maxTileIndex = max(tileCountX * tileCountY, 1u);
    if (tileLinearIndex < maxTileIndex) {
        const ForwardPlusGridEntry tileEntry = tileLightGrid[tileLinearIndex];
        const uint tileBase = min(tileEntry.offset, tileIndexCapacity - 1u);
        uint tileCount = min(tileEntry.count, tileMaxLights);
        if (tileBase + tileCount > tileIndexCapacity) {
            tileCount = tileIndexCapacity - tileBase;
        }

        for (uint i = 0u; i < tileCount; ++i) {
            const uint candidateLightIndex = tileLightIndexList[tileBase + i];
            if (candidateLightIndex >= lightCount) {
                continue;
            }
            const ForwardPlusCullLight candidate = lights[candidateLightIndex];
            if (!isFiniteFloat4(candidate.positionAndRange) || !isFiniteFloat4(candidate.directionAndType)) {
                continue;
            }
            const float radius = max(candidate.positionAndRange.w, 0.0);
            const float4 world = float4(candidate.positionAndRange.xyz, 1.0);
            const float4 view = uniforms.viewMatrix * world;
            const bool intersects = sphereIntersectsAABB(view.xyz, radius, clusterMin, clusterMax);
            if (!intersects) {
                continue;
            }

            if (localCount < maxLightsPerCluster && localCount < 64u) {
                localIndices[localCount++] = candidateLightIndex;
            } else {
                clusterOverflow = true;
            }
        }
    }

    if (localCount == 0u) {
        lightGrid[clusterIndex].offset = 0u;
        lightGrid[clusterIndex].count = 0u;
        return;
    }

    const uint baseOffset = atomic_fetch_add_explicit((device atomic_uint *)&indexHeader.totalIndexCount,
                                                       localCount,
                                                       memory_order_relaxed);

    uint writeCount = localCount;
    if (baseOffset >= indexCapacity) {
        writeCount = 0u;
    } else if (baseOffset + writeCount > indexCapacity) {
        writeCount = indexCapacity - baseOffset;
    }

    if (clusterOverflow || writeCount < localCount) {
        atomic_fetch_add_explicit((device atomic_uint *)&indexHeader.overflowClusterCount,
                                  1u,
                                  memory_order_relaxed);
        atomic_fetch_add_explicit((device atomic_uint *)&stats.clusterOverflowCount,
                                  1u,
                                  memory_order_relaxed);
    }

    const uint safeOffset = (writeCount > 0u) ? baseOffset : 0u;
    lightGrid[clusterIndex].offset = safeOffset;
    lightGrid[clusterIndex].count = writeCount;

    for (uint i = 0u; i < writeCount; ++i) {
        const uint target = baseOffset + i;
        if (target < indexCapacity) {
            lightIndexList[target] = localIndices[i];
        }
    }

    if (writeCount > 0u) {
        atomic_fetch_add_explicit((device atomic_uint *)&stats.clusterIndicesWritten,
                                  writeCount,
                                  memory_order_relaxed);
    }
}
