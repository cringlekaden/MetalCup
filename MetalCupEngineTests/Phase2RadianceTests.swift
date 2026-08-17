import Foundation
import Metal
import simd
import Testing
@testable import MetalCupEngine

@Suite("Phase 2 solar track and twilight")
struct Phase2SolarTrackTests {
    @Test
    func equinoxTrackReachesEveryTwilightBandContinuously() {
        let checkpoints: [(Float, Float)] = [
            (12, 55), (17, 12.2), (18, 0), (18.5, -6.1),
            (19, -12.2), (19.5, -18.3), (0, -55), (5.5, -6.1)
        ]
        for (time, expectedElevation) in checkpoints {
            let angles = SkySystem.solarAngles(timeOfDay: time)
            #expect(abs(angles.elevationDegrees - expectedElevation) < 0.35)
            #expect(angles.elevationDegrees.isFinite)
            #expect(angles.azimuthDegrees.isFinite)
        }
        #expect(SkySystem.solarAngles(timeOfDay: 0).elevationDegrees < -24)
        #expect(simd_distance(SkySystem.sunDirection(timeOfDay: 23.999),
                             SkySystem.sunDirection(timeOfDay: 0.001)) < 0.001)
    }

    @Test
    func twilightIsMonotonicAndHasContinuousBoundaryDerivatives() {
        var previous: Float = -1
        for step in 0...250 {
            let elevation = -24 + Float(step) * 0.1
            let value = DaytimeAtmosphereModel.twilightSolarScale(elevationDegrees: elevation)
            #expect(value.isFinite && value >= previous)
            previous = value
        }
        #expect(DaytimeAtmosphereModel.twilightSolarScale(elevationDegrees: -24) == 0)
        #expect(DaytimeAtmosphereModel.twilightSolarScale(elevationDegrees: -18) > 0)
        #expect(DaytimeAtmosphereModel.twilightSolarScale(elevationDegrees: -6) == 0.025)
        #expect(DaytimeAtmosphereModel.twilightSolarScale(elevationDegrees: 1) == 1)

        let epsilon: Float = 0.001
        for knot: Float in [-18, -12, -6, 0, 1] {
            let center = DaytimeAtmosphereModel.twilightSolarScale(elevationDegrees: knot)
            let left = (center - DaytimeAtmosphereModel.twilightSolarScale(elevationDegrees: knot - epsilon)) / epsilon
            let right = (DaytimeAtmosphereModel.twilightSolarScale(elevationDegrees: knot + epsilon) - center) / epsilon
            #expect(abs(left - right) < 0.002)
        }
    }
}

@Suite("Phase 2 static radiance checkpoints")
struct Phase2StaticCheckpointTests {
    struct Checkpoint {
        let name: String
        let time: Float
        let phase: Float
    }

    static let checkpoints = [
        Checkpoint(name: "midday", time: 12, phase: 0),
        Checkpoint(name: "golden-hour", time: 17, phase: 0),
        Checkpoint(name: "sunset", time: 18, phase: 0),
        Checkpoint(name: "civil-twilight", time: 18.5, phase: 0),
        Checkpoint(name: "nautical-twilight", time: 19, phase: 0),
        Checkpoint(name: "astronomical-twilight", time: 19.5, phase: 0),
        Checkpoint(name: "moonless-deep-night", time: 0, phase: 0),
        Checkpoint(name: "quarter-moon", time: 0, phase: 0.25),
        Checkpoint(name: "full-moon", time: 0, phase: 0.5),
        Checkpoint(name: "dawn", time: 5.5, phase: 0)
    ]

    @Test
    func fixedEVAndAutomaticCheckpointOutputsRemainCoherentAndFinite() throws {
        let support = Phase4LegacyCharacterization()
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase3MetalTestSupport.library(device: device)
        let pipeline = try device.makeComputePipelineState(function: #require(
            library.makeFunction(name: "phase4_procedural_sky_component_samples")
        ))
        let hemisphere = support.hemisphereDirections(count: 1_024)
        var daylightGrayLuminance: Float = 0
        var deepNightGrayLuminance: Float = 0

        for checkpoint in Self.checkpoints {
            let state = state(time: checkpoint.time, phase: checkpoint.phase)
            let sun = simd_normalize(state.sunDirection)
            var horizontal = SIMD3<Float>(sun.x, 0, sun.z)
            if simd_length_squared(horizontal) < 1e-8 { horizontal = SIMD3<Float>(1, 0, 0) }
            horizontal = simd_normalize(horizontal)
            let horizonPerpendicular = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), horizontal))
            var params = state.legacySkyParams
            let referenceCount = 5
            let directions = [
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(horizonPerpendicular.x, 0.001, horizonPerpendicular.z, 0),
                SIMD4<Float>(-horizonPerpendicular.x, 0.001, -horizonPerpendicular.z, 0),
                SIMD4<Float>(simd_normalize(state.sunDirection), 0),
                SIMD4<Float>(simd_normalize(state.moonDirection), 0)
            ] + hemisphere.map { SIMD4<Float>($0, 0) }
            let samples = try support.sample(device: device,
                                             pipeline: pipeline,
                                             params: &params,
                                             directions: directions)
            var diffuseIrradiance = SIMD3<Float>(repeating: 0)
            for index in hemisphere.indices {
                diffuseIrradiance += samples.capture[referenceCount + index].xyz * hemisphere[index].y
            }
            diffuseIrradiance *= (2 * Float.pi) / Float(hemisphere.count)

            let direct = max(state.directionalLightDirection.y, 0) * state.directionalLightColor
                * state.directionalLightIntensity
            let diffuseGray = diffuseIrradiance * (0.18 / Float.pi)
            let directGray = direct * (0.18 / Float.pi)
            let neutralGray = diffuseGray + directGray
            let zenith = samples.visible[0].xyz
            let horizon = (samples.visible[1].xyz + samples.visible[2].xyz) * 0.5
            let visibleSun = samples.visible[3].xyz
            let visibleMoon = samples.visible[4].xyz
            let skyMeter = max(luminance((zenith + horizon) * 0.5), 1e-6)
            let groundMeter = max(luminance(neutralGray), 1e-6)
            let mixedMeter = max(skyMeter * 0.5 + groundMeter * 0.5, 1e-6)
            let targetKey = ExposureTargetKeyCurve().key(solarElevationDegrees: state.solarElevationDegrees)
            let autoEV = ExposureHistogramReference.targetEV100(
                meteredLuminance: mixedMeter,
                targetKey: targetKey,
                minimumEV100: 2,
                maximumEV100: 17
            )
            let skyDominantMeter = skyMeter * 0.75 + groundMeter * 0.25
            let groundDominantMeter = skyMeter * 0.25 + groundMeter * 0.75
            let skyEV = ExposureHistogramReference.targetEV100(
                meteredLuminance: skyDominantMeter, targetKey: targetKey,
                minimumEV100: 2, maximumEV100: 17
            )
            let groundEV = ExposureHistogramReference.targetEV100(
                meteredLuminance: groundDominantMeter, targetKey: targetKey,
                minimumEV100: 2, maximumEV100: 17
            )
            let fixedOutput = SceneLinearHDRContract.finalSDROutput(sceneLinear: neutralGray, ev100: 15)
            let autoOutput = SceneLinearHDRContract.finalSDROutput(sceneLinear: neutralGray, ev100: autoEV)
            let maximumHDR = samples.visible.reduce(Float(0)) { max($0, simd_reduce_max($1.xyz)) }

            print("PHASE2_CHECKPOINT name=\(checkpoint.name) time=\(checkpoint.time) elevation=\(state.solarElevationDegrees) "
                + "zenith=\(zenith) horizon=\(horizon) diffuseIBL=\(diffuseIrradiance) "
                + "direct=\(direct) neutral18=\(neutralGray) moonIrradiance=\(state.moonIrradianceRGB) "
                + "sunDisk=\(visibleSun) moonDisk=\(visibleMoon) "
                + "fixedEV100=15 fixedOutput=\(fixedOutput) targetEV100=\(autoEV) autoOutput=\(autoOutput) "
                + "skyGroundEVDrift=\(abs(skyEV - groundEV)) maxHDR=\(maximumHDR) fp16Headroom=\(65_504 / max(maximumHDR, 1e-6))")

            for value in [zenith, horizon, diffuseIrradiance, direct, neutralGray, fixedOutput, autoOutput] {
                #expect(value.x.isFinite && value.y.isFinite && value.z.isFinite)
                #expect(simd_reduce_min(value) >= 0)
            }
            #expect(maximumHDR.isFinite && maximumHDR < 65_504)
            #expect(abs(skyEV - groundEV) < 1.25)
            #expect(state.atmosphereSourceEV == 0)

            if checkpoint.name == "midday" { daylightGrayLuminance = luminance(neutralGray) }
            if checkpoint.name == "moonless-deep-night" { deepNightGrayLuminance = luminance(neutralGray) }
        }
        #expect(daylightGrayLuminance > deepNightGrayLuminance * 1_000)
        #expect(deepNightGrayLuminance > 0)
    }

    private func state(time: Float, phase: Float) -> EnvironmentRenderState {
        var environment = EnvironmentComponent.default
        environment.source.mode = .procedural
        environment.atmosphere.sourceEV = 0
        environment.celestial.defaultTimeOfDay = time
        environment.celestial.moonPhase = phase
        environment.clouds.coverage = 0
        environment.fog.enabled = false
        let runtime = EnvironmentRuntimeStateComponent(seededFrom: environment)
        return EnvironmentRenderStateBuilder.build(environment: environment, runtime: runtime)
    }
}

@Suite("Phase 2 cloud, fog, and capture energy")
struct Phase2MediumEnergyTests {
    @Test
    func productionCloudLightingMatchesCPUAndStaysWithinIncidentBound() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase3MetalTestSupport.library(device: device)
        let pipeline = try device.makeComputePipelineState(function: #require(
            library.makeFunction(name: "phase2_cloud_radiance_reference")
        ))
        for time: Float in [12, 17.5, 0] {
            var environment = EnvironmentComponent.default
            environment.source.mode = .procedural
            environment.atmosphere.sourceEV = 0
            environment.celestial.defaultTimeOfDay = time
            environment.celestial.moonPhase = time == 0 ? 0.5 : 0
            environment.clouds.coverage = 0.65
            let state = EnvironmentRenderStateBuilder.build(environment: environment, runtime: nil)
            var params = state.legacySkyParams
            let inputs = [
                SIMD4<Float>(0, 1, 0, 0.2),
                SIMD4<Float>(simd_normalize(SIMD3<Float>(0.4, 0.4, 0.8)), 0.65),
                SIMD4<Float>(simd_normalize(state.directionalLightDirection), 1)
            ]
            let shapes = [
                SIMD4<Float>(0.9, 0.9, 0.1, 0),
                SIMD4<Float>(0.55, 0.45, 0.65, 0),
                SIMD4<Float>(0.2, 0.15, 1, 0)
            ]
            let inputBuffer = try Phase2MetalTestSupport.makeBuffer(device: device, values: inputs)
            let shapeBuffer = try Phase2MetalTestSupport.makeBuffer(device: device, values: shapes)
            let resultBuffer = try #require(device.makeBuffer(
                length: MemoryLayout<SIMD4<Float>>.stride * inputs.count,
                options: .storageModeShared
            ))
            let paramsBuffer = try withUnsafeBytes(of: &params) { bytes in
                try #require(device.makeBuffer(bytes: bytes.baseAddress!, length: SkyParams.stride, options: .storageModeShared))
            }
            try Phase2MetalTestSupport.execute(device: device, pipeline: pipeline, width: inputs.count) { encoder in
                encoder.setBuffer(paramsBuffer, offset: 0, index: 0)
                encoder.setBuffer(inputBuffer, offset: 0, index: 1)
                encoder.setBuffer(shapeBuffer, offset: 0, index: 2)
                encoder.setBuffer(resultBuffer, offset: 0, index: 3)
            }
            let results = resultBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: inputs.count)
            for index in inputs.indices {
                let gpu = results[index].xyz
                let cpu = cloudReference(viewDirection: inputs[index].xyz,
                                         density: inputs[index].w,
                                         topLight: shapes[index].x,
                                         selfShadow: shapes[index].y,
                                         edgeSignal: shapes[index].z,
                                         params: params)
                let bound = state.skyAmbientRadianceRGB * 1.8
                    + (state.solarIrradianceRGB + state.moonIrradianceRGB) * 0.55
                    + SIMD3<Float>(repeating: 1e-7)
                #expect(simd_distance(gpu, cpu) < 0.000_02)
                #expect(all(gpu .<= bound + SIMD3<Float>(repeating: 0.000_001)))
                #expect(all(gpu .>= .zero))
            }
        }
    }

    @Test
    func fogConsumesLiveFrameRadianceAndIsFiniteAtNight() {
        var environment = EnvironmentComponent.default
        environment.source.mode = .procedural
        environment.atmosphere.sourceEV = 0
        environment.celestial.defaultTimeOfDay = 0
        environment.celestial.moonPhase = 0.5
        environment.fog.enabled = true
        environment.fog.extinction = 0.025
        let state = EnvironmentRenderStateBuilder.build(environment: environment, runtime: nil)
        let patch = state.legacyFogPatch
        #expect(patch.ambientRadiance == state.skyAmbientRadianceRGB)
        #expect(patch.solarIrradiance == state.directionalLightColor * state.directionalLightIntensity)

        let sample = LocalFogTransport.evaluate(
            cameraPosition: SIMD3<Float>(0, 1.7, 0),
            rayDirection: simd_normalize(SIMD3<Float>(0.2, 0.08, 1)),
            distance: 100,
            ambientRadiance: patch.ambientRadiance,
            solarIrradiance: patch.solarIrradiance,
            directionToSun: patch.directionToSun,
            parameters: patch.parameters
        )
        #expect(sample.transmittance >= 0 && sample.transmittance <= 1)
        #expect(all(sample.ambientInscattering .<= patch.ambientRadiance + SIMD3<Float>(repeating: 1e-8)))
        for value in [sample.ambientInscattering, sample.directionalInscattering, sample.inscattering] {
            #expect(value.x.isFinite && value.y.isFinite && value.z.isFinite)
            #expect(all(value .>= .zero))
        }
    }

    @Test
    func sourceEVScalesVisibleMoonAndCloudInputsExactlyOnce() {
        func state(sourceEV: Float) -> EnvironmentRenderState {
            var environment = EnvironmentComponent.default
            environment.source.mode = .procedural
            environment.atmosphere.sourceEV = sourceEV
            environment.celestial.defaultTimeOfDay = 0
            environment.celestial.moonPhase = 0.5
            return EnvironmentRenderStateBuilder.build(environment: environment, runtime: nil)
        }
        let base = state(sourceEV: 0)
        let plusOne = state(sourceEV: 1)
        #expect(simd_distance(plusOne.moonDiskRadianceRGB, base.moonDiskRadianceRGB * 2) < 0.000_01)
        #expect(simd_distance(plusOne.cloudRenderParams.moonIrradianceRGB,
                             base.cloudRenderParams.moonIrradianceRGB * 2) < 0.000_01)
        #expect(abs(plusOne.legacySkyParams.moonIntensity * plusOne.skySourceScale
                    - DaytimeAtmosphereModel.rec709Luminance(plusOne.moonDiskRadianceRGB)) < 0.000_01)
    }

    private func cloudReference(viewDirection: SIMD3<Float>,
                                density: Float,
                                topLight: Float,
                                selfShadow: Float,
                                edgeSignal: Float,
                                params: SkyParams) -> SIMD3<Float> {
        let view = simd_normalize(viewDirection)
        let zero = SIMD3<Float>(repeating: 0)
        let sky = max(params.cloudSkyRadiance.xyz, zero)
        let sun = max(params.cloudSunIrradiance.xyz, zero)
        let moon = max(params.cloudMoonIrradiance.xyz, zero)
        let extinction = max(params.cloudOpticalParams.x, 0.05)
        let g = min(max(params.cloudOpticalParams.y, -0.85), 0.85)
        let multiple = min(max(params.cloudOpticalParams.z, 0), 1.5)
        let opticalShadow = exp(-density * extinction)
        let ambientWrap = mix(0.48, 0.92, topLight) * mix(0.72, 1.18, multiple)
        let ambient = sky * ambientWrap * mix(0.72, 1, opticalShadow)
        let sunPhase = min(hg(simd_dot(view, simd_normalize(params.sunDirection)), g), 0.45)
        let moonPhase = min(hg(simd_dot(view, simd_normalize(params.moonDirection)), g), 0.32)
        let edgeLift = 0.04 + edgeSignal * 0.10
        let directSun = sun * (edgeLift + sunPhase * 0.42) * selfShadow
        let directMoon = moon * (0.035 + moonPhase * 0.34) * selfShadow
        let bound = sky * 1.8 + (sun + moon) * 0.55 + SIMD3<Float>(repeating: 1e-7)
        return min(max(ambient + directSun + directMoon, zero), bound)
    }

    private func hg(_ cosine: Float, _ g: Float) -> Float {
        let gg = g * g
        return (1 - gg) / (4 * Float.pi * pow(max(1 + gg - 2 * g * min(max(cosine, -1), 1), 1e-4), 1.5))
    }

    private func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
}

private func luminance(_ value: SIMD3<Float>) -> Float {
    DaytimeAtmosphereModel.rec709Luminance(value)
}
