/// SceneSerialization.swift
/// Defines the SceneSerialization types and helpers for the engine.
/// Created by Kaden Cringle.

import Foundation
import simd

public enum SceneSchema {
    public static let currentVersion: Int = 1
}

public struct SceneDocument: Codable {
    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var entities: [EntityDocument]
    public var rendererSettingsOverride: RendererSettingsDTO?
    public var physicsSettingsOverride: PhysicsSettingsDTO?

    public init(
        schemaVersion: Int = SceneSchema.currentVersion,
        id: UUID,
        name: String,
        entities: [EntityDocument],
        rendererSettingsOverride: RendererSettingsDTO? = nil,
        physicsSettingsOverride: PhysicsSettingsDTO? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.entities = entities
        self.rendererSettingsOverride = rendererSettingsOverride
        self.physicsSettingsOverride = physicsSettingsOverride
    }
}

public struct EntityDocument: Codable {
    public var id: UUID
    public var parentId: UUID?
    public var components: ComponentsDocument

    public init(id: UUID, parentId: UUID? = nil, components: ComponentsDocument) {
        self.id = id
        self.parentId = parentId
        self.components = components
    }
}

public struct ComponentsDocument: Codable {
    public var name: NameComponentDTO?
    public var transform: TransformComponentDTO?
    public var layer: LayerComponentDTO?
    public var prefabLink: PrefabLinkComponentDTO?
    public var prefabOverrides: PrefabOverrideComponentDTO?
    public var meshRenderer: MeshRendererComponentDTO?
    public var skinnedMesh: SkinnedMeshComponentDTO?
    public var animator: AnimatorComponentDTO?
    public var materialComponent: MaterialComponentDTO?
    public var rigidbody: RigidbodyComponentDTO?
    public var collider: ColliderComponentDTO?
    public var light: LightComponentDTO?
    public var lightOrbit: LightOrbitComponentDTO?
    public var camera: CameraComponentDTO?
    public var script: ScriptComponentDTO?
    public var characterController: CharacterControllerComponentDTO?
    public var audioSource: AudioSourceComponentDTO?
    public var audioListener: AudioListenerComponentDTO?
    public var skyLight: SkyLightComponentDTO?
    public var environmentState: EnvironmentStateComponentDTO?
    /// Migration-only decode surface for renderer-transient sky IBL state.
    /// New scene writes intentionally leave this nil.
    public var skyIBLState: SkyIBLStateComponentDTO?
    public var environment: EnvironmentComponentDTO?
    public var reflectionProbe: ReflectionProbeComponentDTO?
    public var skyLightTag: TagComponentDTO?
    public var skySunTag: TagComponentDTO?

    public init(
        name: NameComponentDTO? = nil,
        transform: TransformComponentDTO? = nil,
        layer: LayerComponentDTO? = nil,
        prefabLink: PrefabLinkComponentDTO? = nil,
        prefabOverrides: PrefabOverrideComponentDTO? = nil,
        meshRenderer: MeshRendererComponentDTO? = nil,
        skinnedMesh: SkinnedMeshComponentDTO? = nil,
        animator: AnimatorComponentDTO? = nil,
        materialComponent: MaterialComponentDTO? = nil,
        rigidbody: RigidbodyComponentDTO? = nil,
        collider: ColliderComponentDTO? = nil,
        light: LightComponentDTO? = nil,
        lightOrbit: LightOrbitComponentDTO? = nil,
        camera: CameraComponentDTO? = nil,
        script: ScriptComponentDTO? = nil,
        characterController: CharacterControllerComponentDTO? = nil,
        audioSource: AudioSourceComponentDTO? = nil,
        audioListener: AudioListenerComponentDTO? = nil,
        skyLight: SkyLightComponentDTO? = nil,
        environmentState: EnvironmentStateComponentDTO? = nil,
        skyIBLState: SkyIBLStateComponentDTO? = nil,
        environment: EnvironmentComponentDTO? = nil,
        reflectionProbe: ReflectionProbeComponentDTO? = nil,
        skyLightTag: TagComponentDTO? = nil,
        skySunTag: TagComponentDTO? = nil
    ) {
        self.name = name
        self.transform = transform
        self.layer = layer
        self.prefabLink = prefabLink
        self.prefabOverrides = prefabOverrides
        self.meshRenderer = meshRenderer
        self.skinnedMesh = skinnedMesh
        self.animator = animator
        self.materialComponent = materialComponent
        self.rigidbody = rigidbody
        self.collider = collider
        self.light = light
        self.lightOrbit = lightOrbit
        self.camera = camera
        self.script = script
        self.characterController = characterController
        self.audioSource = audioSource
        self.audioListener = audioListener
        self.skyLight = skyLight
        self.environmentState = environmentState
        self.skyIBLState = skyIBLState
        self.environment = environment
        self.reflectionProbe = reflectionProbe
        self.skyLightTag = skyLightTag
        self.skySunTag = skySunTag
    }
}

public struct TagComponentDTO: Codable {
    public var schemaVersion: Int

    public init(schemaVersion: Int = 1) {
        self.schemaVersion = schemaVersion
    }
}

public struct NameComponentDTO: Codable {
    public var schemaVersion: Int
    public var name: String

    public init(schemaVersion: Int = 1, name: String) {
        self.schemaVersion = schemaVersion
        self.name = name
    }
}

public struct TransformComponentDTO: Codable {
    public var schemaVersion: Int
    public var position: Vector3DTO
    public var rotationQuat: Vector4DTO
    public var scale: Vector3DTO

    public init(schemaVersion: Int = 2, position: Vector3DTO, rotationQuat: Vector4DTO, scale: Vector3DTO) {
        self.schemaVersion = schemaVersion
        self.position = position
        self.rotationQuat = rotationQuat
        self.scale = scale
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case position
        case rotationQuat
        case rotation
        case scale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        position = try container.decode(Vector3DTO.self, forKey: .position)
        scale = try container.decode(Vector3DTO.self, forKey: .scale)

        if let quat = try container.decodeIfPresent(Vector4DTO.self, forKey: .rotationQuat) {
            rotationQuat = quat
        } else if let euler = try container.decodeIfPresent(Vector3DTO.self, forKey: .rotation) {
            rotationQuat = Vector4DTO(TransformMath.quaternionFromEulerXYZ(euler.toSIMD()))
        } else {
            rotationQuat = Vector4DTO(TransformMath.identityQuaternion)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(position, forKey: .position)
        try container.encode(rotationQuat, forKey: .rotationQuat)
        try container.encode(scale, forKey: .scale)
    }
}

public struct LayerComponentDTO: Codable {
    public var schemaVersion: Int
    public var layerIndex: Int32

    public init(schemaVersion: Int = 1, layerIndex: Int32) {
        self.schemaVersion = schemaVersion
        self.layerIndex = layerIndex
    }
}

public struct PrefabLinkComponentDTO: Codable {
    public var schemaVersion: Int
    public var prefabHandle: AssetHandle
    public var prefabEntityId: UUID
    public var instanceId: UUID

    public init(schemaVersion: Int = 1, prefabHandle: AssetHandle, prefabEntityId: UUID, instanceId: UUID) {
        self.schemaVersion = schemaVersion
        self.prefabHandle = prefabHandle
        self.prefabEntityId = prefabEntityId
        self.instanceId = instanceId
    }
}

public struct PrefabOverrideComponentDTO: Codable {
    public var schemaVersion: Int
    public var overriddenComponents: [String]

    public init(schemaVersion: Int = 1, overriddenComponents: [String]) {
        self.schemaVersion = schemaVersion
        self.overriddenComponents = overriddenComponents
    }
}

public struct MeshRendererComponentDTO: Codable {
    public var schemaVersion: Int
    public var meshHandle: AssetHandle?
    public var materialHandle: AssetHandle?
    public var submeshMaterialHandles: [AssetHandle?]?
    public var material: MaterialDTO?
    public var albedoMapHandle: AssetHandle?
    public var normalMapHandle: AssetHandle?
    public var metallicMapHandle: AssetHandle?
    public var roughnessMapHandle: AssetHandle?
    public var mrMapHandle: AssetHandle?
    public var ormMapHandle: AssetHandle?
    public var aoMapHandle: AssetHandle?
    public var emissiveMapHandle: AssetHandle?

    public init(
        schemaVersion: Int = 1,
        meshHandle: AssetHandle?,
        materialHandle: AssetHandle?,
        submeshMaterialHandles: [AssetHandle?]?,
        material: MaterialDTO?,
        albedoMapHandle: AssetHandle?,
        normalMapHandle: AssetHandle?,
        metallicMapHandle: AssetHandle?,
        roughnessMapHandle: AssetHandle?,
        mrMapHandle: AssetHandle?,
        ormMapHandle: AssetHandle?,
        aoMapHandle: AssetHandle?,
        emissiveMapHandle: AssetHandle?
    ) {
        self.schemaVersion = schemaVersion
        self.meshHandle = meshHandle
        self.materialHandle = materialHandle
        self.submeshMaterialHandles = submeshMaterialHandles
        self.material = material
        self.albedoMapHandle = albedoMapHandle
        self.normalMapHandle = normalMapHandle
        self.metallicMapHandle = metallicMapHandle
        self.roughnessMapHandle = roughnessMapHandle
        self.mrMapHandle = mrMapHandle
        self.ormMapHandle = ormMapHandle
        self.aoMapHandle = aoMapHandle
        self.emissiveMapHandle = emissiveMapHandle
    }
}

public struct SkinnedMeshComponentDTO: Codable {
    public var schemaVersion: Int
    public var skeletonHandle: AssetHandle?
    public var rootBoneName: String

    public init(schemaVersion: Int = 1,
                skeletonHandle: AssetHandle?,
                rootBoneName: String) {
        self.schemaVersion = schemaVersion
        self.skeletonHandle = skeletonHandle
        self.rootBoneName = rootBoneName
    }

    public init(component: SkinnedMeshComponent) {
        self.schemaVersion = 1
        self.skeletonHandle = component.skeletonHandle
        self.rootBoneName = component.rootBoneName
    }

    public func toComponent() -> SkinnedMeshComponent {
        SkinnedMeshComponent(skeletonHandle: skeletonHandle, rootBoneName: rootBoneName)
    }
}

public struct AnimatorComponentDTO: Codable {
    public var schemaVersion: Int
    public var evaluationMode: AnimatorEvaluationMode
    public var clipHandle: AssetHandle?
    public var graphHandle: AssetHandle?
    public var playbackTime: Float
    public var playbackSpeed: Float
    public var isPlaying: Bool
    public var isLooping: Bool
    public var enableRootMotion: Bool
    
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case evaluationMode
        case clipHandle
        case graphHandle
        case playbackTime
        case playbackSpeed
        case isPlaying
        case isLooping
        case enableRootMotion
    }

    public init(schemaVersion: Int = 2,
                evaluationMode: AnimatorEvaluationMode = .clip,
                clipHandle: AssetHandle?,
                graphHandle: AssetHandle? = nil,
                playbackTime: Float,
                playbackSpeed: Float = 1.0,
                isPlaying: Bool,
                isLooping: Bool,
                enableRootMotion: Bool = true) {
        self.schemaVersion = schemaVersion
        self.evaluationMode = evaluationMode
        self.clipHandle = clipHandle
        self.graphHandle = graphHandle
        self.playbackTime = playbackTime
        self.playbackSpeed = playbackSpeed
        self.isPlaying = isPlaying
        self.isLooping = isLooping
        self.enableRootMotion = enableRootMotion
    }

    public init(component: AnimatorComponent) {
        self.schemaVersion = 2
        self.evaluationMode = component.evaluationMode
        self.clipHandle = component.clipHandle
        self.graphHandle = component.graphHandle
        self.playbackTime = component.playbackTime
        self.playbackSpeed = component.playbackSpeed
        self.isPlaying = component.isPlaying
        self.isLooping = component.isLooping
        self.enableRootMotion = component.enableRootMotion
    }

    public func toComponent() -> AnimatorComponent {
        AnimatorComponent(evaluationMode: graphHandle != nil ? evaluationMode : .clip,
                          clipHandle: clipHandle,
                          graphHandle: graphHandle,
                          playbackTime: playbackTime,
                          playbackSpeed: playbackSpeed,
                          isPlaying: isPlaying,
                          isLooping: isLooping,
                          enableRootMotion: enableRootMotion)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.evaluationMode = try container.decodeIfPresent(AnimatorEvaluationMode.self, forKey: .evaluationMode) ?? .clip
        self.clipHandle = try container.decodeIfPresent(AssetHandle.self, forKey: .clipHandle)
        self.graphHandle = try container.decodeIfPresent(AssetHandle.self, forKey: .graphHandle)
        self.playbackTime = try container.decodeIfPresent(Float.self, forKey: .playbackTime) ?? 0.0
        self.playbackSpeed = try container.decodeIfPresent(Float.self, forKey: .playbackSpeed) ?? 1.0
        self.isPlaying = try container.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? true
        self.isLooping = try container.decodeIfPresent(Bool.self, forKey: .isLooping) ?? true
        self.enableRootMotion = try container.decodeIfPresent(Bool.self, forKey: .enableRootMotion) ?? true
        if graphHandle != nil, schemaVersion < 2 {
            self.evaluationMode = .graph
        }
    }
}

public struct AudioSourceComponentDTO: Codable {
    public var schemaVersion: Int
    public var enabled: Bool
    public var audioAssetHandle: AssetHandle?
    public var volume: Float
    public var pitch: Float
    public var looping: Bool
    public var playOnAwake: Bool
    public var spatialized: Bool
    public var maxDistance: Float
    public var isPlaying: Bool

    public init(schemaVersion: Int = 1,
                enabled: Bool,
                audioAssetHandle: AssetHandle?,
                volume: Float,
                pitch: Float,
                looping: Bool,
                playOnAwake: Bool,
                spatialized: Bool,
                maxDistance: Float,
                isPlaying: Bool) {
        self.schemaVersion = schemaVersion
        self.enabled = enabled
        self.audioAssetHandle = audioAssetHandle
        self.volume = volume
        self.pitch = pitch
        self.looping = looping
        self.playOnAwake = playOnAwake
        self.spatialized = spatialized
        self.maxDistance = maxDistance
        self.isPlaying = isPlaying
    }

    public init(component: AudioSourceComponent) {
        self.schemaVersion = 1
        self.enabled = component.isEnabled
        self.audioAssetHandle = component.audioAssetHandle
        self.volume = component.volume
        self.pitch = component.pitch
        self.looping = component.isLooping
        self.playOnAwake = component.playOnAwake
        self.spatialized = component.isSpatialized
        self.maxDistance = component.maxDistance
        self.isPlaying = component.isPlaying
    }

    public func toComponent() -> AudioSourceComponent {
        AudioSourceComponent(
            isEnabled: enabled,
            audioAssetHandle: audioAssetHandle,
            volume: volume,
            pitch: pitch,
            isLooping: looping,
            playOnAwake: playOnAwake,
            isSpatialized: spatialized,
            maxDistance: maxDistance,
            isPlaying: isPlaying
        )
    }
}

public struct AudioListenerComponentDTO: Codable {
    public var schemaVersion: Int
    public var enabled: Bool
    public var isPrimary: Bool

    public init(schemaVersion: Int = 1,
                enabled: Bool,
                isPrimary: Bool) {
        self.schemaVersion = schemaVersion
        self.enabled = enabled
        self.isPrimary = isPrimary
    }

    public init(component: AudioListenerComponent) {
        self.schemaVersion = 1
        self.enabled = component.isEnabled
        self.isPrimary = component.isPrimary
    }

    public func toComponent() -> AudioListenerComponent {
        AudioListenerComponent(isEnabled: enabled, isPrimary: isPrimary)
    }
}

public struct MaterialComponentDTO: Codable {
    public var schemaVersion: Int
    public var materialHandle: AssetHandle?

    public init(schemaVersion: Int = 1, materialHandle: AssetHandle?) {
        self.schemaVersion = schemaVersion
        self.materialHandle = materialHandle
    }
}

public struct RigidbodyComponentDTO: Codable {
    public var schemaVersion: Int
    public var enabled: Bool
    public var motionType: UInt32
    public var mass: Float
    public var friction: Float
    public var restitution: Float
    public var linearDamping: Float
    public var angularDamping: Float
    public var gravityFactor: Float
    public var allowSleeping: Bool
    public var ccdEnabled: Bool
    public var collisionLayer: Int32

    public init(schemaVersion: Int = 1,
                enabled: Bool,
                motionType: UInt32,
                mass: Float,
                friction: Float,
                restitution: Float,
                linearDamping: Float,
                angularDamping: Float,
                gravityFactor: Float,
                allowSleeping: Bool,
                ccdEnabled: Bool,
                collisionLayer: Int32) {
        self.schemaVersion = schemaVersion
        self.enabled = enabled
        self.motionType = motionType
        self.mass = mass
        self.friction = friction
        self.restitution = restitution
        self.linearDamping = linearDamping
        self.angularDamping = angularDamping
        self.gravityFactor = gravityFactor
        self.allowSleeping = allowSleeping
        self.ccdEnabled = ccdEnabled
        self.collisionLayer = collisionLayer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        motionType = try container.decodeIfPresent(UInt32.self, forKey: .motionType) ?? RigidbodyMotionType.dynamic.rawValue
        mass = try container.decodeIfPresent(Float.self, forKey: .mass) ?? 1.0
        friction = try container.decodeIfPresent(Float.self, forKey: .friction) ?? .nan
        restitution = try container.decodeIfPresent(Float.self, forKey: .restitution) ?? .nan
        linearDamping = try container.decodeIfPresent(Float.self, forKey: .linearDamping) ?? .nan
        angularDamping = try container.decodeIfPresent(Float.self, forKey: .angularDamping) ?? .nan
        gravityFactor = try container.decodeIfPresent(Float.self, forKey: .gravityFactor) ?? 1.0
        allowSleeping = try container.decodeIfPresent(Bool.self, forKey: .allowSleeping) ?? true
        ccdEnabled = try container.decodeIfPresent(Bool.self, forKey: .ccdEnabled) ?? false
        collisionLayer = try container.decodeIfPresent(Int32.self, forKey: .collisionLayer) ?? 0
    }

    public func toComponent() -> RigidbodyComponent {
        toComponent(defaults: PhysicsSettings())
    }

    public func toComponent(defaults: PhysicsSettings) -> RigidbodyComponent {
        let resolvedFriction = friction.isFinite ? friction : defaults.defaultFriction
        let resolvedRestitution = restitution.isFinite ? restitution : defaults.defaultRestitution
        let resolvedLinearDamping = linearDamping.isFinite ? linearDamping : defaults.defaultLinearDamping
        let resolvedAngularDamping = angularDamping.isFinite ? angularDamping : defaults.defaultAngularDamping
        return RigidbodyComponent(isEnabled: enabled,
                                  motionType: RigidbodyMotionType(rawValue: motionType) ?? .dynamic,
                                  mass: mass,
                                  friction: resolvedFriction,
                                  restitution: resolvedRestitution,
                                  linearDamping: resolvedLinearDamping,
                                  angularDamping: resolvedAngularDamping,
                                  gravityFactor: gravityFactor,
                                  allowSleeping: allowSleeping,
                                  ccdEnabled: ccdEnabled,
                                  collisionLayer: collisionLayer)
    }
}

public struct ColliderComponentDTO: Codable {
    public var schemaVersion: Int
    public var enabled: Bool
    public var shapeType: UInt32
    public var boxHalfExtents: Vector3DTO
    public var sphereRadius: Float
    public var capsuleHalfHeight: Float
    public var capsuleRadius: Float
    public var offset: Vector3DTO
    public var rotationOffset: Vector3DTO
    public var isTrigger: Bool
    public var collisionLayerOverride: Int32?
    public var physicsMaterial: AssetHandle?
    public var shapes: [ColliderShapeDTO]?

    public init(schemaVersion: Int = 1,
                enabled: Bool,
                shapeType: UInt32,
                boxHalfExtents: Vector3DTO,
                sphereRadius: Float,
                capsuleHalfHeight: Float,
                capsuleRadius: Float,
                offset: Vector3DTO,
                rotationOffset: Vector3DTO,
                isTrigger: Bool,
                collisionLayerOverride: Int32? = nil,
                physicsMaterial: AssetHandle? = nil,
                shapes: [ColliderShapeDTO]? = nil) {
        self.schemaVersion = schemaVersion
        self.enabled = enabled
        self.shapeType = shapeType
        self.boxHalfExtents = boxHalfExtents
        self.sphereRadius = sphereRadius
        self.capsuleHalfHeight = capsuleHalfHeight
        self.capsuleRadius = capsuleRadius
        self.offset = offset
        self.rotationOffset = rotationOffset
        self.isTrigger = isTrigger
        self.collisionLayerOverride = collisionLayerOverride
        self.physicsMaterial = physicsMaterial
        self.shapes = shapes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        shapeType = try container.decodeIfPresent(UInt32.self, forKey: .shapeType) ?? ColliderShapeType.box.rawValue
        boxHalfExtents = try container.decodeIfPresent(Vector3DTO.self, forKey: .boxHalfExtents) ?? Vector3DTO(SIMD3<Float>(repeating: 0.5))
        sphereRadius = try container.decodeIfPresent(Float.self, forKey: .sphereRadius) ?? 0.5
        capsuleHalfHeight = try container.decodeIfPresent(Float.self, forKey: .capsuleHalfHeight) ?? 0.5
        capsuleRadius = try container.decodeIfPresent(Float.self, forKey: .capsuleRadius) ?? 0.5
        offset = try container.decodeIfPresent(Vector3DTO.self, forKey: .offset) ?? Vector3DTO(.zero)
        rotationOffset = try container.decodeIfPresent(Vector3DTO.self, forKey: .rotationOffset) ?? Vector3DTO(.zero)
        isTrigger = try container.decodeIfPresent(Bool.self, forKey: .isTrigger) ?? false
        collisionLayerOverride = try container.decodeIfPresent(Int32.self, forKey: .collisionLayerOverride)
        physicsMaterial = try container.decodeIfPresent(AssetHandle.self, forKey: .physicsMaterial)
        shapes = try container.decodeIfPresent([ColliderShapeDTO].self, forKey: .shapes)
    }

    public func toComponent() -> ColliderComponent {
        if let shapes, !shapes.isEmpty {
            var component = ColliderComponent()
            component.setShapes(shapes.map { $0.toShape() })
            return component
        }
        return ColliderComponent(isEnabled: enabled,
                                 shapeType: ColliderShapeType(rawValue: shapeType) ?? .box,
                                 boxHalfExtents: boxHalfExtents.toSIMD(),
                                 sphereRadius: sphereRadius,
                                 capsuleHalfHeight: capsuleHalfHeight,
                                 capsuleRadius: capsuleRadius,
                                 offset: offset.toSIMD(),
                                 rotationOffset: rotationOffset.toSIMD(),
                                 isTrigger: isTrigger,
                                 collisionLayerOverride: collisionLayerOverride,
                                 physicsMaterial: physicsMaterial)
    }

    public init(component: ColliderComponent) {
        self.schemaVersion = 2
        self.enabled = component.isEnabled
        self.shapeType = component.shapeType.rawValue
        self.boxHalfExtents = Vector3DTO(component.boxHalfExtents)
        self.sphereRadius = component.sphereRadius
        self.capsuleHalfHeight = component.capsuleHalfHeight
        self.capsuleRadius = component.capsuleRadius
        self.offset = Vector3DTO(component.offset)
        self.rotationOffset = Vector3DTO(component.rotationOffset)
        self.isTrigger = component.isTrigger
        self.collisionLayerOverride = component.collisionLayerOverride
        self.physicsMaterial = component.physicsMaterial
        self.shapes = component.allShapes().map { ColliderShapeDTO(shape: $0) }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case enabled
        case shapeType
        case boxHalfExtents
        case sphereRadius
        case capsuleHalfHeight
        case capsuleRadius
        case offset
        case rotationOffset
        case isTrigger
        case collisionLayerOverride
        case physicsMaterial
        case shapes
    }
}

public struct ColliderShapeDTO: Codable {
    public var enabled: Bool
    public var shapeType: UInt32
    public var boxHalfExtents: Vector3DTO
    public var sphereRadius: Float
    public var capsuleHalfHeight: Float
    public var capsuleRadius: Float
    public var offset: Vector3DTO
    public var rotationOffset: Vector3DTO
    public var isTrigger: Bool
    public var collisionLayerOverride: Int32?
    public var physicsMaterial: AssetHandle?

    public init(shape: ColliderShape) {
        enabled = shape.isEnabled
        shapeType = shape.shapeType.rawValue
        boxHalfExtents = Vector3DTO(shape.boxHalfExtents)
        sphereRadius = shape.sphereRadius
        capsuleHalfHeight = shape.capsuleHalfHeight
        capsuleRadius = shape.capsuleRadius
        offset = Vector3DTO(shape.offset)
        rotationOffset = Vector3DTO(shape.rotationOffset)
        isTrigger = shape.isTrigger
        collisionLayerOverride = shape.collisionLayerOverride
        physicsMaterial = shape.physicsMaterial
    }

    public func toShape() -> ColliderShape {
        ColliderShape(
            isEnabled: enabled,
            shapeType: ColliderShapeType(rawValue: shapeType) ?? .box,
            boxHalfExtents: boxHalfExtents.toSIMD(),
            sphereRadius: sphereRadius,
            capsuleHalfHeight: capsuleHalfHeight,
            capsuleRadius: capsuleRadius,
            offset: offset.toSIMD(),
            rotationOffset: rotationOffset.toSIMD(),
            isTrigger: isTrigger,
            collisionLayerOverride: collisionLayerOverride,
            physicsMaterial: physicsMaterial
        )
    }
}

public struct LightComponentDTO: Codable {
    public var schemaVersion: Int
    public var type: LightTypeDTO
    public var data: LightDataDTO
    public var direction: Vector3DTO
    public var range: Float
    public var innerConeCos: Float
    public var outerConeCos: Float
    public var castsShadows: Bool

    public init(
        schemaVersion: Int = 1,
        type: LightTypeDTO,
        data: LightDataDTO,
        direction: Vector3DTO,
        range: Float,
        innerConeCos: Float,
        outerConeCos: Float,
        castsShadows: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.type = type
        self.data = data
        self.direction = direction
        self.range = range
        self.innerConeCos = innerConeCos
        self.outerConeCos = outerConeCos
        self.castsShadows = castsShadows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        type = try container.decodeIfPresent(LightTypeDTO.self, forKey: .type) ?? .point
        data = try container.decodeIfPresent(LightDataDTO.self, forKey: .data) ?? LightDataDTO(from: LightData())
        direction = try container.decodeIfPresent(Vector3DTO.self, forKey: .direction) ?? Vector3DTO(.zero)
        range = try container.decodeIfPresent(Float.self, forKey: .range) ?? 0.0
        innerConeCos = try container.decodeIfPresent(Float.self, forKey: .innerConeCos) ?? 0.95
        outerConeCos = try container.decodeIfPresent(Float.self, forKey: .outerConeCos) ?? 0.9
        castsShadows = try container.decodeIfPresent(Bool.self, forKey: .castsShadows) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(type, forKey: .type)
        try container.encode(data, forKey: .data)
        try container.encode(direction, forKey: .direction)
        try container.encode(range, forKey: .range)
        try container.encode(innerConeCos, forKey: .innerConeCos)
        try container.encode(outerConeCos, forKey: .outerConeCos)
        try container.encode(castsShadows, forKey: .castsShadows)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case type
        case data
        case direction
        case range
        case innerConeCos
        case outerConeCos
        case castsShadows
    }
}

public struct LightOrbitComponentDTO: Codable {
    public var schemaVersion: Int
    public var centerEntityId: UUID?
    public var radius: Float
    public var speed: Float
    public var height: Float
    public var phase: Float
    public var affectsDirection: Bool

    public init(
        schemaVersion: Int = 1,
        centerEntityId: UUID?,
        radius: Float,
        speed: Float,
        height: Float,
        phase: Float,
        affectsDirection: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.centerEntityId = centerEntityId
        self.radius = radius
        self.speed = speed
        self.height = height
        self.phase = phase
        self.affectsDirection = affectsDirection
    }

    public init(component: LightOrbitComponent) {
        self.schemaVersion = 1
        self.centerEntityId = component.centerEntityId
        self.radius = component.radius
        self.speed = component.speed
        self.height = component.height
        self.phase = component.phase
        self.affectsDirection = component.affectsDirection
    }

    public func toComponent() -> LightOrbitComponent {
        return LightOrbitComponent(
            centerEntityId: centerEntityId,
            radius: radius,
            speed: speed,
            height: height,
            phase: phase,
            affectsDirection: affectsDirection
        )
    }
}

public struct CameraComponentDTO: Codable {
    public var schemaVersion: Int
    public var fovDegrees: Float
    public var orthoSize: Float
    public var nearPlane: Float
    public var farPlane: Float
    public var projectionType: UInt32
    public var isPrimary: Bool
    public var isEditor: Bool
    public var autoExposureEnabled: Bool
    public var exposureEV: Float
    public var exposureCompensation: Float
    public var autoExposureMin: Float
    public var autoExposureMax: Float
    public var adaptationSpeed: Float

    public init(schemaVersion: Int = 4, component: CameraComponent) {
        self.schemaVersion = schemaVersion
        self.fovDegrees = component.fovDegrees
        self.orthoSize = component.orthoSize
        self.nearPlane = component.nearPlane
        self.farPlane = component.farPlane
        self.projectionType = component.projectionType.rawValue
        self.isPrimary = component.isPrimary
        self.isEditor = component.isEditor
        self.autoExposureEnabled = component.autoExposureEnabled
        self.exposureEV = component.exposureEV
        self.exposureCompensation = component.exposureCompensation
        self.autoExposureMin = component.autoExposureMin
        self.autoExposureMax = component.autoExposureMax
        self.adaptationSpeed = component.adaptationSpeed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        fovDegrees = try container.decodeIfPresent(Float.self, forKey: .fovDegrees) ?? 45.0
        orthoSize = try container.decodeIfPresent(Float.self, forKey: .orthoSize) ?? 10.0
        nearPlane = try container.decodeIfPresent(Float.self, forKey: .nearPlane) ?? 0.1
        farPlane = try container.decodeIfPresent(Float.self, forKey: .farPlane) ?? 1000.0
        projectionType = try container.decodeIfPresent(UInt32.self, forKey: .projectionType) ?? ProjectionType.perspective.rawValue
        isPrimary = try container.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? true
        isEditor = try container.decodeIfPresent(Bool.self, forKey: .isEditor) ?? false
        autoExposureEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoExposureEnabled) ?? false
        if let encodedEV = try container.decodeIfPresent(Float.self, forKey: .exposureEV) {
            exposureEV = encodedEV
        } else if let legacyMultiplier = try container.decodeIfPresent(Float.self, forKey: .manualExposure) {
            exposureEV = SceneLinearHDRContract.exposureEV(fromLegacyMultiplier: legacyMultiplier)
        } else {
            exposureEV = 0.0
        }
        exposureCompensation = try container.decodeIfPresent(Float.self, forKey: .exposureCompensation) ?? 0.0
        autoExposureMin = try container.decodeIfPresent(Float.self, forKey: .autoExposureMin) ?? 0.03
        autoExposureMax = try container.decodeIfPresent(Float.self, forKey: .autoExposureMax) ?? 8.0
        adaptationSpeed = try container.decodeIfPresent(Float.self, forKey: .adaptationSpeed) ?? 2.0
    }

    public func toComponent() -> CameraComponent {
        return CameraComponent(
            fovDegrees: fovDegrees,
            orthoSize: orthoSize,
            nearPlane: nearPlane,
            farPlane: farPlane,
            projectionType: ProjectionType(rawValue: projectionType) ?? .perspective,
            isPrimary: isPrimary,
            isEditor: isEditor,
            autoExposureEnabled: autoExposureEnabled,
            exposureEV: exposureEV,
            exposureCompensation: exposureCompensation,
            autoExposureMin: autoExposureMin,
            autoExposureMax: autoExposureMax,
            adaptationSpeed: adaptationSpeed
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(4, forKey: .schemaVersion)
        try container.encode(fovDegrees, forKey: .fovDegrees)
        try container.encode(orthoSize, forKey: .orthoSize)
        try container.encode(nearPlane, forKey: .nearPlane)
        try container.encode(farPlane, forKey: .farPlane)
        try container.encode(projectionType, forKey: .projectionType)
        try container.encode(isPrimary, forKey: .isPrimary)
        try container.encode(isEditor, forKey: .isEditor)
        try container.encode(autoExposureEnabled, forKey: .autoExposureEnabled)
        try container.encode(exposureEV, forKey: .exposureEV)
        try container.encode(exposureCompensation, forKey: .exposureCompensation)
        try container.encode(autoExposureMin, forKey: .autoExposureMin)
        try container.encode(autoExposureMax, forKey: .autoExposureMax)
        try container.encode(adaptationSpeed, forKey: .adaptationSpeed)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case fovDegrees
        case orthoSize
        case nearPlane
        case farPlane
        case projectionType
        case isPrimary
        case isEditor
        case autoExposureEnabled
        case exposureEV
        case manualExposure
        case exposureCompensation
        case autoExposureMin
        case autoExposureMax
        case adaptationSpeed
    }
}

public struct ScriptComponentDTO: Codable {
    public var schemaVersion: Int
    public var enabled: Bool
    public var scriptAssetHandle: AssetHandle?
    public var typeName: String
    public var fieldDataBase64: String
    public var fieldDataVersion: UInt32
    public var serializedFields: [String: ScriptFieldValue]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case enabled
        case scriptAssetHandle
        case typeName
        case fieldDataBase64
        case fieldDataVersion
        case serializedFields
    }

    public init(schemaVersion: Int = 1,
                enabled: Bool,
                scriptAssetHandle: AssetHandle?,
                typeName: String,
                fieldDataBase64: String,
                fieldDataVersion: UInt32 = 1,
                serializedFields: [String: ScriptFieldValue] = [:]) {
        self.schemaVersion = schemaVersion
        self.enabled = enabled
        self.scriptAssetHandle = scriptAssetHandle
        self.typeName = typeName
        self.fieldDataBase64 = fieldDataBase64
        self.fieldDataVersion = fieldDataVersion
        self.serializedFields = serializedFields
    }

    public init(component: ScriptComponent) {
        self.schemaVersion = 1
        self.enabled = component.enabled
        self.scriptAssetHandle = component.scriptAssetHandle
        self.typeName = component.typeName
        self.fieldDataBase64 = component.fieldData.base64EncodedString()
        self.fieldDataVersion = component.fieldDataVersion
        self.serializedFields = component.serializedFields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        scriptAssetHandle = try container.decodeIfPresent(AssetHandle.self, forKey: .scriptAssetHandle)
        typeName = try container.decodeIfPresent(String.self, forKey: .typeName) ?? ""
        fieldDataBase64 = try container.decodeIfPresent(String.self, forKey: .fieldDataBase64) ?? ""
        fieldDataVersion = try container.decodeIfPresent(UInt32.self, forKey: .fieldDataVersion) ?? 1
        serializedFields = try container.decodeIfPresent([String: ScriptFieldValue].self, forKey: .serializedFields) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(scriptAssetHandle, forKey: .scriptAssetHandle)
        try container.encode(typeName, forKey: .typeName)
        try container.encode(fieldDataBase64, forKey: .fieldDataBase64)
        try container.encode(fieldDataVersion, forKey: .fieldDataVersion)
        try container.encode(serializedFields, forKey: .serializedFields)
    }

    public func toComponent() -> ScriptComponent {
        let decoded = Data(base64Encoded: fieldDataBase64) ?? Data()
        return ScriptComponent(enabled: enabled,
                               scriptAssetHandle: scriptAssetHandle,
                               typeName: typeName,
                               fieldData: decoded,
                               fieldDataVersion: fieldDataVersion,
                               serializedFields: serializedFields)
    }
}

public struct CharacterControllerComponentDTO: Codable {
    public var schemaVersion: Int
    public var enabled: Bool
    public var height: Float
    public var radius: Float
    public var stepOffset: Float
    public var moveSpeed: Float
    public var sprintMultiplier: Float
    public var airControl: Float
    public var jumpSpeed: Float
    public var useGravityOverride: Bool
    public var gravity: Float
    public var maxSlope: Float
    public var pushStrength: Float
    public var lookSensitivity: Float
    public var minPitchDegrees: Float
    public var maxPitchDegrees: Float
    public var visualEntityId: UUID?
    public var animatorEntityId: UUID?
    public var cameraPivotEntityId: UUID?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case enabled
        case height
        case radius
        case stepOffset
        case slopeLimit
        case moveSpeed
        case jumpForce
        case sprintMultiplier
        case airControl
        case jumpSpeed
        case useGravityOverride
        case gravity
        case groundProbeDistance
        case maxSlope
        case groundSnapDistance
        case lookSensitivity
        case minPitchDegrees
        case maxPitchDegrees
        case pushStrength
        // Deprecated in runtime since CharacterVirtual ground velocity coupling was removed.
        case groundVelocityFollowThreshold
        case visualEntityId
        case animatorEntityId
        case cameraPivotEntityId
        case debugDraw
    }

    public init(schemaVersion: Int = 1,
                enabled: Bool,
                height: Float,
                radius: Float,
                stepOffset: Float,
                moveSpeed: Float,
                sprintMultiplier: Float,
                airControl: Float = 0.35,
                jumpSpeed: Float,
                useGravityOverride: Bool,
                gravity: Float,
                maxSlope: Float,
                pushStrength: Float = 100.0,
                lookSensitivity: Float = 0.01,
                minPitchDegrees: Float = -80.0,
                maxPitchDegrees: Float = 80.0,
                visualEntityId: UUID? = nil,
                animatorEntityId: UUID? = nil,
                cameraPivotEntityId: UUID? = nil) {
        self.schemaVersion = schemaVersion
        self.enabled = enabled
        self.height = height
        self.radius = radius
        self.stepOffset = stepOffset
        self.moveSpeed = moveSpeed
        self.sprintMultiplier = sprintMultiplier
        self.airControl = airControl
        self.jumpSpeed = jumpSpeed
        self.useGravityOverride = useGravityOverride
        self.gravity = gravity
        self.maxSlope = maxSlope
        self.pushStrength = pushStrength
        self.lookSensitivity = lookSensitivity
        self.minPitchDegrees = minPitchDegrees
        self.maxPitchDegrees = maxPitchDegrees
        self.visualEntityId = visualEntityId
        self.animatorEntityId = animatorEntityId
        self.cameraPivotEntityId = cameraPivotEntityId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.height = try container.decodeIfPresent(Float.self, forKey: .height) ?? 1.8
        self.radius = try container.decodeIfPresent(Float.self, forKey: .radius) ?? 0.35
        self.stepOffset = try container.decodeIfPresent(Float.self, forKey: .stepOffset) ?? 0.25
        self.moveSpeed = try container.decodeIfPresent(Float.self, forKey: .moveSpeed) ?? 4.0
        self.sprintMultiplier = try container.decodeIfPresent(Float.self, forKey: .sprintMultiplier) ?? 1.5
        self.airControl = try container.decodeIfPresent(Float.self, forKey: .airControl) ?? 0.35
        if let jumpSpeed = try container.decodeIfPresent(Float.self, forKey: .jumpSpeed) {
            self.jumpSpeed = jumpSpeed
        } else {
            self.jumpSpeed = try container.decodeIfPresent(Float.self, forKey: .jumpForce) ?? 5.5
        }
        self.useGravityOverride = try container.decodeIfPresent(Bool.self, forKey: .useGravityOverride) ?? false
        self.gravity = try container.decodeIfPresent(Float.self, forKey: .gravity) ?? -9.81
        let legacySlopeLimit = try container.decodeIfPresent(Float.self, forKey: .slopeLimit) ?? 45.0
        self.maxSlope = try container.decodeIfPresent(Float.self, forKey: .maxSlope) ?? legacySlopeLimit
        self.lookSensitivity = try container.decodeIfPresent(Float.self, forKey: .lookSensitivity) ?? 0.01
        self.minPitchDegrees = try container.decodeIfPresent(Float.self, forKey: .minPitchDegrees) ?? -80.0
        self.maxPitchDegrees = try container.decodeIfPresent(Float.self, forKey: .maxPitchDegrees) ?? 80.0
        self.pushStrength = try container.decodeIfPresent(Float.self, forKey: .pushStrength) ?? 100.0
        _ = try container.decodeIfPresent(Float.self, forKey: .groundVelocityFollowThreshold)
        self.visualEntityId = try container.decodeIfPresent(UUID.self, forKey: .visualEntityId)
        self.animatorEntityId = try container.decodeIfPresent(UUID.self, forKey: .animatorEntityId)
        self.cameraPivotEntityId = try container.decodeIfPresent(UUID.self, forKey: .cameraPivotEntityId)
        _ = try container.decodeIfPresent(Bool.self, forKey: .debugDraw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(height, forKey: .height)
        try container.encode(radius, forKey: .radius)
        try container.encode(stepOffset, forKey: .stepOffset)
        try container.encode(moveSpeed, forKey: .moveSpeed)
        try container.encode(sprintMultiplier, forKey: .sprintMultiplier)
        try container.encode(airControl, forKey: .airControl)
        try container.encode(jumpSpeed, forKey: .jumpSpeed)
        try container.encode(useGravityOverride, forKey: .useGravityOverride)
        try container.encode(gravity, forKey: .gravity)
        try container.encode(maxSlope, forKey: .maxSlope)
        try container.encode(pushStrength, forKey: .pushStrength)
        try container.encode(lookSensitivity, forKey: .lookSensitivity)
        try container.encode(minPitchDegrees, forKey: .minPitchDegrees)
        try container.encode(maxPitchDegrees, forKey: .maxPitchDegrees)
        try container.encodeIfPresent(visualEntityId, forKey: .visualEntityId)
        try container.encodeIfPresent(animatorEntityId, forKey: .animatorEntityId)
        try container.encodeIfPresent(cameraPivotEntityId, forKey: .cameraPivotEntityId)
    }

    public init(component: CharacterControllerComponent) {
        self.schemaVersion = 3
        self.enabled = component.isEnabled
        self.height = component.height
        self.radius = component.radius
        self.stepOffset = component.stepOffset
        self.moveSpeed = component.moveSpeed
        self.sprintMultiplier = component.sprintMultiplier
        self.airControl = component.airControl
        self.jumpSpeed = component.jumpSpeed
        self.useGravityOverride = component.useGravityOverride
        self.gravity = component.gravity
        self.maxSlope = component.maxSlope
        self.pushStrength = component.pushStrength
        self.lookSensitivity = component.lookSensitivity
        self.minPitchDegrees = component.minPitchDegrees
        self.maxPitchDegrees = component.maxPitchDegrees
        self.visualEntityId = component.visualEntityId
        self.animatorEntityId = component.animatorEntityId
        self.cameraPivotEntityId = component.cameraPivotEntityId
    }

    public func toComponent() -> CharacterControllerComponent {
        CharacterControllerComponent(isEnabled: enabled,
                                     height: height,
                                     radius: radius,
                                     stepOffset: stepOffset,
                                     moveSpeed: moveSpeed,
                                     sprintMultiplier: sprintMultiplier,
                                     airControl: airControl,
                                     jumpSpeed: jumpSpeed,
                                     useGravityOverride: useGravityOverride,
                                     gravity: gravity,
                                     maxSlope: maxSlope,
                                     pushStrength: pushStrength,
                                     lookSensitivity: lookSensitivity,
                                     minPitchDegrees: minPitchDegrees,
                                     maxPitchDegrees: maxPitchDegrees,
                                     visualEntityId: visualEntityId,
                                     animatorEntityId: animatorEntityId,
                                     cameraPivotEntityId: cameraPivotEntityId)
    }
}

public struct ReflectionProbeComponentDTO: Codable {
    public var schemaVersion: Int
    public var enabled: Bool
    public var intensity: Float
    public var boxExtents: Vector3DTO
    public var blendDistance: Float
    public var priority: Int32
    public var captureResolution: Int32
    public var rebuildMode: ReflectionProbeRebuildMode
    public var includeSky: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case enabled
        case intensity
        case boxExtents
        case blendDistance
        case priority
        case captureResolution
        case rebuildMode
        case includeSky
        case sourceEnvironmentHandle
    }

    public init(
        schemaVersion: Int = 2,
        enabled: Bool,
        intensity: Float,
        boxExtents: Vector3DTO,
        blendDistance: Float,
        priority: Int32,
        captureResolution: Int32,
        rebuildMode: ReflectionProbeRebuildMode,
        includeSky: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.enabled = enabled
        self.intensity = intensity
        self.boxExtents = boxExtents
        self.blendDistance = blendDistance
        self.priority = priority
        self.captureResolution = captureResolution
        self.rebuildMode = rebuildMode
        self.includeSky = includeSky
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        intensity = try container.decodeIfPresent(Float.self, forKey: .intensity) ?? 1.0
        boxExtents = try container.decodeIfPresent(Vector3DTO.self, forKey: .boxExtents) ?? Vector3DTO(SIMD3<Float>(5.0, 5.0, 5.0))
        blendDistance = try container.decodeIfPresent(Float.self, forKey: .blendDistance) ?? 1.0
        priority = try container.decodeIfPresent(Int32.self, forKey: .priority) ?? 0
        captureResolution = try container.decodeIfPresent(Int32.self, forKey: .captureResolution) ?? 128
        rebuildMode = try container.decodeIfPresent(ReflectionProbeRebuildMode.self, forKey: .rebuildMode) ?? .onPlay
        includeSky = try container.decodeIfPresent(Bool.self, forKey: .includeSky) ?? true

        // Decode and ignore legacy authored-HDRI data so older scenes still load cleanly.
        _ = try container.decodeIfPresent(AssetHandle.self, forKey: .sourceEnvironmentHandle)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(intensity, forKey: .intensity)
        try container.encode(boxExtents, forKey: .boxExtents)
        try container.encode(blendDistance, forKey: .blendDistance)
        try container.encode(priority, forKey: .priority)
        try container.encode(captureResolution, forKey: .captureResolution)
        try container.encode(rebuildMode, forKey: .rebuildMode)
        try container.encode(includeSky, forKey: .includeSky)
    }

    public func toComponent() -> ReflectionProbeComponent {
        ReflectionProbeComponent(
            enabled: enabled,
            intensity: intensity,
            boxExtents: boxExtents.toSIMD(),
            blendDistance: blendDistance,
            priority: priority,
            captureResolution: captureResolution,
            rebuildMode: rebuildMode,
            includeSky: includeSky
        )
    }
}

public struct SkyLightComponentDTO: Codable {
    public var schemaVersion: Int
    public var mode: UInt32
    public var enabled: Bool
    public var timeOfDay: Float
    public var weatherType: UInt32
    public var secondaryWeatherType: UInt32
    public var weatherBlend: Float
    public var weatherAmount: Float
    public var atmosphereAmount: Float
    public var cloudCoverage: Float
    public var cloudStyle: UInt32
    public var temperature: Float
    public var mood: Float
    public var moonIntensity: Float
    public var moonSizeDegrees: Float
    public var starIntensity: Float
    public var fogAmount: Float
    public var fogHeight: Float
    public var fogDistance: Float
    public var intensity: Float
    public var skyTint: Vector3DTO
    public var turbidity: Float
    public var azimuthDegrees: Float
    public var elevationDegrees: Float
    public var sunSizeDegrees: Float
    public var zenithTint: Vector3DTO
    public var horizonTint: Vector3DTO
    public var gradientStrength: Float
    public var hazeDensity: Float
    public var hazeFalloff: Float
    public var hazeHeight: Float
    public var ozoneStrength: Float
    public var ozoneTint: Vector3DTO
    public var sunHaloSize: Float
    public var sunHaloIntensity: Float
    public var sunHaloSoftness: Float
    public var cloudsEnabled: Bool
    public var cloudsCoverage: Float
    public var cloudsSoftness: Float
    public var cloudsScale: Float
    public var cloudsSpeed: Float
    public var cloudsWindX: Float
    public var cloudsWindY: Float
    public var cloudsHeight: Float
    public var cloudsThickness: Float
    public var cloudsBrightness: Float
    public var cloudsSunInfluence: Float
    public var hdriHandle: AssetHandle?
    /// Migration-only legacy field. Wave 1 moved this to `SkyIBLStateComponentDTO`.
    public var realtimeUpdate: Bool?

    public init(
        schemaVersion: Int = 2,
        mode: UInt32,
        enabled: Bool,
        timeOfDay: Float,
        weatherType: UInt32,
        secondaryWeatherType: UInt32,
        weatherBlend: Float,
        weatherAmount: Float,
        atmosphereAmount: Float,
        cloudCoverage: Float,
        cloudStyle: UInt32,
        temperature: Float,
        mood: Float,
        moonIntensity: Float,
        moonSizeDegrees: Float,
        starIntensity: Float,
        fogAmount: Float,
        fogHeight: Float,
        fogDistance: Float,
        intensity: Float,
        skyTint: Vector3DTO,
        turbidity: Float,
        azimuthDegrees: Float,
        elevationDegrees: Float,
        sunSizeDegrees: Float,
        zenithTint: Vector3DTO,
        horizonTint: Vector3DTO,
        gradientStrength: Float,
        hazeDensity: Float,
        hazeFalloff: Float,
        hazeHeight: Float,
        ozoneStrength: Float,
        ozoneTint: Vector3DTO,
        sunHaloSize: Float,
        sunHaloIntensity: Float,
        sunHaloSoftness: Float,
        cloudsEnabled: Bool,
        cloudsCoverage: Float,
        cloudsSoftness: Float,
        cloudsScale: Float,
        cloudsSpeed: Float,
        cloudsWindX: Float,
        cloudsWindY: Float,
        cloudsHeight: Float,
        cloudsThickness: Float,
        cloudsBrightness: Float,
        cloudsSunInfluence: Float,
        hdriHandle: AssetHandle?,
        realtimeUpdate: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.mode = mode
        self.enabled = enabled
        self.timeOfDay = timeOfDay
        self.weatherType = weatherType
        self.secondaryWeatherType = secondaryWeatherType
        self.weatherBlend = weatherBlend
        self.weatherAmount = weatherAmount
        self.atmosphereAmount = atmosphereAmount
        self.cloudCoverage = cloudCoverage
        self.cloudStyle = cloudStyle
        self.temperature = temperature
        self.mood = mood
        self.moonIntensity = moonIntensity
        self.moonSizeDegrees = moonSizeDegrees
        self.starIntensity = starIntensity
        self.fogAmount = fogAmount
        self.fogHeight = fogHeight
        self.fogDistance = fogDistance
        self.intensity = intensity
        self.skyTint = skyTint
        self.turbidity = turbidity
        self.azimuthDegrees = azimuthDegrees
        self.elevationDegrees = elevationDegrees
        self.sunSizeDegrees = sunSizeDegrees
        self.zenithTint = zenithTint
        self.horizonTint = horizonTint
        self.gradientStrength = gradientStrength
        self.hazeDensity = hazeDensity
        self.hazeFalloff = hazeFalloff
        self.hazeHeight = hazeHeight
        self.ozoneStrength = ozoneStrength
        self.ozoneTint = ozoneTint
        self.sunHaloSize = sunHaloSize
        self.sunHaloIntensity = sunHaloIntensity
        self.sunHaloSoftness = sunHaloSoftness
        self.cloudsEnabled = cloudsEnabled
        self.cloudsCoverage = cloudsCoverage
        self.cloudsSoftness = cloudsSoftness
        self.cloudsScale = cloudsScale
        self.cloudsSpeed = cloudsSpeed
        self.cloudsWindX = cloudsWindX
        self.cloudsWindY = cloudsWindY
        self.cloudsHeight = cloudsHeight
        self.cloudsThickness = cloudsThickness
        self.cloudsBrightness = cloudsBrightness
        self.cloudsSunInfluence = cloudsSunInfluence
        self.hdriHandle = hdriHandle
        self.realtimeUpdate = realtimeUpdate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SkyLightComponent()
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        mode = try container.decodeIfPresent(UInt32.self, forKey: .mode) ?? defaults.mode.rawValue
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        timeOfDay = try container.decodeIfPresent(Float.self, forKey: .timeOfDay) ?? defaults.timeOfDay
        weatherType = try container.decodeIfPresent(UInt32.self, forKey: .weatherType) ?? defaults.weatherType.rawValue
        secondaryWeatherType = try container.decodeIfPresent(UInt32.self, forKey: .secondaryWeatherType) ?? defaults.secondaryWeatherType.rawValue
        weatherBlend = try container.decodeIfPresent(Float.self, forKey: .weatherBlend) ?? defaults.weatherBlend
        weatherAmount = try container.decodeIfPresent(Float.self, forKey: .weatherAmount) ?? defaults.weatherAmount
        atmosphereAmount = try container.decodeIfPresent(Float.self, forKey: .atmosphereAmount) ?? defaults.atmosphereAmount
        cloudCoverage = try container.decodeIfPresent(Float.self, forKey: .cloudCoverage) ?? defaults.cloudCoverage
        cloudStyle = try container.decodeIfPresent(UInt32.self, forKey: .cloudStyle) ?? defaults.cloudStyle.rawValue
        temperature = try container.decodeIfPresent(Float.self, forKey: .temperature) ?? defaults.temperature
        mood = try container.decodeIfPresent(Float.self, forKey: .mood) ?? defaults.mood
        moonIntensity = try container.decodeIfPresent(Float.self, forKey: .moonIntensity) ?? defaults.moonIntensity
        moonSizeDegrees = try container.decodeIfPresent(Float.self, forKey: .moonSizeDegrees) ?? defaults.moonSizeDegrees
        starIntensity = try container.decodeIfPresent(Float.self, forKey: .starIntensity) ?? defaults.starIntensity
        fogAmount = try container.decodeIfPresent(Float.self, forKey: .fogAmount) ?? defaults.fogAmount
        fogHeight = try container.decodeIfPresent(Float.self, forKey: .fogHeight) ?? defaults.fogHeight
        fogDistance = try container.decodeIfPresent(Float.self, forKey: .fogDistance) ?? defaults.fogDistance
        intensity = try container.decodeIfPresent(Float.self, forKey: .intensity) ?? defaults.intensity
        skyTint = try container.decodeIfPresent(Vector3DTO.self, forKey: .skyTint) ?? Vector3DTO(defaults.skyTint)
        turbidity = try container.decodeIfPresent(Float.self, forKey: .turbidity) ?? defaults.turbidity
        azimuthDegrees = try container.decodeIfPresent(Float.self, forKey: .azimuthDegrees) ?? defaults.azimuthDegrees
        elevationDegrees = try container.decodeIfPresent(Float.self, forKey: .elevationDegrees) ?? defaults.elevationDegrees
        sunSizeDegrees = try container.decodeIfPresent(Float.self, forKey: .sunSizeDegrees) ?? defaults.sunSizeDegrees
        zenithTint = try container.decodeIfPresent(Vector3DTO.self, forKey: .zenithTint) ?? Vector3DTO(defaults.zenithTint)
        horizonTint = try container.decodeIfPresent(Vector3DTO.self, forKey: .horizonTint) ?? Vector3DTO(defaults.horizonTint)
        gradientStrength = try container.decodeIfPresent(Float.self, forKey: .gradientStrength) ?? defaults.gradientStrength
        hazeDensity = try container.decodeIfPresent(Float.self, forKey: .hazeDensity) ?? defaults.hazeDensity
        hazeFalloff = try container.decodeIfPresent(Float.self, forKey: .hazeFalloff) ?? defaults.hazeFalloff
        hazeHeight = try container.decodeIfPresent(Float.self, forKey: .hazeHeight) ?? defaults.hazeHeight
        ozoneStrength = try container.decodeIfPresent(Float.self, forKey: .ozoneStrength) ?? defaults.ozoneStrength
        ozoneTint = try container.decodeIfPresent(Vector3DTO.self, forKey: .ozoneTint) ?? Vector3DTO(defaults.ozoneTint)
        sunHaloSize = try container.decodeIfPresent(Float.self, forKey: .sunHaloSize) ?? defaults.sunHaloSize
        sunHaloIntensity = try container.decodeIfPresent(Float.self, forKey: .sunHaloIntensity) ?? defaults.sunHaloIntensity
        sunHaloSoftness = try container.decodeIfPresent(Float.self, forKey: .sunHaloSoftness) ?? defaults.sunHaloSoftness
        cloudsEnabled = try container.decodeIfPresent(Bool.self, forKey: .cloudsEnabled) ?? defaults.cloudsEnabled
        cloudsCoverage = try container.decodeIfPresent(Float.self, forKey: .cloudsCoverage) ?? defaults.cloudsCoverage
        cloudsSoftness = try container.decodeIfPresent(Float.self, forKey: .cloudsSoftness) ?? defaults.cloudsSoftness
        cloudsScale = try container.decodeIfPresent(Float.self, forKey: .cloudsScale) ?? defaults.cloudsScale
        cloudsSpeed = try container.decodeIfPresent(Float.self, forKey: .cloudsSpeed) ?? defaults.cloudsSpeed
        cloudsWindX = try container.decodeIfPresent(Float.self, forKey: .cloudsWindX) ?? defaults.cloudsWindDirection.x
        cloudsWindY = try container.decodeIfPresent(Float.self, forKey: .cloudsWindY) ?? defaults.cloudsWindDirection.y
        cloudsHeight = try container.decodeIfPresent(Float.self, forKey: .cloudsHeight) ?? defaults.cloudsHeight
        cloudsThickness = try container.decodeIfPresent(Float.self, forKey: .cloudsThickness) ?? defaults.cloudsThickness
        cloudsBrightness = try container.decodeIfPresent(Float.self, forKey: .cloudsBrightness) ?? defaults.cloudsBrightness
        cloudsSunInfluence = try container.decodeIfPresent(Float.self, forKey: .cloudsSunInfluence) ?? defaults.cloudsSunInfluence
        hdriHandle = try container.decodeIfPresent(AssetHandle.self, forKey: .hdriHandle)
        realtimeUpdate = try container.decodeIfPresent(Bool.self, forKey: .realtimeUpdate)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(mode, forKey: .mode)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(timeOfDay, forKey: .timeOfDay)
        try container.encode(weatherType, forKey: .weatherType)
        try container.encode(secondaryWeatherType, forKey: .secondaryWeatherType)
        try container.encode(weatherBlend, forKey: .weatherBlend)
        try container.encode(weatherAmount, forKey: .weatherAmount)
        try container.encode(atmosphereAmount, forKey: .atmosphereAmount)
        try container.encode(cloudCoverage, forKey: .cloudCoverage)
        try container.encode(cloudStyle, forKey: .cloudStyle)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(mood, forKey: .mood)
        try container.encode(moonIntensity, forKey: .moonIntensity)
        try container.encode(moonSizeDegrees, forKey: .moonSizeDegrees)
        try container.encode(starIntensity, forKey: .starIntensity)
        try container.encode(fogAmount, forKey: .fogAmount)
        try container.encode(fogHeight, forKey: .fogHeight)
        try container.encode(fogDistance, forKey: .fogDistance)
        try container.encode(intensity, forKey: .intensity)
        try container.encode(skyTint, forKey: .skyTint)
        try container.encode(turbidity, forKey: .turbidity)
        try container.encode(azimuthDegrees, forKey: .azimuthDegrees)
        try container.encode(elevationDegrees, forKey: .elevationDegrees)
        try container.encode(sunSizeDegrees, forKey: .sunSizeDegrees)
        try container.encode(zenithTint, forKey: .zenithTint)
        try container.encode(horizonTint, forKey: .horizonTint)
        try container.encode(gradientStrength, forKey: .gradientStrength)
        try container.encode(hazeDensity, forKey: .hazeDensity)
        try container.encode(hazeFalloff, forKey: .hazeFalloff)
        try container.encode(hazeHeight, forKey: .hazeHeight)
        try container.encode(ozoneStrength, forKey: .ozoneStrength)
        try container.encode(ozoneTint, forKey: .ozoneTint)
        try container.encode(sunHaloSize, forKey: .sunHaloSize)
        try container.encode(sunHaloIntensity, forKey: .sunHaloIntensity)
        try container.encode(sunHaloSoftness, forKey: .sunHaloSoftness)
        try container.encode(cloudsEnabled, forKey: .cloudsEnabled)
        try container.encode(cloudsCoverage, forKey: .cloudsCoverage)
        try container.encode(cloudsSoftness, forKey: .cloudsSoftness)
        try container.encode(cloudsScale, forKey: .cloudsScale)
        try container.encode(cloudsSpeed, forKey: .cloudsSpeed)
        try container.encode(cloudsWindX, forKey: .cloudsWindX)
        try container.encode(cloudsWindY, forKey: .cloudsWindY)
        try container.encode(cloudsHeight, forKey: .cloudsHeight)
        try container.encode(cloudsThickness, forKey: .cloudsThickness)
        try container.encode(cloudsBrightness, forKey: .cloudsBrightness)
        try container.encode(cloudsSunInfluence, forKey: .cloudsSunInfluence)
        try container.encode(hdriHandle, forKey: .hdriHandle)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case mode
        case enabled
        case timeOfDay
        case weatherType
        case secondaryWeatherType
        case weatherBlend
        case weatherAmount
        case atmosphereAmount
        case cloudCoverage
        case cloudStyle
        case temperature
        case mood
        case moonIntensity
        case moonSizeDegrees
        case starIntensity
        case fogAmount
        case fogHeight
        case fogDistance
        case intensity
        case skyTint
        case turbidity
        case azimuthDegrees
        case elevationDegrees
        case sunSizeDegrees
        case zenithTint
        case horizonTint
        case gradientStrength
        case hazeDensity
        case hazeFalloff
        case hazeHeight
        case ozoneStrength
        case ozoneTint
        case sunHaloSize
        case sunHaloIntensity
        case sunHaloSoftness
        case cloudsEnabled
        case cloudsCoverage
        case cloudsSoftness
        case cloudsScale
        case cloudsSpeed
        case cloudsWindX
        case cloudsWindY
        case cloudsHeight
        case cloudsThickness
        case cloudsBrightness
        case cloudsSunInfluence
        case hdriHandle
        case realtimeUpdate
    }
}

public struct EnvironmentStateComponentDTO: Codable {
    public var schemaVersion: Int
    public var currentTimeOfDay: Float
    public var timeControlMode: UInt32
    public var dayLengthSeconds: Float
    public var environmentTimeScale: Float
    public var currentWeatherType: UInt32
    public var targetWeatherType: UInt32
    public var weatherTransitionProgress: Float
    public var weatherTransitionDuration: Float
    public var weatherAmount: Float
    public var cloudPhase: Float
    public var windPhase: Float
    public var scriptedTimeOfDayOverride: Float?
    public var precipitationAmount: Float
    public var stormActivity: Float
    public var lightningActivity: Float
    public var wetnessDriver: Float

    public init(schemaVersion: Int = 1,
                component: EnvironmentStateComponent) {
        self.schemaVersion = schemaVersion
        self.currentTimeOfDay = component.currentTimeOfDay
        self.timeControlMode = component.timeControlMode.rawValue
        self.dayLengthSeconds = component.dayLengthSeconds
        self.environmentTimeScale = component.environmentTimeScale
        self.currentWeatherType = component.currentWeatherType.rawValue
        self.targetWeatherType = component.targetWeatherType.rawValue
        self.weatherTransitionProgress = component.weatherTransitionProgress
        self.weatherTransitionDuration = component.weatherTransitionDuration
        self.weatherAmount = component.weatherAmount
        self.cloudPhase = component.cloudPhase
        self.windPhase = component.windPhase
        self.scriptedTimeOfDayOverride = component.scriptedTimeOfDayOverride
        self.precipitationAmount = component.precipitationAmount
        self.stormActivity = component.stormActivity
        self.lightningActivity = component.lightningActivity
        self.wetnessDriver = component.wetnessDriver
    }

    public func toComponent() -> EnvironmentStateComponent {
        EnvironmentStateComponent(
            currentTimeOfDay: currentTimeOfDay,
            timeControlMode: EnvironmentTimeControlMode(rawValue: timeControlMode) ?? .fixed,
            dayLengthSeconds: dayLengthSeconds,
            environmentTimeScale: environmentTimeScale,
            currentWeatherType: AtmosphereWeatherType(rawValue: currentWeatherType) ?? .clear,
            targetWeatherType: AtmosphereWeatherType(rawValue: targetWeatherType) ?? .clear,
            weatherTransitionProgress: weatherTransitionProgress,
            weatherTransitionDuration: weatherTransitionDuration,
            weatherAmount: weatherAmount,
            cloudPhase: cloudPhase,
            windPhase: windPhase,
            scriptedTimeOfDayOverride: scriptedTimeOfDayOverride,
            precipitationAmount: precipitationAmount,
            stormActivity: stormActivity,
            lightningActivity: lightningActivity,
            wetnessDriver: wetnessDriver
        )
    }
}

public struct SkyIBLStateComponentDTO: Codable {
    public var schemaVersion: Int
    /// Persist only the stable rebuild-policy knob. The texture handles and timing
    /// bookkeeping remain runtime/transient and are reinitialized on load.
    public var realtimeUpdate: Bool

    public init(schemaVersion: Int = 1,
                realtimeUpdate: Bool = true) {
        self.schemaVersion = schemaVersion
        self.realtimeUpdate = realtimeUpdate
    }

    public init(schemaVersion: Int = 1,
                component: SkyIBLStateComponent) {
        self.schemaVersion = schemaVersion
        self.realtimeUpdate = component.realtimeUpdate
    }

    public func toComponent() -> SkyIBLStateComponent {
        SkyIBLStateComponent(realtimeUpdate: realtimeUpdate)
    }
}

public struct EnvironmentComponentDTO: Codable {
    public var schemaVersion: Int
    public var enabled: Bool
    public var look: EnvironmentLookDTO?
    public var source: EnvironmentSourceDTO
    public var celestial: EnvironmentCelestialDTO
    public var atmosphere: EnvironmentAtmosphereDTO
    public var weather: EnvironmentWeatherDTO
    public var clouds: EnvironmentCloudDTO
    public var fog: EnvironmentFogDTO
    public var ibl: EnvironmentIBLDTO

    public init(schemaVersion: Int = 1,
                enabled: Bool,
                look: EnvironmentLookDTO? = nil,
                source: EnvironmentSourceDTO,
                celestial: EnvironmentCelestialDTO,
                atmosphere: EnvironmentAtmosphereDTO,
                weather: EnvironmentWeatherDTO,
                clouds: EnvironmentCloudDTO,
                fog: EnvironmentFogDTO,
                ibl: EnvironmentIBLDTO) {
        self.schemaVersion = schemaVersion
        self.enabled = enabled
        self.look = look
        self.source = source
        self.celestial = celestial
        self.atmosphere = atmosphere
        self.weather = weather
        self.clouds = clouds
        self.fog = fog
        self.ibl = ibl
    }

    public init(component: EnvironmentComponent) {
        self.init(
            enabled: component.enabled,
            look: EnvironmentLookDTO(config: component.look),
            source: EnvironmentSourceDTO(config: component.source),
            celestial: EnvironmentCelestialDTO(config: component.celestial),
            atmosphere: EnvironmentAtmosphereDTO(config: component.atmosphere),
            weather: EnvironmentWeatherDTO(config: component.weather),
            clouds: EnvironmentCloudDTO(config: component.clouds),
            fog: EnvironmentFogDTO(config: component.fog),
            ibl: EnvironmentIBLDTO(config: component.ibl)
        )
    }

    public func toComponent() -> EnvironmentComponent {
        EnvironmentComponent(
            enabled: enabled,
            look: look?.toConfig() ?? EnvironmentLookConfig(),
            source: source.toConfig(),
            celestial: celestial.toConfig(),
            atmosphere: atmosphere.toConfig(),
            weather: weather.toConfig(),
            clouds: clouds.toConfig(),
            fog: fog.toConfig(),
            ibl: ibl.toConfig()
        )
    }
}

public struct EnvironmentLookDTO: Codable {
    public var schemaVersion: Int
    public var preset: UInt32
    public var mood: Float
    public var warmth: Float
    public var cinematicAmount: Float

    public init(schemaVersion: Int = 1,
                preset: UInt32,
                mood: Float,
                warmth: Float,
                cinematicAmount: Float) {
        self.schemaVersion = schemaVersion
        self.preset = preset
        self.mood = mood
        self.warmth = warmth
        self.cinematicAmount = cinematicAmount
    }

    public init(config: EnvironmentLookConfig) {
        self.init(
            preset: config.preset.rawValue,
            mood: config.mood,
            warmth: config.warmth,
            cinematicAmount: config.cinematicAmount
        )
    }

    public func toConfig() -> EnvironmentLookConfig {
        EnvironmentLookConfig(
            preset: EnvironmentLookPreset(rawValue: preset) ?? .custom,
            mood: mood,
            warmth: warmth,
            cinematicAmount: cinematicAmount
        )
    }
}

public struct EnvironmentSourceDTO: Codable {
    public var schemaVersion: Int
    public var mode: UInt32
    public var hdriTextureHandle: AssetHandle?

    public init(schemaVersion: Int = 1,
                mode: UInt32,
                hdriTextureHandle: AssetHandle?) {
        self.schemaVersion = schemaVersion
        self.mode = mode
        self.hdriTextureHandle = hdriTextureHandle
    }

    public init(config: EnvironmentSourceConfig) {
        self.init(mode: config.mode.rawValue, hdriTextureHandle: config.hdriTextureHandle)
    }

    public func toConfig() -> EnvironmentSourceConfig {
        EnvironmentSourceConfig(
            mode: EnvironmentSourceMode(rawValue: mode) ?? .hdri,
            hdriTextureHandle: hdriTextureHandle
        )
    }
}

public struct EnvironmentCelestialDTO: Codable {
    public var schemaVersion: Int
    public var defaultTimeOfDay: Float
    public var moonIntensity: Float
    public var moonSizeDegrees: Float
    public var starIntensity: Float
    public var starRichness: Float
    public var milkyWayIntensity: Float
    public var milkyWayChroma: Float
    public var milkyWayRotation: Float
    public var nightBrightness: Float

    public init(schemaVersion: Int = 2,
                defaultTimeOfDay: Float,
                moonIntensity: Float,
                moonSizeDegrees: Float,
                starIntensity: Float,
                starRichness: Float = 1.0,
                milkyWayIntensity: Float = 1.0,
                milkyWayChroma: Float = 1.0,
                milkyWayRotation: Float = 0.0,
                nightBrightness: Float = 1.0) {
        self.schemaVersion = schemaVersion
        self.defaultTimeOfDay = defaultTimeOfDay
        self.moonIntensity = moonIntensity
        self.moonSizeDegrees = moonSizeDegrees
        self.starIntensity = starIntensity
        self.starRichness = starRichness
        self.milkyWayIntensity = milkyWayIntensity
        self.milkyWayChroma = milkyWayChroma
        self.milkyWayRotation = milkyWayRotation
        self.nightBrightness = nightBrightness
    }

    public init(config: EnvironmentCelestialConfig) {
        self.init(
            defaultTimeOfDay: config.defaultTimeOfDay,
            moonIntensity: config.moonIntensity,
            moonSizeDegrees: config.moonSizeDegrees,
            starIntensity: config.starIntensity,
            starRichness: config.starRichness,
            milkyWayIntensity: config.milkyWayIntensity,
            milkyWayChroma: config.milkyWayChroma,
            milkyWayRotation: config.milkyWayRotation,
            nightBrightness: config.nightBrightness
        )
    }

    public func toConfig() -> EnvironmentCelestialConfig {
        EnvironmentCelestialConfig(
            defaultTimeOfDay: defaultTimeOfDay,
            moonIntensity: moonIntensity,
            moonSizeDegrees: moonSizeDegrees,
            starIntensity: starIntensity,
            starRichness: starRichness,
            milkyWayIntensity: milkyWayIntensity,
            milkyWayChroma: milkyWayChroma,
            milkyWayRotation: milkyWayRotation,
            nightBrightness: nightBrightness
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case defaultTimeOfDay
        case moonIntensity
        case moonSizeDegrees
        case starIntensity
        case starRichness
        case milkyWayIntensity
        case milkyWayChroma
        case milkyWayRotation
        case nightBrightness
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = EnvironmentCelestialConfig()
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        defaultTimeOfDay = try container.decodeIfPresent(Float.self, forKey: .defaultTimeOfDay) ?? defaults.defaultTimeOfDay
        moonIntensity = try container.decodeIfPresent(Float.self, forKey: .moonIntensity) ?? defaults.moonIntensity
        moonSizeDegrees = try container.decodeIfPresent(Float.self, forKey: .moonSizeDegrees) ?? defaults.moonSizeDegrees
        starIntensity = try container.decodeIfPresent(Float.self, forKey: .starIntensity) ?? defaults.starIntensity
        starRichness = try container.decodeIfPresent(Float.self, forKey: .starRichness) ?? defaults.starRichness
        milkyWayIntensity = try container.decodeIfPresent(Float.self, forKey: .milkyWayIntensity) ?? defaults.milkyWayIntensity
        milkyWayChroma = try container.decodeIfPresent(Float.self, forKey: .milkyWayChroma) ?? defaults.milkyWayChroma
        milkyWayRotation = try container.decodeIfPresent(Float.self, forKey: .milkyWayRotation) ?? defaults.milkyWayRotation
        nightBrightness = try container.decodeIfPresent(Float.self, forKey: .nightBrightness) ?? defaults.nightBrightness
    }
}

public struct EnvironmentAtmosphereDTO: Codable {
    public var schemaVersion: Int
    public var amount: Float
    public var haze: Float
    public var density: Float
    public var temperature: Float
    public var mood: Float

    public init(schemaVersion: Int = 1,
                amount: Float,
                haze: Float,
                density: Float,
                temperature: Float,
                mood: Float) {
        self.schemaVersion = schemaVersion
        self.amount = amount
        self.haze = haze
        self.density = density
        self.temperature = temperature
        self.mood = mood
    }

    public init(config: EnvironmentAtmosphereConfig) {
        self.init(
            amount: config.amount,
            haze: config.haze,
            density: config.density,
            temperature: config.temperature,
            mood: config.mood
        )
    }

    public func toConfig() -> EnvironmentAtmosphereConfig {
        EnvironmentAtmosphereConfig(
            amount: amount,
            haze: haze,
            density: density,
            temperature: temperature,
            mood: mood
        )
    }
}

public struct EnvironmentWeatherDTO: Codable {
    public var schemaVersion: Int
    public var primaryType: UInt32
    public var secondaryType: UInt32
    public var blend: Float
    public var amount: Float

    public init(schemaVersion: Int = 1,
                primaryType: UInt32,
                secondaryType: UInt32,
                blend: Float,
                amount: Float) {
        self.schemaVersion = schemaVersion
        self.primaryType = primaryType
        self.secondaryType = secondaryType
        self.blend = blend
        self.amount = amount
    }

    public init(config: EnvironmentWeatherConfig) {
        self.init(
            primaryType: config.primaryType.rawValue,
            secondaryType: config.secondaryType.rawValue,
            blend: config.blend,
            amount: config.amount
        )
    }

    public func toConfig() -> EnvironmentWeatherConfig {
        EnvironmentWeatherConfig(
            primaryType: EnvironmentWeatherType(rawValue: primaryType) ?? .clear,
            secondaryType: EnvironmentWeatherType(rawValue: secondaryType) ?? .clear,
            blend: blend,
            amount: amount
        )
    }
}

public struct EnvironmentCloudDTO: Codable {
    public var schemaVersion: Int
    public var coverage: Float
    public var style: UInt32
    public var renderMode: UInt32

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case coverage
        case style
        case renderMode
    }

    public init(schemaVersion: Int = 1,
                coverage: Float,
                style: UInt32,
                renderMode: UInt32 = EnvironmentCloudRenderMode.both.rawValue) {
        self.schemaVersion = schemaVersion
        self.coverage = coverage
        self.style = style
        self.renderMode = renderMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        coverage = try container.decode(Float.self, forKey: .coverage)
        style = try container.decode(UInt32.self, forKey: .style)
        renderMode = try container.decodeIfPresent(UInt32.self, forKey: .renderMode)
            ?? EnvironmentCloudRenderMode.both.rawValue
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(coverage, forKey: .coverage)
        try container.encode(style, forKey: .style)
        try container.encode(renderMode, forKey: .renderMode)
    }

    public init(config: EnvironmentCloudConfig) {
        self.init(coverage: config.coverage,
                  style: config.style.rawValue,
                  renderMode: config.renderMode.rawValue)
    }

    public func toConfig() -> EnvironmentCloudConfig {
        EnvironmentCloudConfig(
            coverage: coverage,
            style: EnvironmentCloudStyle(rawValue: style) ?? .puffy,
            renderMode: EnvironmentCloudRenderMode(rawValue: renderMode) ?? .both
        )
    }
}

public struct EnvironmentFogDTO: Codable {
    public var schemaVersion: Int
    public var amount: Float
    public var height: Float
    public var distance: Float

    public init(schemaVersion: Int = 1,
                amount: Float,
                height: Float,
                distance: Float) {
        self.schemaVersion = schemaVersion
        self.amount = amount
        self.height = height
        self.distance = distance
    }

    public init(config: EnvironmentFogConfig) {
        self.init(amount: config.amount, height: config.height, distance: config.distance)
    }

    public func toConfig() -> EnvironmentFogConfig {
        EnvironmentFogConfig(amount: amount, height: height, distance: distance)
    }
}

public struct EnvironmentIBLDTO: Codable {
    public var schemaVersion: Int
    public var realtimeUpdate: Bool
    public var autoRebuildOnChange: Bool

    public init(schemaVersion: Int = 1,
                realtimeUpdate: Bool,
                autoRebuildOnChange: Bool) {
        self.schemaVersion = schemaVersion
        self.realtimeUpdate = realtimeUpdate
        self.autoRebuildOnChange = autoRebuildOnChange
    }

    public init(config: EnvironmentIBLConfig) {
        self.init(
            realtimeUpdate: config.realtimeUpdate,
            autoRebuildOnChange: config.autoRebuildOnChange
        )
    }

    public func toConfig() -> EnvironmentIBLConfig {
        EnvironmentIBLConfig(
            realtimeUpdate: realtimeUpdate,
            autoRebuildOnChange: autoRebuildOnChange
        )
    }
}

public struct RendererSettingsDTO: Codable {
    public var schemaVersion: Int
    public var bloomThreshold: Float
    public var bloomKnee: Float
    public var bloomIntensity: Float
    public var bloomEnabled: UInt32
    public var bloomMaxMips: UInt32
    public var bloomQualityPreset: UInt32
    public var bloomResolutionScale: UInt32
    public var tonemap: UInt32
    public var gamma: Float
    public var iblEnabled: UInt32
    public var iblIntensity: Float
    public var perfFlags: UInt32
    public var iblFireflyClamp: Float
    public var iblFireflyClampEnabled: UInt32
    public var iblSampleMultiplier: Float
    public var skyboxMipBias: Float
    public var iblSpecularLodExponent: Float
    public var iblSpecularLodBias: Float
    public var iblSpecularGrazingLodBias: Float
    public var iblSpecularMinRoughness: Float
    public var specularAAStrength: Float
    public var normalMapMipBias: Float
    public var normalMapMipBiasGrazing: Float
    public var shadingDebugMode: UInt32
    public var iblQualityPreset: UInt32
    // AO fields below are the persisted public SAO model.
    public var ssaoEnabled: UInt32
    public var aoMethod: UInt32
    public var aoQuality: UInt32
    public var ssaoRadius: Float
    public var ssaoIntensity: Float
    public var ssaoPower: Float
    public var ssaoBias: Float
    // Deprecated/internal legacy field preserved only for compatibility with older scene files.
    public var ssaoThickness: Float
    public var ssaoBlurSharpness: Float
    public var heightFogEnabled: UInt32
    public var heightFogColorMode: UInt32
    public var heightFogColor: Vector3DTO
    public var heightFogBaseHeight: Float
    public var heightFogDensity: Float
    public var heightFogHeightFalloff: Float
    public var heightFogStartDistance: Float
    public var heightFogDistanceDensity: Float
    public var outlineEnabled: UInt32
    public var outlineThickness: UInt32
    public var outlineOpacity: Float
    public var outlineColor: Vector3DTO
    public var gridEnabled: UInt32
    public var gridOpacity: Float
    public var gridFadeDistance: Float
    public var gridMajorLineEvery: Float
    public var shadows: ShadowsSettingsDTO

    public init(schemaVersion: Int = 4, settings: RendererSettings) {
        self.schemaVersion = schemaVersion
        self.bloomThreshold = settings.bloomThreshold
        self.bloomKnee = settings.bloomKnee
        self.bloomIntensity = settings.bloomIntensity
        self.bloomEnabled = settings.bloomEnabled
        self.bloomMaxMips = settings.bloomMaxMips
        self.bloomQualityPreset = settings.bloomQualityPreset
        self.bloomResolutionScale = settings.bloomResolutionScale
        self.tonemap = TonemapType.filmic.rawValue
        self.gamma = 2.2
        self.iblEnabled = settings.iblEnabled
        self.iblIntensity = 1.0
        self.perfFlags = settings.perfFlags
        self.iblFireflyClamp = settings.iblFireflyClamp
        self.iblFireflyClampEnabled = settings.iblFireflyClampEnabled
        self.iblSampleMultiplier = settings.iblSampleMultiplier
        self.skyboxMipBias = settings.skyboxMipBias
        self.iblSpecularLodExponent = settings.iblSpecularLodExponent
        self.iblSpecularLodBias = settings.iblSpecularLodBias
        self.iblSpecularGrazingLodBias = settings.iblSpecularGrazingLodBias
        self.iblSpecularMinRoughness = settings.iblSpecularMinRoughness
        self.specularAAStrength = settings.specularAAStrength
        self.normalMapMipBias = settings.normalMapMipBias
        self.normalMapMipBiasGrazing = settings.normalMapMipBiasGrazing
        self.shadingDebugMode = settings.shadingDebugMode
        self.iblQualityPreset = settings.iblQualityPreset
        self.ssaoEnabled = settings.ssaoEnabled
        self.aoMethod = settings.aoMethod.rawValue
        self.aoQuality = settings.aoQuality.rawValue
        self.ssaoRadius = settings.ssaoRadius
        self.ssaoIntensity = settings.ssaoIntensity
        self.ssaoPower = settings.ssaoPower
        self.ssaoBias = settings.ssaoBias
        self.ssaoThickness = settings.ssaoThickness
        self.ssaoBlurSharpness = settings.ssaoBlurSharpness
        self.heightFogEnabled = settings.heightFogEnabled
        self.heightFogColorMode = settings.heightFogColorMode.rawValue
        self.heightFogColor = Vector3DTO(settings.heightFogColor)
        self.heightFogBaseHeight = settings.heightFogBaseHeight
        self.heightFogDensity = settings.heightFogDensity
        self.heightFogHeightFalloff = settings.heightFogHeightFalloff
        self.heightFogStartDistance = settings.heightFogStartDistance
        self.heightFogDistanceDensity = settings.heightFogDistanceDensity
        self.outlineEnabled = settings.outlineEnabled
        self.outlineThickness = settings.outlineThickness
        self.outlineOpacity = settings.outlineOpacity
        self.outlineColor = Vector3DTO(settings.outlineColor)
        self.gridEnabled = settings.gridEnabled
        self.gridOpacity = settings.gridOpacity
        self.gridFadeDistance = settings.gridFadeDistance
        self.gridMajorLineEvery = settings.gridMajorLineEvery
        self.shadows = ShadowsSettingsDTO(settings: settings.shadows)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RendererSettings()
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        bloomThreshold = try container.decodeIfPresent(Float.self, forKey: .bloomThreshold) ?? defaults.bloomThreshold
        bloomKnee = try container.decodeIfPresent(Float.self, forKey: .bloomKnee) ?? defaults.bloomKnee
        bloomIntensity = try container.decodeIfPresent(Float.self, forKey: .bloomIntensity) ?? defaults.bloomIntensity
        bloomEnabled = try container.decodeIfPresent(UInt32.self, forKey: .bloomEnabled) ?? defaults.bloomEnabled
        bloomMaxMips = try container.decodeIfPresent(UInt32.self, forKey: .bloomMaxMips) ?? defaults.bloomMaxMips
        bloomQualityPreset = try container.decodeIfPresent(UInt32.self, forKey: .bloomQualityPreset) ?? defaults.bloomQualityPreset
        bloomResolutionScale = try container.decodeIfPresent(UInt32.self, forKey: .bloomResolutionScale) ?? defaults.bloomResolutionScale
        tonemap = try container.decodeIfPresent(UInt32.self, forKey: .tonemap) ?? defaults.tonemap
        gamma = try container.decodeIfPresent(Float.self, forKey: .gamma) ?? defaults.gamma
        iblEnabled = try container.decodeIfPresent(UInt32.self, forKey: .iblEnabled) ?? defaults.iblEnabled
        iblIntensity = try container.decodeIfPresent(Float.self, forKey: .iblIntensity) ?? defaults.iblIntensity
        perfFlags = try container.decodeIfPresent(UInt32.self, forKey: .perfFlags) ?? defaults.perfFlags
        iblFireflyClamp = try container.decodeIfPresent(Float.self, forKey: .iblFireflyClamp) ?? defaults.iblFireflyClamp
        iblFireflyClampEnabled = try container.decodeIfPresent(UInt32.self, forKey: .iblFireflyClampEnabled) ?? defaults.iblFireflyClampEnabled
        iblSampleMultiplier = try container.decodeIfPresent(Float.self, forKey: .iblSampleMultiplier) ?? defaults.iblSampleMultiplier
        skyboxMipBias = try container.decodeIfPresent(Float.self, forKey: .skyboxMipBias) ?? defaults.skyboxMipBias
        iblSpecularLodExponent = try container.decodeIfPresent(Float.self, forKey: .iblSpecularLodExponent) ?? defaults.iblSpecularLodExponent
        iblSpecularLodBias = try container.decodeIfPresent(Float.self, forKey: .iblSpecularLodBias) ?? defaults.iblSpecularLodBias
        iblSpecularGrazingLodBias = try container.decodeIfPresent(Float.self, forKey: .iblSpecularGrazingLodBias) ?? defaults.iblSpecularGrazingLodBias
        iblSpecularMinRoughness = try container.decodeIfPresent(Float.self, forKey: .iblSpecularMinRoughness) ?? defaults.iblSpecularMinRoughness
        specularAAStrength = try container.decodeIfPresent(Float.self, forKey: .specularAAStrength) ?? defaults.specularAAStrength
        normalMapMipBias = try container.decodeIfPresent(Float.self, forKey: .normalMapMipBias) ?? defaults.normalMapMipBias
        normalMapMipBiasGrazing = try container.decodeIfPresent(Float.self, forKey: .normalMapMipBiasGrazing) ?? defaults.normalMapMipBiasGrazing
        shadingDebugMode = try container.decodeIfPresent(UInt32.self, forKey: .shadingDebugMode) ?? defaults.shadingDebugMode
        iblQualityPreset = try container.decodeIfPresent(UInt32.self, forKey: .iblQualityPreset) ?? defaults.iblQualityPreset
        ssaoEnabled = try container.decodeIfPresent(UInt32.self, forKey: .ssaoEnabled) ?? defaults.ssaoEnabled
        aoMethod = try container.decodeIfPresent(UInt32.self, forKey: .aoMethod) ?? defaults.aoMethod.rawValue
        aoQuality = try container.decodeIfPresent(UInt32.self, forKey: .aoQuality) ?? defaults.aoQuality.rawValue
        ssaoRadius = try container.decodeIfPresent(Float.self, forKey: .ssaoRadius) ?? defaults.ssaoRadius
        ssaoIntensity = try container.decodeIfPresent(Float.self, forKey: .ssaoIntensity) ?? defaults.ssaoIntensity
        ssaoPower = try container.decodeIfPresent(Float.self, forKey: .ssaoPower) ?? defaults.ssaoPower
        ssaoBias = try container.decodeIfPresent(Float.self, forKey: .ssaoBias) ?? defaults.ssaoBias
        ssaoThickness = try container.decodeIfPresent(Float.self, forKey: .ssaoThickness) ?? defaults.ssaoThickness
        ssaoBlurSharpness = try container.decodeIfPresent(Float.self, forKey: .ssaoBlurSharpness) ?? defaults.ssaoBlurSharpness
        heightFogEnabled = try container.decodeIfPresent(UInt32.self, forKey: .heightFogEnabled) ?? defaults.heightFogEnabled
        heightFogColorMode = try container.decodeIfPresent(UInt32.self, forKey: .heightFogColorMode) ?? defaults.heightFogColorMode.rawValue
        heightFogColor = try container.decodeIfPresent(Vector3DTO.self, forKey: .heightFogColor) ?? Vector3DTO(defaults.heightFogColor)
        heightFogBaseHeight = try container.decodeIfPresent(Float.self, forKey: .heightFogBaseHeight) ?? defaults.heightFogBaseHeight
        heightFogDensity = try container.decodeIfPresent(Float.self, forKey: .heightFogDensity) ?? defaults.heightFogDensity
        heightFogHeightFalloff = try container.decodeIfPresent(Float.self, forKey: .heightFogHeightFalloff) ?? defaults.heightFogHeightFalloff
        heightFogStartDistance = try container.decodeIfPresent(Float.self, forKey: .heightFogStartDistance) ?? defaults.heightFogStartDistance
        heightFogDistanceDensity = try container.decodeIfPresent(Float.self, forKey: .heightFogDistanceDensity) ?? defaults.heightFogDistanceDensity
        outlineEnabled = try container.decodeIfPresent(UInt32.self, forKey: .outlineEnabled) ?? defaults.outlineEnabled
        outlineThickness = try container.decodeIfPresent(UInt32.self, forKey: .outlineThickness) ?? defaults.outlineThickness
        outlineOpacity = try container.decodeIfPresent(Float.self, forKey: .outlineOpacity) ?? defaults.outlineOpacity
        outlineColor = try container.decodeIfPresent(Vector3DTO.self, forKey: .outlineColor) ?? Vector3DTO(defaults.outlineColor)
        gridEnabled = try container.decodeIfPresent(UInt32.self, forKey: .gridEnabled) ?? defaults.gridEnabled
        gridOpacity = try container.decodeIfPresent(Float.self, forKey: .gridOpacity) ?? defaults.gridOpacity
        gridFadeDistance = try container.decodeIfPresent(Float.self, forKey: .gridFadeDistance) ?? defaults.gridFadeDistance
        gridMajorLineEvery = try container.decodeIfPresent(Float.self, forKey: .gridMajorLineEvery) ?? defaults.gridMajorLineEvery
        shadows = try container.decodeIfPresent(ShadowsSettingsDTO.self, forKey: .shadows) ?? ShadowsSettingsDTO(settings: defaults.shadows)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(bloomThreshold, forKey: .bloomThreshold)
        try container.encode(bloomKnee, forKey: .bloomKnee)
        try container.encode(bloomIntensity, forKey: .bloomIntensity)
        try container.encode(bloomEnabled, forKey: .bloomEnabled)
        try container.encode(bloomMaxMips, forKey: .bloomMaxMips)
        try container.encode(bloomQualityPreset, forKey: .bloomQualityPreset)
        try container.encode(bloomResolutionScale, forKey: .bloomResolutionScale)
        try container.encode(tonemap, forKey: .tonemap)
        try container.encode(gamma, forKey: .gamma)
        try container.encode(iblEnabled, forKey: .iblEnabled)
        try container.encode(iblIntensity, forKey: .iblIntensity)
        try container.encode(perfFlags, forKey: .perfFlags)
        try container.encode(iblFireflyClamp, forKey: .iblFireflyClamp)
        try container.encode(iblFireflyClampEnabled, forKey: .iblFireflyClampEnabled)
        try container.encode(iblSampleMultiplier, forKey: .iblSampleMultiplier)
        try container.encode(skyboxMipBias, forKey: .skyboxMipBias)
        try container.encode(iblSpecularLodExponent, forKey: .iblSpecularLodExponent)
        try container.encode(iblSpecularLodBias, forKey: .iblSpecularLodBias)
        try container.encode(iblSpecularGrazingLodBias, forKey: .iblSpecularGrazingLodBias)
        try container.encode(iblSpecularMinRoughness, forKey: .iblSpecularMinRoughness)
        try container.encode(specularAAStrength, forKey: .specularAAStrength)
        try container.encode(normalMapMipBias, forKey: .normalMapMipBias)
        try container.encode(normalMapMipBiasGrazing, forKey: .normalMapMipBiasGrazing)
        try container.encode(shadingDebugMode, forKey: .shadingDebugMode)
        try container.encode(iblQualityPreset, forKey: .iblQualityPreset)
        try container.encode(ssaoEnabled, forKey: .ssaoEnabled)
        try container.encode(aoMethod, forKey: .aoMethod)
        try container.encode(aoQuality, forKey: .aoQuality)
        try container.encode(ssaoRadius, forKey: .ssaoRadius)
        try container.encode(ssaoIntensity, forKey: .ssaoIntensity)
        try container.encode(ssaoPower, forKey: .ssaoPower)
        try container.encode(ssaoBias, forKey: .ssaoBias)
        try container.encode(ssaoThickness, forKey: .ssaoThickness)
        try container.encode(ssaoBlurSharpness, forKey: .ssaoBlurSharpness)
        try container.encode(heightFogEnabled, forKey: .heightFogEnabled)
        try container.encode(heightFogColorMode, forKey: .heightFogColorMode)
        try container.encode(heightFogColor, forKey: .heightFogColor)
        try container.encode(heightFogBaseHeight, forKey: .heightFogBaseHeight)
        try container.encode(heightFogDensity, forKey: .heightFogDensity)
        try container.encode(heightFogHeightFalloff, forKey: .heightFogHeightFalloff)
        try container.encode(heightFogStartDistance, forKey: .heightFogStartDistance)
        try container.encode(heightFogDistanceDensity, forKey: .heightFogDistanceDensity)
        try container.encode(outlineEnabled, forKey: .outlineEnabled)
        try container.encode(outlineThickness, forKey: .outlineThickness)
        try container.encode(outlineOpacity, forKey: .outlineOpacity)
        try container.encode(outlineColor, forKey: .outlineColor)
        try container.encode(gridEnabled, forKey: .gridEnabled)
        try container.encode(gridOpacity, forKey: .gridOpacity)
        try container.encode(gridFadeDistance, forKey: .gridFadeDistance)
        try container.encode(gridMajorLineEvery, forKey: .gridMajorLineEvery)
        try container.encode(shadows, forKey: .shadows)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case bloomThreshold
        case bloomKnee
        case bloomIntensity
        case bloomEnabled
        case bloomMaxMips
        case bloomQualityPreset
        case bloomResolutionScale
        case tonemap
        case gamma
        case iblEnabled
        case iblIntensity
        case perfFlags
        case iblFireflyClamp
        case iblFireflyClampEnabled
        case iblSampleMultiplier
        case skyboxMipBias
        case iblSpecularLodExponent
        case iblSpecularLodBias
        case iblSpecularGrazingLodBias
        case iblSpecularMinRoughness
        case specularAAStrength
        case normalMapMipBias
        case normalMapMipBiasGrazing
        case shadingDebugMode
        case iblQualityPreset
        case ssaoEnabled
        case aoMethod
        case aoQuality
        case ssaoRadius
        case ssaoIntensity
        case ssaoPower
        case ssaoBias
        case ssaoThickness
        case ssaoBlurSharpness
        case heightFogEnabled
        case heightFogColorMode
        case heightFogColor
        case heightFogBaseHeight
        case heightFogDensity
        case heightFogHeightFalloff
        case heightFogStartDistance
        case heightFogDistanceDensity
        case outlineEnabled
        case outlineThickness
        case outlineOpacity
        case outlineColor
        case gridEnabled
        case gridOpacity
        case gridFadeDistance
        case gridMajorLineEvery
        case shadows
    }

    public func makeRendererSettings() -> RendererSettings {
        var settings = RendererSettings()
        settings.bloomThreshold = bloomThreshold
        settings.bloomKnee = bloomKnee
        settings.bloomIntensity = bloomIntensity
        settings.bloomEnabled = bloomEnabled
        settings.bloomMaxMips = bloomMaxMips
        settings.bloomQualityPreset = bloomQualityPreset
        settings.bloomResolutionScale = bloomResolutionScale
        // Legacy values remain decodable, but normal Phase 1 output has one fixed
        // transform and one sRGB encode.
        settings.tonemap = TonemapType.filmic.rawValue
        settings.gamma = 2.2
        settings.iblEnabled = iblEnabled
        // Legacy scene overrides such as 0.05 are reserved and ignored.
        settings.iblIntensity = 1.0
        settings.perfFlags = perfFlags
        settings.iblFireflyClamp = iblFireflyClamp
        settings.iblFireflyClampEnabled = iblFireflyClampEnabled
        settings.iblSampleMultiplier = iblSampleMultiplier
        settings.skyboxMipBias = skyboxMipBias
        settings.iblSpecularLodExponent = iblSpecularLodExponent
        settings.iblSpecularLodBias = iblSpecularLodBias
        settings.iblSpecularGrazingLodBias = iblSpecularGrazingLodBias
        settings.iblSpecularMinRoughness = iblSpecularMinRoughness
        settings.specularAAStrength = specularAAStrength
        settings.normalMapMipBias = normalMapMipBias
        settings.normalMapMipBiasGrazing = normalMapMipBiasGrazing
        settings.shadingDebugMode = shadingDebugMode
        settings.iblQualityPreset = iblQualityPreset
        settings.setAOEnabled(ssaoEnabled != 0)
        settings.aoMethod = AOMethod(rawValue: aoMethod) ?? .sao
        settings.applyAOQuality(AOQualityPreset(rawValue: aoQuality) ?? .high)
        settings.setAORadius(ssaoRadius)
        settings.setAOIntensity(ssaoIntensity)
        settings.setAOPower(ssaoPower)
        settings.setAOBias(ssaoBias)
        settings.ssaoThickness = ssaoThickness
        settings.setAOSharpness(ssaoBlurSharpness)
        settings.setHeightFogEnabled(heightFogEnabled != 0)
        settings.setHeightFogColorMode(FogColorMode(rawValue: heightFogColorMode) ?? .manual)
        settings.heightFogColor = heightFogColor.toSIMD()
        settings.heightFogBaseHeight = heightFogBaseHeight
        settings.heightFogDensity = max(0.0, heightFogDensity)
        settings.heightFogHeightFalloff = max(0.0, heightFogHeightFalloff)
        settings.heightFogStartDistance = max(0.0, heightFogStartDistance)
        settings.heightFogDistanceDensity = max(0.0, heightFogDistanceDensity)
        settings.outlineEnabled = outlineEnabled
        settings.outlineThickness = outlineThickness
        settings.outlineOpacity = outlineOpacity
        settings.outlineColor = outlineColor.toSIMD()
        settings.gridEnabled = gridEnabled
        settings.gridOpacity = gridOpacity
        settings.gridFadeDistance = gridFadeDistance
        settings.gridMajorLineEvery = gridMajorLineEvery
        settings.shadows = shadows.toShadowsSettings()
        return settings
    }
}

public struct PhysicsSettingsDTO: Codable {
    public var schemaVersion: Int
    public var isEnabled: Bool
    public var gravity: Vector3DTO
    public var solverIterations: UInt32
    public var qualityPreset: UInt32
    public var fixedDeltaTime: Float
    public var maxSubsteps: Int32
    public var defaultFriction: Float
    public var defaultRestitution: Float
    public var defaultLinearDamping: Float
    public var defaultAngularDamping: Float
    public var ccdEnabled: Bool
    public var resolveInitialOverlap: Bool
    public var deterministic: Bool = false
    public var debugDrawEnabled: Bool
    public var debugDrawInPlay: Bool
    public var showColliders: Bool
    public var showCOMAxes: Bool
    public var showContacts: Bool
    public var showSleeping: Bool = false
    public var showOverlaps: Bool = false
    public var collisionLayerNames: [String] = PhysicsSettings.defaultCollisionLayerNames()
    public var collisionMatrix: [UInt32] = PhysicsSettings.defaultCollisionMatrix()
    public var maxBodies: UInt32 = 8_192
    public var maxBodyPairs: UInt32 = 16_384
    public var maxContactConstraints: UInt32 = 8_192

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case isEnabled
        case gravity
        case solverIterations
        case qualityPreset
        case fixedDeltaTime
        case maxSubsteps
        case defaultFriction
        case defaultRestitution
        case defaultLinearDamping
        case defaultAngularDamping
        case ccdEnabled
        case resolveInitialOverlap
        case deterministic
        case debugDrawEnabled
        case debugDrawInPlay
        case showColliders
        case showCOMAxes
        case showContacts
        case showSleeping
        case showOverlaps
        case collisionLayerNames
        case collisionMatrix
        case maxBodies
        case maxBodyPairs
        case maxContactConstraints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        gravity = try container.decode(Vector3DTO.self, forKey: .gravity)
        solverIterations = try container.decode(UInt32.self, forKey: .solverIterations)
        qualityPreset = try container.decode(UInt32.self, forKey: .qualityPreset)
        fixedDeltaTime = try container.decode(Float.self, forKey: .fixedDeltaTime)
        maxSubsteps = try container.decode(Int32.self, forKey: .maxSubsteps)
        defaultFriction = try container.decode(Float.self, forKey: .defaultFriction)
        defaultRestitution = try container.decode(Float.self, forKey: .defaultRestitution)
        defaultLinearDamping = try container.decodeIfPresent(Float.self, forKey: .defaultLinearDamping) ?? 0.02
        defaultAngularDamping = try container.decode(Float.self, forKey: .defaultAngularDamping)
        ccdEnabled = try container.decode(Bool.self, forKey: .ccdEnabled)
        resolveInitialOverlap = try container.decode(Bool.self, forKey: .resolveInitialOverlap)
        deterministic = try container.decodeIfPresent(Bool.self, forKey: .deterministic) ?? false
        debugDrawEnabled = try container.decode(Bool.self, forKey: .debugDrawEnabled)
        debugDrawInPlay = try container.decode(Bool.self, forKey: .debugDrawInPlay)
        showColliders = try container.decode(Bool.self, forKey: .showColliders)
        showCOMAxes = try container.decode(Bool.self, forKey: .showCOMAxes)
        showContacts = try container.decode(Bool.self, forKey: .showContacts)
        showSleeping = try container.decodeIfPresent(Bool.self, forKey: .showSleeping) ?? false
        showOverlaps = try container.decodeIfPresent(Bool.self, forKey: .showOverlaps) ?? false
        collisionLayerNames = try container.decodeIfPresent([String].self, forKey: .collisionLayerNames) ?? PhysicsSettings.defaultCollisionLayerNames()
        collisionMatrix = try container.decodeIfPresent([UInt32].self, forKey: .collisionMatrix) ?? PhysicsSettings.defaultCollisionMatrix()
        maxBodies = try container.decodeIfPresent(UInt32.self, forKey: .maxBodies) ?? 8_192
        maxBodyPairs = try container.decodeIfPresent(UInt32.self, forKey: .maxBodyPairs) ?? 16_384
        maxContactConstraints = try container.decodeIfPresent(UInt32.self, forKey: .maxContactConstraints) ?? 8_192
    }

    public init(schemaVersion: Int = 1, settings: PhysicsSettings) {
        self.schemaVersion = schemaVersion
        self.isEnabled = settings.isEnabled
        self.gravity = Vector3DTO(settings.gravity)
        self.solverIterations = settings.solverIterations
        self.qualityPreset = settings.qualityPreset.rawValue
        self.fixedDeltaTime = settings.fixedDeltaTime
        self.maxSubsteps = Int32(settings.maxSubsteps)
        self.defaultFriction = settings.defaultFriction
        self.defaultRestitution = settings.defaultRestitution
        self.defaultLinearDamping = settings.defaultLinearDamping
        self.defaultAngularDamping = settings.defaultAngularDamping
        self.ccdEnabled = settings.ccdEnabled
        self.resolveInitialOverlap = settings.resolveInitialOverlap
        self.deterministic = settings.deterministic
        self.debugDrawEnabled = settings.debugDrawEnabled
        self.debugDrawInPlay = settings.debugDrawInPlay
        self.showColliders = settings.showColliders
        self.showCOMAxes = settings.showCOMAxes
        self.showContacts = settings.showContacts
        self.showSleeping = settings.showSleeping
        self.showOverlaps = settings.showOverlaps
        self.collisionLayerNames = settings.collisionLayerNames
        self.collisionMatrix = settings.collisionMatrix
        self.maxBodies = settings.maxBodies
        self.maxBodyPairs = settings.maxBodyPairs
        self.maxContactConstraints = settings.maxContactConstraints
    }

    public func makePhysicsSettings() -> PhysicsSettings {
        let preset = PhysicsSettings.QualityPreset(rawValue: qualityPreset) ?? .medium
        return PhysicsSettings(
            isEnabled: isEnabled,
            gravity: gravity.toSIMD(),
            solverIterations: solverIterations,
            qualityPreset: preset,
            fixedDeltaTime: fixedDeltaTime,
            maxSubsteps: Int(maxSubsteps),
            defaultFriction: defaultFriction,
            defaultRestitution: defaultRestitution,
            defaultLinearDamping: defaultLinearDamping,
            defaultAngularDamping: defaultAngularDamping,
            ccdEnabled: ccdEnabled,
            resolveInitialOverlap: resolveInitialOverlap,
            deterministic: deterministic,
            debugDrawEnabled: debugDrawEnabled,
            debugDrawInPlay: debugDrawInPlay,
            showColliders: showColliders,
            showCOMAxes: showCOMAxes,
            showContacts: showContacts,
            showSleeping: showSleeping,
            showOverlaps: showOverlaps,
            collisionLayerNames: collisionLayerNames,
            collisionMatrix: collisionMatrix,
            maxBodies: maxBodies,
            maxBodyPairs: maxBodyPairs,
            maxContactConstraints: maxContactConstraints
        )
    }
}

public struct ShadowsSettingsDTO: Codable {
    public var enabled: UInt32
    public var directionalEnabled: UInt32
    public var shadowMapResolution: UInt32
    public var cascadeCount: UInt32
    public var cascadeSplitLambda: Float
    public var depthBias: Float
    public var normalBias: Float
    public var pcfRadius: Float
    public var pcfTapPreset: UInt32
    public var pcfTapsCascade0: UInt32
    public var pcfTapsCascade1: UInt32
    public var pcfTapsCascade2: UInt32
    public var pcfTapsCascade3: UInt32
    public var filterMode: UInt32
    public var maxShadowDistance: Float
    public var fadeOutDistance: Float
    public var pcssLightWorldSize: Float
    public var pcssMinFilterRadiusTexels: Float
    public var pcssMaxFilterRadiusTexels: Float
    public var pcssBlockerSearchRadiusTexels: Float
    public var pcssBlockerSamples: UInt32
    public var pcssPCFSamples: UInt32
    public var pcssNoiseEnabled: UInt32

    public init(settings: ShadowsSettings) {
        enabled = settings.enabled
        directionalEnabled = settings.directionalEnabled
        shadowMapResolution = settings.shadowMapResolution
        cascadeCount = settings.cascadeCount
        cascadeSplitLambda = settings.cascadeSplitLambda
        depthBias = settings.depthBias
        normalBias = settings.normalBias
        pcfRadius = settings.pcfRadius
        pcfTapPreset = settings.pcfTapPreset
        pcfTapsCascade0 = settings.pcfTapsCascade0
        pcfTapsCascade1 = settings.pcfTapsCascade1
        pcfTapsCascade2 = settings.pcfTapsCascade2
        pcfTapsCascade3 = settings.pcfTapsCascade3
        filterMode = settings.filterMode
        maxShadowDistance = settings.maxShadowDistance
        fadeOutDistance = settings.fadeOutDistance
        pcssLightWorldSize = settings.pcssLightWorldSize
        pcssMinFilterRadiusTexels = settings.pcssMinFilterRadiusTexels
        pcssMaxFilterRadiusTexels = settings.pcssMaxFilterRadiusTexels
        pcssBlockerSearchRadiusTexels = settings.pcssBlockerSearchRadiusTexels
        pcssBlockerSamples = settings.pcssBlockerSamples
        pcssPCFSamples = settings.pcssPCFSamples
        pcssNoiseEnabled = settings.pcssNoiseEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ShadowsSettings()
        enabled = try container.decodeIfPresent(UInt32.self, forKey: .enabled) ?? defaults.enabled
        directionalEnabled = try container.decodeIfPresent(UInt32.self, forKey: .directionalEnabled) ?? defaults.directionalEnabled
        shadowMapResolution = try container.decodeIfPresent(UInt32.self, forKey: .shadowMapResolution) ?? defaults.shadowMapResolution
        cascadeCount = try container.decodeIfPresent(UInt32.self, forKey: .cascadeCount) ?? defaults.cascadeCount
        cascadeSplitLambda = try container.decodeIfPresent(Float.self, forKey: .cascadeSplitLambda) ?? defaults.cascadeSplitLambda
        depthBias = try container.decodeIfPresent(Float.self, forKey: .depthBias) ?? defaults.depthBias
        normalBias = try container.decodeIfPresent(Float.self, forKey: .normalBias) ?? defaults.normalBias
        pcfRadius = try container.decodeIfPresent(Float.self, forKey: .pcfRadius) ?? defaults.pcfRadius
        pcfTapPreset = try container.decodeIfPresent(UInt32.self, forKey: .pcfTapPreset) ?? defaults.pcfTapPreset
        pcfTapsCascade0 = try container.decodeIfPresent(UInt32.self, forKey: .pcfTapsCascade0) ?? defaults.pcfTapsCascade0
        pcfTapsCascade1 = try container.decodeIfPresent(UInt32.self, forKey: .pcfTapsCascade1) ?? defaults.pcfTapsCascade1
        pcfTapsCascade2 = try container.decodeIfPresent(UInt32.self, forKey: .pcfTapsCascade2) ?? defaults.pcfTapsCascade2
        pcfTapsCascade3 = try container.decodeIfPresent(UInt32.self, forKey: .pcfTapsCascade3) ?? defaults.pcfTapsCascade3
        filterMode = try container.decodeIfPresent(UInt32.self, forKey: .filterMode) ?? defaults.filterMode
        maxShadowDistance = try container.decodeIfPresent(Float.self, forKey: .maxShadowDistance) ?? defaults.maxShadowDistance
        fadeOutDistance = try container.decodeIfPresent(Float.self, forKey: .fadeOutDistance) ?? defaults.fadeOutDistance
        pcssLightWorldSize = try container.decodeIfPresent(Float.self, forKey: .pcssLightWorldSize) ?? defaults.pcssLightWorldSize
        pcssMinFilterRadiusTexels = try container.decodeIfPresent(Float.self, forKey: .pcssMinFilterRadiusTexels) ?? defaults.pcssMinFilterRadiusTexels
        pcssMaxFilterRadiusTexels = try container.decodeIfPresent(Float.self, forKey: .pcssMaxFilterRadiusTexels) ?? defaults.pcssMaxFilterRadiusTexels
        pcssBlockerSearchRadiusTexels = try container.decodeIfPresent(Float.self, forKey: .pcssBlockerSearchRadiusTexels) ?? defaults.pcssBlockerSearchRadiusTexels
        pcssBlockerSamples = try container.decodeIfPresent(UInt32.self, forKey: .pcssBlockerSamples) ?? defaults.pcssBlockerSamples
        pcssPCFSamples = try container.decodeIfPresent(UInt32.self, forKey: .pcssPCFSamples) ?? defaults.pcssPCFSamples
        pcssNoiseEnabled = try container.decodeIfPresent(UInt32.self, forKey: .pcssNoiseEnabled) ?? defaults.pcssNoiseEnabled
    }

    public func toShadowsSettings() -> ShadowsSettings {
        var settings = ShadowsSettings()
        settings.enabled = enabled
        settings.directionalEnabled = directionalEnabled
        settings.shadowMapResolution = shadowMapResolution
        settings.cascadeCount = cascadeCount
        settings.cascadeSplitLambda = cascadeSplitLambda
        settings.depthBias = depthBias
        settings.normalBias = normalBias
        settings.pcfRadius = pcfRadius
        settings.pcfTapPreset = pcfTapPreset
        settings.pcfTapsCascade0 = max(1, min(25, pcfTapsCascade0))
        settings.pcfTapsCascade1 = max(1, min(25, pcfTapsCascade1))
        settings.pcfTapsCascade2 = max(1, min(25, pcfTapsCascade2))
        settings.pcfTapsCascade3 = max(1, min(25, pcfTapsCascade3))
        settings.filterMode = filterMode
        settings.maxShadowDistance = maxShadowDistance
        settings.fadeOutDistance = fadeOutDistance
        settings.pcssLightWorldSize = pcssLightWorldSize
        settings.pcssMinFilterRadiusTexels = pcssMinFilterRadiusTexels
        settings.pcssMaxFilterRadiusTexels = pcssMaxFilterRadiusTexels
        settings.pcssBlockerSearchRadiusTexels = pcssBlockerSearchRadiusTexels
        settings.pcssBlockerSamples = pcssBlockerSamples
        settings.pcssPCFSamples = pcssPCFSamples
        settings.pcssNoiseEnabled = pcssNoiseEnabled
        settings.refreshPCFPreset()
        return settings
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case directionalEnabled
        case shadowMapResolution
        case cascadeCount
        case cascadeSplitLambda
        case depthBias
        case normalBias
        case pcfRadius
        case pcfTapPreset
        case pcfTapsCascade0
        case pcfTapsCascade1
        case pcfTapsCascade2
        case pcfTapsCascade3
        case filterMode
        case maxShadowDistance
        case fadeOutDistance
        case pcssLightWorldSize
        case pcssMinFilterRadiusTexels
        case pcssMaxFilterRadiusTexels
        case pcssBlockerSearchRadiusTexels
        case pcssBlockerSamples
        case pcssPCFSamples
        case pcssNoiseEnabled
    }
}

public struct Vector3DTO: Codable {
    public var x: Float
    public var y: Float
    public var z: Float

    public init(_ value: SIMD3<Float>) {
        self.x = value.x
        self.y = value.y
        self.z = value.z
    }

    public func toSIMD() -> SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }
}

public struct Vector4DTO: Codable {
    public var x: Float
    public var y: Float
    public var z: Float
    public var w: Float

    public init(_ value: SIMD4<Float>) {
        self.x = value.x
        self.y = value.y
        self.z = value.z
        self.w = value.w
    }

    public func toSIMD() -> SIMD4<Float> {
        SIMD4<Float>(x, y, z, w)
    }
}

public struct Vector2DTO: Codable {
    public var x: Float
    public var y: Float

    public init(_ value: SIMD2<Float>) {
        self.x = value.x
        self.y = value.y
    }

    public func toSIMD() -> SIMD2<Float> {
        SIMD2<Float>(x, y)
    }
}

public enum LightTypeDTO: String, Codable {
    case point
    case spot
    case directional

    public init(from type: LightType) {
        switch type {
        case .point:
            self = .point
        case .spot:
            self = .spot
        case .directional:
            self = .directional
        }
    }

    public func toLightType() -> LightType {
        switch self {
        case .point:
            return .point
        case .spot:
            return .spot
        case .directional:
            return .directional
        }
    }
}

public struct LightDataDTO: Codable {
    public var position: Vector3DTO
    public var type: UInt32
    public var direction: Vector3DTO
    public var range: Float
    public var color: Vector3DTO
    public var brightness: Float
    public var ambientIntensity: Float
    public var diffuseIntensity: Float
    public var specularIntensity: Float
    public var innerConeCos: Float
    public var outerConeCos: Float

    public init(from data: LightData) {
        self.position = Vector3DTO(data.position)
        self.type = data.type
        self.direction = Vector3DTO(data.direction)
        self.range = data.range
        self.color = Vector3DTO(data.color)
        self.brightness = data.brightness
        self.ambientIntensity = data.ambientIntensity
        self.diffuseIntensity = data.diffuseIntensity
        self.specularIntensity = data.specularIntensity
        self.innerConeCos = data.innerConeCos
        self.outerConeCos = data.outerConeCos
    }

    public func toLightData() -> LightData {
        var data = LightData()
        data.position = position.toSIMD()
        data.type = type
        data.direction = direction.toSIMD()
        data.range = range
        data.color = color.toSIMD()
        data.brightness = brightness
        data.ambientIntensity = ambientIntensity
        data.diffuseIntensity = diffuseIntensity
        data.specularIntensity = specularIntensity
        data.innerConeCos = innerConeCos
        data.outerConeCos = outerConeCos
        return data
    }
}

public struct MaterialDTO: Codable {
    public var schemaVersion: Int
    public var baseColor: Vector3DTO
    public var metallicScalar: Float
    public var roughnessScalar: Float
    public var aoScalar: Float
    public var emissiveColor: Vector3DTO
    public var emissiveScalar: Float
    public var alphaCutoff: Float
    public var flags: UInt32
    public var clearcoatFactor: Float
    public var clearcoatRoughness: Float
    public var sheenRoughness: Float
    public var pbrMaskMode: UInt32
    public var aoChannel: UInt32
    public var roughnessChannel: UInt32
    public var metallicChannel: UInt32
    public var sheenColor: Vector3DTO
    public var uvTiling: Vector2DTO
    public var uvOffset: Vector2DTO

    public init(schemaVersion: Int = 1, material: MetalCupMaterial) {
        self.schemaVersion = schemaVersion
        self.baseColor = Vector3DTO(material.baseColor)
        self.metallicScalar = material.metallicScalar
        self.roughnessScalar = material.roughnessScalar
        self.aoScalar = material.aoScalar
        self.emissiveColor = Vector3DTO(material.emissiveColor)
        self.emissiveScalar = material.emissiveScalar
        self.alphaCutoff = material.alphaCutoff
        self.flags = material.flags
        self.clearcoatFactor = material.clearcoatFactor
        self.clearcoatRoughness = material.clearcoatRoughness
        self.sheenRoughness = material.sheenRoughness
        self.pbrMaskMode = material.pbrMaskMode
        self.aoChannel = material.aoChannel
        self.roughnessChannel = material.roughnessChannel
        self.metallicChannel = material.metallicChannel
        self.sheenColor = Vector3DTO(material.sheenColor)
        self.uvTiling = Vector2DTO(material.uvTiling)
        self.uvOffset = Vector2DTO(material.uvOffset)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        baseColor = try container.decode(Vector3DTO.self, forKey: .baseColor)
        metallicScalar = try container.decode(Float.self, forKey: .metallicScalar)
        roughnessScalar = try container.decode(Float.self, forKey: .roughnessScalar)
        aoScalar = try container.decode(Float.self, forKey: .aoScalar)
        emissiveColor = try container.decode(Vector3DTO.self, forKey: .emissiveColor)
        emissiveScalar = try container.decode(Float.self, forKey: .emissiveScalar)
        alphaCutoff = try container.decodeIfPresent(Float.self, forKey: .alphaCutoff) ?? 0.5
        flags = try container.decode(UInt32.self, forKey: .flags)
        clearcoatFactor = try container.decode(Float.self, forKey: .clearcoatFactor)
        clearcoatRoughness = try container.decode(Float.self, forKey: .clearcoatRoughness)
        sheenRoughness = try container.decode(Float.self, forKey: .sheenRoughness)
        pbrMaskMode = try container.decodeIfPresent(UInt32.self, forKey: .pbrMaskMode) ?? 0
        aoChannel = try container.decodeIfPresent(UInt32.self, forKey: .aoChannel) ?? 0
        roughnessChannel = try container.decodeIfPresent(UInt32.self, forKey: .roughnessChannel) ?? 1
        metallicChannel = try container.decodeIfPresent(UInt32.self, forKey: .metallicChannel) ?? 2
        sheenColor = try container.decode(Vector3DTO.self, forKey: .sheenColor)
        uvTiling = try container.decodeIfPresent(Vector2DTO.self, forKey: .uvTiling) ?? Vector2DTO(SIMD2<Float>(1.0, 1.0))
        uvOffset = try container.decodeIfPresent(Vector2DTO.self, forKey: .uvOffset) ?? Vector2DTO(SIMD2<Float>(0.0, 0.0))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(baseColor, forKey: .baseColor)
        try container.encode(metallicScalar, forKey: .metallicScalar)
        try container.encode(roughnessScalar, forKey: .roughnessScalar)
        try container.encode(aoScalar, forKey: .aoScalar)
        try container.encode(emissiveColor, forKey: .emissiveColor)
        try container.encode(emissiveScalar, forKey: .emissiveScalar)
        try container.encode(alphaCutoff, forKey: .alphaCutoff)
        try container.encode(flags, forKey: .flags)
        try container.encode(clearcoatFactor, forKey: .clearcoatFactor)
        try container.encode(clearcoatRoughness, forKey: .clearcoatRoughness)
        try container.encode(sheenRoughness, forKey: .sheenRoughness)
        try container.encode(pbrMaskMode, forKey: .pbrMaskMode)
        try container.encode(aoChannel, forKey: .aoChannel)
        try container.encode(roughnessChannel, forKey: .roughnessChannel)
        try container.encode(metallicChannel, forKey: .metallicChannel)
        try container.encode(sheenColor, forKey: .sheenColor)
        try container.encode(uvTiling, forKey: .uvTiling)
        try container.encode(uvOffset, forKey: .uvOffset)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case baseColor
        case metallicScalar
        case roughnessScalar
        case aoScalar
        case emissiveColor
        case emissiveScalar
        case alphaCutoff
        case flags
        case clearcoatFactor
        case clearcoatRoughness
        case sheenRoughness
        case pbrMaskMode
        case aoChannel
        case roughnessChannel
        case metallicChannel
        case sheenColor
        case uvTiling
        case uvOffset
    }

    public func toMaterial() -> MetalCupMaterial {
        var material = MetalCupMaterial()
        material.baseColor = baseColor.toSIMD()
        material.metallicScalar = metallicScalar
        material.roughnessScalar = roughnessScalar
        material.aoScalar = aoScalar
        material.emissiveColor = emissiveColor.toSIMD()
        material.emissiveScalar = emissiveScalar
        material.alphaCutoff = alphaCutoff
        material.flags = flags
        material.clearcoatFactor = clearcoatFactor
        material.clearcoatRoughness = clearcoatRoughness
        material.sheenRoughness = sheenRoughness
        material.pbrMaskMode = pbrMaskMode
        material.aoChannel = aoChannel
        material.roughnessChannel = roughnessChannel
        material.metallicChannel = metallicChannel
        material.sheenColor = sheenColor.toSIMD()
        material.uvTiling = uvTiling.toSIMD()
        material.uvOffset = uvOffset.toSIMD()
        return material
    }
}

public enum SceneSerializer {
    public static func save(scene: EngineScene, to url: URL) throws {
        let rendererSettings = scene.engineContext?.rendererSettings ?? RendererSettings()
        let physicsSettings = scene.engineContext?.physicsSettings ?? PhysicsSettings()
        let document = scene.toDocument(
            rendererSettingsOverride: RendererSettingsDTO(settings: rendererSettings),
            physicsSettingsOverride: PhysicsSettingsDTO(settings: physicsSettings),
            // Persist the editor camera with the scene so editor-only view settings such as
            // exposure mode and manual/auto exposure values survive save/load.
            includeEditorEntities: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: url, options: [.atomic])
    }

    public static func load(from url: URL) throws -> SceneDocument {
        let data = try Data(contentsOf: url)
        _ = MCE_VERIFY(!data.isEmpty, "Scene load empty data: \(url.lastPathComponent)")
        let decoder = JSONDecoder()
        let document = try decoder.decode(SceneDocument.self, from: data)
        return migrateIfNeeded(document)
    }

    private static func migrateIfNeeded(_ document: SceneDocument) -> SceneDocument {
        if document.schemaVersion == SceneSchema.currentVersion {
            return document
        }
        EngineLoggerContext.log(
            "Scene migrate unsupported schema \(document.schemaVersion) -> \(SceneSchema.currentVersion)",
            level: .warning,
            category: .serialization
        )
        return document
    }
}
