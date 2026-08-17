import Metal
import simd
import Testing
@testable import MetalCupEngine

@Suite("SAO production pipeline")
struct SAOProductionPipelineTests {
    @Test
    func productionEvaluatorReportsContactAndBackgroundDiagnostics() throws {
        let size = 64
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase2MetalTestSupport.canonicalLibrary(device: device)
        let projection = matrix_float4x4.perspective(
            fovDegrees: 60,
            aspectRatio: 1,
            near: 0.1,
            far: 100
        )
        var constants = SceneConstants()
        constants.projectionMatrix = projection
        constants.inverseProjectionMatrix = simd_inverse(projection)
        constants.viewMatrix = matrix_identity_float4x4
        constants.inverseViewMatrix = matrix_identity_float4x4
        constants.inverseViewProjectionMatrix = simd_inverse(projection)

        var settings = RendererSettings()
        settings.ssaoEnabled = 1
        settings.ssaoRadius = 0.35
        settings.ssaoIntensity = 1.25
        settings.ssaoPower = 1
        settings.ssaoBias = 0.008

        let planeDepth = rawDepth(viewZ: -10, projection: projection)
        let occluderDepth = rawDepth(viewZ: -9.75, projection: projection)
        var depths = [Float](repeating: planeDepth, count: size * size)
        for y in 20..<44 {
            for x in 32..<48 {
                depths[y * size + x] = occluderDepth
            }
        }
        for y in 0..<8 {
            for x in 0..<8 {
                depths[y * size + x] = 1
            }
        }
        let encodedNormals = [SIMD2<Float>](repeating: .zero, count: size * size)
        let result = try renderDiagnostics(
            device: device,
            library: library,
            size: size,
            depths: depths,
            encodedNormals: encodedNormals,
            settings: settings,
            sceneConstants: constants
        )

        let background = result[2 * size + 2]
        let isolatedPlane = result[52 * size + 16]
        let contact = result[32 * size + 31]
        print("SAO characterization background=\(background) isolated=\(isolatedPlane) contact=\(contact)")

        #expect(background.x == 1)
        #expect(background.y == 0)
        #expect(background.z == 0)
        #expect(abs(isolatedPlane.w - 10) < 0.01)
        #expect(isolatedPlane.x < 0.7)
        #expect(contact.z > 0)
        #expect(contact.y > 0)
        #expect(contact.x < isolatedPlane.x)
    }

    private func rawDepth(viewZ: Float, projection: matrix_float4x4) -> Float {
        let clip = projection * SIMD4<Float>(0, 0, viewZ, 1)
        return clip.z / clip.w
    }

    private func renderDiagnostics(device: MTLDevice,
                                   library: MTLLibrary,
                                   size: Int,
                                   depths: [Float],
                                   encodedNormals: [SIMD2<Float>],
                                   settings: RendererSettings,
                                   sceneConstants: SceneConstants) throws -> [SIMD4<Float>] {
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: size,
            height: size,
            mipmapped: false
        )
        depthDescriptor.storageMode = .shared
        depthDescriptor.usage = .shaderRead
        let depthTexture = try #require(device.makeTexture(descriptor: depthDescriptor))
        depths.withUnsafeBytes { bytes in
            depthTexture.replace(
                region: MTLRegionMake2D(0, 0, size, size),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: MemoryLayout<Float>.stride * size
            )
        }

        let normalDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg32Float,
            width: size,
            height: size,
            mipmapped: false
        )
        normalDescriptor.storageMode = .shared
        normalDescriptor.usage = .shaderRead
        let normalTexture = try #require(device.makeTexture(descriptor: normalDescriptor))
        encodedNormals.withUnsafeBytes { bytes in
            normalTexture.replace(
                region: MTLRegionMake2D(0, 0, size, size),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: MemoryLayout<SIMD2<Float>>.stride * size
            )
        }

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: size,
            height: size,
            mipmapped: false
        )
        outputDescriptor.storageMode = .shared
        outputDescriptor.usage = .renderTarget
        let outputTexture = try #require(device.makeTexture(descriptor: outputDescriptor))

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SimpleVertex>.stride
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = try #require(library.makeFunction(name: "vertex_final"))
        pipelineDescriptor.fragmentFunction = try #require(library.makeFunction(name: "fragment_sao_production_diagnostics"))
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        let vertices = [
            SimpleVertex(position: SIMD3<Float>(-1, -1, 0)),
            SimpleVertex(position: SIMD3<Float>( 1, -1, 0)),
            SimpleVertex(position: SIMD3<Float>(-1,  1, 0)),
            SimpleVertex(position: SIMD3<Float>(-1,  1, 0)),
            SimpleVertex(position: SIMD3<Float>( 1, -1, 0)),
            SimpleVertex(position: SIMD3<Float>( 1,  1, 0))
        ]
        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = outputTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 0)
        let encoder = try #require(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(size), height: Double(size),
                                        znear: 0, zfar: 1))
        encoder.setVertexBytes(vertices,
                               length: MemoryLayout<SimpleVertex>.stride * vertices.count,
                               index: VertexBufferIndex.vertices)
        var mutableSettings = settings
        var mutableConstants = sceneConstants
        encoder.setFragmentBytes(&mutableSettings,
                                 length: RendererSettings.stride,
                                 index: FragmentBufferIndex.rendererSettings)
        encoder.setFragmentBytes(&mutableConstants,
                                 length: SceneConstants.stride,
                                 index: FragmentBufferIndex.postProcessSceneConstants)
        encoder.setFragmentTexture(depthTexture, index: PostProcessTextureIndex.depth)
        encoder.setFragmentTexture(normalTexture, index: PostProcessTextureIndex.normals)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        if let error = commandBuffer.error {
            Issue.record("SAO production diagnostic render failed: \(error.localizedDescription)")
        }

        var output = [SIMD4<Float>](repeating: .zero, count: size * size)
        output.withUnsafeMutableBytes { bytes in
            outputTexture.getBytes(
                bytes.baseAddress!,
                bytesPerRow: MemoryLayout<SIMD4<Float>>.stride * size,
                from: MTLRegionMake2D(0, 0, size, size),
                mipmapLevel: 0
            )
        }
        return output
    }
}
