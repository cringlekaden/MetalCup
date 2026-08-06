/// LightManager.swift
/// Defines the LightManager types and helpers for the engine.
/// Created by Kaden Cringle.

import MetalKit

public class LightManager {

    struct LightRecord {
        let entity: Entity
        var data: LightData
    }

    private var lightRecords: [LightRecord] = []

    static func hasSingleDirectionalShadowCasterInvariant(_ lightData: [LightData]) -> Bool {
        lightData.reduce(into: 0) { count, data in
            if data.type == 2,
               (data.flags & LightDataFlags.directionalShadowCaster.rawValue) != 0 {
                count += 1
            }
        } <= 1
    }

    func setLights(_ records: [LightRecord]) {
        lightRecords = records
    }

    /// Applies the ECS-selected owner to the frame-local GPU stream. The selection
    /// uses entity identity, never array ordering.
    func snapshotLightData(directionalShadowCaster selectedCaster: Entity?) -> [LightData] {
        let result = lightRecords.map { record -> LightData in
            var data = record.data
            data.flags = 0
            if data.type == 2, record.entity == selectedCaster {
                data.flags = LightDataFlags.directionalShadowCaster.rawValue
            }
            return data
        }
#if DEBUG
        let flaggedCount = result.reduce(into: 0) { count, data in
            if (data.flags & LightDataFlags.directionalShadowCaster.rawValue) != 0 {
                count += 1
            }
        }
        MC_ASSERT(Self.hasSingleDirectionalShadowCasterInvariant(result),
                  "Only one directional light may own the cascaded shadow map.")
        if selectedCaster != nil {
            MC_ASSERT(flaggedCount == 1, "The selected directional shadow caster must be present in the GPU light stream.")
        }
#endif
        return result
    }

    func makeLightBuffers(frameContext: RendererFrameContext) -> (countBuffer: MTLBuffer, dataBuffer: MTLBuffer) {
        frameContext.uploadLightData(snapshotLightData(directionalShadowCaster: nil))
    }
    
    func setLightData(_ renderCommandEncoder: MTLRenderCommandEncoder, frameContext: RendererFrameContext) {
        let buffers = makeLightBuffers(frameContext: frameContext)
        renderCommandEncoder.setFragmentBuffer(buffers.countBuffer, offset: 0, index: FragmentBufferIndex.lightCount)
        renderCommandEncoder.setFragmentBuffer(buffers.dataBuffer, offset: 0, index: FragmentBufferIndex.lightData)
    }
}
