/// LocalFogTransport.swift
/// Scene-linear local participating-medium reference math shared by renderer tests and authoring.

import Foundation
import simd

/// Phase 5 local-medium contract.
///
/// Planetary atmosphere remains responsible for sky radiance. Local fog is a separate,
/// camera-local medium evaluated before bloom, exposure, Filmic v1, and sRGB encoding:
///
///     Lout = Lsurface * T + S
///     T = exp(-integral(sigmaT * rho(y), ds))
///     sigmaT = sigmaS + sigmaA
///
/// Distances are world units, `extinction` is inverse world units at `baseHeight`, and
/// `scatteringAlbedo = sigmaS / sigmaT` is component-wise bounded to [0, 1].
public enum LocalFogTransport {
    public struct Parameters: Equatable {
        public var enabled: Bool
        public var extinction: Float
        public var scatteringAlbedo: SIMD3<Float>
        public var baseHeight: Float
        public var scaleHeight: Float
        public var anisotropy: Float
        public var maximumOpticalDepth: Float

        public init(enabled: Bool = false,
                    extinction: Float = 0.02,
                    scatteringAlbedo: SIMD3<Float> = SIMD3<Float>(repeating: 0.9),
                    baseHeight: Float = 0,
                    scaleHeight: Float = 12,
                    anisotropy: Float = 0.2,
                    maximumOpticalDepth: Float = 80) {
            self.enabled = enabled
            self.extinction = max(extinction, 0)
            self.scatteringAlbedo = simd_clamp(scatteringAlbedo, .zero, SIMD3<Float>(repeating: 1))
            self.baseHeight = baseHeight
            self.scaleHeight = max(scaleHeight, 1e-3)
            self.anisotropy = min(max(anisotropy, -0.9), 0.9)
            self.maximumOpticalDepth = min(max(maximumOpticalDepth, 0), 80)
        }
    }

    public struct Sample: Equatable {
        public var opticalDepth: Float
        public var transmittance: Float
        public var ambientInscattering: SIMD3<Float>
        public var directionalInscattering: SIMD3<Float>

        public var inscattering: SIMD3<Float> { ambientInscattering + directionalInscattering }

        public init(opticalDepth: Float = 0,
                    transmittance: Float = 1,
                    ambientInscattering: SIMD3<Float> = .zero,
                    directionalInscattering: SIMD3<Float> = .zero) {
            self.opticalDepth = opticalDepth
            self.transmittance = transmittance
            self.ambientInscattering = ambientInscattering
            self.directionalInscattering = directionalInscattering
        }
    }

    /// Analytic optical depth for rho(y) = exp(-(y - baseHeight) / scaleHeight).
    /// A nil distance denotes the background/infinite-ray limit.
    public static func opticalDepth(cameraPosition: SIMD3<Float>,
                                    rayDirection: SIMD3<Float>,
                                    distance: Float?,
                                    parameters: Parameters) -> Float {
        guard parameters.enabled, parameters.extinction > 0 else { return 0 }
        let directionLength = simd_length(rayDirection)
        guard directionLength > 1e-7 else { return 0 }
        let ray = rayDirection / directionLength
        let scaleHeight = max(parameters.scaleHeight, 1e-3)
        let exponent = min(max(-(cameraPosition.y - parameters.baseHeight) / scaleHeight, -80), 80)
        let extinctionAtCamera = parameters.extinction * exp(exponent)
        let maximum = parameters.maximumOpticalDepth

        if let distance {
            let segmentLength = max(distance, 0)
            guard segmentLength > 0 else { return 0 }
            let k = ray.y / scaleHeight
            let x = k * segmentLength
            let integral: Float
            if abs(x) < 1e-3 {
                integral = segmentLength * (1 - 0.5 * x + x * x / 6)
            } else {
                integral = -expm1(-x) / k
            }
            guard integral.isFinite else { return maximum }
            return min(max(extinctionAtCamera * integral, 0), maximum)
        }

        guard ray.y > 1e-5 else { return maximum }
        return min(max(extinctionAtCamera * scaleHeight / ray.y, 0), maximum)
    }

    public static func henyeyGreenstein(cosTheta: Float, anisotropy: Float) -> Float {
        let g = min(max(anisotropy, -0.9), 0.9)
        let gg = g * g
        let denominator = max(1 + gg - 2 * g * min(max(cosTheta, -1), 1), 1e-5)
        return (1 - gg) / (4 * .pi * pow(denominator, 1.5))
    }

    public static func evaluate(cameraPosition: SIMD3<Float>,
                                rayDirection: SIMD3<Float>,
                                distance: Float?,
                                ambientRadiance: SIMD3<Float>,
                                solarIrradiance: SIMD3<Float>,
                                directionToSun: SIMD3<Float>,
                                parameters: Parameters) -> Sample {
        let tau = opticalDepth(cameraPosition: cameraPosition,
                               rayDirection: rayDirection,
                               distance: distance,
                               parameters: parameters)
        let transmittance = exp(-tau)
        guard parameters.enabled, tau > 0 else { return Sample() }
        let ray = simd_normalize(rayDirection)
        let sun = simd_length_squared(directionToSun) > 1e-8
            ? simd_normalize(directionToSun)
            : SIMD3<Float>(0, 1, 0)
        let scatteredFraction = 1 - transmittance
        let albedo = simd_clamp(parameters.scatteringAlbedo, .zero, SIMD3<Float>(repeating: 1))
        let phase = henyeyGreenstein(cosTheta: simd_dot(ray, sun), anisotropy: parameters.anisotropy)
        return Sample(
            opticalDepth: tau,
            transmittance: transmittance,
            ambientInscattering: max(ambientRadiance, SIMD3<Float>(repeating: 0)) * albedo * scatteredFraction,
            directionalInscattering: max(solarIrradiance, SIMD3<Float>(repeating: 0)) * phase * albedo * scatteredFraction
        )
    }
}
