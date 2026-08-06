/// ShaderLibrary.swift
/// Defines the ShaderLibrary types and helpers for the engine.
/// Created by Kaden Cringle.

import MetalKit

public enum ShaderType {
    case InstancedVertex
    case BasicFragment
    case SkyboxVertex
    case SkyboxFragment
    case FinalVertex
    case FinalFragment
    case CubemapVertex
    case CubemapFragment
    case CubemapOrientationDiagnosticFragment
    case IrradianceFragment
    case PrefilteredVertex
    case PrefilteredFragment
    case FSQuadVertex
    case BRDFFragment
    case BloomExtractFragment
    case HeightFogFragment
    case AutoExposureExtractFragment
    case BloomDownsampleFragment
    case BlurHFragment
    case BlurVFragment
    case SAOEvaluateFragment
    case AOBlurHFragment
    case AOBlurVFragment
    case ProceduralSkyFragment
    case ProceduralSkyVisibleVertex
    case ProceduralSkyVisibleFragment
    case ProceduralSkyCaptureFragment
    case HDRILuminanceFragment
    case PickInstancedVertex
    case PickFragment
    case GridFragment
    case OutlineFragment
    case DebugLineVertex
    case DebugLineFragment
    case CloudImpostorVertex
    case CloudImpostorFragment
    case DepthAlphaFragment
    case ShadowAlphaFragment
    case SceneNormalsFragment
    case SceneNormalsAlphaFragment
    case AONormalsFragment
    case AONormalsAlphaFragment
}

public struct ShaderRegistration {
    public let type: ShaderType
    public let displayName: String
    public let functionName: String

    public init(type: ShaderType, displayName: String, functionName: String) {
        self.type = type
        self.displayName = displayName
        self.functionName = functionName
    }
}

public class ShaderLibrary: Library<ShaderType, MTLFunction> {
    public static let defaultManifest: [ShaderRegistration] = [
        ShaderRegistration(type: .InstancedVertex, displayName: "Scene Instanced Vertex", functionName: "vertex_scene_instanced"),
        ShaderRegistration(type: .BasicFragment, displayName: "Basic Fragment", functionName: "fragment_basic"),
        ShaderRegistration(type: .SkyboxVertex, displayName: "Skybox Vertex", functionName: "vertex_skybox"),
        ShaderRegistration(type: .SkyboxFragment, displayName: "Skybox Fragment", functionName: "fragment_skybox"),
        ShaderRegistration(type: .FinalVertex, displayName: "Final Vertex", functionName: "vertex_final"),
        ShaderRegistration(type: .FinalFragment, displayName: "Final Fragment", functionName: "fragment_final"),
        ShaderRegistration(type: .CubemapVertex, displayName: "Cubemap Vertex", functionName: "vertex_cubemap"),
        ShaderRegistration(type: .CubemapFragment, displayName: "Cubemap Fragment", functionName: "fragment_cubemap"),
        ShaderRegistration(type: .CubemapOrientationDiagnosticFragment, displayName: "Cubemap Orientation Diagnostic Fragment", functionName: "fragment_cubemap_orientation_diagnostic"),
        ShaderRegistration(type: .IrradianceFragment, displayName: "Irradiance Fragment", functionName: "fragment_irradiance"),
        ShaderRegistration(type: .PrefilteredFragment, displayName: "Prefiltered Fragment", functionName: "fragment_prefiltered"),
        ShaderRegistration(type: .FSQuadVertex, displayName: "Fullscreen Quad Vertex", functionName: "vertex_quad"),
        ShaderRegistration(type: .BRDFFragment, displayName: "BRDF Fragment", functionName: "fragment_brdf"),
        ShaderRegistration(type: .BloomExtractFragment, displayName: "Bloom Extract Fragment", functionName: "fragment_bloom_extract"),
        ShaderRegistration(type: .HeightFogFragment, displayName: "Height Fog Fragment", functionName: "fragment_height_fog"),
        ShaderRegistration(type: .AutoExposureExtractFragment, displayName: "Auto Exposure Extract Fragment", functionName: "fragment_auto_exposure_extract"),
        ShaderRegistration(type: .BloomDownsampleFragment, displayName: "Bloom Downsample Fragment", functionName: "fragment_bloom_downsample"),
        ShaderRegistration(type: .BlurHFragment, displayName: "Blur Horizontal Fragment", functionName: "fragment_blur_h"),
        ShaderRegistration(type: .BlurVFragment, displayName: "Blur Vertical Fragment", functionName: "fragment_blur_v"),
        ShaderRegistration(type: .SAOEvaluateFragment, displayName: "SAO Evaluate Fragment", functionName: "fragment_sao_evaluate"),
        ShaderRegistration(type: .AOBlurHFragment, displayName: "AO Blur Horizontal Fragment", functionName: "fragment_ao_blur_h"),
        ShaderRegistration(type: .AOBlurVFragment, displayName: "AO Blur Vertical Fragment", functionName: "fragment_ao_blur_v"),
        ShaderRegistration(type: .ProceduralSkyFragment, displayName: "Procedural Sky Fragment", functionName: "fragment_procedural_sky"),
        ShaderRegistration(type: .ProceduralSkyVisibleVertex, displayName: "Procedural Sky Visible Vertex", functionName: "vertex_procedural_sky_visible"),
        ShaderRegistration(type: .ProceduralSkyVisibleFragment, displayName: "Procedural Sky Visible Fragment", functionName: "fragment_procedural_sky_visible"),
        ShaderRegistration(type: .ProceduralSkyCaptureFragment, displayName: "Procedural Sky Capture Fragment", functionName: "fragment_procedural_sky_capture"),
        ShaderRegistration(type: .HDRILuminanceFragment, displayName: "HDRI Luminance Fragment", functionName: "fragment_hdri_luminance"),
        ShaderRegistration(type: .PickInstancedVertex, displayName: "Pick Instanced Vertex", functionName: "vertex_pick_instanced"),
        ShaderRegistration(type: .PickFragment, displayName: "Pick Fragment", functionName: "fragment_pick_id"),
        ShaderRegistration(type: .GridFragment, displayName: "Grid Fragment", functionName: "fragment_grid"),
        ShaderRegistration(type: .OutlineFragment, displayName: "Outline Fragment", functionName: "fragment_outline_mask"),
        ShaderRegistration(type: .DebugLineVertex, displayName: "Debug Line Vertex", functionName: "vertex_debug_line"),
        ShaderRegistration(type: .DebugLineFragment, displayName: "Debug Line Fragment", functionName: "fragment_debug_line"),
        ShaderRegistration(type: .CloudImpostorVertex, displayName: "Cloud Impostor Vertex", functionName: "vertex_cloud_impostor"),
        ShaderRegistration(type: .CloudImpostorFragment, displayName: "Cloud Impostor Fragment", functionName: "fragment_cloud_impostor"),
        ShaderRegistration(type: .DepthAlphaFragment, displayName: "Depth Alpha Fragment", functionName: "fragment_depth_alpha"),
        ShaderRegistration(type: .ShadowAlphaFragment, displayName: "Shadow Alpha Fragment", functionName: "fragment_shadow_alpha"),
        ShaderRegistration(type: .SceneNormalsFragment, displayName: "Scene Normals Fragment", functionName: "fragment_scene_normals"),
        ShaderRegistration(type: .SceneNormalsAlphaFragment, displayName: "Scene Normals Alpha Fragment", functionName: "fragment_scene_normals_alpha"),
        ShaderRegistration(type: .AONormalsFragment, displayName: "AO Normals Fragment", functionName: "fragment_ao_normals"),
        ShaderRegistration(type: .AONormalsAlphaFragment, displayName: "AO Normals Alpha Fragment", functionName: "fragment_ao_normals_alpha")
    ]

    public static var requiredFunctionNames: [String] {
        defaultManifest.map(\.functionName)
    }

    private var _library: [ShaderType: Shader] = [:]
    private let resourceRegistry: ResourceRegistry
    private let device: MTLDevice
    private let fallbackLibrary: MTLLibrary?

    public init(resourceRegistry: ResourceRegistry, device: MTLDevice, fallbackLibrary: MTLLibrary?) {
        self.resourceRegistry = resourceRegistry
        self.device = device
        self.fallbackLibrary = fallbackLibrary
    }

    public func register(_ type: ShaderType, name: String, functionName: String) {
        _library[type] = Shader(
            name: name,
            functionName: functionName,
            resourceRegistry: resourceRegistry,
            device: device,
            fallbackLibrary: fallbackLibrary
        )
    }

    public func registerDefaults() {
        for registration in Self.defaultManifest {
            register(
                registration.type,
                name: registration.displayName,
                functionName: registration.functionName
            )
        }
    }

    override subscript(_ type: ShaderType)->MTLFunction {
        guard let fn = _library[type]?.function else {
            fatalError("ShaderLibrary: shader for \(type) not registered. Register shaders before building pipeline states.")
        }
        return fn
    }

    public func function(_ type: ShaderType, constants: MTLFunctionConstantValues?) -> MTLFunction {
        guard let shader = _library[type] else {
            fatalError("ShaderLibrary: shader for \(type) not registered. Register shaders before building pipeline states.")
        }
        return shader.makeFunction(constants: constants)
    }
}

public class Shader {
    let name: String
    let functionName: String
    private let resourceRegistry: ResourceRegistry
    private let device: MTLDevice
    private let fallbackLibrary: MTLLibrary?
    var function: MTLFunction!

    init(name: String, functionName: String, resourceRegistry: ResourceRegistry, device: MTLDevice, fallbackLibrary: MTLLibrary?) {
        self.name = name
        self.functionName = functionName
        self.resourceRegistry = resourceRegistry
        self.device = device
        self.fallbackLibrary = fallbackLibrary
        self.function = makeFunction(constants: nil)
    }

    func makeFunction(constants: MTLFunctionConstantValues?) -> MTLFunction {
        let fn = resourceRegistry.resolveFunction(functionName, device: device, fallbackLibrary: fallbackLibrary, constants: constants)
        guard let resolved = fn else {
            if let compileError = resourceRegistry.lastShaderCompileError {
                fatalError("Shader '\(functionName)' not found. Metal compile error: \(compileError)")
            }
            fatalError("Shader '\(functionName)' not found. Ensure the .metal file is compiled into the app target or runtime shader library.")
        }
        resolved.label = name
        return resolved
    }
}
