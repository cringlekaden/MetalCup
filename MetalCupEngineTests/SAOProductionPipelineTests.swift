import Metal
import simd
import Testing
@testable import MetalCupEngine

@Suite("SAO production pipeline")
struct SAOProductionPipelineTests {
    @Test
    func productionEvaluatorSeparatesContactFlatSurfaceAndBackground() throws {
        let size = 128
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
        let occluderDepth = rawDepth(viewZ: -9.9, projection: projection)
        var depths = [Float](repeating: planeDepth, count: size * size)
        for y in 40..<88 {
            for x in 64..<96 {
                depths[y * size + x] = occluderDepth
            }
        }
        for y in 0..<16 {
            for x in 0..<16 {
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

        let background = result[4 * size + 4]
        let isolatedPlane = result[104 * size + 32]
        let contact = result[64 * size + 63]
        print("SAO characterization background=\(background) isolated=\(isolatedPlane) contact=\(contact)")

        #expect(background.x == 1)
        #expect(background.y == 0)
        #expect(background.z == 0)
        #expect(abs(isolatedPlane.w - 10) < 0.01)
        #expect(isolatedPlane.x > 0.995)
        #expect(isolatedPlane.y < 0.001)
        #expect(contact.z > 0.25)
        #expect(contact.y > 0)
        #expect(contact.x < 0.98)
        #expect(contact.x < isolatedPlane.x)

        let repeated = try renderDiagnostics(
            device: device,
            library: library,
            size: size,
            depths: depths,
            encodedNormals: encodedNormals,
            settings: settings,
            sceneConstants: constants
        )
        #expect(repeated[64 * size + 63] == contact)

        var translatedDepths = [Float](repeating: planeDepth, count: size * size)
        for y in 40..<88 {
            for x in 65..<97 {
                translatedDepths[y * size + x] = occluderDepth
            }
        }
        let translated = try renderDiagnostics(
            device: device,
            library: library,
            size: size,
            depths: translatedDepths,
            encodedNormals: encodedNormals,
            settings: settings,
            sceneConstants: constants
        )[64 * size + 64]
        #expect(translated.x < 0.99)
        #expect(abs(translated.x - contact.x) < 0.12)

        var strongerSettings = settings
        strongerSettings.ssaoIntensity = 2
        let strongerContact = try renderDiagnostics(
            device: device,
            library: library,
            size: size,
            depths: depths,
            encodedNormals: encodedNormals,
            settings: strongerSettings,
            sceneConstants: constants
        )[64 * size + 63]
        #expect(strongerContact.x <= contact.x)

        var fogSettings = settings
        fogSettings.heightFogEnabled = 1
        let fogContact = try renderDiagnostics(
            device: device,
            library: library,
            size: size,
            depths: depths,
            encodedNormals: encodedNormals,
            settings: fogSettings,
            sceneConstants: constants
        )[64 * size + 63]
        #expect(fogContact == contact)
    }

    @Test(arguments: [1, 4])
    func productionAOInputsRemainSingleSampleBesideAcceptedSceneMSAA(sceneSampleCount: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let root = try #require(ResourceRegistry.bundledCanonicalShaderRootURL())
        let resourceRegistry = ResourceRegistry(canonicalShaderRootURL: root)
        #expect(resourceRegistry.activateCanonicalShaders(
            device: device,
            requiredFunctions: ShaderLibrary.requiredFunctionNames
        ))
        let preferences = Preferences()
        preferences.sceneMSAASampleCount = sceneSampleCount
        let graphics = Graphics(resourceRegistry: resourceRegistry, device: device, preferences: preferences)
        let assets = AssetManager(device: device, graphics: graphics)
        var settings = RendererSettings()
        let resources = RenderResources(
            preferences: preferences,
            settingsProvider: { settings },
            settingsUpdater: { settings = $0 },
            assetManager: assets,
            device: device
        )
        resources.rebuild(drawableSize: CGSize(width: 96, height: 64))
        let registry = resources.buildRegistry()
        let aoDepth = try #require(registry.namedTexture(RenderNamedResourceKey.ssaoDepth))
        let aoNormals = try #require(registry.namedTexture(RenderNamedResourceKey.ssaoNormals))
        let sceneDepthMSAA = try #require(registry.namedTexture(RenderNamedResourceKey.sceneDepthMSAA))
        let raw = try #require(registry.namedTexture(RenderNamedResourceKey.ssaoRaw))

        #expect(aoDepth.sampleCount == 1)
        #expect(aoDepth.pixelFormat == preferences.defaultDepthPixelFormat)
        #expect(aoDepth.usage.contains(.renderTarget))
        #expect(aoDepth.usage.contains(.shaderRead))
        #expect(aoNormals.sampleCount == 1)
        #expect(aoNormals.pixelFormat == .rg16Float)
        #expect(sceneDepthMSAA.sampleCount == sceneSampleCount)
        #expect(raw.pixelFormat == .rgba16Float)
        #expect(raw.sampleCount == 1)
    }

    @Test
    func productionBilateralFilterPreservesNormalEdgesAndVisibilityRange() throws {
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
        settings.ssaoBlurSharpness = 48

        let planeDepth = rawDepth(viewZ: -10, projection: projection)
        let depths = [Float](repeating: planeDepth, count: size * size)
        var visibility = [Float](repeating: 1, count: size * size)
        var normals = [SIMD2<Float>](repeating: .zero, count: size * size)
        for y in 0..<size {
            for x in (size / 2)..<size {
                visibility[y * size + x] = 0.4
                normals[y * size + x] = SIMD2<Float>(1, 0)
            }
        }

        let filtered = try renderHorizontalBlur(
            device: device,
            library: library,
            size: size,
            visibility: visibility,
            depths: depths,
            encodedNormals: normals,
            settings: settings,
            sceneConstants: constants
        )
        #expect(filtered.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        #expect(filtered[32 * size + 31] > 0.98)
        #expect(filtered[32 * size + 32] < 0.42)
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

    private func renderHorizontalBlur(device: MTLDevice,
                                      library: MTLLibrary,
                                      size: Int,
                                      visibility: [Float],
                                      depths: [Float],
                                      encodedNormals: [SIMD2<Float>],
                                      settings: RendererSettings,
                                      sceneConstants: SceneConstants) throws -> [Float] {
        func texture(pixelFormat: MTLPixelFormat, bytesPerPixel: Int, bytes: UnsafeRawPointer) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: size,
                height: size,
                mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            let result = try #require(device.makeTexture(descriptor: descriptor))
            result.replace(
                region: MTLRegionMake2D(0, 0, size, size),
                mipmapLevel: 0,
                withBytes: bytes,
                bytesPerRow: bytesPerPixel * size
            )
            return result
        }

        let source = try visibility.withUnsafeBytes {
            try texture(pixelFormat: .r32Float, bytesPerPixel: MemoryLayout<Float>.stride, bytes: $0.baseAddress!)
        }
        let depth = try depths.withUnsafeBytes {
            try texture(pixelFormat: .r32Float, bytesPerPixel: MemoryLayout<Float>.stride, bytes: $0.baseAddress!)
        }
        let normals = try encodedNormals.withUnsafeBytes {
            try texture(pixelFormat: .rg32Float, bytesPerPixel: MemoryLayout<SIMD2<Float>>.stride, bytes: $0.baseAddress!)
        }
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: size,
            height: size,
            mipmapped: false
        )
        outputDescriptor.storageMode = .shared
        outputDescriptor.usage = .renderTarget
        let output = try #require(device.makeTexture(descriptor: outputDescriptor))

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SimpleVertex>.stride
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertex_final")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragment_ao_blur_h")
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = .r32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToZero
        samplerDescriptor.tAddressMode = .clampToZero
        let sampler = try #require(device.makeSamplerState(descriptor: samplerDescriptor))
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
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1)
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
        encoder.setFragmentTexture(source, index: PostProcessTextureIndex.source)
        encoder.setFragmentTexture(depth, index: PostProcessTextureIndex.depth)
        encoder.setFragmentTexture(normals, index: PostProcessTextureIndex.normals)
        encoder.setFragmentSamplerState(sampler, index: FragmentSamplerIndex.linearClamp)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)

        var result = [Float](repeating: 0, count: size * size)
        result.withUnsafeMutableBytes { bytes in
            output.getBytes(
                bytes.baseAddress!,
                bytesPerRow: MemoryLayout<Float>.stride * size,
                from: MTLRegionMake2D(0, 0, size, size),
                mipmapLevel: 0
            )
        }
        return result
    }
}
