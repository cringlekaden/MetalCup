/// RenderPipelineStateLibrary.swift
/// Defines the RenderPipelineStateLibrary types and helpers for the engine.
/// Created by Kaden Cringle.

import MetalKit

public enum RenderPipelineStateType {
    case HDRInstanced
    case HDRInstancedTransparent
    case HDRInstancedAdditive
    case PickID
    case DepthPrepassInstanced
    case DepthPrepassAlphaInstanced
    case ShadowAlphaInstanced
    case Skybox
    case Final
    case Cubemap
    case CubemapOrientationDiagnostic
    case IrradianceMap
    case PrefilteredMap
    case BRDF
    case BloomExtract
    case HeightFog
    case BloomDownsample
    case BloomBlurH
    case BloomBlurV
    case SAOEvaluate
    case AOBlurH
    case AOBlurV
    case GridOverlay
    case SelectionOutline
    case FarCloudCards
    case ProceduralSkyCubemap
    case ProceduralSkyVisible
    case ProceduralSkyVisibleCapture
    case HDRILuminance
    case DebugLines
}

public final class RenderPipelineStateLibrary: Library<RenderPipelineStateType, MTLRenderPipelineState> {
    private var library: [RenderPipelineStateType: RenderPipelineState] = [:]
    private var hdrInstancedVariants: [HDRInstancedVariantKey: MTLRenderPipelineState] = [:]
    private var depthPrepassVariants: [DepthPrepassVariantKey: MTLRenderPipelineState] = [:]
    private var sceneNormalsVariants: [SceneNormalsVariantKey: MTLRenderPipelineState] = [:]
    private var aoNormalsVariants: [SceneNormalsVariantKey: MTLRenderPipelineState] = [:]
    private var skyboxVariants: [SkyboxVariantKey: MTLRenderPipelineState] = [:]
    private var proceduralSkyVisibleVariants: [SkyboxVariantKey: MTLRenderPipelineState] = [:]
    private var proceduralSkyCaptureVariants: [SkyboxVariantKey: MTLRenderPipelineState] = [:]
    private var farCloudCardVariants: [SkyboxVariantKey: MTLRenderPipelineState] = [:]
    private let shaders: ShaderLibrary
    private let vertexDescriptors: VertexDescriptorLibrary
    private let preferences: Preferences
    private let device: MTLDevice

    public init(shaders: ShaderLibrary, vertexDescriptors: VertexDescriptorLibrary, preferences: Preferences, device: MTLDevice) {
        self.shaders = shaders
        self.vertexDescriptors = vertexDescriptors
        self.preferences = preferences
        self.device = device
        super.init()
    }

    public func build() {
        if !library.isEmpty { return }

        // Binding Contract (mesh pipelines):
        // Vertex buffers:
        //  - [[buffer(0)]] Vertex (pos/color/uv/normal/tangent.xyz + tangent.w handedness)
        //  - [[buffer(1)]] SceneConstants (SceneConstants)
        //  - [[buffer(3)]] InstanceData (InstanceData) for all mesh draws
        //  - [[buffer(4)]] Bone palette matrices (float4x4[]) when skinning is enabled
        // Fragment buffers:
        //  - [[buffer(1)]] Material (MetalCupMaterial)
        //  - [[buffer(2)]] RendererSettings (RendererSettings)
        //  - [[buffer(3)]] LightCount (int)
        //  - [[buffer(4)]] LightData (LightData[])
        //  - [[buffer(7)]] ShadowConstants (ShadowConstants)
        // Textures/samplers:
        //  - See Shared.metal FragmentTextureIndex / FragmentSamplerIndex

        let defaultHDR = hdrInstancedPipeline(
            debugEnabled: false,
            shadowFilter: .pcf,
            blendMode: .opaque,
            sampleCount: 1,
            alphaToCoverageEnabled: false
        )
        library[.HDRInstanced] = ExistingRenderPipelineState(renderPipelineState: defaultHDR)
        let defaultTransparentHDR = hdrInstancedPipeline(
            debugEnabled: false,
            shadowFilter: .pcf,
            blendMode: .transparent,
            sampleCount: 1,
            alphaToCoverageEnabled: false
        )
        library[.HDRInstancedTransparent] = ExistingRenderPipelineState(renderPipelineState: defaultTransparentHDR)
        let defaultAdditiveHDR = hdrInstancedPipeline(
            debugEnabled: false,
            shadowFilter: .pcf,
            blendMode: .additive,
            sampleCount: 1,
            alphaToCoverageEnabled: false
        )
        library[.HDRInstancedAdditive] = ExistingRenderPipelineState(renderPipelineState: defaultAdditiveHDR)

        library[.PickID] = buildPipeline(label: "PickID") { descriptor in
            descriptor.colorAttachments[0].pixelFormat = .r32Uint
            descriptor.depthAttachmentPixelFormat = preferences.defaultDepthPixelFormat
            descriptor.vertexFunction = shaders[.PickInstancedVertex]
            descriptor.fragmentFunction = shaders[.PickFragment]
            descriptor.vertexDescriptor = vertexDescriptors[.Default]
        }

        library[.DepthPrepassInstanced] = ExistingRenderPipelineState(
            renderPipelineState: depthPrepassPipeline(alphaMasked: false, sampleCount: 1)
        )

        library[.DepthPrepassAlphaInstanced] = ExistingRenderPipelineState(
            renderPipelineState: depthPrepassPipeline(alphaMasked: true, sampleCount: 1)
        )

        library[.ShadowAlphaInstanced] = buildPipeline(label: "ShadowAlphaInstanced") { descriptor in
            descriptor.colorAttachments[0].pixelFormat = .invalid
            descriptor.depthAttachmentPixelFormat = preferences.defaultDepthPixelFormat
            descriptor.vertexFunction = shaders[.InstancedVertex]
            descriptor.fragmentFunction = shaders[.ShadowAlphaFragment]
            descriptor.vertexDescriptor = vertexDescriptors[.Default]
        }

        library[.Skybox] = ExistingRenderPipelineState(renderPipelineState: skyboxPipeline(sampleCount: 1))

        library[.Final] = buildPipeline(label: "Final") { descriptor in
            descriptor.colorAttachments[0].pixelFormat = preferences.defaultColorPixelFormat
            descriptor.vertexFunction = shaders[.FinalVertex]
            descriptor.fragmentFunction = shaders[.FinalFragment]
            descriptor.vertexDescriptor = vertexDescriptors[.Simple]
        }

        library[.Cubemap] = buildPipeline(label: "Cubemap") { descriptor in
            descriptor.colorAttachments[0].pixelFormat = preferences.HDRPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = false
            descriptor.vertexFunction = shaders[.CubemapVertex]
            descriptor.fragmentFunction = shaders[.CubemapFragment]
            descriptor.vertexDescriptor = vertexDescriptors[.Simple]
            descriptor.depthAttachmentPixelFormat = .invalid
            descriptor.stencilAttachmentPixelFormat = .invalid
            descriptor.rasterSampleCount = 1
            descriptor.inputPrimitiveTopology = .triangle
        }

        library[.CubemapOrientationDiagnostic] = buildPipeline(label: "CubemapOrientationDiagnostic") { descriptor in
            descriptor.colorAttachments[0].pixelFormat = preferences.HDRPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = false
            descriptor.vertexFunction = shaders[.CubemapVertex]
            descriptor.fragmentFunction = shaders[.CubemapOrientationDiagnosticFragment]
            descriptor.vertexDescriptor = vertexDescriptors[.Simple]
            descriptor.depthAttachmentPixelFormat = .invalid
            descriptor.stencilAttachmentPixelFormat = .invalid
            descriptor.rasterSampleCount = 1
            descriptor.inputPrimitiveTopology = .triangle
        }

        library[.ProceduralSkyCubemap] = buildPipeline(label: "ProceduralSkyCubemap") { descriptor in
            descriptor.colorAttachments[0].pixelFormat = preferences.HDRPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = false
            descriptor.vertexFunction = shaders[.CubemapVertex]
            descriptor.fragmentFunction = shaders[.ProceduralSkyFragment]
            descriptor.vertexDescriptor = vertexDescriptors[.Simple]
            descriptor.depthAttachmentPixelFormat = .invalid
            descriptor.stencilAttachmentPixelFormat = .invalid
            descriptor.rasterSampleCount = 1
            descriptor.inputPrimitiveTopology = .triangle
        }

        library[.ProceduralSkyVisible] = ExistingRenderPipelineState(renderPipelineState: proceduralSkyVisiblePipeline(sampleCount: 1))
        library[.ProceduralSkyVisibleCapture] = ExistingRenderPipelineState(renderPipelineState: proceduralSkyVisibleCapturePipeline(sampleCount: 1))

        library[.IrradianceMap] = buildPipeline(label: "IrradianceMap") { descriptor in
            descriptor.colorAttachments[0].pixelFormat = preferences.HDRPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = false
            descriptor.vertexFunction = shaders[.CubemapVertex]
            descriptor.fragmentFunction = shaders[.IrradianceFragment]
            descriptor.vertexDescriptor = vertexDescriptors[.Simple]
            descriptor.depthAttachmentPixelFormat = .invalid
            descriptor.stencilAttachmentPixelFormat = .invalid
            descriptor.rasterSampleCount = 1
            descriptor.inputPrimitiveTopology = .triangle
        }

        library[.PrefilteredMap] = buildPipeline(label: "PrefilteredMap") { descriptor in
            descriptor.colorAttachments[0].pixelFormat = preferences.HDRPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = false
            descriptor.vertexFunction = shaders[.CubemapVertex]
            descriptor.fragmentFunction = shaders[.PrefilteredFragment]
            descriptor.vertexDescriptor = vertexDescriptors[.Simple]
            descriptor.depthAttachmentPixelFormat = .invalid
            descriptor.stencilAttachmentPixelFormat = .invalid
            descriptor.rasterSampleCount = 1
            descriptor.inputPrimitiveTopology = .triangle
        }

        library[.BRDF] = buildPipeline(label: "BRDF") { descriptor in
            descriptor.colorAttachments[0].pixelFormat = .rg16Float
            descriptor.depthAttachmentPixelFormat = .invalid
            descriptor.vertexFunction = shaders[.FSQuadVertex]
            descriptor.fragmentFunction = shaders[.BRDFFragment]
            descriptor.vertexDescriptor = vertexDescriptors[.Simple]
        }

        library[.BloomExtract] = buildPipeline(label: "BloomExtract") { descriptor in
            descriptor.colorAttachments[0].pixelFormat = preferences.HDRPixelFormat
            descriptor.vertexFunction = shaders[.FSQuadVertex]
            descriptor.fragmentFunction = shaders[.BloomExtractFragment]
            descriptor.vertexDescriptor = vertexDescriptors[.Simple]
        }

        library[.HeightFog] = buildPipeline(label: "HeightFog") { descriptor in
            descriptor.colorAttachments[0].pixelFormat = preferences.HDRPixelFormat
            descriptor.vertexFunction = shaders[.FSQuadVertex]
            descriptor.fragmentFunction = shaders[.HeightFogFragment]
            descriptor.vertexDescriptor = vertexDescriptors[.Simple]
        }

        library[.BloomDownsample] = buildPipeline(label: "BloomDownsample") { descriptor in
            descriptor.colorAttachments[0].pixelFormat = preferences.HDRPixelFormat
            descriptor.vertexFunction = shaders[.FSQuadVertex]
            descriptor.fragmentFunction = shaders[.BloomDownsampleFragment]
            descriptor.vertexDescriptor = vertexDescriptors[.Simple]
        }

        library[.BloomBlurH] = buildPipeline(label: "BloomBlurH") { descriptor in
            descriptor.colorAttachments[0].pixelFormat = preferences.HDRPixelFormat
            descriptor.vertexFunction = shaders[.FSQuadVertex]
            descriptor.fragmentFunction = shaders[.BlurHFragment]
            descriptor.vertexDescriptor = vertexDescriptors[.Simple]
        }

        library[.BloomBlurV] = buildPipeline(label: "BloomBlurV") { descriptor in
            descriptor.colorAttachments[0].pixelFormat = preferences.HDRPixelFormat
            descriptor.vertexFunction = shaders[.FSQuadVertex]
            descriptor.fragmentFunction = shaders[.BlurVFragment]
            descriptor.vertexDescriptor = vertexDescriptors[.Simple]
        }

        library[.SAOEvaluate] = buildPipeline(label: "SAOEvaluate") { descriptor in
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            descriptor.vertexFunction = shaders[.FSQuadVertex]
            descriptor.fragmentFunction = shaders[.SAOEvaluateFragment]
            descriptor.vertexDescriptor = vertexDescriptors[.Simple]
        }

        library[.AOBlurH] = buildPipeline(label: "AOBlurH") { descriptor in
            descriptor.colorAttachments[0].pixelFormat = .r16Float
            descriptor.vertexFunction = shaders[.FSQuadVertex]
            descriptor.fragmentFunction = shaders[.AOBlurHFragment]
            descriptor.vertexDescriptor = vertexDescriptors[.Simple]
        }

        library[.AOBlurV] = buildPipeline(label: "AOBlurV") { descriptor in
            descriptor.colorAttachments[0].pixelFormat = .r16Float
            descriptor.vertexFunction = shaders[.FSQuadVertex]
            descriptor.fragmentFunction = shaders[.AOBlurVFragment]
            descriptor.vertexDescriptor = vertexDescriptors[.Simple]
        }

        library[.GridOverlay] = buildPipeline(label: "GridOverlay") { descriptor in
            descriptor.colorAttachments[0].pixelFormat = preferences.HDRPixelFormat
            descriptor.vertexFunction = shaders[.FSQuadVertex]
            descriptor.fragmentFunction = shaders[.GridFragment]
            descriptor.vertexDescriptor = vertexDescriptors[.Simple]
        }

        library[.SelectionOutline] = buildPipeline(label: "SelectionOutline") { descriptor in
            descriptor.colorAttachments[0].pixelFormat = .r8Unorm
            descriptor.vertexFunction = shaders[.FSQuadVertex]
            descriptor.fragmentFunction = shaders[.OutlineFragment]
            descriptor.vertexDescriptor = vertexDescriptors[.Simple]
        }

        library[.FarCloudCards] = ExistingRenderPipelineState(renderPipelineState: farCloudCardsPipeline(sampleCount: 1))

        library[.DebugLines] = buildPipeline(label: "DebugLines") { descriptor in
            descriptor.colorAttachments[0].pixelFormat = preferences.HDRPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            descriptor.vertexFunction = shaders[.DebugLineVertex]
            descriptor.fragmentFunction = shaders[.DebugLineFragment]
            descriptor.vertexDescriptor = vertexDescriptors[.DebugLine]
            descriptor.depthAttachmentPixelFormat = .invalid
            descriptor.stencilAttachmentPixelFormat = .invalid
            descriptor.inputPrimitiveTopology = .triangle
        }

        library[.HDRILuminance] = buildPipeline(label: "HDRILuminance") { descriptor in
            descriptor.colorAttachments[0].pixelFormat = .r16Float
            descriptor.vertexFunction = shaders[.FSQuadVertex]
            descriptor.fragmentFunction = shaders[.HDRILuminanceFragment]
            descriptor.vertexDescriptor = vertexDescriptors[.Simple]
        }
    }

    public func rebuild() {
        library.removeAll(keepingCapacity: true)
        hdrInstancedVariants.removeAll(keepingCapacity: true)
        depthPrepassVariants.removeAll(keepingCapacity: true)
        sceneNormalsVariants.removeAll(keepingCapacity: true)
        aoNormalsVariants.removeAll(keepingCapacity: true)
        skyboxVariants.removeAll(keepingCapacity: true)
        proceduralSkyVisibleVariants.removeAll(keepingCapacity: true)
        proceduralSkyCaptureVariants.removeAll(keepingCapacity: true)
        farCloudCardVariants.removeAll(keepingCapacity: true)
        build()
    }

    override subscript(_ type: RenderPipelineStateType) -> MTLRenderPipelineState {
        return library[type]!.renderPipelineState
    }

    public func hdrInstancedPipeline(settings: RendererSettings,
                                     blendMode: HDRBlendMode = .opaque,
                                     sampleCount: Int = 1,
                                     alphaToCoverageEnabled: Bool = false) -> MTLRenderPipelineState {
        let debugEnabled = settings.shadingDebugMode != 0
        let filterMode = ShadowFilterMode(rawValue: settings.shadows.filterMode) ?? .pcf
        return hdrInstancedPipeline(debugEnabled: debugEnabled,
                                    shadowFilter: filterMode,
                                    blendMode: blendMode,
                                    sampleCount: sampleCount,
                                    alphaToCoverageEnabled: alphaToCoverageEnabled)
    }

    public func depthPrepassPipeline(alphaMasked: Bool, sampleCount: Int = 1) -> MTLRenderPipelineState {
        let normalizedSampleCount = normalizedRasterSampleCount(sampleCount)
        let key = DepthPrepassVariantKey(alphaMasked: alphaMasked, sampleCount: normalizedSampleCount)
        if let cached = depthPrepassVariants[key] {
            return cached
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = alphaMasked
            ? "DepthPrepassAlphaInstanced.\(normalizedSampleCount)x"
            : "DepthPrepassInstanced.\(normalizedSampleCount)x"
        descriptor.colorAttachments[0].pixelFormat = .invalid
        descriptor.depthAttachmentPixelFormat = preferences.defaultDepthPixelFormat
        descriptor.vertexFunction = shaders[.InstancedVertex]
        descriptor.fragmentFunction = alphaMasked ? shaders[.DepthAlphaFragment] : nil
        descriptor.vertexDescriptor = vertexDescriptors[.Default]
        descriptor.rasterSampleCount = normalizedSampleCount
        let pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
        depthPrepassVariants[key] = pipeline
        return pipeline
    }

    public func sceneNormalsPipeline(alphaMasked: Bool) -> MTLRenderPipelineState {
        let key = SceneNormalsVariantKey(alphaMasked: alphaMasked)
        if let cached = sceneNormalsVariants[key] {
            return cached
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = alphaMasked ? "SceneNormalsAlphaInstanced" : "SceneNormalsInstanced"
        descriptor.colorAttachments[0].pixelFormat = .rg16Float
        descriptor.depthAttachmentPixelFormat = preferences.defaultDepthPixelFormat
        descriptor.vertexFunction = shaders[.InstancedVertex]
        descriptor.fragmentFunction = alphaMasked ? shaders[.SceneNormalsAlphaFragment] : shaders[.SceneNormalsFragment]
        descriptor.vertexDescriptor = vertexDescriptors[.Default]
        descriptor.rasterSampleCount = 1
        let pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
        sceneNormalsVariants[key] = pipeline
        return pipeline
    }

    public func aoNormalsPipeline(alphaMasked: Bool) -> MTLRenderPipelineState {
        let key = SceneNormalsVariantKey(alphaMasked: alphaMasked)
        if let cached = aoNormalsVariants[key] {
            return cached
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = alphaMasked ? "AONormalsAlphaInstanced" : "AONormalsInstanced"
        descriptor.colorAttachments[0].pixelFormat = .rg16Float
        descriptor.depthAttachmentPixelFormat = preferences.defaultDepthPixelFormat
        descriptor.vertexFunction = shaders[.InstancedVertex]
        descriptor.fragmentFunction = alphaMasked ? shaders[.AONormalsAlphaFragment] : shaders[.AONormalsFragment]
        descriptor.vertexDescriptor = vertexDescriptors[.Default]
        descriptor.rasterSampleCount = 1
        let pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
        aoNormalsVariants[key] = pipeline
        return pipeline
    }

    public func skyboxPipeline(sampleCount: Int = 1) -> MTLRenderPipelineState {
        let normalizedSampleCount = normalizedRasterSampleCount(sampleCount)
        let key = SkyboxVariantKey(sampleCount: normalizedSampleCount)
        if let cached = skyboxVariants[key] {
            return cached
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Skybox.\(normalizedSampleCount)x"
        descriptor.colorAttachments[0].pixelFormat = preferences.HDRPixelFormat
        descriptor.depthAttachmentPixelFormat = preferences.defaultDepthPixelFormat
        descriptor.vertexFunction = shaders[.SkyboxVertex]
        descriptor.fragmentFunction = shaders[.SkyboxFragment]
        descriptor.vertexDescriptor = vertexDescriptors[.Simple]
        descriptor.rasterSampleCount = normalizedSampleCount
        descriptor.inputPrimitiveTopology = .triangle
        let pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
        skyboxVariants[key] = pipeline
        return pipeline
    }

    public func farCloudCardsPipeline(sampleCount: Int = 1) -> MTLRenderPipelineState {
        let normalizedSampleCount = normalizedRasterSampleCount(sampleCount)
        let key = SkyboxVariantKey(sampleCount: normalizedSampleCount)
        if let cached = farCloudCardVariants[key] {
            return cached
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "FarCloudCards.\(normalizedSampleCount)x"
        descriptor.colorAttachments[0].pixelFormat = preferences.HDRPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.depthAttachmentPixelFormat = preferences.defaultDepthPixelFormat
        descriptor.vertexFunction = shaders[.CloudImpostorVertex]
        descriptor.fragmentFunction = shaders[.CloudImpostorFragment]
        descriptor.vertexDescriptor = nil
        descriptor.rasterSampleCount = normalizedSampleCount
        descriptor.inputPrimitiveTopology = .triangle
        let pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
        farCloudCardVariants[key] = pipeline
        return pipeline
    }

    public func proceduralSkyVisiblePipeline(sampleCount: Int = 1) -> MTLRenderPipelineState {
        let normalizedSampleCount = normalizedRasterSampleCount(sampleCount)
        let key = SkyboxVariantKey(sampleCount: normalizedSampleCount)
        if let cached = proceduralSkyVisibleVariants[key] {
            return cached
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "ProceduralSkyVisible.\(normalizedSampleCount)x"
        descriptor.colorAttachments[0].pixelFormat = preferences.HDRPixelFormat
        descriptor.depthAttachmentPixelFormat = preferences.defaultDepthPixelFormat
        descriptor.vertexFunction = shaders[.ProceduralSkyVisibleVertex]
        descriptor.fragmentFunction = shaders[.ProceduralSkyVisibleFragment]
        descriptor.vertexDescriptor = vertexDescriptors[.Simple]
        descriptor.rasterSampleCount = normalizedSampleCount
        descriptor.inputPrimitiveTopology = .triangle
        let pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
        proceduralSkyVisibleVariants[key] = pipeline
        return pipeline
    }

    public func proceduralSkyVisibleCapturePipeline(sampleCount: Int = 1) -> MTLRenderPipelineState {
        let normalizedSampleCount = normalizedRasterSampleCount(sampleCount)
        let key = SkyboxVariantKey(sampleCount: normalizedSampleCount)
        if let cached = proceduralSkyCaptureVariants[key] {
            return cached
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "ProceduralSkyVisibleCapture.\(normalizedSampleCount)x"
        descriptor.colorAttachments[0].pixelFormat = preferences.HDRPixelFormat
        descriptor.depthAttachmentPixelFormat = preferences.defaultDepthPixelFormat
        descriptor.vertexFunction = shaders[.ProceduralSkyVisibleVertex]
        descriptor.fragmentFunction = shaders[.ProceduralSkyCaptureFragment]
        descriptor.vertexDescriptor = vertexDescriptors[.Simple]
        descriptor.rasterSampleCount = normalizedSampleCount
        descriptor.inputPrimitiveTopology = .triangle
        let pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
        proceduralSkyCaptureVariants[key] = pipeline
        return pipeline
    }

    private func hdrInstancedPipeline(debugEnabled: Bool,
                                      shadowFilter: ShadowFilterMode,
                                      blendMode: HDRBlendMode,
                                      sampleCount: Int,
                                      alphaToCoverageEnabled: Bool) -> MTLRenderPipelineState {
        let normalizedSampleCount = normalizedRasterSampleCount(sampleCount)
        let key = HDRInstancedVariantKey(debugEnabled: debugEnabled,
                                         shadowFilter: shadowFilter,
                                         blendMode: blendMode,
                                         sampleCount: normalizedSampleCount,
                                         alphaToCoverageEnabled: alphaToCoverageEnabled)
        if let cached = hdrInstancedVariants[key] {
            return cached
        }
        let pipeline = makeHDRInstancedPipeline(debugEnabled: debugEnabled,
                                                shadowFilter: shadowFilter,
                                                blendMode: blendMode,
                                                sampleCount: normalizedSampleCount,
                                                alphaToCoverageEnabled: alphaToCoverageEnabled)
        hdrInstancedVariants[key] = pipeline
        return pipeline
    }

    private func makeHDRInstancedPipeline(debugEnabled: Bool,
                                          shadowFilter: ShadowFilterMode,
                                          blendMode: HDRBlendMode,
                                          sampleCount: Int,
                                          alphaToCoverageEnabled: Bool) -> MTLRenderPipelineState {
        let constants = MTLFunctionConstantValues()
        var debugFlag = debugEnabled
        var filterValue = Int32(shadowFilter.rawValue)
        var alphaToCoverageFlag = alphaToCoverageEnabled
        constants.setConstantValue(&debugFlag, type: .bool, index: 0)
        constants.setConstantValue(&filterValue, type: .int, index: 1)
        constants.setConstantValue(&alphaToCoverageFlag, type: .bool, index: 2)

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "HDRInstanced.\(blendMode.label)"
        descriptor.colorAttachments[0].pixelFormat = preferences.HDRPixelFormat
        descriptor.depthAttachmentPixelFormat = preferences.defaultDepthPixelFormat
        descriptor.vertexFunction = shaders[.InstancedVertex]
        descriptor.fragmentFunction = shaders.function(.BasicFragment, constants: constants)
        descriptor.vertexDescriptor = vertexDescriptors[.Default]
        descriptor.rasterSampleCount = sampleCount
        descriptor.isAlphaToCoverageEnabled = alphaToCoverageEnabled
        configureHDRBlendState(descriptor.colorAttachments[0], blendMode: blendMode)
        return try! device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func normalizedRasterSampleCount(_ sampleCount: Int) -> Int {
        max(1, sampleCount)
    }

    private func configureHDRBlendState(_ attachment: MTLRenderPipelineColorAttachmentDescriptor, blendMode: HDRBlendMode) {
        switch blendMode {
        case .opaque:
            attachment.isBlendingEnabled = false
        case .transparent:
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case .additive:
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
        }
    }
}

protocol RenderPipelineState {
    var renderPipelineState: MTLRenderPipelineState! { get }
}

class BasicRenderPipelineState: RenderPipelineState {
    var renderPipelineState: MTLRenderPipelineState!
    init(label: String, descriptor: MTLRenderPipelineDescriptor, device: MTLDevice) {
        descriptor.label = label
        renderPipelineState = try! device.makeRenderPipelineState(descriptor: descriptor)
    }
}

class ExistingRenderPipelineState: RenderPipelineState {
    var renderPipelineState: MTLRenderPipelineState!
    init(renderPipelineState: MTLRenderPipelineState) {
        self.renderPipelineState = renderPipelineState
    }
}

private struct HDRInstancedVariantKey: Hashable {
    let debugEnabled: Bool
    let shadowFilter: ShadowFilterMode
    let blendMode: HDRBlendMode
    let sampleCount: Int
    let alphaToCoverageEnabled: Bool
}

private struct DepthPrepassVariantKey: Hashable {
    let alphaMasked: Bool
    let sampleCount: Int
}

private struct SkyboxVariantKey: Hashable {
    let sampleCount: Int
}

private struct SceneNormalsVariantKey: Hashable {
    let alphaMasked: Bool
}

public enum HDRBlendMode: Hashable {
    case opaque
    case transparent
    case additive

    fileprivate var label: String {
        switch self {
        case .opaque:
            return "Opaque"
        case .transparent:
            return "Transparent"
        case .additive:
            return "Additive"
        }
    }
}

extension RenderPipelineStateLibrary {
    private func buildPipeline(label: String, configure: (MTLRenderPipelineDescriptor) -> Void) -> RenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        configure(descriptor)
        return BasicRenderPipelineState(label: label, descriptor: descriptor, device: device)
    }
}
