import Foundation
import Metal
import Testing
import simd
@testable import MetalCupEngine

@Suite("Phase 5 legacy fog characterization")
struct Phase5LegacyFogCharacterizationTests {
    @Test
    func legacyBackgroundAppliesTwoExtraDirectionalCoverageCurves() {
        let opticalDepth: Float = 1
        let physicalCoverage = 1 - exp(-opticalDepth)
        let horizonWeight: Float = 1
        let zenithWeight: Float = 0
        let directionalCoverage = min(
            physicalCoverage * mix(0.18, 1, horizonWeight) * mix(1, 0.55, zenithWeight),
            mix(0.35, 0.94, horizonWeight)
        )
        let secondSkyCoverage = directionalCoverage
            * mix(0.28, 0.86, horizonWeight)
            * mix(1, 0.42, zenithWeight)

        #expect(physicalCoverage > 0.63 && physicalCoverage < 0.64)
        #expect(abs(directionalCoverage - physicalCoverage) < 0.000001)
        #expect(secondSkyCoverage < physicalCoverage)
    }

    @Test
    func legacyBackgroundUsesViewDependentVirtualDistance() {
        let maxAerialDistance: Float = 2_600
        let zenithDistance = mix(maxAerialDistance * 0.22, maxAerialDistance, 0)
        let horizonDistance = mix(maxAerialDistance * 0.22, maxAerialDistance, 1)
        #expect(zenithDistance == 572)
        #expect(horizonDistance == 2_600)
        #expect(horizonDistance / zenithDistance > 4.5)
    }

    @Test
    func legacyFogCombinesHeightAndIndependentDistanceDensity() {
        let segmentLength: Float = 50
        let heightDensity: Float = 0.03
        let distanceDensity: Float = 0.02
        let oldOpticalDepth = heightDensity * segmentLength + distanceDensity * segmentLength
        #expect(abs(oldOpticalDepth - 2.5) < 0.000001)
        #expect(oldOpticalDepth > heightDensity * segmentLength)
    }

    private func mix(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }
}

@Suite("Fog transmittance references")
struct FogTransmittanceReferenceTests {
    @Test
    func homogeneousBeerLambertAndDisabledIdentity() {
        let homogeneous = LocalFogTransport.Parameters(enabled: true,
                                                        extinction: 0.02,
                                                        baseHeight: 0,
                                                        scaleHeight: 1_000_000,
                                                        anisotropy: 0)
        for distance: Float in [0, 1, 5, 10, 25, 50, 100] {
            let tau = LocalFogTransport.opticalDepth(cameraPosition: .zero,
                                                     rayDirection: SIMD3<Float>(1, 0, 0),
                                                     distance: distance,
                                                     parameters: homogeneous)
            #expect(abs(tau - 0.02 * distance) < 0.0001)
            #expect(abs(exp(-tau) - exp(-0.02 * distance)) < 0.0001)
        }
        var disabled = homogeneous
        disabled.enabled = false
        #expect(LocalFogTransport.opticalDepth(cameraPosition: .zero,
                                               rayDirection: SIMD3<Float>(1, 0, 0),
                                               distance: 100,
                                               parameters: disabled) == 0)
    }

    @Test
    func distanceAndDensityAreMonotonicAndFinite() {
        let parameters = LocalFogTransport.Parameters(enabled: true, extinction: 0.03, scaleHeight: 12)
        let near = LocalFogTransport.opticalDepth(cameraPosition: .zero,
                                                  rayDirection: SIMD3<Float>(1, 0, 0),
                                                  distance: 5,
                                                  parameters: parameters)
        let far = LocalFogTransport.opticalDepth(cameraPosition: .zero,
                                                 rayDirection: SIMD3<Float>(1, 0, 0),
                                                 distance: 50,
                                                 parameters: parameters)
        var denser = parameters
        denser.extinction *= 2
        let dense = LocalFogTransport.opticalDepth(cameraPosition: .zero,
                                                   rayDirection: SIMD3<Float>(1, 0, 0),
                                                   distance: 50,
                                                   parameters: denser)
        #expect(near < far)
        #expect(far < dense)
        #expect(near.isFinite && far.isFinite && dense.isFinite)
    }
}

@Suite("Height-fog optical-depth references")
struct HeightFogOpticalDepthTests {
    @Test(arguments: [Float(-0.8), -0.2, 0, 0.2, 0.8])
    func analyticIntegralMatchesNumericalQuadrature(rayY: Float) {
        let parameters = LocalFogTransport.Parameters(enabled: true,
                                                        extinction: 0.035,
                                                        baseHeight: -1,
                                                        scaleHeight: 14)
        let direction = simd_normalize(SIMD3<Float>(sqrt(max(1 - rayY * rayY, 0)), rayY, 0))
        let distance: Float = 80
        let analytic = LocalFogTransport.opticalDepth(cameraPosition: SIMD3<Float>(0, 3, 0),
                                                      rayDirection: direction,
                                                      distance: distance,
                                                      parameters: parameters)
        let steps = 20_000
        let step = distance / Float(steps)
        var numerical: Float = 0
        for index in 0..<steps {
            let s = (Float(index) + 0.5) * step
            let y = 3 + direction.y * s
            numerical += parameters.extinction
                * exp(-(y - parameters.baseHeight) / parameters.scaleHeight) * step
        }
        numerical = min(numerical, parameters.maximumOpticalDepth)
        #expect(abs(analytic - numerical) < 0.001)
    }

    @Test
    func backgroundLimitsAreStable() {
        let parameters = LocalFogTransport.Parameters(enabled: true, extinction: 0.02, scaleHeight: 10)
        let upward = LocalFogTransport.opticalDepth(cameraPosition: .zero,
                                                    rayDirection: SIMD3<Float>(0, 1, 0),
                                                    distance: nil,
                                                    parameters: parameters)
        let horizontal = LocalFogTransport.opticalDepth(cameraPosition: .zero,
                                                        rayDirection: SIMD3<Float>(1, 0, 0),
                                                        distance: nil,
                                                        parameters: parameters)
        let downward = LocalFogTransport.opticalDepth(cameraPosition: .zero,
                                                      rayDirection: SIMD3<Float>(0, -1, 0),
                                                      distance: nil,
                                                      parameters: parameters)
        #expect(abs(upward - 0.2) < 0.00001)
        #expect(horizontal == parameters.maximumOpticalDepth)
        #expect(downward == parameters.maximumOpticalDepth)
    }
}

@Suite("Fog in-scattering references")
struct FogInscatteringReferenceTests {
    @Test
    func zeroScatteringAlbedoCreatesNoGlow() {
        let parameters = LocalFogTransport.Parameters(enabled: true,
                                                        extinction: 0.1,
                                                        scatteringAlbedo: .zero,
                                                        scaleHeight: 20)
        let sample = LocalFogTransport.evaluate(cameraPosition: .zero,
                                                rayDirection: SIMD3<Float>(1, 0, 0),
                                                distance: 10,
                                                ambientRadiance: SIMD3<Float>(repeating: 1),
                                                solarIrradiance: SIMD3<Float>(repeating: 4),
                                                directionToSun: SIMD3<Float>(1, 0, 0),
                                                parameters: parameters)
        #expect(sample.transmittance < 1)
        #expect(sample.inscattering == .zero)
    }

    @Test
    func scatteringIsBoundedAndForwardPhaseIsFinite() {
        let parameters = LocalFogTransport.Parameters(enabled: true,
                                                        extinction: 0.08,
                                                        scatteringAlbedo: SIMD3<Float>(repeating: 0.85),
                                                        scaleHeight: 20,
                                                        anisotropy: 0.5)
        let sample = LocalFogTransport.evaluate(cameraPosition: .zero,
                                                rayDirection: SIMD3<Float>(1, 0, 0),
                                                distance: 20,
                                                ambientRadiance: SIMD3<Float>(0.4, 0.5, 0.6),
                                                solarIrradiance: SIMD3<Float>(2, 1.8, 1.5),
                                                directionToSun: SIMD3<Float>(1, 0, 0),
                                                parameters: parameters)
        #expect(sample.inscattering.x >= 0 && sample.inscattering.y >= 0 && sample.inscattering.z >= 0)
        #expect(sample.inscattering.x.isFinite && sample.inscattering.y.isFinite && sample.inscattering.z.isFinite)
        #expect(LocalFogTransport.henyeyGreenstein(cosTheta: 1, anisotropy: 0.5)
                > LocalFogTransport.henyeyGreenstein(cosTheta: -1, anisotropy: 0.5))
    }
}

@Suite("Fog production GPU references")
struct FogDepthReconstructionGPUTests {
    @Test
    func productionMetalTransportMatchesCPUReferences() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Phase2MetalTestSupport.canonicalLibrary(device: device)
        let function = try #require(library.makeFunction(name: "phase5_local_fog_reference_samples"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let inputs: [SIMD4<Float>] = [
            SIMD4<Float>(0, 0, 10, 0),
            SIMD4<Float>(3, 0.5, 80, 0),
            SIMD4<Float>(0, 1, 0, 1),
            SIMD4<Float>(0, 0, 0, 1),
            SIMD4<Float>(-2, -0.4, 25, 0)
        ]
        let parameters = inputs.map { _ in SIMD4<Float>(0.035, -1, 14, 0.3) }
        let inputBuffer = try Phase2MetalTestSupport.makeBuffer(device: device, values: inputs)
        let parameterBuffer = try Phase2MetalTestSupport.makeBuffer(device: device, values: parameters)
        let outputBuffer = try #require(device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride * inputs.count,
                                                          options: .storageModeShared))
        try Phase2MetalTestSupport.execute(device: device, pipeline: pipeline, width: inputs.count) { encoder in
            encoder.setBuffer(inputBuffer, offset: 0, index: 0)
            encoder.setBuffer(parameterBuffer, offset: 0, index: 1)
            encoder.setBuffer(outputBuffer, offset: 0, index: 2)
        }
        let results = outputBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: inputs.count)
        let cpuParameters = LocalFogTransport.Parameters(enabled: true,
                                                          extinction: 0.035,
                                                          baseHeight: -1,
                                                          scaleHeight: 14,
                                                          anisotropy: 0.3)
        for index in inputs.indices {
            let input = inputs[index]
            let direction = SIMD3<Float>(sqrt(max(1 - input.y * input.y, 0)), input.y, 0)
            let expected = LocalFogTransport.opticalDepth(cameraPosition: SIMD3<Float>(0, input.x, 0),
                                                          rayDirection: direction,
                                                          distance: input.w > 0.5 ? nil : input.z,
                                                          parameters: cpuParameters)
            #expect(abs(results[index].x - expected) < 0.0002)
            #expect(abs(results[index].y - exp(-expected)) < 0.0002)
            #expect(results[index].x.isFinite && results[index].y.isFinite && results[index].z.isFinite)
        }
    }
}

@Suite("Fog sky/object continuity")
struct FogSkyObjectContinuityTests {
    @Test
    func distantGeometryConvergesTowardHorizontalBackgroundLimit() {
        let parameters = LocalFogTransport.Parameters(enabled: true, extinction: 0.02, scaleHeight: 12)
        let direction = SIMD3<Float>(1, 0, 0)
        let distant = LocalFogTransport.opticalDepth(cameraPosition: .zero,
                                                     rayDirection: direction,
                                                     distance: 100_000,
                                                     parameters: parameters)
        let background = LocalFogTransport.opticalDepth(cameraPosition: .zero,
                                                        rayDirection: direction,
                                                        distance: nil,
                                                        parameters: parameters)
        #expect(distant == background)
        #expect(exp(-distant) < 1e-20)
    }
}

@Suite("Fog environment coupling")
struct FogEnvironmentCouplingTests {
    @Test
    func localFogDoesNotChangeIBLSourceSignature() {
        var environment = EnvironmentComponent()
        let before = EnvironmentRenderStateBuilder.build(environment: environment, runtime: nil).iblSignature
        environment.fog = EnvironmentFogConfig(enabled: true,
                                               extinction: 0.08,
                                               scatteringAlbedo: SIMD3<Float>(0.8, 0.9, 1),
                                               baseHeight: -2,
                                               scaleHeight: 6,
                                               anisotropy: 0.4)
        let after = EnvironmentRenderStateBuilder.build(environment: environment, runtime: nil).iblSignature
        #expect(before == after)
    }

    @Test
    func legacySchemaMigratesDeterministically() throws {
        let data = Data(#"{"schemaVersion":1,"amount":0.04,"height":-2,"distance":9}"#.utf8)
        let config = try JSONDecoder().decode(EnvironmentFogDTO.self, from: data).toConfig()
        #expect(config.enabled)
        #expect(config.extinction == 0.04)
        #expect(config.baseHeight == -2)
        #expect(config.scaleHeight == 9)
        #expect(config.scatteringAlbedo == SIMD3<Float>(repeating: 0.9))
    }

    @Test
    func sourceEnergyScalesInscatteringWithoutChangingTransmittance() {
        let parameters = LocalFogTransport.Parameters(enabled: true,
                                                       extinction: 0.04,
                                                       scatteringAlbedo: SIMD3<Float>(repeating: 0.8),
                                                       scaleHeight: 16,
                                                       anisotropy: 0.3)
        let baseline = LocalFogTransport.evaluate(cameraPosition: .zero,
                                                  rayDirection: simd_normalize(SIMD3<Float>(1, 0.1, 0)),
                                                  distance: 30,
                                                  ambientRadiance: SIMD3<Float>(0.2, 0.3, 0.4),
                                                  solarIrradiance: SIMD3<Float>(1.0, 0.9, 0.7),
                                                  directionToSun: simd_normalize(SIMD3<Float>(1, 0.4, 0)),
                                                  parameters: parameters)
        let doubled = LocalFogTransport.evaluate(cameraPosition: .zero,
                                                 rayDirection: simd_normalize(SIMD3<Float>(1, 0.1, 0)),
                                                 distance: 30,
                                                 ambientRadiance: SIMD3<Float>(0.4, 0.6, 0.8),
                                                 solarIrradiance: SIMD3<Float>(2.0, 1.8, 1.4),
                                                 directionToSun: simd_normalize(SIMD3<Float>(1, 0.4, 0)),
                                                 parameters: parameters)
        #expect(baseline.transmittance == doubled.transmittance)
        #expect(simd_length(doubled.inscattering - baseline.inscattering * 2) < 0.000001)
    }

    @Test
    func fogPassPrecedesBloomAndProbeCaptureExcludesLocalFog() throws {
        let graphSource = try engineSource(relativePath: "Core/Rendering/RenderGraph.swift")
        let fogOffset = try #require(graphSource.range(of: "HeightFogPass()")?.lowerBound)
        let bloomOffset = try #require(graphSource.range(of: "BloomExtractPass()")?.lowerBound)
        #expect(fogOffset < bloomOffset)

        let probeSource = try engineSource(relativePath: "Core/ReflectionProbeRuntimeManager.swift")
        #expect(probeSource.contains("let shouldApplyHeightFog = false"))
    }

    private func engineSource(relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("MetalCupEngine/\(relativePath)"),
                          encoding: .utf8)
    }
}

@Suite("Fog PBR integration")
struct FogPBRIntegrationTests {
    @Test
    func transportIsLinearInSurfaceRadianceAndExposureIndependent() {
        let parameters = LocalFogTransport.Parameters(enabled: true, extinction: 0.03, scaleHeight: 20)
        let fog = LocalFogTransport.evaluate(cameraPosition: .zero,
                                             rayDirection: SIMD3<Float>(1, 0, 0),
                                             distance: 25,
                                             ambientRadiance: SIMD3<Float>(0.2, 0.3, 0.4),
                                             solarIrradiance: SIMD3<Float>(1.0, 0.9, 0.7),
                                             directionToSun: SIMD3<Float>(0, 1, 0),
                                             parameters: parameters)
        let direct = SIMD3<Float>(0.7, 0.6, 0.5)
        let indirect = SIMD3<Float>(0.2, 0.25, 0.3)
        let combined = (direct + indirect) * fog.transmittance + fog.inscattering
        let decomposed = direct * fog.transmittance
            + indirect * fog.transmittance
            + fog.ambientInscattering
            + fog.directionalInscattering
        #expect(simd_length(combined - decomposed) < 0.000001)
        #expect(fog == LocalFogTransport.evaluate(cameraPosition: .zero,
                                                 rayDirection: SIMD3<Float>(1, 0, 0),
                                                 distance: 25,
                                                 ambientRadiance: SIMD3<Float>(0.2, 0.3, 0.4),
                                                 solarIrradiance: SIMD3<Float>(1.0, 0.9, 0.7),
                                                 directionToSun: SIMD3<Float>(0, 1, 0),
                                                 parameters: parameters))
    }
}
