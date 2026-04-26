/// Components.swift
/// Defines the Components types and helpers for the engine.
/// Created by Kaden Cringle.

import Foundation
import simd

public struct NameComponent {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

public struct TransformComponent {
    public var position: SIMD3<Float>
    public var scale: SIMD3<Float>
    private var rotationStorage: SIMD4<Float>

    public var rotation: SIMD4<Float> {
        get { rotationStorage }
        set { rotationStorage = TransformMath.normalizedQuaternion(newValue) }
    }

    public init(
        position: SIMD3<Float> = .zero,
        rotation: SIMD4<Float> = TransformMath.identityQuaternion,
        scale: SIMD3<Float> = SIMD3<Float>(repeating: 1.0)
    ) {
        self.position = position
        self.scale = scale
        self.rotationStorage = TransformMath.normalizedQuaternion(rotation)
    }
}

public struct ParentComponent {
    public var parent: UUID

    public init(parent: UUID) {
        self.parent = parent
    }
}

public struct ChildrenComponent {
    public var children: [UUID]

    public init(children: [UUID] = []) {
        self.children = children
    }
}

public enum RigidbodyMotionType: UInt32, Codable {
    case staticBody = 0
    case dynamic = 1
    case kinematic = 2
}

public enum ColliderShapeType: UInt32, Codable {
    case box = 0
    case sphere = 1
    case capsule = 2
}

public struct ColliderShape: Codable {
    public var isEnabled: Bool
    public var shapeType: ColliderShapeType
    public var boxHalfExtents: SIMD3<Float>
    public var sphereRadius: Float
    public var capsuleHalfHeight: Float
    public var capsuleRadius: Float
    public var offset: SIMD3<Float>
    public var rotationOffset: SIMD3<Float>
    public var isTrigger: Bool
    public var collisionLayerOverride: Int32?
    public var physicsMaterial: AssetHandle?

    public init(isEnabled: Bool = true,
                shapeType: ColliderShapeType = .box,
                boxHalfExtents: SIMD3<Float> = SIMD3<Float>(repeating: 0.5),
                sphereRadius: Float = 0.5,
                capsuleHalfHeight: Float = 0.5,
                capsuleRadius: Float = 0.5,
                offset: SIMD3<Float> = .zero,
                rotationOffset: SIMD3<Float> = .zero,
                isTrigger: Bool = false,
                collisionLayerOverride: Int32? = nil,
                physicsMaterial: AssetHandle? = nil) {
        self.isEnabled = isEnabled
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
    }
}

public struct RigidbodyComponent {
    public var isEnabled: Bool
    public var motionType: RigidbodyMotionType
    public var mass: Float
    public var friction: Float
    public var restitution: Float
    public var linearDamping: Float
    public var angularDamping: Float
    public var gravityFactor: Float
    public var allowSleeping: Bool
    public var ccdEnabled: Bool
    public var collisionLayer: Int32
    public var bodyId: UInt64?

    public init(isEnabled: Bool = true,
                motionType: RigidbodyMotionType = .dynamic,
                mass: Float = 1.0,
                friction: Float = 0.6,
                restitution: Float = 0.0,
                linearDamping: Float = 0.02,
                angularDamping: Float = 0.2,
                gravityFactor: Float = 1.0,
                allowSleeping: Bool = true,
                ccdEnabled: Bool = false,
                collisionLayer: Int32 = 0,
                bodyId: UInt64? = nil) {
        self.isEnabled = isEnabled
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
        self.bodyId = bodyId
    }
}

public struct ColliderComponent {
    public var isEnabled: Bool
    public var shapeType: ColliderShapeType
    public var boxHalfExtents: SIMD3<Float>
    public var sphereRadius: Float
    public var capsuleHalfHeight: Float
    public var capsuleRadius: Float
    public var offset: SIMD3<Float>
    public var rotationOffset: SIMD3<Float>
    public var isTrigger: Bool
    public var collisionLayerOverride: Int32?
    public var physicsMaterial: AssetHandle?
    public var additionalShapes: [ColliderShape]

    public init(isEnabled: Bool = true,
                shapeType: ColliderShapeType = .box,
                boxHalfExtents: SIMD3<Float> = SIMD3<Float>(repeating: 0.5),
                sphereRadius: Float = 0.5,
                capsuleHalfHeight: Float = 0.5,
                capsuleRadius: Float = 0.5,
                offset: SIMD3<Float> = .zero,
                rotationOffset: SIMD3<Float> = .zero,
                isTrigger: Bool = false,
                collisionLayerOverride: Int32? = nil,
                physicsMaterial: AssetHandle? = nil,
                additionalShapes: [ColliderShape] = []) {
        self.isEnabled = isEnabled
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
        self.additionalShapes = additionalShapes
    }

    public func primaryShape() -> ColliderShape {
        ColliderShape(
            isEnabled: isEnabled,
            shapeType: shapeType,
            boxHalfExtents: boxHalfExtents,
            sphereRadius: sphereRadius,
            capsuleHalfHeight: capsuleHalfHeight,
            capsuleRadius: capsuleRadius,
            offset: offset,
            rotationOffset: rotationOffset,
            isTrigger: isTrigger,
            collisionLayerOverride: collisionLayerOverride,
            physicsMaterial: physicsMaterial
        )
    }

    public func allShapes() -> [ColliderShape] {
        var shapes: [ColliderShape] = [primaryShape()]
        shapes.append(contentsOf: additionalShapes)
        return shapes
    }

    public mutating func setShapes(_ shapes: [ColliderShape]) {
        let resolved = shapes.isEmpty ? [ColliderShape()] : shapes
        let primary = resolved[0]
        isEnabled = primary.isEnabled
        shapeType = primary.shapeType
        boxHalfExtents = primary.boxHalfExtents
        sphereRadius = primary.sphereRadius
        capsuleHalfHeight = primary.capsuleHalfHeight
        capsuleRadius = primary.capsuleRadius
        offset = primary.offset
        rotationOffset = primary.rotationOffset
        isTrigger = primary.isTrigger
        collisionLayerOverride = primary.collisionLayerOverride
        physicsMaterial = primary.physicsMaterial
        additionalShapes = Array(resolved.dropFirst())
    }
}

public struct LayerComponent {
    public var index: Int32

    public init(index: Int32 = LayerCatalog.defaultLayerIndex) {
        self.index = index
    }
}

public struct ScriptComponent {
    public enum RuntimeState: UInt32 {
        case unloaded = 0
        case loaded = 1
        case error = 2
        case disabled = 3
    }

    public var enabled: Bool
    public var scriptAssetHandle: AssetHandle?
    public var typeName: String
    public var fieldData: Data
    public var fieldDataVersion: UInt32
    public var serializedFields: [String: ScriptFieldValue]
    public var fieldMetadata: [String: ScriptFieldMetadata]
    public var runtimeState: RuntimeState
    public var instanceHandle: UInt64
    public var hasInstance: Bool
    public var lastError: String

    public init(enabled: Bool = true,
                scriptAssetHandle: AssetHandle? = nil,
                typeName: String = "",
                fieldData: Data = Data(),
                fieldDataVersion: UInt32 = 1,
                serializedFields: [String: ScriptFieldValue] = [:],
                fieldMetadata: [String: ScriptFieldMetadata] = [:],
                runtimeState: RuntimeState = .unloaded,
                instanceHandle: UInt64 = 0,
                hasInstance: Bool = false,
                lastError: String = "") {
        self.enabled = enabled
        self.scriptAssetHandle = scriptAssetHandle
        self.typeName = typeName
        self.fieldData = fieldData
        self.fieldDataVersion = fieldDataVersion
        self.serializedFields = serializedFields
        self.fieldMetadata = fieldMetadata
        self.runtimeState = runtimeState
        self.instanceHandle = instanceHandle
        self.hasInstance = hasInstance
        self.lastError = lastError
    }
}

public enum ScriptFieldType: String, Codable, CaseIterable {
    case bool
    case int
    case float
    case vec2
    case vec3
    case color3
    case string
    case entity
    case prefab

    // Backward-compat aliases used by older serialized data.
    case number
    case boolean
}

public struct ScriptFieldMetadata: Equatable {
    public var name: String
    public var type: ScriptFieldType
    public var defaultValue: ScriptFieldValue
    public var minValue: Float?
    public var maxValue: Float?
    public var step: Float?
    public var tooltip: String

    public init(name: String,
                type: ScriptFieldType,
                defaultValue: ScriptFieldValue,
                minValue: Float? = nil,
                maxValue: Float? = nil,
                step: Float? = nil,
                tooltip: String = "") {
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
        self.minValue = minValue
        self.maxValue = maxValue
        self.step = step
        self.tooltip = tooltip
    }
}

public enum ScriptFieldValue: Equatable {
    case bool(Bool)
    case int(Int32)
    case float(Float)
    case vec2(SIMD2<Float>)
    case vec3(SIMD3<Float>)
    case color3(SIMD3<Float>)
    case string(String)
    case entity(UUID?)
    case prefab(AssetHandle?)
}

extension ScriptFieldValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case bool
        case int
        case float
        case number
        case boolean
        case string
        case vec2
        case vec3
        case color3
        case entity
        case prefab
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ScriptFieldType.self, forKey: .type)
        switch type {
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .bool))
        case .int:
            self = .int(try container.decode(Int32.self, forKey: .int))
        case .float:
            self = .float(try container.decode(Float.self, forKey: .float))
        case .vec2:
            let values = try container.decode([Float].self, forKey: .vec2)
            let x = values.count > 0 ? values[0] : 0.0
            let y = values.count > 1 ? values[1] : 0.0
            self = .vec2(SIMD2<Float>(x, y))
        case .number:
            self = .float(try container.decode(Float.self, forKey: .number))
        case .boolean:
            self = .bool(try container.decode(Bool.self, forKey: .boolean))
        case .string:
            self = .string(try container.decode(String.self, forKey: .string))
        case .vec3:
            let values = try container.decode([Float].self, forKey: .vec3)
            let x = values.count > 0 ? values[0] : 0.0
            let y = values.count > 1 ? values[1] : 0.0
            let z = values.count > 2 ? values[2] : 0.0
            self = .vec3(SIMD3<Float>(x, y, z))
        case .color3:
            let values = try container.decode([Float].self, forKey: .color3)
            let x = values.count > 0 ? values[0] : 1.0
            let y = values.count > 1 ? values[1] : 1.0
            let z = values.count > 2 ? values[2] : 1.0
            self = .color3(SIMD3<Float>(x, y, z))
        case .entity:
            if let raw = try container.decodeIfPresent(String.self, forKey: .entity), let uuid = UUID(uuidString: raw) {
                self = .entity(uuid)
            } else {
                self = .entity(nil)
            }
        case .prefab:
            if let raw = try container.decodeIfPresent(String.self, forKey: .prefab),
               let uuid = UUID(uuidString: raw) {
                self = .prefab(AssetHandle(rawValue: uuid))
            } else {
                self = .prefab(nil)
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .bool(value):
            try container.encode(ScriptFieldType.bool, forKey: .type)
            try container.encode(value, forKey: .bool)
        case let .int(value):
            try container.encode(ScriptFieldType.int, forKey: .type)
            try container.encode(value, forKey: .int)
        case let .float(value):
            try container.encode(ScriptFieldType.float, forKey: .type)
            try container.encode(value, forKey: .float)
        case let .vec2(value):
            try container.encode(ScriptFieldType.vec2, forKey: .type)
            try container.encode([value.x, value.y], forKey: .vec2)
        case let .string(value):
            try container.encode(ScriptFieldType.string, forKey: .type)
            try container.encode(value, forKey: .string)
        case let .vec3(value):
            try container.encode(ScriptFieldType.vec3, forKey: .type)
            try container.encode([value.x, value.y, value.z], forKey: .vec3)
        case let .color3(value):
            try container.encode(ScriptFieldType.color3, forKey: .type)
            try container.encode([value.x, value.y, value.z], forKey: .color3)
        case let .entity(value):
            try container.encode(ScriptFieldType.entity, forKey: .type)
            try container.encode(value?.uuidString, forKey: .entity)
        case let .prefab(value):
            try container.encode(ScriptFieldType.prefab, forKey: .type)
            try container.encode(value?.rawValue.uuidString, forKey: .prefab)
        }
    }
}

public struct CharacterControllerComponent {
    public var isEnabled: Bool
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
    public var interpolateSubtree: Bool

    // Runtime state
    public var moveInput: SIMD2<Float>
    public var lookInput: SIMD2<Float>
    public var wantsSprint: Bool
    public var jumpBufferTimer: Float
    public var jumpConsumedOnGroundContact: Bool
    public var characterHandle: UInt64
    public var velocity: SIMD3<Float>
    public var isGrounded: Bool
    public var lastGroundBodyId: UInt64
    public var yawRadians: Float
    public var pitchRadians: Float
    public var lookInitialized: Bool
    public var runtimeConfigApplied: Bool
    public var runtimeAppliedRadius: Float
    public var runtimeAppliedHeight: Float
    public var runtimeAppliedMaxSlope: Float
    public var runtimeAppliedStepOffset: Float
    public var runtimeAppliedGravity: Float
    public var runtimeAppliedJumpSpeed: Float
    public var runtimeAppliedPushStrength: Float

    public init(isEnabled: Bool = true,
                height: Float = 1.8,
                radius: Float = 0.35,
                stepOffset: Float = 0.25,
                moveSpeed: Float = 4.0,
                sprintMultiplier: Float = 1.5,
                airControl: Float = 0.35,
                jumpSpeed: Float = 5.5,
                useGravityOverride: Bool = false,
                gravity: Float = -9.81,
                maxSlope: Float = 45.0,
                pushStrength: Float = 100.0,
                lookSensitivity: Float = 0.01,
                minPitchDegrees: Float = -80.0,
                maxPitchDegrees: Float = 80.0,
                visualEntityId: UUID? = nil,
                animatorEntityId: UUID? = nil,
                cameraPivotEntityId: UUID? = nil,
                interpolateSubtree: Bool = true,
                moveInput: SIMD2<Float> = .zero,
                lookInput: SIMD2<Float> = .zero,
                wantsSprint: Bool = false,
                jumpBufferTimer: Float = 0.0,
                jumpConsumedOnGroundContact: Bool = false,
                characterHandle: UInt64 = 0,
                velocity: SIMD3<Float> = .zero,
                isGrounded: Bool = false,
                lastGroundBodyId: UInt64 = 0,
                yawRadians: Float = 0.0,
                pitchRadians: Float = 0.0,
                lookInitialized: Bool = false,
                runtimeConfigApplied: Bool = false,
                runtimeAppliedRadius: Float = 0.0,
                runtimeAppliedHeight: Float = 0.0,
                runtimeAppliedMaxSlope: Float = 0.0,
                runtimeAppliedStepOffset: Float = 0.0,
                runtimeAppliedGravity: Float = 0.0,
                runtimeAppliedJumpSpeed: Float = 0.0,
                runtimeAppliedPushStrength: Float = 0.0) {
        self.isEnabled = isEnabled
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
        self.interpolateSubtree = interpolateSubtree
        self.moveInput = moveInput
        self.lookInput = lookInput
        self.wantsSprint = wantsSprint
        self.jumpBufferTimer = jumpBufferTimer
        self.jumpConsumedOnGroundContact = jumpConsumedOnGroundContact
        self.characterHandle = characterHandle
        self.velocity = velocity
        self.isGrounded = isGrounded
        self.lastGroundBodyId = lastGroundBodyId
        self.yawRadians = yawRadians
        self.pitchRadians = pitchRadians
        self.lookInitialized = lookInitialized
        self.runtimeConfigApplied = runtimeConfigApplied
        self.runtimeAppliedRadius = runtimeAppliedRadius
        self.runtimeAppliedHeight = runtimeAppliedHeight
        self.runtimeAppliedMaxSlope = runtimeAppliedMaxSlope
        self.runtimeAppliedStepOffset = runtimeAppliedStepOffset
        self.runtimeAppliedGravity = runtimeAppliedGravity
        self.runtimeAppliedJumpSpeed = runtimeAppliedJumpSpeed
        self.runtimeAppliedPushStrength = runtimeAppliedPushStrength
    }
}

public enum PrefabOverrideType: String, Codable, CaseIterable {
    case name
    case hierarchy
    case layer
    case meshRenderer
    case material
    case rigidbody
    case collider
    case light
    case lightOrbit
    case camera
    case script
    case sky
    case skyLight
    case reflectionProbe
    case skyLightTag
    case skySunTag
    case skinnedMesh
    case animator
    case audioSource
    case audioListener
}

public struct PrefabOverrideComponent {
    public var overridden: Set<PrefabOverrideType>

    public init(overridden: Set<PrefabOverrideType> = []) {
        self.overridden = overridden
    }

    public func contains(_ type: PrefabOverrideType) -> Bool {
        return overridden.contains(type)
    }
}

public struct PrefabInstanceComponent {
    public var prefabHandle: AssetHandle
    public var prefabEntityId: UUID
    public var instanceId: UUID

    public init(prefabHandle: AssetHandle, prefabEntityId: UUID, instanceId: UUID = UUID()) {
        self.prefabHandle = prefabHandle
        self.prefabEntityId = prefabEntityId
        self.instanceId = instanceId
    }
}

public struct MeshRendererComponent {
    public var meshHandle: AssetHandle?
    public var materialHandle: AssetHandle?
    public var submeshMaterialHandles: [AssetHandle?]?
    public var material: MetalCupMaterial?
    public var albedoMapHandle: AssetHandle?
    public var normalMapHandle: AssetHandle?
    public var metallicMapHandle: AssetHandle?
    public var roughnessMapHandle: AssetHandle?
    public var mrMapHandle: AssetHandle?
    public var ormMapHandle: AssetHandle?
    public var aoMapHandle: AssetHandle?
    public var emissiveMapHandle: AssetHandle?

    public init(
        meshHandle: AssetHandle?,
        materialHandle: AssetHandle? = nil,
        submeshMaterialHandles: [AssetHandle?]? = nil,
        material: MetalCupMaterial? = nil,
        albedoMapHandle: AssetHandle? = nil,
        normalMapHandle: AssetHandle? = nil,
        metallicMapHandle: AssetHandle? = nil,
        roughnessMapHandle: AssetHandle? = nil,
        mrMapHandle: AssetHandle? = nil,
        ormMapHandle: AssetHandle? = nil,
        aoMapHandle: AssetHandle? = nil,
        emissiveMapHandle: AssetHandle? = nil
    ) {
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

public struct SkinnedMeshComponent {
    public var skeletonHandle: AssetHandle?
    public var rootBoneName: String

    public init(skeletonHandle: AssetHandle? = nil, rootBoneName: String = "") {
        self.skeletonHandle = skeletonHandle
        self.rootBoneName = rootBoneName
    }
}

public typealias EntityID = UUID
public typealias AssetID = AssetHandle

/// Canonical runtime contracts for animation output.
/// Producer-owned by `AnimationSystem`; consumers must treat these values as read-only tick truth.
public enum LocomotionAuthorityMode: UInt8 {
    case none
    case animationRootMotion
    case controllerDriven
    case hybridReserved
}

public enum RootMotionSource: UInt8 {
    case none
    case state
    case transitionBlend
}

public enum TransitionTickPhase: UInt8 {
    case entering
    case active
    case exiting
}

public struct TransitionTickInfo {
    public var sourceStateId: String
    public var targetStateId: String
    public var normalizedTime: Float
    public var duration: Float
    public var phase: TransitionTickPhase

    public init(sourceStateId: String = "",
                targetStateId: String = "",
                normalizedTime: Float = 0.0,
                duration: Float = 0.0,
                phase: TransitionTickPhase = .active) {
        self.sourceStateId = sourceStateId
        self.targetStateId = targetStateId
        self.normalizedTime = normalizedTime
        self.duration = duration
        self.phase = phase
    }
}

public struct StateMachineTickResult {
    public var graphId: AssetID
    public var activeStateId: String
    public var activeStateName: String
    public var isInTransition: Bool
    public var transition: TransitionTickInfo?
    public var stateTime: Float
    public var normalizedStateTime: Float

    public init(graphId: AssetID = AssetID(),
                activeStateId: String = "",
                activeStateName: String = "",
                isInTransition: Bool = false,
                transition: TransitionTickInfo? = nil,
                stateTime: Float = 0.0,
                normalizedStateTime: Float = 0.0) {
        self.graphId = graphId
        self.activeStateId = activeStateId
        self.activeStateName = activeStateName
        self.isInTransition = isInTransition
        self.transition = transition
        self.stateTime = stateTime
        self.normalizedStateTime = normalizedStateTime
    }
}

public struct RootMotionFrame {
    public var mode: LocomotionAuthorityMode
    public var authoredDeltaLocal: SIMD3<Float>
    public var authoredDeltaRotationLocal: simd_quatf
    public var effectiveDeltaLocal: SIMD3<Float>
    public var effectiveDeltaRotationLocal: simd_quatf
    /// State-level authored semantic: whether the active state is configured to author root motion.
    public var stateHasAuthoredRootMotion: Bool
    /// Frame-level contribution semantic: whether this tick had authored root motion contribution.
    public var hasAuthoredMotion: Bool
    public var isActive: Bool
    public var source: RootMotionSource

    public init(mode: LocomotionAuthorityMode = .none,
                authoredDeltaLocal: SIMD3<Float> = .zero,
                authoredDeltaRotationLocal: simd_quatf = simd_quatf(vector: TransformMath.identityQuaternion),
                effectiveDeltaLocal: SIMD3<Float> = .zero,
                effectiveDeltaRotationLocal: simd_quatf = simd_quatf(vector: TransformMath.identityQuaternion),
                stateHasAuthoredRootMotion: Bool = false,
                hasAuthoredMotion: Bool = false,
                isActive: Bool = false,
                source: RootMotionSource = .none) {
        self.mode = mode
        self.authoredDeltaLocal = authoredDeltaLocal
        self.authoredDeltaRotationLocal = authoredDeltaRotationLocal.normalized
        self.effectiveDeltaLocal = effectiveDeltaLocal
        self.effectiveDeltaRotationLocal = effectiveDeltaRotationLocal.normalized
        self.stateHasAuthoredRootMotion = stateHasAuthoredRootMotion
        self.hasAuthoredMotion = hasAuthoredMotion
        self.isActive = isActive
        self.source = source
    }
}

public struct AnimatorParameterWriteSet {
    public var bools: [String: Bool]
    public var floats: [String: Float]
    public var ints: [String: Int32]
    public var triggersSet: Set<String>
    public var triggersReset: Set<String>

    public init(bools: [String: Bool] = [:],
                floats: [String: Float] = [:],
                ints: [String: Int32] = [:],
                triggersSet: Set<String> = [],
                triggersReset: Set<String> = []) {
        self.bools = bools
        self.floats = floats
        self.ints = ints
        self.triggersSet = triggersSet
        self.triggersReset = triggersReset
    }
}

/// Optional animation debug contract payload for per-tick diagnostics.
/// Producer-owned by `AnimationSystem`; consumers should not derive authority from this data.
public struct AnimationTickDebug {
    public var notes: [String: String]

    public init(notes: [String: String] = [:]) {
        self.notes = notes
    }
}

public struct AnimationTickResult {
    public var entity: EntityID
    public var tickIndex: UInt64
    public var dt: Float
    public var stateMachine: StateMachineTickResult
    public var rootMotion: RootMotionFrame
    public var animatorWrites: AnimatorParameterWriteSet
    public var debug: AnimationTickDebug?

    public init(entity: EntityID = UUID(),
                tickIndex: UInt64 = 0,
                dt: Float = 0.0,
                stateMachine: StateMachineTickResult = StateMachineTickResult(),
                rootMotion: RootMotionFrame = RootMotionFrame(),
                animatorWrites: AnimatorParameterWriteSet = AnimatorParameterWriteSet(),
                debug: AnimationTickDebug? = nil) {
        self.entity = entity
        self.tickIndex = tickIndex
        self.dt = dt
        self.stateMachine = stateMachine
        self.rootMotion = rootMotion
        self.animatorWrites = animatorWrites
        self.debug = debug
    }
}

/// Temporary phase-1 compatibility adapter that projects canonical animation tick contracts
/// back into legacy runtime fields consumed by unrefactored systems.
/// One-way only: canonical -> legacy.
public struct AnimationRuntimeCompatibilityView {
    public let canonical: AnimationTickResult

    public init(canonical: AnimationTickResult) {
        self.canonical = canonical
    }

    public var usesRootMotion: Bool {
        canonical.rootMotion.isActive
    }

    public func rootMotionDelta(fallback: RootMotionDelta = .zero) -> RootMotionDelta {
        _ = fallback
        return RootMotionDelta(deltaPos: canonical.rootMotion.effectiveDeltaLocal,
                               deltaRot: canonical.rootMotion.effectiveDeltaRotationLocal.vector)
    }

    public func rootMotionSample(fallback: RootMotionRuntimeSample? = nil) -> RootMotionRuntimeSample? {
        if canonical.tickIndex == 0 {
            return fallback
        }
        let rotation = canonical.rootMotion.effectiveDeltaRotationLocal.vector
        return RootMotionRuntimeSample(
            tickID: canonical.tickIndex,
            deltaTranslationLocal: canonical.rootMotion.effectiveDeltaLocal,
            deltaRotationLocal: rotation,
            sourceStateName: canonical.stateMachine.activeStateName,
            sourceNodeID: fallback?.sourceNodeID,
            sampleStartTime: max(canonical.stateMachine.stateTime - canonical.dt, 0.0),
            sampleEndTime: canonical.stateMachine.stateTime,
            isValid: canonical.rootMotion.hasAuthoredMotion
        )
    }

    public func fixedTickRuntimeSnapshot(fallback: AnimationFixedTickRuntimeSnapshot? = nil) -> AnimationFixedTickRuntimeSnapshot {
        let effectiveRotation = canonical.rootMotion.effectiveDeltaRotationLocal.vector
        let sampleHasNonZeroDelta: Bool = {
            let delta = canonical.rootMotion.effectiveDeltaLocal
            let rotation = canonical.rootMotion.effectiveDeltaRotationLocal
            let rotationRadians = 2.0 * acos(simd_clamp(abs(rotation.real), 0.0, 1.0))
            return simd_length(delta) > 1.0e-6 || rotationRadians > 1.0e-5
        }()
        let currentStateID = UUID(uuidString: canonical.stateMachine.activeStateId)
        let nextStateID = canonical.stateMachine.transition.flatMap { UUID(uuidString: $0.targetStateId) }
        return AnimationFixedTickRuntimeSnapshot(
            tickID: canonical.tickIndex,
            currentStateID: currentStateID ?? fallback?.currentStateID,
            currentStateName: canonical.stateMachine.activeStateName,
            nextStateID: nextStateID ?? fallback?.nextStateID,
            nextStateName: fallback?.nextStateName ?? "",
            authoredUsesRootMotion: canonical.rootMotion.stateHasAuthoredRootMotion,
            stateWantsRootMotion: fallback?.stateWantsRootMotion ?? canonical.rootMotion.isActive,
            effectiveUsesRootMotion: canonical.rootMotion.isActive,
            sampleHasNonZeroDelta: sampleHasNonZeroDelta,
            rootMotionSampleValid: canonical.rootMotion.hasAuthoredMotion,
            rootMotionTrackConsumed: fallback?.rootMotionTrackConsumed ?? canonical.rootMotion.isActive,
            translationSourceJointIndex: fallback?.translationSourceJointIndex ?? -1,
            translationSourceJointName: fallback?.translationSourceJointName ?? "",
            rotationSourceJointIndex: fallback?.rotationSourceJointIndex ?? -1,
            rotationSourceJointName: fallback?.rotationSourceJointName ?? "",
            localRootDeltaTranslation: canonical.rootMotion.effectiveDeltaLocal,
            worldRootDeltaTranslation: canonical.rootMotion.effectiveDeltaLocal,
            rootDeltaRotation: effectiveRotation,
            sampleTime: canonical.stateMachine.stateTime,
            sampleDuration: max(canonical.dt, fallback?.sampleDuration ?? 0.0),
            isTransitionBlend: canonical.stateMachine.isInTransition
        )
    }
}

// TODO(phase-2): Deprecate overlapping snapshot/root-motion flags once all consumers read AnimationTickResult.
public struct RootMotionDelta {
    public var deltaPos: SIMD3<Float>
    public var deltaRot: SIMD4<Float>

    public init(deltaPos: SIMD3<Float> = .zero,
                deltaRot: SIMD4<Float> = TransformMath.identityQuaternion) {
        self.deltaPos = deltaPos
        self.deltaRot = TransformMath.normalizedQuaternion(deltaRot)
    }

    public static let zero = RootMotionDelta()
}

public struct RootMotionRuntimeSample {
    public var tickID: UInt64
    public var deltaTranslationLocal: SIMD3<Float>
    public var deltaRotationLocal: SIMD4<Float>
    public var sourceStateName: String
    public var sourceNodeID: UUID?
    public var sampleStartTime: Float
    public var sampleEndTime: Float
    public var isValid: Bool

    public init(tickID: UInt64 = 0,
                deltaTranslationLocal: SIMD3<Float> = .zero,
                deltaRotationLocal: SIMD4<Float> = TransformMath.identityQuaternion,
                sourceStateName: String = "",
                sourceNodeID: UUID? = nil,
                sampleStartTime: Float = 0.0,
                sampleEndTime: Float = 0.0,
                isValid: Bool = false) {
        self.tickID = tickID
        self.deltaTranslationLocal = deltaTranslationLocal
        self.deltaRotationLocal = TransformMath.normalizedQuaternion(deltaRotationLocal)
        self.sourceStateName = sourceStateName
        self.sourceNodeID = sourceNodeID
        self.sampleStartTime = sampleStartTime
        self.sampleEndTime = sampleEndTime
        self.isValid = isValid
    }
}

public struct AnimationFixedTickRuntimeSnapshot {
    public var tickID: UInt64
    public var currentStateID: UUID?
    public var currentStateName: String
    public var nextStateID: UUID?
    public var nextStateName: String
    public var authoredUsesRootMotion: Bool
    public var stateWantsRootMotion: Bool
    public var effectiveUsesRootMotion: Bool
    public var sampleHasNonZeroDelta: Bool
    public var rootMotionSampleValid: Bool
    public var rootMotionTrackConsumed: Bool
    public var translationSourceJointIndex: Int
    public var translationSourceJointName: String
    public var rotationSourceJointIndex: Int
    public var rotationSourceJointName: String
    public var localRootDeltaTranslation: SIMD3<Float>
    public var worldRootDeltaTranslation: SIMD3<Float>
    public var rootDeltaRotation: SIMD4<Float>
    public var sampleTime: Float
    public var sampleDuration: Float
    public var isTransitionBlend: Bool

    public init(tickID: UInt64 = 0,
                currentStateID: UUID? = nil,
                currentStateName: String = "",
                nextStateID: UUID? = nil,
                nextStateName: String = "",
                authoredUsesRootMotion: Bool = false,
                stateWantsRootMotion: Bool = false,
                effectiveUsesRootMotion: Bool = false,
                sampleHasNonZeroDelta: Bool = false,
                rootMotionSampleValid: Bool = false,
                rootMotionTrackConsumed: Bool = false,
                translationSourceJointIndex: Int = -1,
                translationSourceJointName: String = "",
                rotationSourceJointIndex: Int = -1,
                rotationSourceJointName: String = "",
                localRootDeltaTranslation: SIMD3<Float> = .zero,
                worldRootDeltaTranslation: SIMD3<Float> = .zero,
                rootDeltaRotation: SIMD4<Float> = TransformMath.identityQuaternion,
                sampleTime: Float = 0.0,
                sampleDuration: Float = 0.0,
                isTransitionBlend: Bool = false) {
        self.tickID = tickID
        self.currentStateID = currentStateID
        self.currentStateName = currentStateName
        self.nextStateID = nextStateID
        self.nextStateName = nextStateName
        self.authoredUsesRootMotion = authoredUsesRootMotion
        self.stateWantsRootMotion = stateWantsRootMotion
        self.effectiveUsesRootMotion = effectiveUsesRootMotion
        self.sampleHasNonZeroDelta = sampleHasNonZeroDelta
        self.rootMotionSampleValid = rootMotionSampleValid
        self.rootMotionTrackConsumed = rootMotionTrackConsumed
        self.translationSourceJointIndex = translationSourceJointIndex
        self.translationSourceJointName = translationSourceJointName
        self.rotationSourceJointIndex = rotationSourceJointIndex
        self.rotationSourceJointName = rotationSourceJointName
        self.localRootDeltaTranslation = localRootDeltaTranslation
        self.worldRootDeltaTranslation = worldRootDeltaTranslation
        self.rootDeltaRotation = TransformMath.normalizedQuaternion(rootDeltaRotation)
        self.sampleTime = sampleTime
        self.sampleDuration = sampleDuration
        self.isTransitionBlend = isTransitionBlend
    }
}

public struct AnimationPoseRuntimeState {
    public var sampleTime: Float
    public var sampleDuration: Float
    public var localPose: [TransformComponent]
    public var globalPose: [TransformComponent]
    public var rootMotionDelta: RootMotionDelta
    public var rootMotionSample: RootMotionRuntimeSample?
    public var usesRootMotion: Bool
    public var currentStateName: String
    public var rootMotionBoneName: String
    public var rootMotionJointIndex: Int
    public var rootMotionTrackConsumed: Bool
    public var rootMotionTranslationBoneName: String
    public var rootMotionTranslationJointIndex: Int
    public var rootMotionRotationBoneName: String
    public var rootMotionRotationJointIndex: Int
    public var rootMotionConsumeBoneName: String
    public var rootMotionConsumeJointIndex: Int
    public var fixedTickRuntimeSnapshot: AnimationFixedTickRuntimeSnapshot?

    public init(sampleTime: Float = 0.0,
                sampleDuration: Float = 0.0,
                localPose: [TransformComponent] = [],
                globalPose: [TransformComponent] = [],
                rootMotionDelta: RootMotionDelta = .zero,
                rootMotionSample: RootMotionRuntimeSample? = nil,
                usesRootMotion: Bool = false,
                currentStateName: String = "",
                rootMotionBoneName: String = "",
                rootMotionJointIndex: Int = -1,
                rootMotionTrackConsumed: Bool = false,
                rootMotionTranslationBoneName: String = "",
                rootMotionTranslationJointIndex: Int = -1,
                rootMotionRotationBoneName: String = "",
                rootMotionRotationJointIndex: Int = -1,
                rootMotionConsumeBoneName: String = "",
                rootMotionConsumeJointIndex: Int = -1,
                fixedTickRuntimeSnapshot: AnimationFixedTickRuntimeSnapshot? = nil) {
        self.sampleTime = sampleTime
        self.sampleDuration = sampleDuration
        self.localPose = localPose
        self.globalPose = globalPose
        self.rootMotionDelta = rootMotionDelta
        self.rootMotionSample = rootMotionSample
        self.usesRootMotion = usesRootMotion
        self.currentStateName = currentStateName
        self.rootMotionBoneName = rootMotionBoneName
        self.rootMotionJointIndex = rootMotionJointIndex
        self.rootMotionTrackConsumed = rootMotionTrackConsumed
        self.rootMotionTranslationBoneName = rootMotionTranslationBoneName
        self.rootMotionTranslationJointIndex = rootMotionTranslationJointIndex
        self.rootMotionRotationBoneName = rootMotionRotationBoneName
        self.rootMotionRotationJointIndex = rootMotionRotationJointIndex
        self.rootMotionConsumeBoneName = rootMotionConsumeBoneName
        self.rootMotionConsumeJointIndex = rootMotionConsumeJointIndex
        self.fixedTickRuntimeSnapshot = fixedTickRuntimeSnapshot
    }
}

public enum AnimatorEvaluationMode: UInt32, Codable {
    case clip = 0
    case graph = 1
}

public struct AnimationGraphDebugTraceEntry {
    public var nodeID: UUID
    public var nodeType: String
    public var nodeTitle: String
    public var outputSummary: String

    public init(nodeID: UUID,
                nodeType: String,
                nodeTitle: String,
                outputSummary: String) {
        self.nodeID = nodeID
        self.nodeType = nodeType
        self.nodeTitle = nodeTitle
        self.outputSummary = outputSummary
    }
}

public struct AnimationGraphRuntimeInstanceState {
    public var graphHandle: AnimationGraphHandle?
    public var floatParameterValues: [Float]
    public var boolParameterValues: [Bool]
    public var intParameterValues: [Int]
    public var triggerParameterValues: [Bool]
    public var floatLocalVariableValues: [Float]
    public var boolLocalVariableValues: [Bool]
    public var intLocalVariableValues: [Int]
    public var currentStateNodeID: UUID?
    public var nextStateNodeID: UUID?
    public var transitionElapsedSeconds: Float
    public var transitionDurationSeconds: Float
    public var nodeLocalTimes: [UUID: Float]
    public var triggerLatchedParameterIndices: Set<Int>
    public var stateMachineCurrentStateByNodeID: [UUID: UUID]
    public var stateMachineNextStateByNodeID: [UUID: UUID]
    public var stateMachineTransitionElapsedByNodeID: [UUID: Float]
    public var stateMachineTransitionDurationByNodeID: [UUID: Float]
    public var stateMachineTransitionSynchronizeByNodeID: [UUID: Bool]
    public var stateMachineStateElapsedByNodeID: [UUID: Float]
    public var captureDebugTrace: Bool
    public var debugTraceEntries: [AnimationGraphDebugTraceEntry]

    public init(graphHandle: AnimationGraphHandle? = nil,
                floatParameterValues: [Float] = [],
                boolParameterValues: [Bool] = [],
                intParameterValues: [Int] = [],
                triggerParameterValues: [Bool] = [],
                floatLocalVariableValues: [Float] = [],
                boolLocalVariableValues: [Bool] = [],
                intLocalVariableValues: [Int] = [],
                currentStateNodeID: UUID? = nil,
                nextStateNodeID: UUID? = nil,
                transitionElapsedSeconds: Float = 0.0,
                transitionDurationSeconds: Float = 0.0,
                nodeLocalTimes: [UUID: Float] = [:],
                triggerLatchedParameterIndices: Set<Int> = [],
                stateMachineCurrentStateByNodeID: [UUID: UUID] = [:],
                stateMachineNextStateByNodeID: [UUID: UUID] = [:],
                stateMachineTransitionElapsedByNodeID: [UUID: Float] = [:],
                stateMachineTransitionDurationByNodeID: [UUID: Float] = [:],
                stateMachineTransitionSynchronizeByNodeID: [UUID: Bool] = [:],
                stateMachineStateElapsedByNodeID: [UUID: Float] = [:],
                captureDebugTrace: Bool = false,
                debugTraceEntries: [AnimationGraphDebugTraceEntry] = []) {
        self.graphHandle = graphHandle
        self.floatParameterValues = floatParameterValues
        self.boolParameterValues = boolParameterValues
        self.intParameterValues = intParameterValues
        self.triggerParameterValues = triggerParameterValues
        self.floatLocalVariableValues = floatLocalVariableValues
        self.boolLocalVariableValues = boolLocalVariableValues
        self.intLocalVariableValues = intLocalVariableValues
        self.currentStateNodeID = currentStateNodeID
        self.nextStateNodeID = nextStateNodeID
        self.transitionElapsedSeconds = transitionElapsedSeconds
        self.transitionDurationSeconds = transitionDurationSeconds
        self.nodeLocalTimes = nodeLocalTimes
        self.triggerLatchedParameterIndices = triggerLatchedParameterIndices
        self.stateMachineCurrentStateByNodeID = stateMachineCurrentStateByNodeID
        self.stateMachineNextStateByNodeID = stateMachineNextStateByNodeID
        self.stateMachineTransitionElapsedByNodeID = stateMachineTransitionElapsedByNodeID
        self.stateMachineTransitionDurationByNodeID = stateMachineTransitionDurationByNodeID
        self.stateMachineTransitionSynchronizeByNodeID = stateMachineTransitionSynchronizeByNodeID
        self.stateMachineStateElapsedByNodeID = stateMachineStateElapsedByNodeID
        self.captureDebugTrace = captureDebugTrace
        self.debugTraceEntries = debugTraceEntries
    }

    public mutating func resetDefaults(from compiledGraph: CompiledAnimationGraph, graphHandle: AnimationGraphHandle) {
        self.graphHandle = graphHandle
        let parameterCount = compiledGraph.parameters.count
        let localVariableCount = compiledGraph.localVariables.count
        self.floatParameterValues = Array(repeating: 0.0, count: parameterCount)
        self.boolParameterValues = Array(repeating: false, count: parameterCount)
        self.intParameterValues = Array(repeating: 0, count: parameterCount)
        self.triggerParameterValues = Array(repeating: false, count: parameterCount)
        self.floatLocalVariableValues = Array(repeating: 0.0, count: localVariableCount)
        self.boolLocalVariableValues = Array(repeating: false, count: localVariableCount)
        self.intLocalVariableValues = Array(repeating: 0, count: localVariableCount)
        for parameter in compiledGraph.parameters {
            let index = parameter.index
            guard index >= 0, index < parameterCount else { continue }
            switch parameter.type {
            case .float:
                self.floatParameterValues[index] = parameter.defaultFloat
            case .bool:
                self.boolParameterValues[index] = parameter.defaultBool
            case .int:
                self.intParameterValues[index] = parameter.defaultInt
            case .trigger:
                self.triggerParameterValues[index] = false
            }
        }
        for localVariable in compiledGraph.localVariables {
            let index = localVariable.index
            guard index >= 0, index < localVariableCount else { continue }
            switch localVariable.type {
            case .float:
                self.floatLocalVariableValues[index] = localVariable.defaultFloat
            case .bool:
                self.boolLocalVariableValues[index] = localVariable.defaultBool
            case .int:
                self.intLocalVariableValues[index] = localVariable.defaultInt
            }
        }
        self.currentStateNodeID = nil
        self.nextStateNodeID = nil
        self.transitionElapsedSeconds = 0.0
        self.transitionDurationSeconds = 0.0
        self.nodeLocalTimes = [:]
        self.triggerLatchedParameterIndices = []
        self.stateMachineCurrentStateByNodeID = [:]
        self.stateMachineNextStateByNodeID = [:]
        self.stateMachineTransitionElapsedByNodeID = [:]
        self.stateMachineTransitionDurationByNodeID = [:]
        self.stateMachineTransitionSynchronizeByNodeID = [:]
        self.stateMachineStateElapsedByNodeID = [:]
        self.debugTraceEntries = []
    }

    public func hasParameterStorage(count: Int) -> Bool {
        return hasStorage(parameterCount: count, localVariableCount: floatLocalVariableValues.count)
    }

    public func hasStorage(parameterCount: Int, localVariableCount: Int) -> Bool {
        return floatParameterValues.count == parameterCount &&
            boolParameterValues.count == parameterCount &&
            intParameterValues.count == parameterCount &&
            triggerParameterValues.count == parameterCount &&
            floatLocalVariableValues.count == localVariableCount &&
            boolLocalVariableValues.count == localVariableCount &&
            intLocalVariableValues.count == localVariableCount
    }

    public mutating func setFloat(index: Int, value: Float) {
        guard index >= 0, index < floatParameterValues.count else { return }
        floatParameterValues[index] = value
    }

    public mutating func setBool(index: Int, value: Bool) {
        guard index >= 0, index < boolParameterValues.count else { return }
        boolParameterValues[index] = value
    }

    public mutating func setInt(index: Int, value: Int) {
        guard index >= 0, index < intParameterValues.count else { return }
        intParameterValues[index] = value
    }

    public mutating func setTrigger(index: Int) {
        guard index >= 0, index < triggerParameterValues.count else { return }
        triggerParameterValues[index] = true
        triggerLatchedParameterIndices.insert(index)
    }

    public mutating func clearTrigger(index: Int) {
        guard index >= 0, index < triggerParameterValues.count else { return }
        triggerParameterValues[index] = false
        triggerLatchedParameterIndices.remove(index)
    }

    public mutating func setLocalFloat(index: Int, value: Float) {
        guard index >= 0, index < floatLocalVariableValues.count else { return }
        floatLocalVariableValues[index] = value
    }

    public mutating func setLocalBool(index: Int, value: Bool) {
        guard index >= 0, index < boolLocalVariableValues.count else { return }
        boolLocalVariableValues[index] = value
    }

    public mutating func setLocalInt(index: Int, value: Int) {
        guard index >= 0, index < intLocalVariableValues.count else { return }
        intLocalVariableValues[index] = value
    }
}

public struct AnimatorComponent {
    public var evaluationMode: AnimatorEvaluationMode
    public var clipHandle: AssetHandle?
    public var graphHandle: AnimationGraphHandle?
    public var playbackTime: Float
    public var playbackSpeed: Float
    public var isPlaying: Bool
    public var isLooping: Bool
    public var isControllerDriven: Bool
    public var enableRootMotion: Bool
    public var graphRuntimeState: AnimationGraphRuntimeInstanceState?
    public var poseRuntimeState: AnimationPoseRuntimeState?
    /// Canonical latest fixed/variable animation tick output for this animator.
    /// Producer-owned by `AnimationSystem`; consumer systems must not recompute or mutate.
    public var latestAnimationTickResult: AnimationTickResult?

    public init(evaluationMode: AnimatorEvaluationMode = .clip,
                clipHandle: AssetHandle? = nil,
                graphHandle: AnimationGraphHandle? = nil,
                playbackTime: Float = 0.0,
                playbackSpeed: Float = 1.0,
                isPlaying: Bool = true,
                isLooping: Bool = true,
                isControllerDriven: Bool = false,
                enableRootMotion: Bool = true,
                graphRuntimeState: AnimationGraphRuntimeInstanceState? = nil,
                poseRuntimeState: AnimationPoseRuntimeState? = nil,
                latestAnimationTickResult: AnimationTickResult? = nil) {
        self.evaluationMode = evaluationMode
        self.clipHandle = clipHandle
        self.graphHandle = graphHandle
        self.playbackTime = playbackTime
        self.playbackSpeed = playbackSpeed
        self.isPlaying = isPlaying
        self.isLooping = isLooping
        self.isControllerDriven = isControllerDriven
        self.enableRootMotion = enableRootMotion
        self.graphRuntimeState = graphRuntimeState
        self.poseRuntimeState = poseRuntimeState
        self.latestAnimationTickResult = latestAnimationTickResult
    }
}

public struct AudioSourceComponent {
    public var isEnabled: Bool
    public var audioAssetHandle: AssetHandle?
    public var volume: Float
    public var pitch: Float
    public var isLooping: Bool
    public var playOnAwake: Bool
    public var isSpatialized: Bool
    public var maxDistance: Float
    public var isPlaying: Bool

    public init(isEnabled: Bool = true,
                audioAssetHandle: AssetHandle? = nil,
                volume: Float = 1.0,
                pitch: Float = 1.0,
                isLooping: Bool = false,
                playOnAwake: Bool = false,
                isSpatialized: Bool = true,
                maxDistance: Float = 25.0,
                isPlaying: Bool = false) {
        self.isEnabled = isEnabled
        self.audioAssetHandle = audioAssetHandle
        self.volume = volume
        self.pitch = pitch
        self.isLooping = isLooping
        self.playOnAwake = playOnAwake
        self.isSpatialized = isSpatialized
        self.maxDistance = maxDistance
        self.isPlaying = isPlaying
    }
}

public struct AudioListenerComponent {
    public var isEnabled: Bool
    public var isPrimary: Bool

    public init(isEnabled: Bool = true,
                isPrimary: Bool = true) {
        self.isEnabled = isEnabled
        self.isPrimary = isPrimary
    }
}

public struct MaterialComponent {
    public var materialHandle: AssetHandle?

    public init(materialHandle: AssetHandle? = nil) {
        self.materialHandle = materialHandle
    }
}

public enum ProjectionType: UInt32 {
    case perspective = 0
    case orthographic = 1
}

public struct CameraComponent {
    public var fovDegrees: Float
    public var orthoSize: Float
    public var nearPlane: Float
    public var farPlane: Float
    public var projectionType: ProjectionType
    public var isPrimary: Bool
    public var isEditor: Bool
    public var autoExposureEnabled: Bool
    public var manualExposure: Float
    public var exposureCompensation: Float
    public var autoExposureMin: Float
    public var autoExposureMax: Float
    public var adaptationSpeed: Float

    public init(
        fovDegrees: Float = 45.0,
        orthoSize: Float = 10.0,
        nearPlane: Float = 0.1,
        farPlane: Float = 1000.0,
        projectionType: ProjectionType = .perspective,
        isPrimary: Bool = true,
        isEditor: Bool = true,
        autoExposureEnabled: Bool = true,
        manualExposure: Float = 1.0,
        exposureCompensation: Float = 0.0,
        autoExposureMin: Float = 0.03,
        autoExposureMax: Float = 8.0,
        adaptationSpeed: Float = 2.0
    ) {
        self.fovDegrees = fovDegrees
        self.orthoSize = orthoSize
        self.nearPlane = nearPlane
        self.farPlane = farPlane
        self.projectionType = projectionType
        self.isPrimary = isPrimary
        self.isEditor = isEditor
        self.autoExposureEnabled = autoExposureEnabled
        self.manualExposure = manualExposure
        self.exposureCompensation = exposureCompensation
        self.autoExposureMin = autoExposureMin
        self.autoExposureMax = autoExposureMax
        self.adaptationSpeed = adaptationSpeed
    }
}

public enum LightType {
    case point
    case spot
    case directional
}

public struct LightComponent {
    public var type: LightType
    public var data: LightData
    /// Direction the light rays travel (from the light toward the scene).
    /// For directional lights, runtime derives this from TransformComponent.rotation.
    /// This value is retained for backward compatibility/fallback serialization.
    public var direction: SIMD3<Float>
    public var range: Float
    public var innerConeCos: Float
    public var outerConeCos: Float
    public var castsShadows: Bool

    public init(
        type: LightType = .point,
        data: LightData = LightData(),
        direction: SIMD3<Float> = SIMD3<Float>(0, -1, 0),
        range: Float = 0.0,
        innerConeCos: Float = 0.95,
        outerConeCos: Float = 0.9,
        castsShadows: Bool = false
    ) {
        self.type = type
        self.data = data
        self.direction = direction
        self.range = range
        self.innerConeCos = innerConeCos
        self.outerConeCos = outerConeCos
        self.castsShadows = castsShadows
    }
}

public struct LightOrbitComponent {
    public var centerEntityId: UUID?
    public var radius: Float
    public var speed: Float
    public var height: Float
    public var phase: Float
    public var affectsDirection: Bool

    public init(
        centerEntityId: UUID? = nil,
        radius: Float = 1.0,
        speed: Float = 1.0,
        height: Float = 0.0,
        phase: Float = 0.0,
        affectsDirection: Bool = true
    ) {
        self.centerEntityId = centerEntityId
        self.radius = radius
        self.speed = speed
        self.height = height
        self.phase = phase
        self.affectsDirection = affectsDirection
    }
}

public struct SkyComponent {
    public var environmentMapHandle: AssetHandle?

    public init(environmentMapHandle: AssetHandle? = nil) {
        self.environmentMapHandle = environmentMapHandle
    }
}

public enum ReflectionProbeRebuildMode: UInt32, Codable {
    case manual = 0
    case onPlay = 1
}

public enum ReflectionProbeRuntimeStatus: Int32, CaseIterable {
    case idle = 0
    case queued = 1
    case capturing = 2
    case filtering = 3
    case ready = 4
    case failed = 5
}

public struct ReflectionProbeComponent: Equatable {
    public var enabled: Bool
    public var intensity: Float
    /// Probe-local half extents for the authored influence box, reused later for box projection.
    public var boxExtents: SIMD3<Float>
    /// Soft edge distance used to fade from this probe back to the global reflection fallback.
    public var blendDistance: Float
    /// Higher priority wins when multiple authored probes overlap the same region.
    public var priority: Int32
    /// Requested cubemap face resolution for scene capture.
    public var captureResolution: Int32
    /// Controls whether the probe rebuilds only on demand or when play mode starts.
    public var rebuildMode: ReflectionProbeRebuildMode
    /// Whether the scene sky contributes to the captured probe.
    public var includeSky: Bool

    public init(
        enabled: Bool = true,
        intensity: Float = 1.0,
        boxExtents: SIMD3<Float> = SIMD3<Float>(5.0, 5.0, 5.0),
        blendDistance: Float = 1.0,
        priority: Int32 = 0,
        captureResolution: Int32 = 128,
        rebuildMode: ReflectionProbeRebuildMode = .onPlay,
        includeSky: Bool = true
    ) {
        self.enabled = enabled
        self.intensity = intensity
        self.boxExtents = boxExtents
        self.blendDistance = blendDistance
        self.priority = priority
        self.captureResolution = captureResolution
        self.rebuildMode = rebuildMode
        self.includeSky = includeSky
    }
}

public enum SkyMode: UInt32 {
    case hdri = 0
    case procedural = 1
}

public struct SkyLightComponent: Equatable {
    public var mode: SkyMode
    public var enabled: Bool
    public var intensity: Float
    public var skyTint: SIMD3<Float>
    public var turbidity: Float
    public var azimuthDegrees: Float
    public var elevationDegrees: Float
    public var sunSizeDegrees: Float
    public var zenithTint: SIMD3<Float>
    public var horizonTint: SIMD3<Float>
    public var gradientStrength: Float
    public var hazeDensity: Float
    public var hazeFalloff: Float
    public var hazeHeight: Float
    public var ozoneStrength: Float
    public var ozoneTint: SIMD3<Float>
    public var sunHaloSize: Float
    public var sunHaloIntensity: Float
    public var sunHaloSoftness: Float
    public var cloudsEnabled: Bool
    public var cloudsCoverage: Float
    public var cloudsSoftness: Float
    public var cloudsScale: Float
    public var cloudsSpeed: Float
    public var cloudsWindDirection: SIMD2<Float>
    public var cloudsHeight: Float
    public var cloudsThickness: Float
    public var cloudsBrightness: Float
    public var cloudsSunInfluence: Float
    public var hdriHandle: AssetHandle?
    public var iblEnvironmentHandle: AssetHandle?
    public var iblIrradianceHandle: AssetHandle?
    public var iblPrefilteredHandle: AssetHandle?
    public var iblBrdfHandle: AssetHandle?
    public var needsRebuild: Bool
    public var rebuildRequested: Bool
    public var realtimeUpdate: Bool
    public var lastRebuildTime: Double

    public init(
        mode: SkyMode = .hdri,
        enabled: Bool = true,
        intensity: Float = 1.0,
        skyTint: SIMD3<Float> = SIMD3<Float>(1.0, 1.0, 1.0),
        turbidity: Float = 2.0,
        azimuthDegrees: Float = 0.0,
        elevationDegrees: Float = 30.0,
        sunSizeDegrees: Float = 0.535,
        zenithTint: SIMD3<Float> = SIMD3<Float>(0.24, 0.45, 0.95),
        horizonTint: SIMD3<Float> = SIMD3<Float>(0.95, 0.75, 0.55),
        gradientStrength: Float = 1.0,
        hazeDensity: Float = 0.35,
        hazeFalloff: Float = 2.2,
        hazeHeight: Float = 0.0,
        ozoneStrength: Float = 0.35,
        ozoneTint: SIMD3<Float> = SIMD3<Float>(0.55, 0.7, 1.0),
        sunHaloSize: Float = 2.5,
        sunHaloIntensity: Float = 0.5,
        sunHaloSoftness: Float = 1.2,
        cloudsEnabled: Bool = false,
        cloudsCoverage: Float = 0.35,
        cloudsSoftness: Float = 0.6,
        cloudsScale: Float = 1.0,
        cloudsSpeed: Float = 0.02,
        cloudsWindDirection: SIMD2<Float> = SIMD2<Float>(1.0, 0.0),
        cloudsHeight: Float = 0.25,
        cloudsThickness: Float = 0.35,
        cloudsBrightness: Float = 1.0,
        cloudsSunInfluence: Float = 1.0,
        hdriHandle: AssetHandle? = nil,
        iblEnvironmentHandle: AssetHandle? = nil,
        iblIrradianceHandle: AssetHandle? = nil,
        iblPrefilteredHandle: AssetHandle? = nil,
        iblBrdfHandle: AssetHandle? = nil,
        needsRebuild: Bool = true,
        rebuildRequested: Bool = false,
        realtimeUpdate: Bool = true,
        lastRebuildTime: Double = 0.0
    ) {
        self.mode = mode
        self.enabled = enabled
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
        self.cloudsWindDirection = cloudsWindDirection
        self.cloudsHeight = cloudsHeight
        self.cloudsThickness = cloudsThickness
        self.cloudsBrightness = cloudsBrightness
        self.cloudsSunInfluence = cloudsSunInfluence
        self.hdriHandle = hdriHandle
        self.iblEnvironmentHandle = iblEnvironmentHandle
        self.iblIrradianceHandle = iblIrradianceHandle
        self.iblPrefilteredHandle = iblPrefilteredHandle
        self.iblBrdfHandle = iblBrdfHandle
        self.needsRebuild = needsRebuild
        self.rebuildRequested = rebuildRequested
        self.realtimeUpdate = realtimeUpdate
        self.lastRebuildTime = lastRebuildTime
    }
}

public struct SkyLightTag {
    public init() {}
}

public struct SkySunTag {
    public init() {}
}
