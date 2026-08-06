import Metal
import Testing
import simd
@testable import MetalCupEngine

enum Phase3MetalTestSupport {
    static let quadVertices: [SimpleVertex] = [
        SimpleVertex(position: [-1, -1, 0]),
        SimpleVertex(position: [ 1, -1, 0]),
        SimpleVertex(position: [-1,  1, 0]),
        SimpleVertex(position: [-1,  1, 0]),
        SimpleVertex(position: [ 1, -1, 0]),
        SimpleVertex(position: [ 1,  1, 0])
    ]

    static func library(device: MTLDevice) throws -> MTLLibrary {
        try Phase2MetalTestSupport.canonicalLibrary(device: device)
    }

    static func sampler(device: MTLDevice) throws -> MTLSamplerState {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        descriptor.rAddressMode = .clampToEdge
        descriptor.normalizedCoordinates = true
        return try #require(device.makeSamplerState(descriptor: descriptor))
    }

    static func makeCube(device: MTLDevice,
                         size: Int,
                         mipmapped: Bool,
                         label: String) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.textureCubeDescriptor(
            pixelFormat: .rgba16Float,
            size: size,
            mipmapped: mipmapped
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        texture.label = label
        return texture
    }

    static func fillUniform(_ texture: MTLTexture, color: SIMD4<Float>) {
        for mip in 0..<texture.mipmapLevelCount {
            let size = max(1, texture.width >> mip)
            let halfColor = SIMD4<Float16>(
                Float16(color.x), Float16(color.y), Float16(color.z), Float16(color.w)
            )
            let pixels = [SIMD4<Float16>](repeating: halfColor, count: size * size)
            pixels.withUnsafeBytes { bytes in
                for face in 0..<6 {
                    texture.replace(
                        region: MTLRegionMake2D(0, 0, size, size),
                        mipmapLevel: mip,
                        slice: face,
                        withBytes: bytes.baseAddress!,
                        bytesPerRow: size * MemoryLayout<SIMD4<Float16>>.stride,
                        bytesPerImage: bytes.count
                    )
                }
            }
        }
    }

    static func fillDirectionalMarker(_ texture: MTLTexture,
                                      direction markerDirection: SIMD3<Float>,
                                      radiance: Float = 16,
                                      cosineThreshold: Float = 0.985) throws {
        let marker = simd_normalize(markerDirection)
        let size = texture.width
        for faceRaw in 0..<6 {
            let face = try #require(CubemapConvention.Face(rawValue: faceRaw))
            var pixels = [SIMD4<Float16>]()
            pixels.reserveCapacity(size * size)
            for y in 0..<size {
                for x in 0..<size {
                    let uv = SIMD2<Float>(
                        (Float(x) + 0.5) / Float(size),
                        (Float(y) + 0.5) / Float(size)
                    )
                    let direction = CubemapConvention.direction(face: face, uv: uv)
                    let value = simd_dot(direction, marker) >= cosineThreshold ? radiance : 0
                    pixels.append(SIMD4<Float16>(Float16(value), Float16(value), Float16(value), 1))
                }
            }
            pixels.withUnsafeBytes { bytes in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, size, size),
                    mipmapLevel: 0,
                    slice: faceRaw,
                    withBytes: bytes.baseAddress!,
                    bytesPerRow: size * MemoryLayout<SIMD4<Float16>>.stride,
                    bytesPerImage: bytes.count
                )
            }
        }
        try generateMipmaps(texture)
    }

    static func generateMipmaps(_ texture: MTLTexture) throws {
        guard texture.mipmapLevelCount > 1 else { return }
        let queue = try #require(texture.device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
    }

    static func renderDiagnosticCube(device: MTLDevice,
                                     library: MTLLibrary,
                                     fragmentName: String,
                                     size: Int = 64) throws -> MTLTexture {
        let target = try makeCube(device: device, size: size, mipmapped: true, label: fragmentName)
        try renderCubeFaces(
            device: device,
            library: library,
            fragmentName: fragmentName,
            target: target,
            mip: 0
        ) { encoder, face in
            var params = SIMD2<Float>(1, Float(face))
            encoder.setFragmentBytes(
                &params,
                length: MemoryLayout<SIMD2<Float>>.stride,
                index: 0
            )
        }
        try generateMipmaps(target)
        return target
    }

    static func renderIrradiance(device: MTLDevice,
                                 library: MTLLibrary,
                                 source: MTLTexture,
                                 size: Int = 16,
                                 sampleCount: UInt32 = 2048) throws -> MTLTexture {
        let target = try makeCube(device: device, size: size, mipmapped: false, label: "Phase3.Irradiance")
        let sourceSampler = try sampler(device: device)
        try renderCubeFaces(
            device: device,
            library: library,
            fragmentName: "fragment_irradiance",
            target: target,
            mip: 0
        ) { encoder, face in
            var params = IBLIrradianceParams()
            params.sampleCount = sampleCount
            params.fireflyClamp = 0
            params.fireflyClampEnabled = 0
            params.padding = Float(face)
            encoder.setFragmentBytes(&params, length: IBLIrradianceParams.stride, index: 0)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentSamplerState(sourceSampler, index: 0)
        }
        return target
    }

    static func renderPrefilter(device: MTLDevice,
                                library: MTLLibrary,
                                source: MTLTexture,
                                size: Int = 32,
                                sampleCount: UInt32 = 1024) throws -> MTLTexture {
        let target = try makeCube(device: device, size: size, mipmapped: true, label: "Phase3.Prefilter")
        let sourceSampler = try sampler(device: device)
        for mip in 0..<target.mipmapLevelCount {
            let roughness = Float(mip) / Float(max(target.mipmapLevelCount - 1, 1))
            try renderCubeFaces(
                device: device,
                library: library,
                fragmentName: "fragment_prefiltered",
                target: target,
                mip: mip
            ) { encoder, face in
                var params = IBLPrefilterParams()
                params.roughness = roughness
                params.sampleCount = sampleCount
                params.fireflyClamp = 0
                params.fireflyClampEnabled = 0
                params.envMipCount = Float(source.mipmapLevelCount)
                params.padding = Float(face)
                encoder.setFragmentBytes(&params, length: IBLPrefilterParams.stride, index: 0)
                encoder.setFragmentTexture(source, index: 0)
                encoder.setFragmentSamplerState(sourceSampler, index: 0)
            }
        }
        return target
    }

    static func sampleCube(device: MTLDevice,
                           library: MTLLibrary,
                           texture: MTLTexture,
                           directionsAndMip: [SIMD4<Float>]) throws -> [SIMD4<Float>] {
        let function = try #require(library.makeFunction(name: "phase3_sample_cubemap_directions"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let input = try Phase2MetalTestSupport.makeBuffer(device: device, values: directionsAndMip)
        let output = try #require(device.makeBuffer(
            length: MemoryLayout<SIMD4<Float>>.stride * directionsAndMip.count,
            options: .storageModeShared
        ))
        let sourceSampler = try sampler(device: device)
        try Phase2MetalTestSupport.execute(
            device: device,
            pipeline: pipeline,
            width: directionsAndMip.count
        ) { encoder in
            encoder.setBuffer(input, offset: 0, index: 0)
            encoder.setBuffer(output, offset: 0, index: 1)
            encoder.setTexture(texture, index: 0)
            encoder.setSamplerState(sourceSampler, index: 0)
        }
        let values = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: directionsAndMip.count)
        return directionsAndMip.indices.map { values[$0] }
    }

    static func compute<FloatInput, FloatOutput>(device: MTLDevice,
                                                  library: MTLLibrary,
                                                  functionName: String,
                                                  inputs: [FloatInput],
                                                  outputType: FloatOutput.Type) throws -> [FloatOutput] {
        let function = try #require(library.makeFunction(name: functionName))
        let pipeline = try device.makeComputePipelineState(function: function)
        let input = try Phase2MetalTestSupport.makeBuffer(device: device, values: inputs)
        let output = try #require(device.makeBuffer(
            length: MemoryLayout<FloatOutput>.stride * inputs.count,
            options: .storageModeShared
        ))
        try Phase2MetalTestSupport.execute(device: device, pipeline: pipeline, width: inputs.count) { encoder in
            encoder.setBuffer(input, offset: 0, index: 0)
            encoder.setBuffer(output, offset: 0, index: 1)
        }
        let values = output.contents().bindMemory(to: FloatOutput.self, capacity: inputs.count)
        return inputs.indices.map { values[$0] }
    }

    private static func renderCubeFaces(device: MTLDevice,
                                        library: MTLLibrary,
                                        fragmentName: String,
                                        target: MTLTexture,
                                        mip: Int,
                                        configure: (MTLRenderCommandEncoder, Int) -> Void) throws {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Phase3.\(fragmentName)"
        descriptor.vertexFunction = try #require(library.makeFunction(name: "vertex_cubemap"))
        descriptor.fragmentFunction = try #require(library.makeFunction(name: fragmentName))
        descriptor.colorAttachments[0].pixelFormat = target.pixelFormat
        descriptor.vertexDescriptor = simpleVertexDescriptor()
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let vertexBuffer = try Phase2MetalTestSupport.makeBuffer(device: device, values: quadVertices)
        var identity = matrix_identity_float4x4

        for face in 0..<6 {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].slice = face
            pass.colorAttachments[0].level = mip
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            let encoder = try #require(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(pipeline)
            encoder.setCullMode(.none)
            encoder.setViewport(MTLViewport(
                originX: 0,
                originY: 0,
                width: Double(max(1, target.width >> mip)),
                height: Double(max(1, target.height >> mip)),
                znear: 0,
                zfar: 1
            ))
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&identity, length: MemoryLayout<matrix_float4x4>.stride, index: 1)
            configure(encoder, face)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: quadVertices.count)
            encoder.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        if let error = commandBuffer.error {
            Issue.record("Phase 3 cube render failed: \(error.localizedDescription)")
        }
    }

    private static func simpleVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        descriptor.attributes[0].format = .float3
        descriptor.attributes[0].bufferIndex = 0
        descriptor.attributes[0].offset = 0
        descriptor.layouts[0].stride = MemoryLayout<SimpleVertex>.stride
        descriptor.layouts[0].stepFunction = .perVertex
        return descriptor
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3<Float>(x, y, z) }
    var yz: SIMD2<Float> { SIMD2<Float>(y, z) }
}
