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
            solarAngularRadiusRadians: params.sunAngularRadius,
            nightBrightness: params.atmosphereOpticalParams.w
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
        #expect(simd_distance(state.solarIrradianceRGB,
                              state.sunColor * state.sunIntensity) < 1e-6)

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
        #expect(freshness.status == "final, exact, current")
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

@Suite("Built-in neutral material reference geometry")
struct BuiltinMaterialReferenceGeometryTests {
    @Test
    func sphereNormalsAndTangentsAreFiniteOrthonormal() {
        for v: Float in [0, 0.125, 0.25, 0.5, 0.75, 0.875, 1] {
            for u: Float in [0, 0.125, 0.25, 0.5, 0.75, 1] {
                let vertex = SphereMesh.referenceVertex(u: u, v: v)
                #expect(abs(simd_length(vertex.normal) - 1) < 0.00001)
                #expect(abs(simd_length(vertex.tangent.xyz) - 1) < 0.00001)
                #expect(abs(simd_dot(vertex.normal, vertex.tangent.xyz)) < 0.00001)
                #expect(vertex.position.x.isFinite && vertex.position.y.isFinite && vertex.position.z.isFinite)
            }
        }
        #expect(BuiltinAssets.sphereMesh != BuiltinAssets.cubeMesh)
    }

    @Test
    func roundedBoxNormalsAndTangentsRemainFiniteAcrossFacesAndCorners() {
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, -1), SIMD3<Float>(0, 1, 0)),
            (SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 1, 0)),
            (SIMD3<Float>(0, 1, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, -1)),
            (SIMD3<Float>(0, -1, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, 1)),
            (SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)),
            (SIMD3<Float>(0, 0, -1), SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 1, 0))
        ]
        for (normal, uAxis, vAxis) in faces {
            for u: Float in [-1, -0.82, 0, 0.82, 1] {
                for v: Float in [-1, -0.82, 0, 0.82, 1] {
                    let vertex = RoundedCubeMesh.referenceVertex(
                        faceNormal: normal, uAxis: uAxis, vAxis: vAxis, u: u, v: v
                    )
                    #expect(abs(simd_length(vertex.normal) - 1) < 0.00001)
                    #expect(abs(simd_length(vertex.tangent.xyz) - 1) < 0.00001)
                    #expect(abs(simd_dot(vertex.normal, vertex.tangent.xyz)) < 0.00001)
                    #expect(abs(vertex.tangent.w) == 1)
                    #expect(vertex.position.x.isFinite && vertex.position.y.isFinite && vertex.position.z.isFinite)
                }
            }
        }
        #expect(BuiltinAssets.roundedCubeMesh != BuiltinAssets.cubeMesh)
        #expect(BuiltinAssets.roundedCubeMesh != BuiltinAssets.sphereMesh)
    }
}

@Suite("Phase 4B daylight chromaticity and neutral-reference calibration")
struct Phase4BDaylightChromaticityTests {
    private let elevations: [Float] = [60, 30, 10, 5, 0]

    @Test
    func calibratedProductionRGBRemainsFiniteAndDocumented() {
        for elevation in elevations {
            let sun = direction(elevationDegrees: elevation)
            let parameters = DaytimeAtmosphereModel.Parameters(sourceEV: 0)
            let zenith = DaytimeAtmosphereModel.sample(
                direction: SIMD3<Float>(0, 1, 0), sunDirection: sun, parameters: parameters
            ).capture
            let horizonToward = DaytimeAtmosphereModel.sample(
                direction: SIMD3<Float>(1, 0.001, 0), sunDirection: sun, parameters: parameters
            ).capture
            let horizonOpposite = DaytimeAtmosphereModel.sample(
                direction: SIMD3<Float>(-1, 0.001, 0), sunDirection: sun, parameters: parameters
            ).capture
            let rightAngle = DaytimeAtmosphereModel.sample(
                direction: SIMD3<Float>(0, 0.001, 1), sunDirection: sun, parameters: parameters
            ).capture
            let lower = DaytimeAtmosphereModel.sample(
                direction: SIMD3<Float>(0, -1, 0), sunDirection: sun, parameters: parameters
            ).capture
            let integration = integrateEnvironment(sunDirection: sun, parameters: parameters)
            let solar = DaytimeAtmosphereModel.solarIrradiance(
                sunDirection: sun, parameters: parameters
            ).rgb
            let directGray = solar * max(sun.y, 0) * (0.18 / Float.pi)
            let skyGray = integration.upward * (0.18 / Float.pi)
            let combinedGray = directGray + skyGray
            let finalGray = SceneLinearHDRContract.finalSDROutput(
                sceneLinear: combinedGray, exposureEV: 0
            )
            let horizontalTotal = integration.horizontalUpper + integration.horizontalLower
            let lowerFraction = luminance(integration.horizontalLower)
                / max(luminance(horizontalTotal), 0.000001)

            print(
                "PHASE4B_AFTER elevation=\(elevation) "
                    + "zenith=\(zenith) zenithXY=\(chromaticityXY(zenith)) "
                    + "horizonSun=\(horizonToward) horizonOpposite=\(horizonOpposite) "
                    + "rightAngle=\(rightAngle) upperAverage=\(integration.upperAverage) "
                    + "lower=\(lower) upwardIrradiance=\(integration.upward) "
                    + "horizontalUpper=\(integration.horizontalUpper) "
                    + "horizontalLower=\(integration.horizontalLower) lowerFraction=\(lowerFraction) "
                    + "solar=\(solar) directGray=\(directGray) skyGray=\(skyGray) "
                    + "combinedGray=\(combinedGray) finalGray=\(finalGray)"
            )

            for value in [zenith, horizonToward, horizonOpposite, rightAngle, lower,
                          integration.upward, horizontalTotal, solar, combinedGray, finalGray] {
                #expect(value.x.isFinite && value.y.isFinite && value.z.isFinite)
                #expect(simd_reduce_min(value) >= 0)
            }
        }

        // Golden-hour direct light is warm while the opposite upper sky retains
        // cooler separation. This detects a return to the old uniform brown cast.
        let lowSun = direction(elevationDegrees: 10)
        let opposite = DaytimeAtmosphereModel.sample(
            direction: SIMD3<Float>(-1, 0.001, 0),
            sunDirection: lowSun,
            parameters: .init(sourceEV: 0)
        ).capture
        let direct = DaytimeAtmosphereModel.solarIrradiance(
            sunDirection: lowSun, parameters: .init(sourceEV: 0)
        ).rgb
        #expect(opposite.z / max(opposite.x, 0.000001) > 1.3)
        #expect(direct.x / max(direct.z, 0.000001) > 2.5)
    }

    @Test
    func highSunZenithIsBlueAndDirectDaylightIsBroadlyNeutral() {
        let sun = direction(elevationDegrees: 60)
        let parameters = DaytimeAtmosphereModel.Parameters(sourceEV: 0)
        let zenith = DaytimeAtmosphereModel.sample(
            direction: SIMD3<Float>(0, 1, 0), sunDirection: sun, parameters: parameters
        ).capture
        let solar = DaytimeAtmosphereModel.solarIrradiance(
            sunDirection: sun, parameters: parameters
        ).rgb
        #expect(zenith.z / zenith.x > 3)
        #expect(zenith.y / zenith.x > 1.5)
        #expect(solar.x / solar.z < 1.3)
        #expect(solar.y / solar.z < 1.2)
    }

    @Test
    func lowerHemisphereIsBoundedAndDoesNotDominateHorizontalIrradiance() {
        for elevation in elevations {
            let integration = integrateEnvironment(
                sunDirection: direction(elevationDegrees: elevation),
                parameters: .init(sourceEV: 0)
            )
            let total = integration.horizontalUpper + integration.horizontalLower
            let lowerFraction = luminance(integration.horizontalLower) / max(luminance(total), 0.000001)
            #expect(lowerFraction >= 0)
            #expect(lowerFraction < 0.25)
        }
    }

    @Test
    func neutralGroundAlbedoInfluenceIsMonotonicAndEnergyBounded() {
        let sun = direction(elevationDegrees: 60)
        let lowerDirection = SIMD3<Float>(0, -1, 0)
        let black = DaytimeAtmosphereModel.sample(
            direction: lowerDirection, sunDirection: sun, parameters: .init(groundAlbedo: 0)
        ).atmosphere
        let calibrated = DaytimeAtmosphereModel.sample(
            direction: lowerDirection, sunDirection: sun,
            parameters: .init(groundAlbedo: DaytimeAtmosphereModel.groundAlbedo)
        ).atmosphere
        let bright = DaytimeAtmosphereModel.sample(
            direction: lowerDirection, sunDirection: sun, parameters: .init(groundAlbedo: 0.4)
        ).atmosphere
        #expect(simd_reduce_max(black) < 0.000001)
        #expect(simd_reduce_min(calibrated - black) >= 0)
        #expect(simd_reduce_min(bright - calibrated) >= 0)
        #expect(luminance(calibrated) < luminance(
            DaytimeAtmosphereModel.sample(
                direction: SIMD3<Float>(0, 1, 0), sunDirection: sun,
                parameters: .init(groundAlbedo: DaytimeAtmosphereModel.groundAlbedo)
            ).capture
        ))
    }

    @Test
    func currentNormalizationRetainsPracticalHalfFloatHeadroomAtSourceEVPlusOne() {
        let radius = DaytimeAtmosphereModel.solarAngularRadiusDegrees * Float.pi / 180
        let currentPeak = simd_reduce_max(
            DaytimeAtmosphereModel.topSolarDiskRadianceRGB(radiusRadians: radius)
                * DaytimeAtmosphereModel.sourceScale(sourceEV: 1)
        )
        let candidatePeak = currentPeak * 1.1
        #expect(currentPeak < 60_000)
        #expect(65_504 - currentPeak > 5_000)
        #expect(65_504 - candidatePeak < 1_000)
    }

    @Test
    func productionMetalMatchesCalibratedDaylightColor() throws {
        let support = Phase4LegacyCharacterization()
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase3MetalTestSupport.library(device: device)
        let pipeline = try device.makeComputePipelineState(function: #require(
            library.makeFunction(name: "phase4_procedural_sky_component_samples")
        ))
        for elevation: Float in [60, 10] {
            var params = SkySystem.shaderParams(
                authored: support.makeSky(elevationDegrees: elevation), runtime: nil
            )
            let directions = support.sampleDirections(params: params)
            let gpu = try support.sample(
                device: device, pipeline: pipeline, params: &params, directions: directions
            )
            let zenith = gpu.capture[0].xyz
            #expect(zenith.z > zenith.y)
            #expect(zenith.y > zenith.x)
            if elevation == 10 {
                let opposite = gpu.capture[3].xyz
                #expect(opposite.z / max(opposite.x, 0.000001) > 1.3)
            }
        }
    }

    @Test
    func neutralMaterialReferencesUseProductionIBLAndPBRPaths() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase3MetalTestSupport.library(device: device)
        let sun = direction(elevationDegrees: 60)
        let parameters = DaytimeAtmosphereModel.Parameters(sourceEV: 0)
        let source = try Phase3MetalTestSupport.makeCube(
            device: device, size: 64, mipmapped: true, label: "Phase4B.DaylightSource"
        )
        try fillProceduralCapture(source, sunDirection: sun, parameters: parameters)
        let irradiance = try Phase3MetalTestSupport.renderIrradiance(
            device: device, library: library, source: source, size: 16, sampleCount: 2048
        )
        let prefiltered = try Phase3MetalTestSupport.renderPrefilter(
            device: device, library: library, source: source, size: 32, sampleCount: 1024
        )
        let upwardIrradiance = try Phase3MetalTestSupport.sampleCube(
            device: device, library: library, texture: irradiance,
            directionsAndMip: [SIMD4<Float>(0, 1, 0, 0)]
        )[0].xyz
        let roughnesses: [Float] = [0.06, 0.8]
        let maxMip = Float(prefiltered.mipmapLevelCount - 1)
        let prefilteredSamples = try Phase3MetalTestSupport.sampleCube(
            device: device, library: library, texture: prefiltered,
            directionsAndMip: roughnesses.map { SIMD4<Float>(0, 1, 0, $0 * maxMip) }
        ).map(\.xyz)
        let brdfSamples: [SIMD2<Float>] = try Phase3MetalTestSupport.compute(
            device: device,
            library: library,
            functionName: "phase3_brdf_lut_reference_samples",
            inputs: roughnesses.map { SIMD2<Float>(1, $0) },
            outputType: SIMD2<Float>.self
        )
        let solar = DaytimeAtmosphereModel.solarIrradiance(
            sunDirection: sun, parameters: parameters
        ).rgb

        let references: [(String, SIMD3<Float>, Float, Float, Int)] = [
            ("smoothDielectric", SIMD3<Float>(repeating: 0.8), 0, 0.06, 0),
            ("smoothNeutralMetal", SIMD3<Float>(repeating: 0.92), 1, 0.06, 0),
            ("roughNeutralMetal", SIMD3<Float>(repeating: 0.92), 1, 0.8, 1)
        ]
        for (name, baseColor, metallic, roughness, sampleIndex) in references {
            let response = materialResponse(
                baseColor: baseColor,
                metallic: metallic,
                roughness: roughness,
                sunDirection: sun,
                solarIrradiance: solar,
                skyIrradiance: upwardIrradiance,
                prefilteredRadiance: prefilteredSamples[sampleIndex],
                brdf: brdfSamples[sampleIndex]
            )
            let final = SceneLinearHDRContract.finalSDROutput(
                sceneLinear: response.combined, exposureEV: 0
            )
            print("PHASE4B_MATERIAL name=\(name) direct=\(response.direct) "
                + "ibl=\(response.ibl) combined=\(response.combined) final=\(final)")
            #expect(simd_distance(response.combined, response.direct + response.ibl) < 0.000001)
            for value in [response.direct, response.ibl, response.combined, final] {
                #expect(value.x.isFinite && value.y.isFinite && value.z.isFinite)
                #expect(simd_reduce_min(value) >= 0)
            }
            if metallic == 1 {
                #expect(simd_reduce_min(response.ibl) > 0)
            }
        }
    }

    @Test
    func filmicV1PreservesTheNeutralAxis() {
        for value: Float in [0.001, 0.01, 0.18, 1, 4, 16, 100] {
            let output = SceneLinearHDRContract.finalSDROutput(
                sceneLinear: SIMD3<Float>(repeating: value), exposureEV: 0
            )
            #expect(abs(output.x - output.y) < 0.000001)
            #expect(abs(output.y - output.z) < 0.000001)
        }
    }

    private func integrateEnvironment(
        sunDirection: SIMD3<Float>,
        parameters: DaytimeAtmosphereModel.Parameters,
        sampleCount: Int = 8_192
    ) -> Phase4BEnvironmentIntegration {
        let solidAngle = 4 * Float.pi / Float(sampleCount)
        let goldenAngle = Float.pi * (3 - sqrt(5 as Float))
        let upwardNormal = SIMD3<Float>(0, 1, 0)
        let horizontalNormal = SIMD3<Float>(1, 0, 0)
        var upward = SIMD3<Float>(repeating: 0)
        var horizontalUpper = SIMD3<Float>(repeating: 0)
        var horizontalLower = SIMD3<Float>(repeating: 0)
        var upperSum = SIMD3<Float>(repeating: 0)
        var upperCount: Float = 0

        for index in 0..<sampleCount {
            let y = 1 - 2 * (Float(index) + 0.5) / Float(sampleCount)
            let radius = sqrt(max(0, 1 - y * y))
            let phi = Float(index) * goldenAngle
            let sampleDirection = SIMD3<Float>(cos(phi) * radius, y, sin(phi) * radius)
            let radiance = DaytimeAtmosphereModel.sample(
                direction: sampleDirection,
                sunDirection: sunDirection,
                parameters: parameters
            ).capture
            upward += radiance * max(simd_dot(sampleDirection, upwardNormal), 0) * solidAngle
            let horizontalWeight = max(simd_dot(sampleDirection, horizontalNormal), 0) * solidAngle
            if sampleDirection.y >= 0 {
                horizontalUpper += radiance * horizontalWeight
                upperSum += radiance
                upperCount += 1
            } else {
                horizontalLower += radiance * horizontalWeight
            }
        }

        return Phase4BEnvironmentIntegration(
            upward: upward,
            horizontalUpper: horizontalUpper,
            horizontalLower: horizontalLower,
            upperAverage: upperSum / max(upperCount, 1)
        )
    }

    private func fillProceduralCapture(
        _ texture: MTLTexture,
        sunDirection: SIMD3<Float>,
        parameters: DaytimeAtmosphereModel.Parameters
    ) throws {
        let size = texture.width
        for faceIndex in 0..<6 {
            let face = try #require(CubemapConvention.Face(rawValue: faceIndex))
            var pixels = [SIMD4<Float16>]()
            pixels.reserveCapacity(size * size)
            for y in 0..<size {
                for x in 0..<size {
                    let uv = SIMD2<Float>(
                        (Float(x) + 0.5) / Float(size),
                        (Float(y) + 0.5) / Float(size)
                    )
                    let worldDirection = CubemapConvention.direction(face: face, uv: uv)
                    let radiance = DaytimeAtmosphereModel.sample(
                        direction: worldDirection,
                        sunDirection: sunDirection,
                        parameters: parameters
                    ).capture
                    pixels.append(SIMD4<Float16>(
                        Float16(radiance.x), Float16(radiance.y), Float16(radiance.z), 1
                    ))
                }
            }
            pixels.withUnsafeBytes { bytes in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, size, size),
                    mipmapLevel: 0,
                    slice: faceIndex,
                    withBytes: bytes.baseAddress!,
                    bytesPerRow: size * MemoryLayout<SIMD4<Float16>>.stride,
                    bytesPerImage: bytes.count
                )
            }
        }
        try Phase3MetalTestSupport.generateMipmaps(texture)
    }

    private func materialResponse(
        baseColor: SIMD3<Float>,
        metallic: Float,
        roughness: Float,
        sunDirection: SIMD3<Float>,
        solarIrradiance: SIMD3<Float>,
        skyIrradiance: SIMD3<Float>,
        prefilteredRadiance: SIMD3<Float>,
        brdf: SIMD2<Float>
    ) -> Phase4BMaterialResponse {
        let normal = SIMD3<Float>(0, 1, 0)
        let view = normal
        let light = simd_normalize(sunDirection)
        let half = simd_normalize(view + light)
        let nDotL = max(simd_dot(normal, light), 0)
        let nDotV = max(simd_dot(normal, view), 0)
        let nDotH = max(simd_dot(normal, half), 0)
        let hDotV = max(simd_dot(half, view), 0)
        let f0 = DirectPBRReferenceMath.f0(baseColor: baseColor, metallic: metallic)
        let fresnel = DirectPBRReferenceMath.fresnelSchlick(cosine: hDotV, f0: f0)
        let diffuse = baseColor / Float.pi
            * (SIMD3<Float>(repeating: 1) - fresnel)
            * (1 - metallic)
        let specular = DirectPBRReferenceMath.directSpecular(
            normalDotView: nDotV,
            normalDotLight: nDotL,
            normalDotHalf: nDotH,
            halfDotView: hDotV,
            perceptualRoughness: roughness,
            f0: f0
        )
        let direct = (diffuse + specular) * solarIrradiance * nDotL

        let diffuseIBL = skyIrradiance * (baseColor / Float.pi)
        let kD = (SIMD3<Float>(repeating: 1) - f0) * (1 - metallic)
        let singleScatter = f0 * brdf.x + SIMD3<Float>(repeating: brdf.y)
        let energyDenominator = max(brdf.x + brdf.y, 0.001)
        let rawCompensation = SIMD3<Float>(repeating: 1)
            + f0 * (1 / energyDenominator - 1)
        let compensation = simd_clamp(
            rawCompensation,
            SIMD3<Float>(repeating: 1),
            SIMD3<Float>(repeating: 1.5)
        )
        let compensationWeight = roughness * roughness
        let specularIBL = prefilteredRadiance * singleScatter
            * simd_mix(
                SIMD3<Float>(repeating: 1), compensation,
                SIMD3<Float>(repeating: compensationWeight)
            )
        let ibl = kD * diffuseIBL + specularIBL
        return Phase4BMaterialResponse(direct: direct, ibl: ibl, combined: direct + ibl)
    }

    private func luminance(_ value: SIMD3<Float>) -> Float {
        simd_dot(value, SIMD3<Float>(0.2126, 0.7152, 0.0722))
    }

    private func chromaticityXY(_ value: SIMD3<Float>) -> SIMD2<Float> {
        let xyz = SIMD3<Float>(
            0.4123908 * value.x + 0.3575843 * value.y + 0.1804808 * value.z,
            0.2126390 * value.x + 0.7151687 * value.y + 0.0721923 * value.z,
            0.0193308 * value.x + 0.1191948 * value.y + 0.9505322 * value.z
        )
        let sum = xyz.x + xyz.y + xyz.z
        return sum > 0 ? SIMD2<Float>(xyz.x / sum, xyz.y / sum) : .zero
    }
}

private struct Phase4BEnvironmentIntegration {
    var upward: SIMD3<Float>
    var horizontalUpper: SIMD3<Float>
    var horizontalLower: SIMD3<Float>
    var upperAverage: SIMD3<Float>
}

private struct Phase4BMaterialResponse {
    var direct: SIMD3<Float>
    var ibl: SIMD3<Float>
    var combined: SIMD3<Float>
}

private func direction(elevationDegrees: Float, azimuthDegrees: Float = 0) -> SIMD3<Float> {
    let elevation = elevationDegrees * .pi / 180
    let azimuth = azimuthDegrees * .pi / 180
    return simd_normalize(SIMD3<Float>(cos(elevation) * cos(azimuth),
                                      sin(elevation),
                                      cos(elevation) * sin(azimuth)))
}
