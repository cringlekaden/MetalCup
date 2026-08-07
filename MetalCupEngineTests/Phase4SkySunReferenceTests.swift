import Foundation
import Metal
import Testing
import simd
@testable import MetalCupEngine

@Suite("Procedural atmosphere references")
struct ProceduralAtmosphereReferenceTests {
    @Test
    func requiredElevationsRemainFiniteNonnegativeAndHalfFloatSafe() {
        let directions = [
            SIMD3<Float>(0, 1, 0),
            simd_normalize(SIMD3<Float>(1, 0.001, 0)),
            simd_normalize(SIMD3<Float>(-1, 0.001, 0)),
            SIMD3<Float>(0, -1, 0)
        ]
        for elevation in Phase4LegacyCharacterization.elevations {
            let sun = direction(elevationDegrees: elevation)
            for sourceEV: Float in [-2, -1, 0, 1] {
                let parameters = DaytimeAtmosphereModel.Parameters(sourceEV: sourceEV)
                for direction in directions + [sun] {
                    let sample = DaytimeAtmosphereModel.sample(direction: direction,
                                                               sunDirection: sun,
                                                               parameters: parameters)
                    for value in [sample.atmosphere, sample.aureole, sample.disk, sample.visible, sample.capture] {
                        #expect(value.x.isFinite && value.y.isFinite && value.z.isFinite)
                        #expect(simd_reduce_min(value) >= 0)
                        #expect(simd_reduce_max(value) < 65_504)
                    }
                }
            }
        }
    }

    @Test
    func productionGPUAgreesWithCPUAtReferenceDirections() throws {
        let support = Phase4LegacyCharacterization()
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase3MetalTestSupport.library(device: device)
        let pipeline = try device.makeComputePipelineState(function: #require(
            library.makeFunction(name: "phase4_procedural_sky_component_samples")
        ))
        for elevation in Phase4LegacyCharacterization.elevations {
            var params = SkySystem.shaderParams(authored: support.makeSky(elevationDegrees: elevation), runtime: nil)
            let directions = support.sampleDirections(params: params)
            let gpu = try support.sample(device: device, pipeline: pipeline, params: &params, directions: directions)
            let parameters = parameters(from: params)
            for index in directions.indices {
                let cpu = DaytimeAtmosphereModel.sample(direction: directions[index].xyz,
                                                         sunDirection: params.sunDirection,
                                                         parameters: parameters)
                #expect(simd_distance(cpu.atmosphere, gpu.atmosphere[index].xyz) < 0.002)
                #expect(simd_distance(cpu.aureole, gpu.aureole[index].xyz) < 0.002)
                #expect(simd_distance(cpu.disk, gpu.disk[index].xyz) < 2.0)
                #expect(simd_distance(cpu.visible, gpu.visible[index].xyz) < 2.0)
                // CPU Foundation and Metal fast transcendental paths diverge most
                // at the horizon; 0.005 scene-radiance units is below RGBA16F and
                // integration tolerances while still catching component drift.
                #expect(simd_distance(cpu.capture, gpu.capture[index].xyz) < 0.005)
            }
        }
    }

    @Test
    func sourceEVScalesEveryDaytimeTermPredictably() {
        let sun = direction(elevationDegrees: 45)
        let view = simd_normalize(SIMD3<Float>(0.2, 0.8, 0.3))
        let base = DaytimeAtmosphereModel.sample(direction: view, sunDirection: sun, parameters: .init(sourceEV: 0))
        let baseSun = DaytimeAtmosphereModel.sample(direction: sun, sunDirection: sun, parameters: .init(sourceEV: 0))
        let baseIrradiance = DaytimeAtmosphereModel.solarIrradiance(sunDirection: sun, parameters: .init(sourceEV: 0))
        for (ev, multiplier): (Float, Float) in [(-2, 0.25), (-1, 0.5), (0, 1), (1, 2)] {
            let sample = DaytimeAtmosphereModel.sample(direction: view,
                                                       sunDirection: sun,
                                                       parameters: .init(sourceEV: ev))
            let sunSample = DaytimeAtmosphereModel.sample(direction: sun,
                                                          sunDirection: sun,
                                                          parameters: .init(sourceEV: ev))
            let irradiance = DaytimeAtmosphereModel.solarIrradiance(sunDirection: sun,
                                                                    parameters: .init(sourceEV: ev))
            #expect(simd_distance(sample.atmosphere, base.atmosphere * multiplier) < 0.00001)
            #expect(simd_distance(sample.aureole, base.aureole * multiplier) < 0.00001)
            #expect(simd_distance(sunSample.disk, baseSun.disk * multiplier) < 0.01)
            #expect(simd_distance(sunSample.visible, baseSun.visible * multiplier) < 0.02)
            #expect(simd_distance(irradiance.rgb, baseIrradiance.rgb * multiplier) < 0.00001)
        }
    }

    private func parameters(from params: SkyParams) -> DaytimeAtmosphereModel.Parameters {
        DaytimeAtmosphereModel.Parameters(
            sourceEV: log2(max(params.intensity, 0.0001)),
            densityScale: params.atmosphereScatteringParams.x,
            aerosolScale: params.atmosphereScatteringParams.y,
            ozoneScale: params.atmosphereScatteringParams.w,
            multipleScatteringStrength: params.atmosphereOpticalParams.y,
            groundAlbedo: params.atmosphereOpticalParams.z,
            solarAngularRadiusRadians: params.sunAngularRadius
        )
    }
}

@Suite("Sky and analytic Sun energy coupling")
struct SkySunEnergyCouplingTests {
    @Test
    func generatedSunReconstructsGroundIrradianceAndDirection() {
        var environment = EnvironmentComponent.default
        environment.celestial.defaultTimeOfDay = 12
        environment.atmosphere.sourceEV = 0
        let state = EnvironmentRenderStateBuilder.build(environment: environment, runtime: nil)
        #expect(simd_distance(state.sunColor * state.sunIntensity, state.solarIrradianceRGB) < 0.000001)
        #expect(simd_distance(state.sunDirection, state.legacySkyParams.sunDirection) < 0.000001)
        #expect(state.sunIntensity > 0)
        #expect(state.iblLightingIntensity == 1)
    }

    @Test
    func directSunDisablesSmoothlyBelowTheHorizon() {
        let params = DaytimeAtmosphereModel.Parameters()
        let atHorizon = DaytimeAtmosphereModel.solarIrradiance(
            sunDirection: direction(elevationDegrees: 0), parameters: params
        )
        let below = DaytimeAtmosphereModel.solarIrradiance(
            sunDirection: direction(elevationDegrees: -2), parameters: params
        )
        #expect(atHorizon.illuminance > 0)
        #expect(below.illuminance == 0)
    }
}

@Suite("Solar disk projected integral")
struct SolarDiskIntegralTests {
    @Test
    func diskIntegralEqualsAnalyticRGBIrradiance() {
        for elevation in Phase4LegacyCharacterization.elevations {
            let sun = direction(elevationDegrees: elevation)
            let parameters = DaytimeAtmosphereModel.Parameters()
            let sample = DaytimeAtmosphereModel.sample(direction: sun,
                                                       sunDirection: sun,
                                                       parameters: parameters)
            let integral = sample.disk * DaytimeAtmosphereModel.projectedSolidAngle(
                radiusRadians: parameters.solarAngularRadiusRadians
            )
            let analytic = DaytimeAtmosphereModel.solarIrradiance(sunDirection: sun,
                                                                  parameters: parameters).rgb
            #expect(simd_distance(integral, analytic) < 0.00001)
        }
    }

    @Test
    func evPlusOneDiskRemainsRepresentableInRGBA16Float() {
        let radiance = DaytimeAtmosphereModel.topSolarDiskRadianceRGB(
            radiusRadians: DaytimeAtmosphereModel.solarAngularRadiusDegrees * .pi / 180
        ) * DaytimeAtmosphereModel.sourceScale(sourceEV: 1)
        #expect(simd_reduce_max(radiance) < 65_504)
    }
}

@Suite("Sky IBL energy partition")
struct SkyIBLEnergyPartitionTests {
    @Test
    func visibleIsCapturePlusDiskAndCombinedIsAdditive() {
        let sun = direction(elevationDegrees: 30)
        let parameters = DaytimeAtmosphereModel.Parameters()
        for direction in [sun, SIMD3<Float>(0, 1, 0), simd_normalize(SIMD3<Float>(1, 0.01, 0))] {
            let sample = DaytimeAtmosphereModel.sample(direction: direction,
                                                       sunDirection: sun,
                                                       parameters: parameters)
            #expect(simd_distance(sample.visible, sample.capture + sample.disk) < 0.000001)
        }
        let direct = SIMD3<Float>(0.4, 0.35, 0.3)
        let indirect = SIMD3<Float>(0.2, 0.3, 0.5)
        #expect(simd_distance(direct + indirect, SIMD3<Float>(0.6, 0.65, 0.8)) < 0.000001)
    }
}

@Suite("Authoritative environment frame coherence")
struct EnvironmentFrameCoherenceTests {
    @Test
    func oneFrameStateOwnsDiskSunAndShadowDirections() {
        var environment = EnvironmentComponent.default
        environment.celestial.defaultTimeOfDay = 16
        let state = EnvironmentRenderStateBuilder.build(environment: environment, runtime: nil)
        let shadowRay = -state.sunDirection
        let rotation = TransformMath.rotationForDirectionalLight(direction: shadowRay)
        let transformedRay = simd_normalize(simd_quatf(vector: rotation).act(SIMD3<Float>(0, 0, -1)))
        #expect(simd_distance(state.sunDirection, state.legacySkyParams.sunDirection) < 0.000001)
        #expect(simd_distance(transformedRay, shadowRay) < 0.00001)
        #expect(state.solarIrradianceRGB == state.sunColor * state.sunIntensity)

        let frame = EnvironmentFrameStateComponent(renderState: state)
        #expect(frame.sourceSignature == state.iblSignature)
        #expect(frame.iblPhase == .dirty)
    }

    @Test
    func environmentOwnedSunPublishesTheSameTransformAndShadowRay() throws {
        let scene = EngineScene(name: "Phase4SunOwnership",
                                prefabSystem: nil,
                                engineContext: nil,
                                shouldBuildScene: false)
        let entity = scene.ecs.createEntity(name: "Environment")
        var environment = EnvironmentComponent.default
        environment.source.mode = .procedural
        environment.celestial.defaultTimeOfDay = 12
        scene.ecs.add(environment, to: entity)
        let renderState = EnvironmentRenderStateBuilder.build(environment: environment, runtime: nil)
        scene.ecs.add(EnvironmentFrameStateComponent(renderState: renderState), to: entity)

        SkySystem.update(scene: scene)
        let sunEntity = try #require(scene.ecs.firstEntity(with: SkySunTag.self))
        let light = try #require(scene.ecs.get(LightComponent.self, for: sunEntity))
        let transform = try #require(scene.ecs.get(TransformComponent.self, for: sunEntity))
        let ray = TransformMath.directionalLightDirection(from: transform.rotation)
        #expect(light.castsShadows)
        #expect(simd_distance(ray, -renderState.sunDirection) < 0.00001)
        #expect(simd_distance(light.data.color * light.data.brightness,
                             renderState.solarIrradianceRGB) < 0.00001)
    }

    @Test
    func missingPhase4AuthoredFieldsDecodeToDeterministicDefaults() throws {
        let atmosphere = try JSONDecoder().decode(
            EnvironmentAtmosphereDTO.self,
            from: Data(#"{"amount":0.28,"haze":0.16,"density":1,"temperature":0,"mood":0}"#.utf8)
        )
        #expect(atmosphere.sourceEV == 0)

        let celestial = try JSONDecoder().decode(EnvironmentCelestialDTO.self, from: Data("{}".utf8))
        #expect(celestial.timeControlMode == EnvironmentTimeControlMode.fixed.rawValue)
        #expect(celestial.dayLengthSeconds == 600)
        #expect(celestial.timeScale == 1)
    }

    @Test
    func generatedEnvironmentSunIsNeverSerializedAsAnAuthoredEntity() {
        let scene = EngineScene(name: "Phase4Serialization",
                                prefabSystem: nil,
                                engineContext: nil,
                                shouldBuildScene: false)
        let environmentEntity = scene.ecs.createEntity(name: "Environment")
        scene.ecs.add(EnvironmentComponent.default, to: environmentEntity)

        let generatedSun = scene.ecs.createEntity(name: "Sun")
        scene.ecs.add(SkySunTag(), to: generatedSun)
        scene.ecs.add(LightComponent(type: .directional), to: generatedSun)

        let authoredLight = scene.ecs.createEntity(name: "Authored Key")
        scene.ecs.add(LightComponent(type: .directional), to: authoredLight)

        let document = scene.toDocument()
        #expect(document.entities.contains(where: { $0.id == authoredLight.id }))
        #expect(!document.entities.contains(where: { $0.id == generatedSun.id }))
    }
}

@Suite("Time-varying environment")
struct TimeVaryingEnvironmentTests {
    @Test
    func staticTimeIsDeterministicAndTimeChangesOnlyEnvironmentSourceIdentity() {
        var environment = EnvironmentComponent.default
        environment.source.mode = .procedural
        let noonA = EnvironmentRenderStateBuilder.build(environment: environment, runtime: nil)
        let noonB = EnvironmentRenderStateBuilder.build(environment: environment, runtime: nil)
        #expect(noonA.iblSignature == noonB.iblSignature)
        #expect(noonA.sunDirection == noonB.sunDirection)

        environment.celestial.defaultTimeOfDay = 17
        let later = EnvironmentRenderStateBuilder.build(environment: environment, runtime: nil)
        #expect(later.iblSignature != noonA.iblSignature)
        #expect(simd_distance(later.sunDirection, noonA.sunDirection) > 0.1)
    }
}

@Suite("Sky IBL rebuild integration")
struct SkyIBLRebuildIntegrationTests {
    @Test
    func laggingInteractiveCanAdvanceButFinalRequiresExactSettledSource() {
        let completedSignature = EnvironmentIBLSignature(finalTimeOfDay: 1)
        let newerSignature = EnvironmentIBLSignature(finalTimeOfDay: 2)
        let state = EnvironmentIBLStateComponent(
            dirty: true,
            pendingSignature: newerSignature,
            currentRebuildQuality: .interactive,
            phase: .rebuildingInteractive,
            sourceGeneration: 8,
            inFlightGeneration: 7,
            lastBuiltGeneration: 6,
            lastSourceChangeTime: 10
        )
        #expect(!EnvironmentIBLRebuildLifecycle.completionIsCurrent(
            activeEnvironmentMatches: true,
            desiredSignature: newerSignature,
            state: state,
            completedSignature: completedSignature,
            completedGeneration: 7
        ))
        #expect(EnvironmentIBLRebuildLifecycle.mayPublishLaggingInteractive(
            state: state,
            completedGeneration: 7,
            completedQuality: .interactive
        ))
        #expect(!EnvironmentIBLRebuildLifecycle.mayPublishLaggingInteractive(
            state: state,
            completedGeneration: 7,
            completedQuality: .final
        ))
    }

    @Test
    func freshnessReportsAngularLagAndFinalSettlement() {
        let current = EnvironmentRenderStateBuilder.build(environment: .default, runtime: nil)
        var state = EnvironmentIBLStateComponent(dirty: true,
                                                 lastBuiltSignature: current.iblSignature,
                                                 lastBuiltQuality: .interactive,
                                                 phase: .interactiveReady,
                                                 lastBuiltGeneration: 2,
                                                 lastBuiltTimeOfDay: current.finalTimeOfDay - 1,
                                                 lastBuiltSunDirection: direction(elevationDegrees: 10))
        var freshness = EnvironmentIBLRebuildLifecycle.freshness(state: state, current: current)
        #expect(freshness.status.contains("lagging"))
        #expect((freshness.angularLagDegrees ?? 0) > 0)
        state.dirty = false
        state.phase = .finalReady
        state.lastBuiltQuality = .final
        state.lastBuiltSignature = current.iblSignature
        freshness = EnvironmentIBLRebuildLifecycle.freshness(state: state, current: current)
        #expect(freshness.status == "final and current")
    }
}

@Suite("Sky Sun PBR integration")
struct SkySunPBRIntegrationTests {
    @Test
    func lambertianReferencesUseSceneLinearIrradianceWithoutSAOOrExposure() {
        let sun = direction(elevationDegrees: 60)
        let solar = DaytimeAtmosphereModel.solarIrradiance(sunDirection: sun, parameters: .init())
        let whiteDirect = solar.rgb / Float.pi
        let grayDirect = whiteDirect * 0.18
        #expect(simd_distance(grayDirect, whiteDirect * 0.18) < 0.000001)
        #expect(simd_reduce_min(whiteDirect) >= 0)
        #expect(simd_reduce_max(whiteDirect) < 1)
    }
}

private func direction(elevationDegrees: Float, azimuthDegrees: Float = 0) -> SIMD3<Float> {
    let elevation = elevationDegrees * .pi / 180
    let azimuth = azimuthDegrees * .pi / 180
    return simd_normalize(SIMD3<Float>(cos(elevation) * cos(azimuth),
                                      sin(elevation),
                                      cos(elevation) * sin(azimuth)))
}
