import Metal
import Testing
import simd
@testable import MetalCupEngine

@Suite("Phase 4 procedural-sky energy partition")
struct Phase4LegacyCharacterization {
    static let elevations: [Float] = [90, 60, 30, 10, 5, 0, -2, -6, -12, -18, -24]

    @Test
    func generatedSunDirectionAlreadyMatchesTheVisibleDisk() {
        for elevation in Self.elevations {
            let sky = makeSky(elevationDegrees: elevation)
            let derived = SkySystem.derivedAtmosphere(authored: sky, runtime: nil)
            let params = SkySystem.shaderParams(authored: sky, runtime: nil)
            #expect(simd_distance(derived.sunDirectionWorld, params.sunDirection) < 0.000001)
            #expect(simd_distance(derived.sunRayDirectionWorld, -params.sunDirection) < 0.000001)
        }
    }

    @Test
    func captureExcludesOnlyTheUnscatteredSolarDisk() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase3MetalTestSupport.library(device: device)
        let pipeline = try device.makeComputePipelineState(function: #require(
            library.makeFunction(name: "phase4_procedural_sky_component_samples")
        ))
        var params = SkySystem.shaderParams(authored: makeSky(elevationDegrees: 60), runtime: nil)
        let sun = simd_normalize(params.sunDirection)
        let results = try sample(device: device, pipeline: pipeline, params: &params, directions: [SIMD4<Float>(sun, 0)])

        let visible = results.visible[0].xyz
        let capture = results.capture[0].xyz
        let disk = results.disk[0].xyz
        #expect(simd_distance(visible - capture, disk) < 0.01)
        #expect(luminance(disk) > 0.1)
    }

    @Test
    func legacySolarAndSkyEnergySnapshot() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase3MetalTestSupport.library(device: device)
        let pipeline = try device.makeComputePipelineState(function: #require(
            library.makeFunction(name: "phase4_procedural_sky_component_samples")
        ))

        for elevation in Self.elevations {
            let sky = makeSky(elevationDegrees: elevation)
            var params = SkySystem.shaderParams(authored: sky, runtime: nil)
            let referenceDirections = sampleDirections(params: params)
            let integrationDirections = hemisphereDirections(count: 2048)
            let directions = referenceDirections + integrationDirections.map { SIMD4<Float>($0, 0) }
            let results = try sample(device: device, pipeline: pipeline, params: &params, directions: directions)

            var skyIrradiance = SIMD3<Float>(repeating: 0)
            for index in integrationDirections.indices {
                let direction = integrationDirections[index]
                let sampleIndex = referenceDirections.count + index
                let radiance = results.atmosphere[sampleIndex].xyz + results.aureole[sampleIndex].xyz
                skyIrradiance += radiance * max(direction.y, 0)
            }
            skyIrradiance *= (2 * Float.pi) / Float(integrationDirections.count)

            let diskCenter = results.disk[1].xyz
            let projectedSolidAngle = Float.pi * pow(sin(params.sunAngularRadius), 2)
            let diskProjectedIntegral = diskCenter * projectedSolidAngle
            let analyticIrradiance = DaytimeAtmosphereModel.topSolarIrradianceRGB()
                * params.solarExtinctionTint
                * params.solarVisibility
                * params.intensity
            let directToSky = luminance(analyticIrradiance) / max(luminance(skyIrradiance), 0.000001)
            let maximum = results.visible.reduce(Float(0)) { max($0, simd_reduce_max($1.xyz)) }

            print(
                "PHASE4_REPAIRED elevation=\(elevation) "
                    + "zenith=\(results.visible[0].xyz) "
                    + "disk=\(results.visible[1].xyz) "
                    + "horizonSun=\(results.visible[2].xyz) "
                    + "horizonOpposite=\(results.visible[3].xyz) "
                    + "rightAngle=\(results.visible[4].xyz) "
                    + "aureole=\(results.visible[5].xyz) "
                    + "ground=\(results.visible[6].xyz) "
                    + "diskIntegral=\(diskProjectedIntegral) "
                    + "analytic=\(analyticIrradiance) "
                    + "skyIrradiance=\(skyIrradiance) "
                    + "white=\(skyIrradiance / Float.pi) "
                    + "gray=\(skyIrradiance * (0.18 / Float.pi)) "
                    + "directToSky=\(directToSky) max=\(maximum)"
            )

            #expect(skyIrradiance.x.isFinite && skyIrradiance.y.isFinite && skyIrradiance.z.isFinite)
            #expect(analyticIrradiance.x.isFinite && analyticIrradiance.y.isFinite && analyticIrradiance.z.isFinite)
            #expect(maximum < 65_504)
            for index in referenceDirections.indices {
                #expect(simd_distance(results.visible[index].xyz - results.capture[index].xyz,
                                      results.disk[index].xyz) < 0.02)
            }

            if elevation == 60 {
                #expect(simd_distance(analyticIrradiance, diskProjectedIntegral) < 0.01)
            }
        }
    }

    func makeSky(elevationDegrees: Float) -> SkyLightComponent {
        SkyLightComponent(
            mode: .procedural,
            timeOfDay: 12,
            moonIntensity: 0,
            starIntensity: 0,
            intensity: 1,
            azimuthDegrees: 0,
            elevationDegrees: elevationDegrees,
            cloudsEnabled: false
        )
    }

    func sampleDirections(params: SkyParams) -> [SIMD4<Float>] {
        let sun = simd_normalize(params.sunDirection)
        var horizontal = SIMD3<Float>(sun.x, 0, sun.z)
        if simd_length_squared(horizontal) < 0.000001 {
            horizontal = SIMD3<Float>(1, 0, 0)
        }
        horizontal = simd_normalize(horizontal)
        let tangent = simd_normalize(simd_cross(sun, abs(sun.y) < 0.95 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(0, 0, 1)))
        let aureoleAngle = max(params.sunAngularRadius * 4, 0.02)
        let aureole = simd_normalize(sun * cos(aureoleAngle) + tangent * sin(aureoleAngle))
        return [
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(sun, 0),
            SIMD4<Float>(horizontal.x, 0.001, horizontal.z, 0),
            SIMD4<Float>(-horizontal.x, 0.001, -horizontal.z, 0),
            SIMD4<Float>(0, 0.001, 1, 0),
            SIMD4<Float>(aureole, 0),
            SIMD4<Float>(0, -1, 0, 0)
        ]
    }

    func hemisphereDirections(count: Int) -> [SIMD3<Float>] {
        let goldenAngle = Float.pi * (3 - sqrt(5 as Float))
        return (0..<count).map { index in
            let y = (Float(index) + 0.5) / Float(count)
            let radius = sqrt(max(0, 1 - y * y))
            let phi = Float(index) * goldenAngle
            return SIMD3<Float>(cos(phi) * radius, y, sin(phi) * radius)
        }
    }

    func sample(device: MTLDevice,
                        pipeline: MTLComputePipelineState,
                        params: inout SkyParams,
                        directions: [SIMD4<Float>]) throws -> SkyComponentSamples {
        let paramsBuffer = try withUnsafeBytes(of: &params) { bytes in
            try #require(device.makeBuffer(bytes: bytes.baseAddress!, length: SkyParams.stride, options: .storageModeShared))
        }
        let directionBuffer = try Phase2MetalTestSupport.makeBuffer(device: device, values: directions)
        let byteCount = MemoryLayout<SIMD4<Float>>.stride * directions.count
        let buffers = try (0..<5).map { _ in
            try #require(device.makeBuffer(length: byteCount, options: .storageModeShared))
        }
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: 1,
            height: 1,
            mipmapped: false
        )
        textureDescriptor.usage = .shaderRead
        let fallbackTexture = try #require(device.makeTexture(descriptor: textureDescriptor))

        try Phase2MetalTestSupport.execute(device: device, pipeline: pipeline, width: directions.count) { encoder in
            encoder.setBuffer(paramsBuffer, offset: 0, index: 0)
            encoder.setBuffer(directionBuffer, offset: 0, index: 1)
            for index in buffers.indices {
                encoder.setBuffer(buffers[index], offset: 0, index: index + 2)
            }
            encoder.setTexture(fallbackTexture, index: 0)
            encoder.setTexture(fallbackTexture, index: 1)
            encoder.setTexture(fallbackTexture, index: 2)
        }

        func values(_ buffer: MTLBuffer) -> [SIMD4<Float>] {
            let pointer = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: directions.count)
            return Array(UnsafeBufferPointer(start: pointer, count: directions.count))
        }
        return SkyComponentSamples(
            atmosphere: values(buffers[0]),
            disk: values(buffers[1]),
            aureole: values(buffers[2]),
            visible: values(buffers[3]),
            capture: values(buffers[4])
        )
    }

    func luminance(_ color: SIMD3<Float>) -> Float {
        simd_dot(color, SIMD3<Float>(0.2126, 0.7152, 0.0722))
    }
}

struct SkyComponentSamples {
    var atmosphere: [SIMD4<Float>]
    var disk: [SIMD4<Float>]
    var aureole: [SIMD4<Float>]
    var visible: [SIMD4<Float>]
    var capture: [SIMD4<Float>]
}
