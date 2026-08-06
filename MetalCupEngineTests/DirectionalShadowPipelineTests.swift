import Testing
import Metal
import simd
@testable import MetalCupEngine

struct DirectionalShadowPipelineTests {
    @Test
    func selectedCasterOwnershipIsExplicitAndOrderIndependent() {
        let selected = Entity()
        let noncaster = Entity()
        var directional = LightData()
        directional.type = 2

        let manager = LightManager()
        manager.setLights([
            .init(entity: noncaster, data: directional),
            .init(entity: selected, data: directional)
        ])
        let firstOrder = manager.snapshotLightData(directionalShadowCaster: selected)
        #expect(firstOrder[0].flags == 0)
        #expect(firstOrder[1].flags == LightDataFlags.directionalShadowCaster.rawValue)

        manager.setLights([
            .init(entity: selected, data: directional),
            .init(entity: noncaster, data: directional)
        ])
        let secondOrder = manager.snapshotLightData(directionalShadowCaster: selected)
        #expect(secondOrder[0].flags == LightDataFlags.directionalShadowCaster.rawValue)
        #expect(secondOrder[1].flags == 0)
        #expect(LightManager.hasSingleDirectionalShadowCasterInvariant(secondOrder))

        let noCaster = manager.snapshotLightData(directionalShadowCaster: nil)
        #expect(noCaster.allSatisfy { $0.flags == 0 })

        var invalid = secondOrder
        invalid[1].flags = LightDataFlags.directionalShadowCaster.rawValue
        #expect(!LightManager.hasSingleDirectionalShadowCasterInvariant(invalid))
    }

    @Test
    func authoredCasterAndGeneratedSunOwnershipStayCoherent() throws {
        let scene = EngineScene(
            name: "ShadowOwnership",
            prefabSystem: nil,
            engineContext: nil,
            shouldBuildScene: false
        )
        let environmentEntity = scene.ecs.createEntity(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000010")),
            name: "Environment"
        )
        scene.ecs.add(EnvironmentComponent(
            source: EnvironmentSourceConfig(mode: .procedural)
        ), to: environmentEntity)

        let generatedSun = scene.ecs.createEntity(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000020")),
            name: "Generated Sun"
        )
        scene.ecs.add(TransformComponent(
            rotation: TransformMath.rotationForDirectionalLight(
                direction: simd_normalize(SIMD3<Float>(0.25, -0.9, 0.35))
            )
        ), to: generatedSun)
        var brightGeneratedData = LightData()
        brightGeneratedData.brightness = 20
        scene.ecs.add(LightComponent(
            type: .directional,
            data: brightGeneratedData,
            castsShadows: false
        ), to: generatedSun)
        scene.ecs.add(SkySunTag(), to: generatedSun)

        let authoredCaster = scene.ecs.createEntity(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000030")),
            name: "Authored Caster"
        )
        let authoredRay = simd_normalize(SIMD3<Float>(-0.5, -0.8, -0.3))
        scene.ecs.add(TransformComponent(
            rotation: TransformMath.rotationForDirectionalLight(direction: authoredRay)
        ), to: authoredCaster)
        scene.ecs.add(LightComponent(type: .directional, castsShadows: true), to: authoredCaster)

        scene.syncLights()
        let authoredSnapshot = scene.makeRenderFrameSnapshot(frameToken: 1, layerFilterMask: .all)
        #expect(authoredSnapshot.directionalShadowLightEntityID == authoredCaster.id)
        #expect(authoredSnapshot.directionalLights.count == 2)
        #expect(authoredSnapshot.directionalLights.filter {
            ($0.flags & LightDataFlags.directionalShadowCaster.rawValue) != 0
        }.count == 1)

        var generatedComponent = try #require(scene.ecs.get(LightComponent.self, for: generatedSun))
        generatedComponent.castsShadows = true
        scene.ecs.add(generatedComponent, to: generatedSun)
        scene.syncLights()
        let generatedSnapshot = scene.makeRenderFrameSnapshot(frameToken: 2, layerFilterMask: .all)
        #expect(generatedSnapshot.directionalShadowLightEntityID == generatedSun.id)

        generatedComponent.castsShadows = false
        scene.ecs.add(generatedComponent, to: generatedSun)
        var authoredComponent = try #require(scene.ecs.get(LightComponent.self, for: authoredCaster))
        authoredComponent.castsShadows = false
        scene.ecs.add(authoredComponent, to: authoredCaster)
        scene.syncLights()
        let noCasterSnapshot = scene.makeRenderFrameSnapshot(frameToken: 3, layerFilterMask: .all)
        #expect(noCasterSnapshot.directionalShadowLightEntityID == nil)
        #expect(noCasterSnapshot.directionalShadowLightDirection == nil)
        #expect(noCasterSnapshot.directionalLights.allSatisfy { $0.flags == 0 })
    }

    @Test
    func selectedCasterFlagMatchesTheMetalABI() throws {
        // Replace the former float2 padding with uint flags + float padding so the
        // established Swift/Metal stride remains unchanged.
        #expect(LightData.stride == 112)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase2MetalTestSupport.canonicalLibrary(device: device)
        let function = try #require(library.makeFunction(name: "phase2_shadow_owner_samples"))
        let pipeline = try device.makeComputePipelineState(function: function)

        var selected = LightData()
        selected.type = 2
        selected.flags = LightDataFlags.directionalShadowCaster.rawValue
        var noncaster = selected
        noncaster.flags = 0
        var point = selected
        point.type = 0
        let lights = [selected, noncaster, point]
        let lightBuffer = try lights.withUnsafeBytes { bytes in
            try #require(device.makeBuffer(
                bytes: bytes.baseAddress!,
                length: bytes.count,
                options: .storageModeShared
            ))
        }
        let resultBuffer = try #require(device.makeBuffer(
            length: MemoryLayout<SIMD4<Float>>.stride * lights.count,
            options: .storageModeShared
        ))
        try Phase2MetalTestSupport.execute(device: device, pipeline: pipeline, width: lights.count) { encoder in
            encoder.setBuffer(lightBuffer, offset: 0, index: 0)
            encoder.setBuffer(resultBuffer, offset: 0, index: 1)
        }
        let results = resultBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: lights.count)
        #expect(results[0].x == 1)
        #expect(results[1].x == 0)
        #expect(results[2].x == 0)
    }

    @Test(arguments: [1, 3, 4])
    func offscreenHardShadowDepthArrayHasOccupiedSlicesAndKnownReceivers(cascadeCount: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase2MetalTestSupport.canonicalLibrary(device: device)
        let vertexFunction = try #require(library.makeFunction(name: "phase2_shadow_test_vertex"))
        let receiverFunction = try #require(library.makeFunction(name: "phase2_hard_shadow_receiver_samples"))

        let renderDescriptor = MTLRenderPipelineDescriptor()
        renderDescriptor.vertexFunction = vertexFunction
        renderDescriptor.depthAttachmentPixelFormat = .depth32Float
        let renderPipeline = try device.makeRenderPipelineState(descriptor: renderDescriptor)
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        let depthState = try #require(device.makeDepthStencilState(descriptor: depthDescriptor))

        let resolution = 32
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: resolution,
            height: resolution,
            mipmapped: false
        )
        textureDescriptor.textureType = .type2DArray
        textureDescriptor.arrayLength = cascadeCount
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .private
        let depthTexture = try #require(device.makeTexture(descriptor: textureDescriptor))

        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        for slice in 0..<cascadeCount {
            let storedDepth = 0.2 + Float(slice) * 0.1
            let vertices = [
                SIMD4<Float>(-0.8, -0.8, storedDepth, 1),
                SIMD4<Float>( 0.8, -0.8, storedDepth, 1),
                SIMD4<Float>( 0.0,  0.8, storedDepth, 1)
            ]
            let pass = MTLRenderPassDescriptor()
            pass.depthAttachment.texture = depthTexture
            pass.depthAttachment.slice = slice
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .store
            pass.depthAttachment.clearDepth = 1
            let encoder = try #require(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(renderPipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setViewport(MTLViewport(
                originX: 0,
                originY: 0,
                width: Double(resolution),
                height: Double(resolution),
                znear: 0,
                zfar: 1
            ))
            encoder.setVertexBytes(
                vertices,
                length: MemoryLayout<SIMD4<Float>>.stride * vertices.count,
                index: 0
            )
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
            encoder.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)

        let bytesPerRow = 256
        let bytesPerImage = bytesPerRow * resolution
        let readback = try #require(device.makeBuffer(
            length: bytesPerImage * cascadeCount,
            options: .storageModeShared
        ))
        let readbackCommands = try #require(queue.makeCommandBuffer())
        let blit = try #require(readbackCommands.makeBlitCommandEncoder())
        for slice in 0..<cascadeCount {
            blit.copy(
                from: depthTexture,
                sourceSlice: slice,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: resolution, height: resolution, depth: 1),
                to: readback,
                destinationOffset: slice * bytesPerImage,
                destinationBytesPerRow: bytesPerRow,
                destinationBytesPerImage: bytesPerImage
            )
        }
        blit.endEncoding()
        readbackCommands.commit()
        readbackCommands.waitUntilCompleted()
        #expect(readbackCommands.status == .completed)
        let depthBytes = readback.contents()
        for slice in 0..<cascadeCount {
            var minimum = Float.greatestFiniteMagnitude
            var maximum = -Float.greatestFiniteMagnitude
            var nonClearCount = 0
            for row in 0..<resolution {
                for column in 0..<resolution {
                    let value = depthBytes.load(
                        fromByteOffset: slice * bytesPerImage + row * bytesPerRow + column * MemoryLayout<Float>.stride,
                        as: Float.self
                    )
                    minimum = min(minimum, value)
                    maximum = max(maximum, value)
                    if value < 0.999999 {
                        nonClearCount += 1
                    }
                }
            }
            #expect(minimum.isFinite && maximum.isFinite)
            #expect(minimum < 0.7)
            #expect(maximum == 1)
            #expect(nonClearCount > 0)
            #expect(nonClearCount < resolution * resolution)
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        let sampler = try #require(device.makeSamplerState(descriptor: samplerDescriptor))
        let receiverPipeline = try device.makeComputePipelineState(function: receiverFunction)
        var receiverSamples: [SIMD4<Float>] = []
        for slice in 0..<cascadeCount {
            receiverSamples.append(SIMD4<Float>(0.5, 0.5, Float(slice), 0.75))
            receiverSamples.append(SIMD4<Float>(0.98, 0.98, Float(slice), 0.75))
        }
        let receiverBuffer = try #require(device.makeBuffer(
            bytes: receiverSamples,
            length: MemoryLayout<SIMD4<Float>>.stride * receiverSamples.count,
            options: .storageModeShared
        ))
        let resultBuffer = try #require(device.makeBuffer(
            length: MemoryLayout<SIMD4<Float>>.stride * receiverSamples.count,
            options: .storageModeShared
        ))
        try Phase2MetalTestSupport.execute(
            device: device,
            pipeline: receiverPipeline,
            width: receiverSamples.count
        ) { encoder in
            encoder.setTexture(depthTexture, index: 0)
            encoder.setSamplerState(sampler, index: 0)
            encoder.setBuffer(receiverBuffer, offset: 0, index: 0)
            encoder.setBuffer(resultBuffer, offset: 0, index: 1)
        }
        let results = resultBuffer.contents().bindMemory(
            to: SIMD4<Float>.self,
            capacity: receiverSamples.count
        )
        for slice in 0..<cascadeCount {
            let occupied = results[slice * 2]
            let clear = results[slice * 2 + 1]
            #expect(occupied.x < 1)
            #expect(occupied.z == 0)
            #expect(clear.x == 1)
            #expect(clear.z == 1)
            #expect(occupied.x.isFinite && clear.x.isFinite)
        }
    }

    @Test
    func identityTransformConflictsWithLegacySerializedDirection() {
        withKnownIssue("Phase 2A: legacy serialized directions are ignored even when the transform is default") {
            let intendedRay = simd_normalize(SIMD3<Float>(-0.5, -0.8, -0.3))
            let transformRay = TransformMath.directionalLightDirection(from: TransformMath.identityQuaternion)
            #expect(simd_distance(intendedRay, transformRay) < 0.00001)
        }
    }

    @Test
    func currentSlopeFacingUsesTheOppositeOfSurfaceToLight() {
        withKnownIssue("Phase 2A: receiver slope bias evaluates N dot -L") {
            let normal = SIMD3<Float>(0, 1, 0)
            let surfaceToLight = SIMD3<Float>(0, 1, 0)
            #expect(Phase2LegacyCharacterization.slopeFacing(normal: normal, surfaceToLight: surfaceToLight) == 1)
        }
    }
}
