import Foundation
import Metal
import Testing
import simd
@testable import MetalCupEngine

@Suite("Engine-wide exposure architecture")
struct ExposureArchitectureTests {
    @Test
    func defaultsCalibrationAndPhysicalCameraArePhotographicallyConsistent() {
        let defaults = ExposurePolicyResolver.engineFallback
        #expect(defaults.mode == .automaticHistogram)
        #expect(defaults.meteringMode == .centerWeighted)
        #expect(defaults.histogramLogMin == -20)
        #expect(defaults.histogramLogMax == 16)
        #expect(defaults.lowPercentile == 0.05)
        #expect(defaults.highPercentile == 0.95)
        #expect(defaults.minimumEV100 == 2)
        #expect(defaults.maximumEV100 == 17)
        #expect(ExposureCalibration.sceneEV100 == 15)
        #expect(ExposureCalibration.exposureGain(ev100: 15, compensation: 0) == 1)
        #expect(ExposureCalibration.exposureGain(ev100: 14, compensation: 0) == 2)
        #expect(abs(ExposureCalibration.physicalEV100(aperture: 16,
                                                     shutterSeconds: 1.0 / 128.0,
                                                     iso: 100) - 15) < 0.000_001)

        let physical = ExposureSettings(mode: .physicalCamera,
                                        aperture: 16,
                                        shutterSeconds: 1.0 / 128.0,
                                        iso: 100)
        #expect(abs(physical.authoredEV100 - 15) < 0.000_001)
    }

    @Test
    func fieldLevelHierarchyBlendsNumericStopsAndResolvesCategoriesAndLocksByPriority() {
        var project = ExposureSettings(mode: .automaticHistogram, compensation: 0)
        project.manualEV100 = 15
        let camera = ExposurePolicyOverride(compensation: 1, manualEV100: 14)
        let lowVolume = ExposureOverrideLayer(
            policy: ExposurePolicyOverride(mode: .manualEV100, compensation: 3),
            weight: 0.49,
            priority: 1,
            source: "Low Volume",
            lockOperation: .lock
        )
        let highVolume = ExposureOverrideLayer(
            policy: ExposurePolicyOverride(mode: .manualEV100, compensation: 5),
            weight: 0.5,
            priority: 2,
            source: "High Volume",
            lockOperation: .unlock
        )
        let runtimeA = ExposureOverrideLayer(
            policy: ExposurePolicyOverride(compensation: 4),
            priority: 10,
            source: "Gameplay A"
        )
        let runtimeB = ExposureOverrideLayer(
            policy: ExposurePolicyOverride(compensation: 4.5),
            priority: 10,
            source: "Gameplay B",
            lockOperation: .lock
        )
        let viewport = ExposureOverrideLayer(
            policy: ExposurePolicyOverride(mode: .physicalCamera, compensation: -1),
            priority: .max,
            source: "Editor Viewport",
            lockOperation: .unlock
        )
        let result = ExposurePolicyResolver.resolve(project: project,
                                                    camera: camera,
                                                    volumes: [highVolume, lowVolume],
                                                    gameplayAndCinematic: [runtimeA, runtimeB],
                                                    viewport: viewport)
        #expect(result.settings.mode == .physicalCamera)
        #expect(result.settings.compensation == -1)
        #expect(result.settings.manualEV100 == 14)
        #expect(result.resolvedSource == "Editor Viewport")
        #expect(!result.isLocked)

        let withoutViewport = ExposurePolicyResolver.resolve(project: project,
                                                             camera: camera,
                                                             volumes: [highVolume, lowVolume],
                                                             gameplayAndCinematic: [runtimeA, runtimeB])
        #expect(withoutViewport.settings.mode == .manualEV100)
        #expect(withoutViewport.settings.compensation == 4.5)
        #expect(withoutViewport.isLocked)
        #expect(withoutViewport.resolvedSource == "Gameplay B")
    }

    @Test
    func targetKeyCurvePreservesDeliberateNightDarkness() {
        let curve = ExposureTargetKeyCurve()
        let dayKey = curve.key(solarElevationDegrees: 30)
        let twilightKey = curve.key(solarElevationDegrees: 0)
        let nightKey = curve.key(solarElevationDegrees: -18)
        #expect(dayKey == 0.18)
        #expect(twilightKey == 0.09)
        #expect(abs(nightKey - 0.04) < 0.000_001)

        let luminance: Float = 0.01
        let dayEV = ExposureHistogramReference.targetEV100(meteredLuminance: luminance,
                                                           targetKey: dayKey,
                                                           minimumEV100: -8,
                                                           maximumEV100: 24)
        let nightEV = ExposureHistogramReference.targetEV100(meteredLuminance: luminance,
                                                             targetKey: nightKey,
                                                             minimumEV100: -8,
                                                             maximumEV100: 24)
        #expect(nightEV > dayEV)
        #expect(ExposureCalibration.exposureGain(ev100: nightEV, compensation: 0)
                < ExposureCalibration.exposureGain(ev100: dayEV, compensation: 0))
    }

    @Test
    func percentileClippingRejectsTinySunAndEmissiveOutliers() {
        let ordinary = Array(repeating: Float(0.18), count: 190)
        let outliers = Array(repeating: Float(65_000), count: 10)
        let histogram = ExposureHistogramReference.histogram(luminances: ordinary + outliers)
        let clipped = ExposureHistogramReference.percentileMeanLuminance(histogram: histogram,
                                                                          lowPercentile: 0.05,
                                                                          highPercentile: 0.95)
        #expect(clipped > 0.15 && clipped < 0.22)

        let skyWeighted = ExposureHistogramReference.histogram(luminances: [0.01, 10], weights: [1, 0.35])
        let unweighted = ExposureHistogramReference.histogram(luminances: [0.01, 10])
        let weightedMeter = ExposureHistogramReference.percentileMeanLuminance(histogram: skyWeighted,
                                                                                lowPercentile: 0,
                                                                                highPercentile: 1)
        let unweightedMeter = ExposureHistogramReference.percentileMeanLuminance(histogram: unweighted,
                                                                                  lowPercentile: 0,
                                                                                  highPercentile: 1)
        #expect(weightedMeter < unweightedMeter)
    }

    @Test
    func asymmetricAdaptationIsMonotonicBoundedAndPauseSafe() {
        let towardDark = ExposureHistogramReference.adaptedEV100(current: 15,
                                                                 target: 5,
                                                                 deltaTime: 0.5,
                                                                 darkAdaptationRate: 3,
                                                                 lightAdaptationRate: 8)
        let towardLight = ExposureHistogramReference.adaptedEV100(current: 5,
                                                                  target: 15,
                                                                  deltaTime: 0.5,
                                                                  darkAdaptationRate: 3,
                                                                  lightAdaptationRate: 8)
        #expect(towardDark == 13.5)
        #expect(towardLight == 9)
        #expect(ExposureHistogramReference.adaptedEV100(current: 9,
                                                       target: 15,
                                                       deltaTime: 0,
                                                       darkAdaptationRate: 3,
                                                       lightAdaptationRate: 8) == 9)
        #expect(ExposureHistogramReference.adaptedEV100(current: 14.9,
                                                       target: 15,
                                                       deltaTime: 1,
                                                       darkAdaptationRate: 3,
                                                       lightAdaptationRate: 8) == 15)
    }

    @Test
    func preExposureReconstructsTrueRadianceAndPreservesBloomThresholdSpace() {
        let trueScene = SIMD3<Float>(0.25, 2, 1000)
        let trueBloom = SIMD3<Float>(0.1, 0.5, 20)
        for preExposure: Float in [1.0 / 1024.0, 0.25, 1, 8, 32] {
            let storedScene = SceneLinearHDRContract.preExposedStorage(trueRadiance: trueScene,
                                                                       renderPreExposure: preExposure)
            let storedBloom = SceneLinearHDRContract.preExposedStorage(trueRadiance: trueBloom,
                                                                       renderPreExposure: preExposure)
            let reconstructed = SceneLinearHDRContract.reconstructCameraLinear(
                storedScene: storedScene,
                storedBloom: storedBloom,
                exposureGain: 4,
                renderPreExposure: preExposure
            )
            expectClose(reconstructed, (trueScene + trueBloom) * 4, tolerance: 0.001)
            #expect((2 * preExposure) >= (1.5 * preExposure))
            #expect((1 * preExposure) < (1.5 * preExposure))
            #expect(storedScene.x.isFinite && storedScene.y.isFinite && storedScene.z.isFinite)
        }
    }

    @Test
    func independentViewsCutsTeleportsPauseScrubsAndCaptureIsolation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var committed: [ExposureViewStateIdentity: ExposureDiagnostics] = [:]
        let system = ExposureSystem(device: device) { committed[$0.identity] = $0 }
        let sceneID = UUID()
        let cameraA = UUID()
        let cameraB = UUID()
        let identityA = ExposureViewStateIdentity(sceneID: sceneID, cameraID: cameraA,
                                                  viewportInstanceID: 1, viewKind: .game)
        let identityB = ExposureViewStateIdentity(sceneID: sceneID, cameraID: cameraB,
                                                  viewportInstanceID: 2, viewKind: .editorScene)
        let automatic = ExposureSettings(mode: .automaticHistogram, useOutdoorPrior: false)
        let firstA = try #require(system.prepare(identity: identityA,
                                                projectDefaults: automatic,
                                                viewSettings: SceneViewExposureSettings(),
                                                solarElevationDegrees: nil,
                                                cameraPosition: .zero,
                                                unscaledDeltaTime: 1.0 / 60.0,
                                                frameIndex: 0))
        #expect(firstA.meteringUniforms.resetHistory == 1)
        writeOutput(ExposureOutputUniforms(exposureGain: 256,
                                           currentEV100: 7,
                                           targetEV100: 7), to: firstA.outputBuffer)
        system.complete(firstA)

        let nextA = try #require(system.prepare(identity: identityA,
                                               projectDefaults: automatic,
                                               viewSettings: SceneViewExposureSettings(adaptationPaused: true),
                                               solarElevationDegrees: nil,
                                               cameraPosition: SIMD3<Float>(1, 0, 0),
                                               unscaledDeltaTime: 10,
                                               frameIndex: 1))
        #expect(nextA.meteringUniforms.resetHistory == 0)
        #expect(nextA.meteringUniforms.deltaTime == 0)
        #expect(readOutput(nextA.outputBuffer).currentEV100 == 7)

        let firstB = try #require(system.prepare(identity: identityB,
                                                projectDefaults: automatic,
                                                viewSettings: SceneViewExposureSettings(),
                                                solarElevationDegrees: nil,
                                                cameraPosition: .zero,
                                                unscaledDeltaTime: 1.0 / 60.0,
                                                frameIndex: 0))
        #expect(readOutput(firstB.outputBuffer).currentEV100 == 15)
        #expect(firstB.outputBuffer !== firstA.outputBuffer)

        system.reset(viewportID: identityB.viewportInstanceID)
        let resetB = try #require(system.prepare(identity: identityB,
                                                projectDefaults: automatic,
                                                viewSettings: SceneViewExposureSettings(),
                                                solarElevationDegrees: nil,
                                                cameraPosition: .zero,
                                                unscaledDeltaTime: 1.0 / 60.0,
                                                frameIndex: 1))
        #expect(resetB.meteringUniforms.resetHistory == 1)

        let teleported = try #require(system.prepare(identity: identityA,
                                                     projectDefaults: automatic,
                                                     viewSettings: SceneViewExposureSettings(),
                                                     solarElevationDegrees: nil,
                                                     cameraPosition: SIMD3<Float>(100, 0, 0),
                                                     unscaledDeltaTime: 1.0 / 60.0,
                                                     frameIndex: 2))
        #expect(teleported.meteringUniforms.resetHistory == 1)

        _ = system.prepare(identity: identityA, projectDefaults: automatic,
                           viewSettings: SceneViewExposureSettings(), solarElevationDegrees: 0,
                           cameraPosition: SIMD3<Float>(100, 0, 0), unscaledDeltaTime: 0.1, frameIndex: 0)
        let scrubbed = try #require(system.prepare(identity: identityA,
                                                  projectDefaults: automatic,
                                                  viewSettings: SceneViewExposureSettings(),
                                                  solarElevationDegrees: 12,
                                                  cameraPosition: SIMD3<Float>(100, 0, 0),
                                                  unscaledDeltaTime: 0.1,
                                                  frameIndex: 1))
        #expect(scrubbed.meteringUniforms.resetHistory == 1)

        system.notify(.cameraCut, identity: identityA)
        let cut = try #require(system.prepare(identity: identityA,
                                             projectDefaults: automatic,
                                             viewSettings: SceneViewExposureSettings(),
                                             solarElevationDegrees: 12,
                                             cameraPosition: SIMD3<Float>(100, 0, 0),
                                             unscaledDeltaTime: 0.1,
                                             frameIndex: 2))
        #expect(cut.meteringUniforms.resetHistory == 1)

        let captureIdentity = ExposureViewStateIdentity(sceneID: sceneID, cameraID: cameraA,
                                                        viewportInstanceID: 3, viewKind: .iblCapture)
        let capture = try #require(system.prepare(identity: captureIdentity,
                                                 projectDefaults: automatic,
                                                 viewSettings: SceneViewExposureSettings(),
                                                 solarElevationDegrees: -18,
                                                 cameraPosition: nil,
                                                 unscaledDeltaTime: 0.1,
                                                 frameIndex: 0))
        let captureOutput = readOutput(capture.outputBuffer)
        #expect(!capture.automatic)
        #expect(capture.meteringUniforms.renderPreExposure == 1)
        #expect(captureOutput.exposureGain == 1)
        #expect(captureOutput.renderPreExposure == 1)
        #expect(committed[captureIdentity] != nil)
    }

    @Test
    func proceduralSolarPriorIsSoftAndHDRIRemainsHistogramOnly() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let system = ExposureSystem(device: device) { _ in }
        let settings = ExposureSettings(mode: .automaticHistogram, useOutdoorPrior: true)
        let sceneID = UUID()
        let proceduralIdentity = ExposureViewStateIdentity(sceneID: sceneID, cameraID: UUID(),
                                                           viewportInstanceID: 80, viewKind: .game)
        let procedural = try #require(system.prepare(identity: proceduralIdentity,
                                                     projectDefaults: settings,
                                                     viewSettings: SceneViewExposureSettings(),
                                                     solarElevationDegrees: -18,
                                                     cameraPosition: .zero,
                                                     unscaledDeltaTime: 1.0 / 60.0,
                                                     frameIndex: 0))
        #expect(procedural.meteringUniforms.outdoorPriorEnabled == 1)
        #expect(procedural.meteringUniforms.outdoorPriorStrength > 2)
        #expect(procedural.meteringUniforms.targetKey < settings.targetKeyCurve.daylightKey)

        let hdriIdentity = ExposureViewStateIdentity(sceneID: sceneID, cameraID: UUID(),
                                                     viewportInstanceID: 81, viewKind: .game)
        let hdri = try #require(system.prepare(identity: hdriIdentity,
                                              projectDefaults: settings,
                                              viewSettings: SceneViewExposureSettings(),
                                              solarElevationDegrees: nil,
                                              cameraPosition: .zero,
                                              unscaledDeltaTime: 1.0 / 60.0,
                                              frameIndex: 0))
        #expect(hdri.meteringUniforms.outdoorPriorEnabled == 0)
        #expect(hdri.meteringUniforms.outdoorPriorStrength == 0)
        #expect(hdri.meteringUniforms.targetKey == settings.targetKeyCurve.daylightKey)
    }

    @Test
    func cameraAndPostProcessPoliciesRoundTripWithoutLegacyExposureFields() throws {
        let maskHandle = AssetHandle(string: "60000000-0000-4000-8000-000000000001")
        let camera = CameraComponent(exposurePolicy: ExposurePolicyOverride(
            mode: .physicalCamera,
            compensation: 0.5,
            aperture: 2.8,
            shutterSeconds: 1.0 / 60.0,
            iso: 400,
            meteringMode: .spot,
            meteringMaskHandle: maskHandle,
            lowPercentile: 0.1,
            highPercentile: 0.9
        ))
        let encodedCamera = try JSONEncoder().encode(CameraComponentDTO(component: camera))
        let cameraJSON = try #require(JSONSerialization.jsonObject(with: encodedCamera) as? [String: Any])
        #expect(cameraJSON["exposurePolicy"] != nil)
        #expect(cameraJSON["exposureEV"] == nil)
        #expect(cameraJSON["autoExposureEnabled"] == nil)
        let decodedCamera = try JSONDecoder().decode(CameraComponentDTO.self, from: encodedCamera).toComponent()
        #expect(decodedCamera.exposurePolicy == camera.exposurePolicy)
        #expect(decodedCamera.exposurePolicy.meteringMaskHandle == maskHandle)

        let volume = PostProcessVolumeComponent(enabled: true,
                                                isGlobal: false,
                                                priority: 20,
                                                blendDistance: 4,
                                                weight: 0.75,
                                                exposure: ExposurePolicyOverride(compensation: 2,
                                                                                 minimumEV100: 4,
                                                                                 maximumEV100: 16))
        let encodedVolume = try JSONEncoder().encode(PostProcessVolumeComponentDTO(component: volume))
        let decodedVolume = try JSONDecoder().decode(PostProcessVolumeComponentDTO.self, from: encodedVolume).toComponent()
        #expect(decodedVolume.enabled == volume.enabled)
        #expect(decodedVolume.isGlobal == volume.isGlobal)
        #expect(decodedVolume.priority == volume.priority)
        #expect(decodedVolume.blendDistance == volume.blendDistance)
        #expect(decodedVolume.weight == volume.weight)
        #expect(decodedVolume.exposure == volume.exposure)
    }

    private func readOutput(_ buffer: MTLBuffer) -> ExposureOutputUniforms {
        buffer.contents().bindMemory(to: ExposureOutputUniforms.self, capacity: 1).pointee
    }

    private func writeOutput(_ output: ExposureOutputUniforms, to buffer: MTLBuffer) {
        var value = output
        withUnsafeBytes(of: &value) { bytes in
            buffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }

    private func expectClose(_ actual: SIMD3<Float>, _ expected: SIMD3<Float>, tolerance: Float) {
        #expect(abs(actual.x - expected.x) <= tolerance)
        #expect(abs(actual.y - expected.y) <= tolerance)
        #expect(abs(actual.z - expected.z) <= tolerance)
    }
}

@Suite("Exposure histogram GPU agreement")
struct ExposureHistogramGPUTests {
    @Test
    func gpuHistogramPercentilesMatchCPUReferenceInTrueRadianceSpace() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase2MetalTestSupport.canonicalLibrary(device: device)
        let histogramFunction = try #require(library.makeFunction(name: "kernel_exposure_histogram"))
        let reductionFunction = try #require(library.makeFunction(name: "kernel_exposure_reduce"))
        let histogramPipeline = try device.makeComputePipelineState(function: histogramFunction)
        let reductionPipeline = try device.makeComputePipelineState(function: reductionFunction)
        let width = 16
        let height = 16
        let luminances: [Float] = [
            0.001, 0.003, 0.01, 0.03,
            0.06, 0.09, 0.12, 0.18,
            0.25, 0.5, 1, 2,
            4, 8, 64, 16_000
        ]
        let renderPreExposure: Float = 4
        var scenePixels = Array(repeating: SIMD4<Float>(0, 0, 0, 1), count: width * height)
        for y in 0..<4 {
            for x in 0..<4 {
                let value = luminances[y * 4 + x] * renderPreExposure
                scenePixels[(y * 4 + 2) * width + (x * 4 + 2)] = SIMD4<Float>(value, value, value, 1)
            }
        }
        let sceneTexture = try makeTexture(device: device, pixelFormat: .rgba32Float,
                                           width: width, height: height,
                                           values: scenePixels)
        let depthTexture = try makeTexture(device: device, pixelFormat: .r32Float,
                                           width: width, height: height,
                                           values: Array(repeating: Float(0.5), count: width * height))
        let maskTexture = try makeTexture(device: device, pixelFormat: .rgba32Float,
                                          width: width, height: height,
                                          values: Array(repeating: SIMD4<Float>(1, 1, 1, 1), count: width * height))
        let histogramBuffer = try #require(device.makeBuffer(length: 130 * MemoryLayout<UInt32>.stride,
                                                             options: .storageModeShared))
        memset(histogramBuffer.contents(), 0, histogramBuffer.length)
        let outputBuffer = try #require(device.makeBuffer(length: ExposureOutputUniforms.stride,
                                                          options: .storageModeShared))
        var output = ExposureOutputUniforms()
        withUnsafeBytes(of: &output) { bytes in
            outputBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        var uniforms = ExposureMeteringUniforms()
        uniforms.viewportWidth = UInt32(width)
        uniforms.viewportHeight = UInt32(height)
        uniforms.meteringMode = ExposureMeteringMode.average.rawValue
        uniforms.resetHistory = 1
        uniforms.lowPercentile = 0.05
        uniforms.highPercentile = 0.95
        uniforms.minimumEV100 = -8
        uniforms.maximumEV100 = 24
        uniforms.targetKey = 0.18
        uniforms.renderPreExposure = renderPreExposure
        uniforms.skyInfluenceCap = 1

        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(histogramPipeline)
        encoder.setTexture(sceneTexture, index: 0)
        encoder.setTexture(depthTexture, index: 1)
        encoder.setTexture(maskTexture, index: 2)
        encoder.setSamplerState(try #require(device.makeSamplerState(descriptor: MTLSamplerDescriptor())), index: 0)
        encoder.setBuffer(histogramBuffer, offset: 0, index: 0)
        encoder.setBytes(&uniforms, length: ExposureMeteringUniforms.stride, index: 1)
        encoder.dispatchThreads(MTLSize(width: 4, height: 4, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 1))
        encoder.setComputePipelineState(reductionPipeline)
        encoder.setBuffer(histogramBuffer, offset: 0, index: 0)
        encoder.setBytes(&uniforms, length: ExposureMeteringUniforms.stride, index: 1)
        encoder.setBuffer(outputBuffer, offset: 0, index: 2)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)

        let gpuHistogramPointer = histogramBuffer.contents().bindMemory(to: UInt32.self, capacity: 130)
        let gpuHistogram = Array(UnsafeBufferPointer(start: gpuHistogramPointer, count: 128))
        let cpuHistogram = ExposureHistogramReference.histogram(luminances: luminances)
        #expect(gpuHistogram == cpuHistogram)
        let gpuOutput = outputBuffer.contents().bindMemory(to: ExposureOutputUniforms.self, capacity: 1).pointee
        let cpuMetered = ExposureHistogramReference.percentileMeanLuminance(histogram: cpuHistogram)
        #expect(abs(log2(gpuOutput.meteredLuminance) - log2(cpuMetered)) < 0.000_1)
        #expect(abs(gpuOutput.targetEV100 - ExposureHistogramReference.targetEV100(
            meteredLuminance: cpuMetered, targetKey: 0.18, minimumEV100: -8, maximumEV100: 24
        )) < 0.000_1)
        #expect(gpuOutput.histogramSampleCount == 16)
        #expect(gpuOutput.maximumStoredHDR >= 16_000 * renderPreExposure * 0.999)
        #expect(gpuOutput.fp16SaturationCount == 0)
    }

    private func makeTexture<T>(device: MTLDevice,
                                pixelFormat: MTLPixelFormat,
                                width: Int,
                                height: Int,
                                values: [T]) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        values.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: width * MemoryLayout<T>.stride)
        }
        return texture
    }
}
