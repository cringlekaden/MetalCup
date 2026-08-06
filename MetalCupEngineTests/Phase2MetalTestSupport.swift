import Metal
import Testing
@testable import MetalCupEngine

enum Phase2MetalTestSupport {
    static func makeBuffer<T>(device: MTLDevice, values: [T]) throws -> MTLBuffer {
        try values.withUnsafeBytes { bytes in
            try #require(device.makeBuffer(
                bytes: bytes.baseAddress!,
                length: bytes.count,
                options: .storageModeShared
            ))
        }
    }

    static func makeBuffer<T>(device: MTLDevice, value: T) throws -> MTLBuffer {
        var value = value
        return try withUnsafeBytes(of: &value) { bytes in
            try #require(device.makeBuffer(
                bytes: bytes.baseAddress!,
                length: bytes.count,
                options: .storageModeShared
            ))
        }
    }

    static func canonicalLibrary(device: MTLDevice) throws -> MTLLibrary {
        let root = try #require(ResourceRegistry.bundledCanonicalShaderRootURL())
        let registry = ResourceRegistry(canonicalShaderRootURL: root)
        #expect(registry.activateCanonicalShaders(
            device: device,
            requiredFunctions: ShaderLibrary.requiredFunctionNames
        ))
        return try #require(registry.defaultLibrary)
    }

    static func execute(device: MTLDevice,
                        pipeline: MTLComputePipelineState,
                        width: Int,
                        encode: (MTLComputeCommandEncoder) -> Void) throws {
        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encode(encoder)
        let threadWidth = max(1, min(pipeline.maxTotalThreadsPerThreadgroup, width))
        encoder.dispatchThreads(
            MTLSize(width: width, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        if let error = commandBuffer.error {
            Issue.record("Metal command buffer failed: \(error.localizedDescription)")
        }
    }
}
