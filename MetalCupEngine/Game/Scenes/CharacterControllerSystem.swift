/// CharacterControllerSystem.swift
/// Owns character controller runtime state, input queues, and fixed-step updates.
/// Created by Kaden Cringle.

import Foundation
import simd

public struct CharacterTerrainSample {
    public var normal: SIMD3<Float>
    public var height: Float
    public var material: UInt32?

    public init(normal: SIMD3<Float> = SIMD3<Float>(0.0, 1.0, 0.0),
                height: Float = 0.0,
                material: UInt32? = nil) {
        self.normal = normal
        self.height = height
        self.material = material
    }
}

public struct CharacterGroundState {
    public var isGrounded: Bool
    public var groundNormal: SIMD3<Float>
    public var groundBodyId: UInt64
    public var groundVelocity: SIMD3<Float>
    public var isMovingPlatform: Bool
    public var terrainSample: CharacterTerrainSample?

    public init(isGrounded: Bool = false,
                groundNormal: SIMD3<Float> = SIMD3<Float>(0.0, 1.0, 0.0),
                groundBodyId: UInt64 = 0,
                groundVelocity: SIMD3<Float> = .zero,
                isMovingPlatform: Bool = false,
                terrainSample: CharacterTerrainSample? = nil) {
        self.isGrounded = isGrounded
        self.groundNormal = groundNormal
        self.groundBodyId = groundBodyId
        self.groundVelocity = groundVelocity
        self.isMovingPlatform = isMovingPlatform
        self.terrainSample = terrainSample
    }
}

public struct CharacterLocomotionOutput {
    public var desiredVelocity: SIMD3<Float>
    public var actualVelocity: SIMD3<Float>
    public var grounded: Bool
    public var groundNormal: SIMD3<Float>
    public var groundBodyId: UInt64
    public var rootMotionDeltaMagnitude: Float
    public var rootMotionEnabled: Bool
    public var rootMotionActive: Bool
    public var rootMotionStateName: String

    public init(desiredVelocity: SIMD3<Float> = .zero,
                actualVelocity: SIMD3<Float> = .zero,
                grounded: Bool = false,
                groundNormal: SIMD3<Float> = SIMD3<Float>(0.0, 1.0, 0.0),
                groundBodyId: UInt64 = 0,
                rootMotionDeltaMagnitude: Float = 0.0,
                rootMotionEnabled: Bool = false,
                rootMotionActive: Bool = false,
                rootMotionStateName: String = "") {
        self.desiredVelocity = desiredVelocity
        self.actualVelocity = actualVelocity
        self.grounded = grounded
        self.groundNormal = groundNormal
        self.groundBodyId = groundBodyId
        self.rootMotionDeltaMagnitude = rootMotionDeltaMagnitude
        self.rootMotionEnabled = rootMotionEnabled
        self.rootMotionActive = rootMotionActive
        self.rootMotionStateName = rootMotionStateName
    }
}

public struct CharacterControllerDebugVisualization {
    public var enabled: Bool
    public var groundNormal: SIMD3<Float>
    public var basisForward: SIMD3<Float>
    public var basisRight: SIMD3<Float>

    public init(enabled: Bool = false,
                groundNormal: SIMD3<Float> = SIMD3<Float>(0.0, 1.0, 0.0),
                basisForward: SIMD3<Float> = SIMD3<Float>(0.0, 0.0, 1.0),
                basisRight: SIMD3<Float> = SIMD3<Float>(1.0, 0.0, 0.0)) {
        self.enabled = enabled
        self.groundNormal = groundNormal
        self.basisForward = basisForward
        self.basisRight = basisRight
    }
}

public struct CharacterControllerPreStepContext {
    public let scene: EngineScene
    public let entity: Entity
    public let fixedDelta: Float
    public let desiredHorizontalVelocity: SIMD3<Float>
    public let groundState: CharacterGroundState
}

public struct CharacterControllerPostStepContext {
    public let scene: EngineScene
    public let entity: Entity
    public let fixedDelta: Float
    public let locomotion: CharacterLocomotionOutput
    public let groundState: CharacterGroundState
}

public protocol CharacterGroundProvider {
    func resolveGround(scene: EngineScene,
                       physicsSystem: PhysicsSystem,
                       entity: Entity,
                       controller: CharacterControllerComponent,
                       characterHandle: UInt64) -> CharacterGroundState
}

public protocol CharacterControllerStepHook {
    func preStep(_ context: CharacterControllerPreStepContext)
    func postStep(_ context: CharacterControllerPostStepContext)
}

public final class CharacterControllerSystem {
    private struct LocalMovementIntent {
        let raw: SIMD2<Float>
        let direction: SIMD2<Float>
        let magnitude: Float
    }

    private struct PlanarMovementBasis {
        let forward: SIMD3<Float>
        let right: SIMD3<Float>
    }

    private struct LocomotionIntent {
        let rawInput: SIMD2<Float>
        let lookInput: SIMD2<Float>
        let sprinting: Bool
        let local: LocalMovementIntent
    }

    private struct AnimationFrameFetchResult {
        let tickResult: AnimationTickResult?
        let snapshot: AnimationFixedTickRuntimeSnapshot
        let enableRootMotion: Bool
        let jumpTriggerLatched: Bool
        let consumeJointName: String
        let consumeJointIndex: Int
        let sourceEntityID: UUID
        let sourceWorldScale: Float
    }

    private struct AuthorityResolutionResult {
        let mode: LocomotionAuthorityMode
        let rootMotionActive: Bool
        let reason: String
    }

    private struct AuthorityStabilityState {
        var mode: LocomotionAuthorityMode
        var rootMotionActive: Bool
        var pendingDropTicks: Int
    }

    private struct CharacterMotorCommand {
        let desiredHorizontalVelocity: SIMD3<Float>
        let rootMotionWorldDelta: SIMD3<Float>
        let rootMotionLocalDelta: SIMD3<Float>
        let usesRootMotion: Bool
        let bypassedInputDirectionReconstruction: Bool
    }

    private struct CharacterInterpolationState {
        var prevPosition: SIMD3<Float>
        var currPosition: SIMD3<Float>
        var prevRotation: SIMD4<Float>
        var currRotation: SIMD4<Float>
        var initialized: Bool
    }

    private struct PivotInterpolationState {
        var prevRotation: SIMD4<Float>
        var currRotation: SIMD4<Float>
        var initialized: Bool
    }

    private var characterMoveRequests: [UUID: SIMD2<Float>] = [:]
    private var characterLookRequests: [UUID: SIMD2<Float>] = [:]
    private var characterSprintRequests: [UUID: Bool] = [:]
    private var characterJumpRequests: Set<UUID> = []
    private var characterHandlesByEntity: [UUID: UInt64] = [:]
    private var characterInterpolationStates: [UUID: CharacterInterpolationState] = [:]
    private var pivotInterpolationStates: [UUID: PivotInterpolationState] = [:]
    private var renderInterpolationAlpha: Float = 0.0
    private var renderWorldTransformCache: [UUID: TransformComponent] = [:]
    private var locomotionOutputsByEntity: [UUID: CharacterLocomotionOutput] = [:]
    private var debugVisualizationByEntity: [UUID: CharacterControllerDebugVisualization] = [:]
    private struct RuntimeAnimationDiagnosticsState {
        var currentState: String
        var nextState: String
        var authoredUsesRootMotion: Bool
        var stateWantsRootMotion: Bool
        var effectiveUsesRootMotion: Bool
        var sampleHasNonZeroDelta: Bool
        var controllerUsingRootMotion: Bool
        var rootMotionActive: Bool
        var grounded: Bool
        var jumpTriggerLatched: Bool
        var translationSourceJointIndex: Int
        var rotationSourceJointIndex: Int
        var consumeJointIndex: Int
    }
    private struct AnimatorLocomotionParameterState {
        var smoothedSpeed: Float
        var movingLatched: Bool
        var groundedLatched: Bool
        var groundedInitialized: Bool
        var groundedStableTicks: Int
        var airborneStableTicks: Int
    }
    private struct AnimatorParameterWriteResult {
        let wroteMovementSpeed: Bool
        let wroteGrounded: Bool
        let wroteMoving: Bool
        let wroteSprinting: Bool
        let wroteJumpTrigger: Bool
        let animatorEntityID: UUID
    }
    private var runtimeDiagnosticsByEntity: [UUID: RuntimeAnimationDiagnosticsState] = [:]
    private var cameraBasisDebugCounterByEntity: [UUID: Int] = [:]
    private var loggedRootMotionFailureKeys: Set<String> = []
    private var loggedAnimatorResolveFailures: Set<String> = []
    private var consumedRootMotionTickByEntity: [UUID: UInt64] = [:]
    private var timelineSecondsByEntity: [UUID: Float] = [:]
    private var jumpStartEntryTimeByEntity: [UUID: Float] = [:]
    private var jumpImpulseTimeByEntity: [UUID: Float] = [:]
    private var lastCardinalIntentKeyByEntity: [UUID: String] = [:]
    private var animatorLocomotionParameterStateByEntity: [UUID: AnimatorLocomotionParameterState] = [:]
    private var lastAnimatorParameterSignatureByEntity: [UUID: String] = [:]
    private var smoothedFacingDirectionByEntity: [UUID: SIMD3<Float>] = [:]
    private var lastLocomotionAuthorityRootMotionByEntity: [UUID: Bool] = [:]
    private var authorityStabilityByEntity: [UUID: AuthorityStabilityState] = [:]
    private var loggedCanonicalTruthFallbackKeys: Set<String> = []
    private var fixedStepCounter: UInt64 = 0
    private var groundProvider: CharacterGroundProvider = DefaultCharacterGroundProvider()
    private var stepHook: CharacterControllerStepHook?

    public init() {}

    public func enqueueMove(entityId: UUID, direction: SIMD3<Float>) {
        characterMoveRequests[entityId] = SIMD2<Float>(direction.x, direction.z)
    }

    public func enqueueMoveInput(entityId: UUID, input: SIMD2<Float>) {
        characterMoveRequests[entityId] = input
    }

    public func enqueueSprint(entityId: UUID, isSprinting: Bool) {
        characterSprintRequests[entityId] = isSprinting
    }

    public func enqueueLookInput(entityId: UUID, delta: SIMD2<Float>) {
        let previous = characterLookRequests[entityId] ?? .zero
        characterLookRequests[entityId] = previous + delta
    }

    public func enqueueJump(entityId: UUID) {
        characterJumpRequests.insert(entityId)
    }

    public func isGrounded(scene: EngineScene, entityId: UUID) -> Bool {
        guard let entity = scene.ecs.entity(with: entityId),
              let controller = scene.ecs.get(CharacterControllerComponent.self, for: entity) else {
            return false
        }
        return controller.isGrounded
    }

    public func velocity(scene: EngineScene, entityId: UUID) -> SIMD3<Float> {
        guard let entity = scene.ecs.entity(with: entityId),
              let controller = scene.ecs.get(CharacterControllerComponent.self, for: entity) else {
            return .zero
        }
        return controller.velocity
    }

    public func locomotionOutput(entityId: UUID) -> CharacterLocomotionOutput {
        locomotionOutputsByEntity[entityId] ?? CharacterLocomotionOutput()
    }

    public func debugVisualization(entityId: UUID) -> CharacterControllerDebugVisualization {
        debugVisualizationByEntity[entityId] ?? CharacterControllerDebugVisualization()
    }

    public func setDebugDrawEnabled(entityId: UUID, isEnabled: Bool) {
        var state = debugVisualizationByEntity[entityId] ?? CharacterControllerDebugVisualization()
        state.enabled = isEnabled
        debugVisualizationByEntity[entityId] = state
    }

    public func isDebugDrawEnabled(entityId: UUID) -> Bool {
        debugVisualizationByEntity[entityId]?.enabled ?? false
    }

    public func setGroundProvider(_ provider: CharacterGroundProvider?) {
        groundProvider = provider ?? DefaultCharacterGroundProvider()
    }

    public func setStepHook(_ hook: CharacterControllerStepHook?) {
        stepHook = hook
    }

    public func setRenderInterpolationAlpha(_ alpha: Float, scene: EngineScene) {
        renderInterpolationAlpha = simd_clamp(alpha, 0.0, 1.0)
        rebuildRenderWorldTransformCache(scene: scene)
    }

    public func renderWorldTransform(scene: EngineScene, entity: Entity) -> TransformComponent {
        if let cached = renderWorldTransformCache[entity.id] {
            return cached
        }
        return scene.ecs.worldTransform(for: entity)
    }

    public func fixedStep(scene: EngineScene, fixedDelta: Float) {
        fixedStepCounter &+= 1
        guard let physicsSystem = scene.physicsSystem else {
            scene.ecs.viewDeterministic(CharacterControllerComponent.self) { entity, _ in
                guard var controller = scene.ecs.get(CharacterControllerComponent.self, for: entity) else { return }
                controller.characterHandle = 0
                controller.isGrounded = false
                controller.velocity = .zero
                controller.lookInput = .zero
                controller.jumpBufferTimer = 0.0
                controller.jumpConsumedOnGroundContact = false
                scene.ecs.add(controller, to: entity)
            }
            characterHandlesByEntity.removeAll(keepingCapacity: true)
            characterInterpolationStates.removeAll(keepingCapacity: true)
            pivotInterpolationStates.removeAll(keepingCapacity: true)
            renderWorldTransformCache.removeAll(keepingCapacity: true)
            locomotionOutputsByEntity.removeAll(keepingCapacity: true)
            debugVisualizationByEntity.removeAll(keepingCapacity: true)
            consumedRootMotionTickByEntity.removeAll(keepingCapacity: true)
            loggedAnimatorResolveFailures.removeAll(keepingCapacity: true)
            animatorLocomotionParameterStateByEntity.removeAll(keepingCapacity: true)
            lastAnimatorParameterSignatureByEntity.removeAll(keepingCapacity: true)
            smoothedFacingDirectionByEntity.removeAll(keepingCapacity: true)
            lastLocomotionAuthorityRootMotionByEntity.removeAll(keepingCapacity: true)
            authorityStabilityByEntity.removeAll(keepingCapacity: true)
            characterJumpRequests.removeAll(keepingCapacity: true)
            characterLookRequests.removeAll(keepingCapacity: true)
            return
        }

        var activeEntityIDs: Set<UUID> = []
        activeEntityIDs.reserveCapacity(characterHandlesByEntity.count + 8)
        var activePivotEntityIDs: Set<UUID> = []
        activePivotEntityIDs.reserveCapacity(characterHandlesByEntity.count)
        scene.ecs.viewDeterministic(CharacterControllerComponent.self) { entity, component in
            activeEntityIDs.insert(entity.id)
            guard var controller = scene.ecs.get(CharacterControllerComponent.self, for: entity),
                  let transform = scene.ecs.get(TransformComponent.self, for: entity) else { return }
            let rigidbody = scene.ecs.get(RigidbodyComponent.self, for: entity)
            if !component.isEnabled {
                if controller.characterHandle != 0 {
                    physicsSystem.destroyCharacter(handle: controller.characterHandle)
                }
                controller.characterHandle = 0
                controller.runtimeConfigApplied = false
                controller.isGrounded = false
                controller.velocity = .zero
                controller.lookInput = .zero
                controller.jumpBufferTimer = 0.0
                controller.jumpConsumedOnGroundContact = false
                characterInterpolationStates.removeValue(forKey: entity.id)
                if let pivotEntityID = controller.cameraPivotEntityId {
                    pivotInterpolationStates.removeValue(forKey: pivotEntityID)
                }
                locomotionOutputsByEntity[entity.id] = CharacterLocomotionOutput()
                debugVisualizationByEntity[entity.id] = CharacterControllerDebugVisualization(enabled: isDebugDrawEnabled(entityId: entity.id))
                scene.ecs.add(controller, to: entity)
                characterHandlesByEntity.removeValue(forKey: entity.id)
                return
            }

            let timelineSeconds = (timelineSecondsByEntity[entity.id] ?? 0.0) + fixedDelta
            timelineSecondsByEntity[entity.id] = timelineSeconds

            // Stage: IntentCollection
            let intent = collectLocomotionIntent(entityID: entity.id, controller: controller)
            let lookInput = intent.lookInput
            let sprinting = intent.sprinting
            let movementIntent = intent.local
            let rawInputIntent = movementIntent.raw
            let movementMagnitude = movementIntent.magnitude
            let movementDirectionLocal = movementIntent.direction
            let movementIntentLocal = movementIntent.raw
            let sprintIntentActive = sprinting && movementMagnitude > 0.02
            controller.moveInput = movementIntentLocal
            controller.lookInput = lookInput
            controller.wantsSprint = sprinting

            var rootMotionDelta = RootMotionDelta()
            var rootMotionDeltaMagnitude: Float = 0.0
            var rootMotionDeltaRotationMagnitude: Float = 0.0
            var rootMotionEnabled = false
            var rootMotionAuthoredUsesCurrentState = false
            var rootMotionStateWantsPolicy = false
            var rootMotionUsesCurrentState = false
            var rootMotionSampleHasNonZeroDelta = false
            var rootMotionActive = false
            var rootMotionStateName = ""
            var nextStateName = ""
            var jumpTriggerLatched = false
            var jumpStateSampleTime: Float = 0.0
            var jumpStateNormalizedTime: Float = 0.0
            var rootMotionSampleDuration: Float = 0.0
            var rootMotionSampleTickID: UInt64 = 0
            var rootMotionFromTransitionBlend = false
            var rootMotionTranslationSourceJointName = ""
            var rootMotionTranslationSourceJointIndex = -1
            var rootMotionRotationSourceJointName = ""
            var rootMotionRotationSourceJointIndex = -1
            var rootMotionConsumeJointName = ""
            var rootMotionConsumeJointIndex = -1
            var rootMotionSourceEntityID: UUID? = nil
            var rootMotionSourceWorldScale: Float = 1.0
            var authorityMode: LocomotionAuthorityMode = .controllerDriven
            var authorityReason = "no_animation_frame"
            var rootMotionModeForLog: LocomotionAuthorityMode = .controllerDriven
            if let rootMotion = resolveRootMotionForController(scene: scene,
                                                              entity: entity,
                                                              controller: controller,
                                                              currentFixedTick: fixedStepCounter) {
                let snapshot = rootMotion.snapshot
                let canonical = rootMotion.tickResult
                rootMotionEnabled = rootMotion.enableRootMotion
                rootMotionAuthoredUsesCurrentState = canonical?.rootMotion.stateHasAuthoredRootMotion ?? snapshot.authoredUsesRootMotion
                rootMotionStateWantsPolicy = canonical?.rootMotion.isActive ?? snapshot.stateWantsRootMotion
                rootMotionUsesCurrentState = canonical?.rootMotion.isActive ?? snapshot.effectiveUsesRootMotion
                rootMotionSampleHasNonZeroDelta = canonical?.rootMotion.hasAuthoredMotion ?? snapshot.sampleHasNonZeroDelta
                rootMotionStateName = canonical?.stateMachine.activeStateName ?? snapshot.currentStateName
                nextStateName = snapshot.nextStateName
                jumpTriggerLatched = rootMotion.jumpTriggerLatched
                jumpStateSampleTime = canonical?.stateMachine.stateTime ?? snapshot.sampleTime
                rootMotionSampleDuration = max(0.0, snapshot.sampleDuration)
                jumpStateNormalizedTime = runtimeStatePlaybackNormalized(sampleTime: jumpStateSampleTime,
                                                                        duration: rootMotionSampleDuration)
                rootMotionTranslationSourceJointName = snapshot.translationSourceJointName
                rootMotionTranslationSourceJointIndex = snapshot.translationSourceJointIndex
                rootMotionRotationSourceJointName = snapshot.rotationSourceJointName
                rootMotionRotationSourceJointIndex = snapshot.rotationSourceJointIndex
                rootMotionConsumeJointName = rootMotion.consumeJointName
                rootMotionConsumeJointIndex = rootMotion.consumeJointIndex
                rootMotionSourceEntityID = rootMotion.sourceEntityID
                rootMotionSourceWorldScale = rootMotion.sourceWorldScale
                if canonical?.rootMotion.isActive == true,
                   rootMotionTranslationSourceJointIndex >= 0,
                   rootMotionConsumeJointIndex >= 0,
                   rootMotionTranslationSourceJointIndex != rootMotionConsumeJointIndex {
                    let key = "\(entity.id.uuidString)|consumeMismatch|\(rootMotionStateName)|\(rootMotionTranslationSourceJointIndex)->\(rootMotionConsumeJointIndex)"
                    if !loggedRootMotionFailureKeys.contains(key) {
                        loggedRootMotionFailureKeys.insert(key)
                        EngineLoggerContext.log(
                            "AnimCC root-motion channel mismatch entity=\(entity.id.uuidString) state=\(rootMotionStateName.isEmpty ? "<none>" : rootMotionStateName) translationSourceJoint=\(rootMotionTranslationSourceJointName.isEmpty ? "<none>" : rootMotionTranslationSourceJointName)#\(rootMotionTranslationSourceJointIndex) consumeJoint=\(rootMotionConsumeJointName.isEmpty ? "<none>" : rootMotionConsumeJointName)#\(rootMotionConsumeJointIndex)",
                            level: .warning,
                            category: .scene
                        )
                    }
                }

                rootMotionSampleTickID = canonical?.tickIndex ?? snapshot.tickID
                rootMotionFromTransitionBlend = canonical?.stateMachine.isInTransition ?? snapshot.isTransitionBlend
                let authority = resolveLocomotionAuthority(enableRootMotion: rootMotion.enableRootMotion,
                                                           entityID: entity.id,
                                                           animationTick: canonical,
                                                           fallbackSnapshot: snapshot)
                authorityMode = authority.mode
                authorityReason = authority.reason
                rootMotionModeForLog = canonical?.rootMotion.mode ?? authority.mode
                let duplicateConsume = consumedRootMotionTickByEntity[entity.id] == rootMotionSampleTickID
                if duplicateConsume {
                    EngineLoggerContext.log(
                        "AnimCC duplicate root-motion consume blocked entity=\(entity.id.uuidString) tickID=\(rootMotionSampleTickID) state=\(rootMotionStateName)",
                        level: .error,
                        category: .scene
                    )
                } else if authority.rootMotionActive {
                    if let canonical {
                        rootMotionDelta = sanitizeRootMotionDelta(RootMotionDelta(deltaPos: canonical.rootMotion.effectiveDeltaLocal,
                                                                                  deltaRot: canonical.rootMotion.effectiveDeltaRotationLocal.vector))
                    } else {
                        let key = "\(entity.id.uuidString)|canonicalTruthFallback"
                        if !loggedCanonicalTruthFallbackKeys.contains(key) {
                            loggedCanonicalTruthFallbackKeys.insert(key)
                            EngineLoggerContext.log(
                                "AnimCC canonical truth fallback entity=\(entity.id.uuidString) reason=legacySnapshotUsedForRootMotionAuthority",
                                level: .warning,
                                category: .scene
                            )
                        }
                        rootMotionDelta = sanitizeRootMotionDelta(RootMotionDelta(deltaPos: snapshot.localRootDeltaTranslation,
                                                                                  deltaRot: snapshot.rootDeltaRotation))
                    }
                    rootMotionActive = true
                    consumedRootMotionTickByEntity[entity.id] = rootMotionSampleTickID
                } else if rootMotionAuthoredUsesCurrentState && rootMotion.enableRootMotion {
                    EngineLoggerContext.log(
                        "AnimCC root-motion state inactive entity=\(entity.id.uuidString) state=\(rootMotionStateName) stateWantsRootMotion=\(rootMotionStateWantsPolicy) sampleHasNonZeroDelta=\(rootMotionSampleHasNonZeroDelta) consumedTrack=\(snapshot.rootMotionTrackConsumed) transitionBlend=\(rootMotionFromTransitionBlend) reason=\(authorityReason)",
                        level: .debug,
                        category: .scene
                    )
                }
            }
            rootMotionDeltaMagnitude = simd_length(rootMotionDelta.deltaPos)
            rootMotionDeltaRotationMagnitude = rootMotionRotationMagnitudeRadians(rootMotionDelta)
            let previousLocomotionAuthority = lastLocomotionAuthorityRootMotionByEntity[entity.id]
            let previousMode = authorityStabilityByEntity[entity.id]?.mode ?? .none
            let authorityModeChanged = previousMode != authorityMode
            if previousLocomotionAuthority != rootMotionActive || authorityModeChanged {
                lastLocomotionAuthorityRootMotionByEntity[entity.id] = rootMotionActive
                EngineLoggerContext.log(
                    "AnimCC locomotion authority entity=\(entity.id.uuidString) tickID=\(rootMotionSampleTickID) previousMode=\(String(describing: previousMode)) newMode=\(String(describing: authorityMode)) reason=\(authorityReason) rootMotion.isActive=\(rootMotionActive) rootMotion.mode=\(String(describing: rootMotionModeForLog)) movementMagnitude=\(movementMagnitude) state=\(rootMotionStateName.isEmpty ? "<none>" : rootMotionStateName) rootMotionEnabled=\(rootMotionEnabled) sampleHasNonZeroDelta=\(rootMotionSampleHasNonZeroDelta)",
                    level: .debug,
                    category: .scene
                )
            }
            if rootMotionDeltaMagnitude > 1.0 {
                EngineLoggerContext.log(
                    "AnimCC root-motion spike entity=\(entity.id.uuidString) tickID=\(rootMotionSampleTickID) magnitude=\(rootMotionDeltaMagnitude) state=\(rootMotionStateName)",
                    level: .error,
                    category: .scene
                )
            }

            let characterForwardAxis = TransformMath.localForward
            if !controller.lookInitialized {
                if let pivotEntityId = controller.cameraPivotEntityId,
                   let pivotEntity = scene.ecs.entity(with: pivotEntityId),
                   let pivotLocalTransform = scene.ecs.get(TransformComponent.self, for: pivotEntity) {
                    let pivotWorldTransform = scene.ecs.worldTransform(for: pivotEntity)
                    controller.yawRadians = worldYawRadians(from: pivotWorldTransform.rotation, fallback: 0.0)
                    let localForward = simd_quatf(vector: TransformMath.normalizedQuaternion(pivotLocalTransform.rotation)).act(characterForwardAxis)
                    let clampedY = simd_clamp(localForward.y, -1.0, 1.0)
                    controller.pitchRadians = asin(clampedY)
                } else {
                    controller.yawRadians = worldYawRadians(from: transform.rotation, fallback: 0.0)
                    controller.pitchRadians = 0.0
                }
                controller.lookInitialized = true
            }

            let lookSensitivity = max(0.0, controller.lookSensitivity)
            let yawDelta = -lookInput.x * lookSensitivity
            controller.yawRadians = wrapRadians(controller.yawRadians + yawDelta)
            let minPitch = controller.minPitchDegrees * (.pi / 180.0)
            let maxPitch = controller.maxPitchDegrees * (.pi / 180.0)
            controller.pitchRadians = simd_clamp(controller.pitchRadians + lookInput.y * lookSensitivity,
                                                 min(minPitch, maxPitch),
                                                 max(minPitch, maxPitch))
            controller.lookInput = .zero

            let upAxis = SIMD3<Float>(0.0, 1.0, 0.0)
            let normalizedInput = movementDirectionLocal

            let worldTransform = scene.ecs.worldTransform(for: entity)
            let currentWorldRotation = simd_quatf(vector: TransformMath.normalizedQuaternion(worldTransform.rotation))
            var currentForward = currentWorldRotation.act(characterForwardAxis)
            currentForward.y = 0.0
            let currentFacingYaw: Float = {
                if simd_length_squared(currentForward) > 1.0e-6 {
                    let normalizedForward = simd_normalize(currentForward)
                    return atan2(normalizedForward.x, normalizedForward.z)
                }
                return controller.yawRadians
            }()
            // Stage: BasisResolution
            let cameraWorldYawRadians = controller.yawRadians
            let cameraYawQuat = simd_quatf(angle: cameraWorldYawRadians, axis: upAxis)
            let basis = makePlanarMovementBasis(cameraYawQuat: cameraYawQuat, fallbackForward: characterForwardAxis)
            let forward = basis.forward
            let right = basis.right

            var desiredHorizontal = projectLocalIntentDirectionToWorld(normalizedInput, basis: basis)
            if simd_length_squared(desiredHorizontal) > 1.0e-6 {
                desiredHorizontal = simd_normalize(desiredHorizontal)
            }

            let locomotionIntentThreshold: Float = 0.05
            let hasLocomotionIntent = movementMagnitude > locomotionIntentThreshold && simd_length_squared(desiredHorizontal) > 1.0e-6
            if hasLocomotionIntent {
                var smoothedDirection = smoothedFacingDirectionByEntity[entity.id] ?? desiredHorizontal
                if simd_length_squared(smoothedDirection) <= 1.0e-6 {
                    smoothedDirection = desiredHorizontal
                }
                let facingBlendAlpha = simd_clamp(1.0 - exp(-20.0 * fixedDelta), 0.0, 1.0)
                smoothedDirection += (desiredHorizontal - smoothedDirection) * facingBlendAlpha
                if simd_length_squared(smoothedDirection) > 1.0e-6 {
                    smoothedDirection = simd_normalize(smoothedDirection)
                } else {
                    smoothedDirection = desiredHorizontal
                }
                smoothedFacingDirectionByEntity[entity.id] = smoothedDirection
                desiredHorizontal = smoothedDirection
            } else {
                smoothedFacingDirectionByEntity.removeValue(forKey: entity.id)
            }
            var characterYawRadians = currentFacingYaw
            var targetYawRadians = currentFacingYaw
            if rootMotionActive {
                if hasLocomotionIntent {
                    // Root-motion translation remains authoritative, but facing must track
                    // camera-relative intent so grounded locomotion is not direction-locked.
                    targetYawRadians = atan2(desiredHorizontal.x, desiredHorizontal.z)
                    let yawDelta = wrapRadians(targetYawRadians - characterYawRadians)
                    let turnSpeedRadiansPerSecond: Float = 10.0
                    let alpha = simd_clamp(1.0 - exp(-turnSpeedRadiansPerSecond * fixedDelta), 0.0, 1.0)
                    characterYawRadians = wrapRadians(characterYawRadians + yawDelta * alpha)
                } else {
                    // Keep airborne/non-locomotion behavior unchanged: consume authored rotation delta.
                    characterYawRadians = wrapRadians(characterYawRadians + yawDeltaRadians(from: rootMotionDelta.deltaRot))
                    targetYawRadians = characterYawRadians
                }
            } else if hasLocomotionIntent {
                targetYawRadians = atan2(desiredHorizontal.x, desiredHorizontal.z)
                let yawDelta = wrapRadians(targetYawRadians - characterYawRadians)
                let turnSpeedRadiansPerSecond: Float = 10.0
                let alpha = simd_clamp(1.0 - exp(-turnSpeedRadiansPerSecond * fixedDelta), 0.0, 1.0)
                characterYawRadians = wrapRadians(characterYawRadians + yawDelta * alpha)
            }

            let characterYawQuat = simd_quatf(angle: characterYawRadians, axis: upAxis)
            let yawRotation = TransformMath.normalizedQuaternion(characterYawQuat.vector)
            let speedMultiplier = sprintIntentActive ? max(1.0, controller.sprintMultiplier) : 1.0
            let horizontalVelocity = desiredHorizontal * max(0.0, controller.moveSpeed) * speedMultiplier
            let desiredHorizontalVelocity = SIMD3<Float>(horizontalVelocity.x, 0.0, horizontalVelocity.z)
            let controllerScale = worldTransform.scale.x
            let animatorVisualScale = rootMotionSourceWorldScale
            let rawLocalRootDelta = SIMD3<Float>(rootMotionDelta.deltaPos.x, 0.0, rootMotionDelta.deltaPos.z)
            var localRootDelta: SIMD3<Float> = rootMotionActive ? rawLocalRootDelta : .zero
            let extractedRootMotionPlanarMagnitude = rootMotionActive
                ? simd_length(SIMD2<Float>(rawLocalRootDelta.x, rawLocalRootDelta.z)) * max(animatorVisualScale, 0.0)
                : 0.0
            let rootMotionTranslationGatedOff = false
            var scaledRootDelta = rootMotionActive
                ? (localRootDelta * max(animatorVisualScale, 0.0))
                : .zero
            var spikeGuardRejected = false
            if rootMotionActive {
                let localPlanarMagnitude = simd_length(SIMD2<Float>(localRootDelta.x, localRootDelta.z))
                let scaledPlanarMagnitude = simd_length(SIMD2<Float>(scaledRootDelta.x, scaledRootDelta.z))
                let brokenTransitionDelta = rootMotionFromTransitionBlend && scaledPlanarMagnitude > 1.25
                let brokenAnyDelta = scaledPlanarMagnitude > 2.5 || localPlanarMagnitude > 1.0
                if brokenTransitionDelta || brokenAnyDelta {
                    spikeGuardRejected = true
                    localRootDelta = .zero
                    scaledRootDelta = .zero
                }
            }
            // Stage: MotorCommandBuild
            let motorCommand = buildCharacterMotorCommand(desiredHorizontalVelocity: desiredHorizontalVelocity,
                                                          rootMotionLocalDelta: scaledRootDelta,
                                                          rootMotionActive: rootMotionActive,
                                                          characterYawQuat: characterYawQuat)
            let clipWorldRootDelta = motorCommand.rootMotionWorldDelta
            let rootHorizontalDisplacement = motorCommand.usesRootMotion ? motorCommand.rootMotionWorldDelta : .zero
            let worldRootDelta = rootHorizontalDisplacement
            let usedRootMotionFallbackDisplacement = false
            if rootMotionActive && (spikeGuardRejected || fixedStepCounter % 30 == 0) {
                EngineLoggerContext.log(
                    "AnimCC spike guard entity=\(entity.id.uuidString) tickID=\(rootMotionSampleTickID) state=\(rootMotionStateName.isEmpty ? "<none>" : rootMotionStateName) transitionBlend=\(rootMotionFromTransitionBlend) localDelta=\(rawLocalRootDelta) scaledDelta=\(scaledRootDelta) appliedDelta=\(rootHorizontalDisplacement) inputReconstructionBypassed=\(motorCommand.bypassedInputDirectionReconstruction) rejectedOrClamped=\(spikeGuardRejected)",
                    level: spikeGuardRejected ? .warning : .debug,
                    category: .scene
                )
            }
            let createdCharacterThisTick: Bool
            if controller.characterHandle == 0 {
                let desc = PhysicsCharacterCreation(radius: controller.radius,
                                                    height: controller.height,
                                                    position: worldTransform.position,
                                                    rotation: yawRotation,
                                                    collisionLayer: rigidbody?.collisionLayer ?? 0,
                                                    ignoreBodyId: rigidbody?.bodyId ?? 0)
                controller.characterHandle = physicsSystem.createCharacter(desc: desc)
                if controller.characterHandle == 0 {
                    scene.ecs.add(controller, to: entity)
                    return
                }
                createdCharacterThisTick = true
            } else {
                createdCharacterThisTick = false
            }
            characterHandlesByEntity[entity.id] = controller.characterHandle

            let gravityY = controller.useGravityOverride ? controller.gravity : (scene.engineContext?.physicsSettings.gravity.y ?? -9.81)
            let worldUpAxis = SIMD3<Float>(0.0, 1.0, 0.0)
            let slopeRadians = controller.maxSlope * (.pi / 180.0)
            let shouldApplyConfig = createdCharacterThisTick || !controller.runtimeConfigApplied
            if shouldApplyConfig || abs(controller.runtimeAppliedRadius - controller.radius) > 1.0e-4 || abs(controller.runtimeAppliedHeight - controller.height) > 1.0e-4 {
                physicsSystem.setCharacterShapeCapsule(handle: controller.characterHandle, radius: controller.radius, height: controller.height)
                controller.runtimeAppliedRadius = controller.radius
                controller.runtimeAppliedHeight = controller.height
            }
            if shouldApplyConfig || abs(controller.runtimeAppliedMaxSlope - slopeRadians) > 1.0e-4 {
                physicsSystem.setCharacterMaxSlope(handle: controller.characterHandle, radians: slopeRadians)
                controller.runtimeAppliedMaxSlope = slopeRadians
            }
            if shouldApplyConfig || abs(controller.runtimeAppliedStepOffset - controller.stepOffset) > 1.0e-4 {
                physicsSystem.setCharacterStepOffset(handle: controller.characterHandle, meters: max(0.0, controller.stepOffset))
                controller.runtimeAppliedStepOffset = controller.stepOffset
            }
            if shouldApplyConfig || abs(controller.runtimeAppliedGravity - gravityY) > 1.0e-4 {
                physicsSystem.setCharacterGravity(handle: controller.characterHandle, value: gravityY)
                controller.runtimeAppliedGravity = gravityY
            }
            if shouldApplyConfig || abs(controller.runtimeAppliedJumpSpeed - controller.jumpSpeed) > 1.0e-4 {
                physicsSystem.setCharacterJumpSpeed(handle: controller.characterHandle, value: max(0.0, controller.jumpSpeed))
                controller.runtimeAppliedJumpSpeed = controller.jumpSpeed
            }
            if shouldApplyConfig || abs(controller.runtimeAppliedPushStrength - controller.pushStrength) > 1.0e-4 {
                physicsSystem.setCharacterPushStrength(handle: controller.characterHandle, value: max(0.0, controller.pushStrength))
                controller.runtimeAppliedPushStrength = controller.pushStrength
            }
            if shouldApplyConfig {
                physicsSystem.setCharacterUpVector(handle: controller.characterHandle, up: worldUpAxis)
                controller.runtimeConfigApplied = true
            }

            let wasGrounded = physicsSystem.characterIsGrounded(handle: controller.characterHandle)
            let preGroundState = groundProvider.resolveGround(scene: scene,
                                                              physicsSystem: physicsSystem,
                                                              entity: entity,
                                                              controller: controller,
                                                              characterHandle: controller.characterHandle)
            stepHook?.preStep(.init(scene: scene,
                                    entity: entity,
                                    fixedDelta: fixedDelta,
                                    desiredHorizontalVelocity: desiredHorizontalVelocity,
                                    groundState: preGroundState))
            if !wasGrounded {
                controller.jumpConsumedOnGroundContact = false
            }
            let movingJumpLeadTime: Float = 0.08
            let standingJumpLeadTime: Float = 0.18
            let jumpBufferWindow: Float = 0.12
            let movementIntentMagnitude = simd_length(movementIntentLocal)
            let jumpStartLeadTime = movementIntentMagnitude < 0.2 ? standingJumpLeadTime : movingJumpLeadTime
            controller.jumpBufferTimer = max(0.0, controller.jumpBufferTimer - fixedDelta)
            if characterJumpRequests.contains(entity.id) {
                controller.jumpBufferTimer = jumpBufferWindow + jumpStartLeadTime
                EngineLoggerContext.log(
                    "AnimCC jump input entity=\(entity.id.uuidString) jumpType=\(movementIntentMagnitude < 0.2 ? "standing" : "moving") currentState=\(rootMotionStateName.isEmpty ? "<none>" : rootMotionStateName) nextState=\(nextStateName.isEmpty ? "<none>" : nextStateName) grounded=\(wasGrounded) jumpTriggerLatched=\(jumpTriggerLatched) jumpLeadTime=\(jumpStartLeadTime)",
                    level: .debug,
                    category: .scene
                )
            }
            let jumpImpulseReady = controller.jumpBufferTimer > 0.0 && controller.jumpBufferTimer <= jumpBufferWindow
            let standingJump = movementIntentMagnitude < 0.2
            let inJumpStartState = rootMotionStateName.caseInsensitiveCompare("JumpStart") == .orderedSame
            let jumpStartReadyForImpulse = !standingJump
                || ((inJumpStartState && (jumpStateNormalizedTime >= 0.08 || jumpStateSampleTime >= 0.10))
                    || controller.jumpBufferTimer <= 0.01)
            let jumpRequested = wasGrounded
                && !controller.jumpConsumedOnGroundContact
                && jumpImpulseReady
                && jumpStartReadyForImpulse
            var jumpTriggerConsumedThisFrame = false
            if jumpRequested {
                controller.jumpConsumedOnGroundContact = true
                controller.jumpBufferTimer = 0.0
                jumpTriggerConsumedThisFrame = true
                jumpImpulseTimeByEntity[entity.id] = timelineSeconds
                EngineLoggerContext.log(
                    "AnimCC jump impulse entity=\(entity.id.uuidString) state=\(rootMotionStateName.isEmpty ? "<none>" : rootMotionStateName) grounded=\(wasGrounded) impulseTime=\(timelineSeconds)",
                    level: .debug,
                    category: .scene
                )
            }

            var desiredVelocity = desiredHorizontalVelocity
            if !rootMotionActive, !wasGrounded {
                let airControl = simd_clamp(controller.airControl, 0.0, 1.0)
                if airControl < 0.999 {
                    let currentHorizontal = SIMD3<Float>(controller.velocity.x, 0.0, controller.velocity.z)
                    desiredVelocity = simd_mix(currentHorizontal, desiredVelocity, SIMD3<Float>(repeating: airControl))
                }
            }

            // Stage: MotorIntegrate
            let startPosition = worldTransform.position
            var updated = rootMotionActive
                ? physicsSystem.updateCharacterDisplacement(handle: controller.characterHandle,
                                                            dt: fixedDelta,
                                                            desiredDisplacement: rootHorizontalDisplacement,
                                                            jumpRequested: jumpRequested)
                : physicsSystem.updateCharacter(handle: controller.characterHandle,
                                               dt: fixedDelta,
                                               desiredVelocity: desiredVelocity,
                                               jumpRequested: jumpRequested)
            if !updated {
                physicsSystem.destroyCharacter(handle: controller.characterHandle)
                let desc = PhysicsCharacterCreation(radius: controller.radius,
                                                    height: controller.height,
                                                    position: startPosition,
                                                    rotation: yawRotation,
                                                    collisionLayer: rigidbody?.collisionLayer ?? 0,
                                                    ignoreBodyId: rigidbody?.bodyId ?? 0)
                controller.characterHandle = physicsSystem.createCharacter(desc: desc)
                characterHandlesByEntity[entity.id] = controller.characterHandle
                if controller.characterHandle != 0 {
                    controller.runtimeConfigApplied = false
                    updated = rootMotionActive
                        ? physicsSystem.updateCharacterDisplacement(handle: controller.characterHandle,
                                                                    dt: fixedDelta,
                                                                    desiredDisplacement: rootHorizontalDisplacement,
                                                                    jumpRequested: jumpRequested)
                        : physicsSystem.updateCharacter(handle: controller.characterHandle,
                                                       dt: fixedDelta,
                                                       desiredVelocity: desiredVelocity,
                                                       jumpRequested: jumpRequested)
                }
            }
            guard updated,
                  let finalPosition = physicsSystem.characterPosition(handle: controller.characterHandle) else {
                scene.ecs.add(controller, to: entity)
                return
            }

            let resolvedTransform = TransformComponent(position: finalPosition,
                                                       rotation: yawRotation,
                                                       scale: worldTransform.scale)
            _ = scene.transformAuthority.setWorldTransform(entity: entity,
                                                           transform: resolvedTransform,
                                                           source: .characterController)

            let postGroundState = groundProvider.resolveGround(scene: scene,
                                                               physicsSystem: physicsSystem,
                                                               entity: entity,
                                                               controller: controller,
                                                               characterHandle: controller.characterHandle)
            controller.isGrounded = postGroundState.isGrounded
            controller.lastGroundBodyId = postGroundState.groundBodyId
            let actualVelocity = fixedDelta > 1.0e-6
                ? (finalPosition - startPosition) / fixedDelta
                : .zero
            let appliedDisplacement = finalPosition - startPosition
            let appliedDisplacementMagnitude = simd_length(appliedDisplacement)
            let hasInputIntent = movementMagnitude > 0.02
            var parameterState = animatorLocomotionParameterStateByEntity[entity.id]
                ?? AnimatorLocomotionParameterState(smoothedSpeed: 0.0,
                                                    movingLatched: false,
                                                    groundedLatched: postGroundState.isGrounded,
                                                    groundedInitialized: false,
                                                    groundedStableTicks: 0,
                                                    airborneStableTicks: 0)
            let movementSpeedForGraph: Float = {
                if !hasInputIntent {
                    parameterState.smoothedSpeed = 0.0
                    parameterState.movingLatched = false
                    return 0.0
                }
                // Graph uses MovementSpeed transitions at ~0.1 and blend samples at 0 (walk) / 5 (run).
                // Keep walk near the walk sample while still above transition threshold, and drive sprint
                // to the run sample to avoid long-term mixed-loop beat jitter.
                let targetGraphSpeed: Float = sprintIntentActive ? 5.0 : 0.12
                if sprintIntentActive {
                    // Lock sprint to the run sample so we do not drift in/out of walk blending.
                    parameterState.smoothedSpeed = targetGraphSpeed
                } else {
                let speedBlendAlpha = simd_clamp(1.0 - exp(-12.0 * fixedDelta), 0.0, 1.0)
                parameterState.smoothedSpeed += (targetGraphSpeed - parameterState.smoothedSpeed) * speedBlendAlpha
                }
                let movingEnterThreshold: Float = 0.14
                let movingExitThreshold: Float = 0.06
                if !parameterState.movingLatched {
                    parameterState.movingLatched = parameterState.smoothedSpeed >= movingEnterThreshold
                        || movementMagnitude >= movingEnterThreshold
                } else if parameterState.smoothedSpeed <= movingExitThreshold && movementMagnitude <= 0.04 {
                    parameterState.movingLatched = false
                }
                return parameterState.movingLatched ? max(parameterState.smoothedSpeed, 0.12) : 0.0
            }()
            let groundedForGraph: Bool = {
                let sensorGrounded = postGroundState.isGrounded
                if jumpTriggerConsumedThisFrame {
                    parameterState.groundedInitialized = true
                    parameterState.groundedLatched = false
                    parameterState.groundedStableTicks = 0
                    parameterState.airborneStableTicks = 0
                    return false
                }
                if !parameterState.groundedInitialized {
                    parameterState.groundedInitialized = true
                    parameterState.groundedLatched = sensorGrounded
                    parameterState.groundedStableTicks = 0
                    parameterState.airborneStableTicks = 0
                    return parameterState.groundedLatched
                }
                if sensorGrounded {
                    parameterState.groundedStableTicks += 1
                    parameterState.airborneStableTicks = 0
                    if parameterState.groundedStableTicks >= 2 {
                        parameterState.groundedLatched = true
                    }
                } else {
                    parameterState.airborneStableTicks += 1
                    parameterState.groundedStableTicks = 0
                    if parameterState.airborneStableTicks >= 2 {
                        parameterState.groundedLatched = false
                    }
                }
                return parameterState.groundedLatched
            }()
            animatorLocomotionParameterStateByEntity[entity.id] = parameterState
            // Stage: AnimatorParameterAdapt
            let animatorParameterWrite = writeCanonicalAnimatorParameters(scene: scene,
                                                                          controllerEntity: entity,
                                                                          controller: controller,
                                                                          movementSpeed: movementSpeedForGraph,
                                                                          grounded: groundedForGraph,
                                                                          moving: parameterState.movingLatched,
                                                                          sprinting: sprintIntentActive,
                                                                          jumpTriggerEdge: jumpTriggerConsumedThisFrame)
            controller.velocity = actualVelocity
            controller.lookInput = .zero
            let debugEnabled = isDebugDrawEnabled(entityId: entity.id)
            debugVisualizationByEntity[entity.id] = CharacterControllerDebugVisualization(enabled: debugEnabled,
                                                                                          groundNormal: postGroundState.groundNormal,
                                                                                          basisForward: forward,
                                                                                          basisRight: right)
            let debugDesiredVelocity = rootMotionActive && fixedDelta > 1.0e-6
                ? (rootHorizontalDisplacement / fixedDelta)
                : desiredVelocity
            let locomotionOutput = CharacterLocomotionOutput(desiredVelocity: debugDesiredVelocity,
                                                             actualVelocity: actualVelocity,
                                                             grounded: postGroundState.isGrounded,
                                                             groundNormal: postGroundState.groundNormal,
                                                             groundBodyId: postGroundState.groundBodyId,
                                                             rootMotionDeltaMagnitude: rootMotionDeltaMagnitude,
                                                             rootMotionEnabled: rootMotionEnabled,
                                                             rootMotionActive: rootMotionActive,
                                                             rootMotionStateName: rootMotionStateName)
            locomotionOutputsByEntity[entity.id] = locomotionOutput

            // Stage: DiagnosticsPublish
            let currentDiagnostics = RuntimeAnimationDiagnosticsState(currentState: rootMotionStateName,
                                                                     nextState: nextStateName,
                                                                     authoredUsesRootMotion: rootMotionAuthoredUsesCurrentState,
                                                                     stateWantsRootMotion: rootMotionStateWantsPolicy,
                                                                     effectiveUsesRootMotion: rootMotionUsesCurrentState,
                                                                     sampleHasNonZeroDelta: rootMotionSampleHasNonZeroDelta,
                                                                     controllerUsingRootMotion: rootMotionActive,
                                                                     rootMotionActive: rootMotionActive,
                                                                     grounded: postGroundState.isGrounded,
                                                                     jumpTriggerLatched: jumpTriggerLatched,
                                                                     translationSourceJointIndex: rootMotionTranslationSourceJointIndex,
                                                                     rotationSourceJointIndex: rootMotionRotationSourceJointIndex,
                                                                     consumeJointIndex: rootMotionConsumeJointIndex)
            let previousDiagnostics = runtimeDiagnosticsByEntity[entity.id]
            let didStateChange = previousDiagnostics?.currentState != currentDiagnostics.currentState
                || previousDiagnostics?.nextState != currentDiagnostics.nextState
            let didRootMotionTruthChange = previousDiagnostics?.authoredUsesRootMotion != currentDiagnostics.authoredUsesRootMotion
                || previousDiagnostics?.stateWantsRootMotion != currentDiagnostics.stateWantsRootMotion
                || previousDiagnostics?.effectiveUsesRootMotion != currentDiagnostics.effectiveUsesRootMotion
                || previousDiagnostics?.sampleHasNonZeroDelta != currentDiagnostics.sampleHasNonZeroDelta
                || previousDiagnostics?.controllerUsingRootMotion != currentDiagnostics.controllerUsingRootMotion
            let didRootMotionToggle = previousDiagnostics?.rootMotionActive != currentDiagnostics.rootMotionActive
            let didRootMotionChannelChange = previousDiagnostics?.translationSourceJointIndex != currentDiagnostics.translationSourceJointIndex
                || previousDiagnostics?.rotationSourceJointIndex != currentDiagnostics.rotationSourceJointIndex
                || previousDiagnostics?.consumeJointIndex != currentDiagnostics.consumeJointIndex
            if didRootMotionTruthChange || fixedStepCounter % 30 == 0 {
                EngineLoggerContext.log(
                    "AnimCC root-motion truth entity=\(entity.id.uuidString) currentState=\(rootMotionStateName.isEmpty ? "<none>" : rootMotionStateName) authoredUsesRootMotion=\(rootMotionAuthoredUsesCurrentState) stateWantsRootMotion=\(rootMotionStateWantsPolicy) effectiveUsesRootMotion=\(rootMotionUsesCurrentState) sampleHasNonZeroDelta=\(rootMotionSampleHasNonZeroDelta) transitionBlend=\(rootMotionFromTransitionBlend) controllerUsingRootMotion=\(rootMotionActive)",
                    level: .debug,
                    category: .scene
                )
            }
            if previousDiagnostics?.grounded != currentDiagnostics.grounded {
                EngineLoggerContext.log(
                    "AnimCC grounded change entity=\(entity.id.uuidString) grounded=\(currentDiagnostics.grounded) movementMagnitude=\(movementMagnitude)",
                    level: .debug,
                    category: .scene
                )
            }
            if didStateChange || didRootMotionToggle || didRootMotionChannelChange {
                let playbackSummary: String
                if ["JumpStart", "Airborne", "Land"].contains(rootMotionStateName) {
                    playbackSummary = " playbackTime=\(jumpStateSampleTime) normalized=\(jumpStateNormalizedTime)"
                } else {
                    playbackSummary = ""
                }
                let visualTransformSummary: String = {
                    guard let visualEntityID = controller.visualEntityId,
                          let visualEntity = scene.ecs.entity(with: visualEntityID),
                          let visualLocal = scene.ecs.get(TransformComponent.self, for: visualEntity) else {
                        return " visualEntity=<none>"
                    }
                    let visualWorld = scene.ecs.worldTransform(for: visualEntity)
                    return " visualEntity=\(visualEntityID.uuidString) visualLocalPos=\(visualLocal.position) visualLocalRot=\(visualLocal.rotation) visualWorldPos=\(visualWorld.position)"
                }()
                EngineLoggerContext.log(
                    "AnimCC state entity=\(entity.id.uuidString) currentState=\(rootMotionStateName.isEmpty ? "<none>" : rootMotionStateName) nextState=\(nextStateName.isEmpty ? "<none>" : nextStateName) usesRootMotion=\(rootMotionUsesCurrentState) rootMotionActive=\(rootMotionActive) translationSourceJoint=\(rootMotionTranslationSourceJointName.isEmpty ? "<none>" : rootMotionTranslationSourceJointName)#\(rootMotionTranslationSourceJointIndex) rotationSourceJoint=\(rootMotionRotationSourceJointName.isEmpty ? "<none>" : rootMotionRotationSourceJointName)#\(rootMotionRotationSourceJointIndex) consumeJoint=\(rootMotionConsumeJointName.isEmpty ? "<none>" : rootMotionConsumeJointName)#\(rootMotionConsumeJointIndex) controllerScale=\(controllerScale) animatorVisualScale=\(animatorVisualScale) animatorSourceEntity=\(rootMotionSourceEntityID?.uuidString ?? "<none>") localRootDelta=\(localRootDelta) scaledRootDelta=\(scaledRootDelta) clipWorldRootDelta=\(clipWorldRootDelta) extractedPlanarRootMagnitude=\(extractedRootMotionPlanarMagnitude) rootMotionTranslationGatedOff=\(rootMotionTranslationGatedOff) worldRootDelta=\(worldRootDelta) rootDeltaTranslationMag=\(rootMotionDeltaMagnitude) appliedWorldDelta=\(rootHorizontalDisplacement) rawInputDirection=\(rawInputIntent) normalizedDirection=\(normalizedInput) movementMagnitude=\(movementMagnitude) movementDirection=\(desiredHorizontal) forward=\(forward) right=\(right) cameraYaw=\(controller.yawRadians) rootDeltaRotationMag=\(rootMotionDeltaRotationMagnitude) appliedDisplacementMag=\(appliedDisplacementMagnitude) fallbackDisplacement=\(usedRootMotionFallbackDisplacement) grounded=\(postGroundState.isGrounded) jumpTriggerLatched=\(jumpTriggerLatched) jumpTriggerConsumed=\(jumpTriggerConsumedThisFrame)\(playbackSummary)\(visualTransformSummary)",
                    level: .debug,
                    category: .scene
                )
                EngineLoggerContext.log(
                    "AnimCC transition entity=\(entity.id.uuidString) from=\(previousDiagnostics?.currentState ?? "<none>") to=\(rootMotionStateName.isEmpty ? "<none>" : rootMotionStateName) next=\(nextStateName.isEmpty ? "<none>" : nextStateName) transitionBlend=\(rootMotionFromTransitionBlend) movementMagnitude=\(movementMagnitude) grounded=\(currentDiagnostics.grounded)",
                    level: .debug,
                    category: .scene
                )
            }
            if let animatorParameterWrite {
                let signature = "speed=\(movementSpeedForGraph)|grounded=\(groundedForGraph)|moving=\(parameterState.movingLatched)|sprinting=\(sprintIntentActive)|jump=\(jumpTriggerConsumedThisFrame)|w=\(animatorParameterWrite.wroteMovementSpeed),\(animatorParameterWrite.wroteGrounded),\(animatorParameterWrite.wroteMoving),\(animatorParameterWrite.wroteSprinting),\(animatorParameterWrite.wroteJumpTrigger)"
                let lastSignature = lastAnimatorParameterSignatureByEntity[entity.id]
                if lastSignature != signature || fixedStepCounter % 30 == 0 {
                    lastAnimatorParameterSignatureByEntity[entity.id] = signature
                    EngineLoggerContext.log(
                        "AnimCC params entity=\(entity.id.uuidString) animatorEntity=\(animatorParameterWrite.animatorEntityID.uuidString) speed=\(movementSpeedForGraph) grounded=\(groundedForGraph) moving=\(parameterState.movingLatched) sprinting=\(sprintIntentActive) jumpEdge=\(jumpTriggerConsumedThisFrame) wrote=[MovementSpeed:\(animatorParameterWrite.wroteMovementSpeed),Grounded:\(animatorParameterWrite.wroteGrounded),Moving:\(animatorParameterWrite.wroteMoving),Sprinting:\(animatorParameterWrite.wroteSprinting),jumpTrigger:\(animatorParameterWrite.wroteJumpTrigger)] movementMagnitude=\(movementMagnitude)",
                        level: .debug,
                        category: .scene
                    )
                }
            }
            runtimeDiagnosticsByEntity[entity.id] = currentDiagnostics

            let intentMagnitude = simd_length(normalizedInput)
            let cardinalIntentKey: String = {
                guard intentMagnitude >= 0.2 else { return "Idle" }
                let horizontal = normalizedInput.x >= 0.5 ? "D" : (normalizedInput.x <= -0.5 ? "A" : "")
                let vertical = normalizedInput.y >= 0.5 ? "W" : (normalizedInput.y <= -0.5 ? "S" : "")
                let key = vertical + horizontal
                return key.isEmpty ? "Analog" : key
            }()
            let previousCardinalIntent = lastCardinalIntentKeyByEntity[entity.id]
            let keyboardCardinals: Set<String> = ["W", "A", "S", "D", "WA", "WD", "SA", "SD"]
            if keyboardCardinals.contains(cardinalIntentKey),
               previousCardinalIntent != cardinalIntentKey {
                lastCardinalIntentKeyByEntity[entity.id] = cardinalIntentKey
                let dotForward = simd_dot(rootHorizontalDisplacement, forward)
                let dotRight = simd_dot(rootHorizontalDisplacement, right)
                let validation = validateMovementConvention(intentKey: cardinalIntentKey,
                                                            rawInput: rawInputIntent,
                                                            normalizedDirection: normalizedInput,
                                                            localRootDelta: localRootDelta,
                                                            forward: forward,
                                                            right: right,
                                                            worldDelta: rootHorizontalDisplacement,
                                                            usedFallbackDisplacement: usedRootMotionFallbackDisplacement)
                EngineLoggerContext.log(
                    "AnimCC direction validation entity=\(entity.id.uuidString) intent=\(cardinalIntentKey) rawInput=\(rawInputIntent) localIntentBeforeNormalization=\(movementIntentLocal) normalizedLocalDirection=\(normalizedInput) movementMagnitude=\(movementMagnitude) localRootDelta=\(localRootDelta) forward=\(forward) right=\(right) worldDelta=\(rootHorizontalDisplacement) dotWorldForward=\(dotForward) dotWorldRight=\(dotRight) fallbackDisplacement=\(usedRootMotionFallbackDisplacement) validation=\(validation)",
                    level: .debug,
                    category: .scene
                )
            }

            if didStateChange,
               rootMotionStateName.caseInsensitiveCompare("JumpStart") == .orderedSame,
               previousDiagnostics?.currentState.caseInsensitiveCompare("JumpStart") != .orderedSame {
                jumpStartEntryTimeByEntity[entity.id] = timelineSeconds
                let key = "\(entity.id.uuidString)|jumpLiftOff"
                loggedRootMotionFailureKeys.remove(key)
                EngineLoggerContext.log(
                    "AnimCC JumpStart active entity=\(entity.id.uuidString) entryTime=\(timelineSeconds) playbackTime=\(jumpStateSampleTime) normalized=\(jumpStateNormalizedTime)",
                    level: .debug,
                    category: .scene
                )
            }
            if rootMotionStateName.caseInsensitiveCompare("JumpStart") == .orderedSame,
               wasGrounded,
               !postGroundState.isGrounded,
               let jumpStartEntry = jumpStartEntryTimeByEntity[entity.id] {
                let key = "\(entity.id.uuidString)|jumpLiftOff"
                if !loggedRootMotionFailureKeys.contains(key) {
                    loggedRootMotionFailureKeys.insert(key)
                    let jumpStartVisibleDuration = timelineSeconds - jumpStartEntry
                    let impulseDelay = jumpImpulseTimeByEntity[entity.id].map { timelineSeconds - $0 } ?? -1.0
                    EngineLoggerContext.log(
                        "AnimCC JumpStart liftoff entity=\(entity.id.uuidString) jumpStartDurationBeforeUngrounded=\(jumpStartVisibleDuration) impulseToUngrounded=\(impulseDelay)",
                        level: .debug,
                        category: .scene
                    )
                }
            }
            if didStateChange,
               rootMotionStateName.caseInsensitiveCompare("Airborne") == .orderedSame,
               previousDiagnostics?.currentState.caseInsensitiveCompare("Airborne") != .orderedSame {
                let jumpStartDuration = jumpStartEntryTimeByEntity[entity.id].map { timelineSeconds - $0 } ?? -1.0
                let impulseToAirborne = jumpImpulseTimeByEntity[entity.id].map { timelineSeconds - $0 } ?? -1.0
                EngineLoggerContext.log(
                    "AnimCC Airborne transition entity=\(entity.id.uuidString) jumpStartToAirborne=\(jumpStartDuration) impulseToAirborne=\(impulseToAirborne) grounded=\(postGroundState.isGrounded)",
                    level: .debug,
                    category: .scene
                )
            }

            if abs(animatorVisualScale - 1.0) > 0.25 {
                let scaleKey = "\(entity.id.uuidString)|scaleRootMotionVerification"
                if !loggedRootMotionFailureKeys.contains(scaleKey) {
                    loggedRootMotionFailureKeys.insert(scaleKey)
                    EngineLoggerContext.log(
                        "AnimCC scale verification entity=\(entity.id.uuidString) controllerScale=\(controllerScale) animatorVisualScale=\(animatorVisualScale) animatorSourceEntity=\(rootMotionSourceEntityID?.uuidString ?? "<none>") localRootDelta=\(localRootDelta) scaledRootDelta=\(scaledRootDelta) worldRootDelta=\(worldRootDelta) appliedDisplacementMag=\(appliedDisplacementMagnitude) fallbackDisplacement=\(usedRootMotionFallbackDisplacement)",
                        level: .debug,
                        category: .scene
                    )
                }
            }

            if rootMotionActive,
               extractedRootMotionPlanarMagnitude > 1.0e-4,
               appliedDisplacementMagnitude < 1.0e-5 {
                let failureKey = "\(entity.id.uuidString)|\(rootMotionStateName)|noAppliedDisplacement"
                if !loggedRootMotionFailureKeys.contains(failureKey) {
                    loggedRootMotionFailureKeys.insert(failureKey)
                    EngineLoggerContext.log(
                        "AnimCC root motion extraction/application mismatch entity=\(entity.id.uuidString) currentState=\(rootMotionStateName) extractedPlanarRootMagnitude=\(extractedRootMotionPlanarMagnitude) appliedDisplacementMag=\(appliedDisplacementMagnitude) grounded=\(postGroundState.isGrounded)",
                        level: .warning,
                        category: .scene
                    )
                }
            }

            stepHook?.postStep(.init(scene: scene,
                                     entity: entity,
                                     fixedDelta: fixedDelta,
                                     locomotion: locomotionOutput,
                                     groundState: postGroundState))
            let updatedRotation = TransformMath.normalizedQuaternion(yawRotation)
            var interpolation = characterInterpolationStates[entity.id] ?? CharacterInterpolationState(prevPosition: finalPosition,
                                                                                                      currPosition: finalPosition,
                                                                                                      prevRotation: updatedRotation,
                                                                                                      currRotation: updatedRotation,
                                                                                                      initialized: false)
            if !interpolation.initialized {
                interpolation.prevPosition = startPosition
                interpolation.currPosition = finalPosition
                interpolation.prevRotation = updatedRotation
                interpolation.currRotation = updatedRotation
                interpolation.initialized = true
            } else {
                interpolation.prevPosition = interpolation.currPosition
                interpolation.prevRotation = interpolation.currRotation
                interpolation.currPosition = finalPosition
                interpolation.currRotation = updatedRotation
            }
            characterInterpolationStates[entity.id] = interpolation

            var pivotParentWorldYawRadians: Float = 0.0
            var appliedPivotLocalYawRadians = controller.yawRadians
            if let pivotEntityId = controller.cameraPivotEntityId,
               let pivotEntity = scene.ecs.entity(with: pivotEntityId),
               var pivotTransform = scene.ecs.get(TransformComponent.self, for: pivotEntity) {
                activePivotEntityIDs.insert(pivotEntity.id)
                let previousPivotRotation = TransformMath.normalizedQuaternion(pivotTransform.rotation)
                if let pivotParent = scene.ecs.getParent(pivotEntity) {
                    let parentWorldTransform = scene.ecs.worldTransform(for: pivotParent)
                    pivotParentWorldYawRadians = worldYawRadians(from: parentWorldTransform.rotation, fallback: 0.0)
                }
                appliedPivotLocalYawRadians = wrapRadians(controller.yawRadians - pivotParentWorldYawRadians)
                let yawQuat = simd_quatf(angle: appliedPivotLocalYawRadians, axis: SIMD3<Float>(0.0, 1.0, 0.0))
                let pitchQuat = simd_quatf(angle: controller.pitchRadians, axis: SIMD3<Float>(1.0, 0.0, 0.0))
                let updatedPivotRotation = TransformMath.normalizedQuaternion(simd_normalize(yawQuat * pitchQuat).vector)
                pivotTransform.rotation = updatedPivotRotation
                _ = scene.transformAuthority.setLocalTransform(entity: pivotEntity,
                                                               transform: pivotTransform,
                                                               source: .characterController)
                var pivotInterpolation = pivotInterpolationStates[pivotEntity.id]
                    ?? PivotInterpolationState(prevRotation: updatedPivotRotation,
                                               currRotation: updatedPivotRotation,
                                               initialized: false)
                if !pivotInterpolation.initialized {
                    pivotInterpolation.prevRotation = previousPivotRotation
                    pivotInterpolation.currRotation = updatedPivotRotation
                    pivotInterpolation.initialized = true
                } else {
                    pivotInterpolation.prevRotation = pivotInterpolation.currRotation
                    pivotInterpolation.currRotation = updatedPivotRotation
                }
                pivotInterpolationStates[pivotEntity.id] = pivotInterpolation
            }
            let debugTick = (cameraBasisDebugCounterByEntity[entity.id] ?? 0) + 1
            cameraBasisDebugCounterByEntity[entity.id] = debugTick
            if debugTick % 30 == 0 {
                EngineLoggerContext.log(
                    "AnimCC camera basis entity=\(entity.id.uuidString) cameraWorldYaw=\(controller.yawRadians) pivotParentWorldYaw=\(pivotParentWorldYawRadians) pivotLocalYaw=\(appliedPivotLocalYawRadians) forward=\(forward) right=\(right) rawInput=\(rawInputIntent) movementDirection=\(desiredHorizontal) characterFacingYaw=\(characterYawRadians)",
                    level: .debug,
                    category: .scene
                )
                EngineLoggerContext.log(
                    "AnimCC locomotion rm entity=\(entity.id.uuidString) usesRootMotion=\(rootMotionUsesCurrentState) effectiveDeltaLocal=\(scaledRootDelta) extractedPlanarRootMagnitude=\(extractedRootMotionPlanarMagnitude) worldRootDelta=\(worldRootDelta) controllerDisplacement=\(rootHorizontalDisplacement) inputReconstructionBypassed=\(motorCommand.bypassedInputDirectionReconstruction) gatedNoInput=\(rootMotionTranslationGatedOff) currentYaw=\(characterYawRadians) targetYaw=\(targetYawRadians) sampleTime=\(jumpStateSampleTime) sampleDuration=\(rootMotionSampleDuration)",
                    level: .debug,
                    category: .scene
                )
            }

            scene.ecs.add(controller, to: entity)
        }

        let staleCharacterEntities = characterHandlesByEntity.keys.filter { !activeEntityIDs.contains($0) }
        for entityId in staleCharacterEntities {
            if let handle = characterHandlesByEntity[entityId] {
                physicsSystem.destroyCharacter(handle: handle)
            }
            characterHandlesByEntity.removeValue(forKey: entityId)
            characterInterpolationStates.removeValue(forKey: entityId)
            pivotInterpolationStates.removeValue(forKey: entityId)
            renderWorldTransformCache.removeValue(forKey: entityId)
            locomotionOutputsByEntity.removeValue(forKey: entityId)
            debugVisualizationByEntity.removeValue(forKey: entityId)
            runtimeDiagnosticsByEntity.removeValue(forKey: entityId)
            consumedRootMotionTickByEntity.removeValue(forKey: entityId)
            cameraBasisDebugCounterByEntity.removeValue(forKey: entityId)
            timelineSecondsByEntity.removeValue(forKey: entityId)
            jumpStartEntryTimeByEntity.removeValue(forKey: entityId)
            jumpImpulseTimeByEntity.removeValue(forKey: entityId)
            lastCardinalIntentKeyByEntity.removeValue(forKey: entityId)
            animatorLocomotionParameterStateByEntity.removeValue(forKey: entityId)
            lastAnimatorParameterSignatureByEntity.removeValue(forKey: entityId)
            smoothedFacingDirectionByEntity.removeValue(forKey: entityId)
            lastLocomotionAuthorityRootMotionByEntity.removeValue(forKey: entityId)
            authorityStabilityByEntity.removeValue(forKey: entityId)
        }
        let stalePivotEntities = pivotInterpolationStates.keys.filter { !activePivotEntityIDs.contains($0) }
        for pivotEntityID in stalePivotEntities {
            pivotInterpolationStates.removeValue(forKey: pivotEntityID)
        }
        characterJumpRequests.removeAll(keepingCapacity: true)
        characterLookRequests.removeAll(keepingCapacity: true)
    }

    public func onEntityDestroyed(_ entityId: UUID) {
        characterHandlesByEntity.removeValue(forKey: entityId)
        characterInterpolationStates.removeValue(forKey: entityId)
        pivotInterpolationStates.removeValue(forKey: entityId)
        renderWorldTransformCache.removeValue(forKey: entityId)
        locomotionOutputsByEntity.removeValue(forKey: entityId)
        debugVisualizationByEntity.removeValue(forKey: entityId)
        runtimeDiagnosticsByEntity.removeValue(forKey: entityId)
        consumedRootMotionTickByEntity.removeValue(forKey: entityId)
        cameraBasisDebugCounterByEntity.removeValue(forKey: entityId)
        timelineSecondsByEntity.removeValue(forKey: entityId)
        jumpStartEntryTimeByEntity.removeValue(forKey: entityId)
        jumpImpulseTimeByEntity.removeValue(forKey: entityId)
        lastCardinalIntentKeyByEntity.removeValue(forKey: entityId)
        animatorLocomotionParameterStateByEntity.removeValue(forKey: entityId)
        lastAnimatorParameterSignatureByEntity.removeValue(forKey: entityId)
        smoothedFacingDirectionByEntity.removeValue(forKey: entityId)
        lastLocomotionAuthorityRootMotionByEntity.removeValue(forKey: entityId)
        authorityStabilityByEntity.removeValue(forKey: entityId)
    }

    public func prepareForPhysicsStart(scene: EngineScene) {
        scene.ecs.viewDeterministic(CharacterControllerComponent.self) { entity, _ in
            guard var controller = scene.ecs.get(CharacterControllerComponent.self, for: entity) else { return }
            controller.characterHandle = 0
            controller.runtimeConfigApplied = false
            scene.ecs.add(controller, to: entity)
        }
        characterHandlesByEntity.removeAll(keepingCapacity: true)
        characterInterpolationStates.removeAll(keepingCapacity: true)
        pivotInterpolationStates.removeAll(keepingCapacity: true)
        renderWorldTransformCache.removeAll(keepingCapacity: true)
        locomotionOutputsByEntity.removeAll(keepingCapacity: true)
        debugVisualizationByEntity.removeAll(keepingCapacity: true)
        runtimeDiagnosticsByEntity.removeAll(keepingCapacity: true)
        consumedRootMotionTickByEntity.removeAll(keepingCapacity: true)
        loggedAnimatorResolveFailures.removeAll(keepingCapacity: true)
        cameraBasisDebugCounterByEntity.removeAll(keepingCapacity: true)
        timelineSecondsByEntity.removeAll(keepingCapacity: true)
        jumpStartEntryTimeByEntity.removeAll(keepingCapacity: true)
        jumpImpulseTimeByEntity.removeAll(keepingCapacity: true)
        lastCardinalIntentKeyByEntity.removeAll(keepingCapacity: true)
        loggedRootMotionFailureKeys.removeAll(keepingCapacity: true)
        animatorLocomotionParameterStateByEntity.removeAll(keepingCapacity: true)
        lastAnimatorParameterSignatureByEntity.removeAll(keepingCapacity: true)
        smoothedFacingDirectionByEntity.removeAll(keepingCapacity: true)
        lastLocomotionAuthorityRootMotionByEntity.removeAll(keepingCapacity: true)
        authorityStabilityByEntity.removeAll(keepingCapacity: true)
    }

    public func destroyAllCharacters(using physicsSystem: PhysicsSystem) {
        for (_, handle) in characterHandlesByEntity {
            physicsSystem.destroyCharacter(handle: handle)
        }
        characterHandlesByEntity.removeAll(keepingCapacity: true)
        characterInterpolationStates.removeAll(keepingCapacity: true)
        pivotInterpolationStates.removeAll(keepingCapacity: true)
        renderWorldTransformCache.removeAll(keepingCapacity: true)
        locomotionOutputsByEntity.removeAll(keepingCapacity: true)
        runtimeDiagnosticsByEntity.removeAll(keepingCapacity: true)
        consumedRootMotionTickByEntity.removeAll(keepingCapacity: true)
        loggedAnimatorResolveFailures.removeAll(keepingCapacity: true)
        cameraBasisDebugCounterByEntity.removeAll(keepingCapacity: true)
        timelineSecondsByEntity.removeAll(keepingCapacity: true)
        jumpStartEntryTimeByEntity.removeAll(keepingCapacity: true)
        jumpImpulseTimeByEntity.removeAll(keepingCapacity: true)
        lastCardinalIntentKeyByEntity.removeAll(keepingCapacity: true)
        loggedRootMotionFailureKeys.removeAll(keepingCapacity: true)
        animatorLocomotionParameterStateByEntity.removeAll(keepingCapacity: true)
        lastAnimatorParameterSignatureByEntity.removeAll(keepingCapacity: true)
        smoothedFacingDirectionByEntity.removeAll(keepingCapacity: true)
        lastLocomotionAuthorityRootMotionByEntity.removeAll(keepingCapacity: true)
        authorityStabilityByEntity.removeAll(keepingCapacity: true)
    }

    public func resetForSceneApply() {
        characterHandlesByEntity.removeAll(keepingCapacity: true)
        characterInterpolationStates.removeAll(keepingCapacity: true)
        pivotInterpolationStates.removeAll(keepingCapacity: true)
        renderWorldTransformCache.removeAll(keepingCapacity: true)
        locomotionOutputsByEntity.removeAll(keepingCapacity: true)
        debugVisualizationByEntity.removeAll(keepingCapacity: true)
        runtimeDiagnosticsByEntity.removeAll(keepingCapacity: true)
        consumedRootMotionTickByEntity.removeAll(keepingCapacity: true)
        loggedAnimatorResolveFailures.removeAll(keepingCapacity: true)
        cameraBasisDebugCounterByEntity.removeAll(keepingCapacity: true)
        timelineSecondsByEntity.removeAll(keepingCapacity: true)
        jumpStartEntryTimeByEntity.removeAll(keepingCapacity: true)
        jumpImpulseTimeByEntity.removeAll(keepingCapacity: true)
        lastCardinalIntentKeyByEntity.removeAll(keepingCapacity: true)
        loggedRootMotionFailureKeys.removeAll(keepingCapacity: true)
        animatorLocomotionParameterStateByEntity.removeAll(keepingCapacity: true)
        lastAnimatorParameterSignatureByEntity.removeAll(keepingCapacity: true)
        smoothedFacingDirectionByEntity.removeAll(keepingCapacity: true)
        lastLocomotionAuthorityRootMotionByEntity.removeAll(keepingCapacity: true)
        authorityStabilityByEntity.removeAll(keepingCapacity: true)
        characterJumpRequests.removeAll(keepingCapacity: true)
        characterLookRequests.removeAll(keepingCapacity: true)
        characterSprintRequests.removeAll(keepingCapacity: true)
        characterMoveRequests.removeAll(keepingCapacity: true)
    }

    public func resetRuntimeInputState() {
        characterMoveRequests.removeAll(keepingCapacity: true)
        characterLookRequests.removeAll(keepingCapacity: true)
        characterSprintRequests.removeAll(keepingCapacity: true)
        characterJumpRequests.removeAll(keepingCapacity: true)
        runtimeDiagnosticsByEntity.removeAll(keepingCapacity: true)
        consumedRootMotionTickByEntity.removeAll(keepingCapacity: true)
        loggedAnimatorResolveFailures.removeAll(keepingCapacity: true)
        cameraBasisDebugCounterByEntity.removeAll(keepingCapacity: true)
        timelineSecondsByEntity.removeAll(keepingCapacity: true)
        jumpStartEntryTimeByEntity.removeAll(keepingCapacity: true)
        jumpImpulseTimeByEntity.removeAll(keepingCapacity: true)
        lastCardinalIntentKeyByEntity.removeAll(keepingCapacity: true)
        loggedRootMotionFailureKeys.removeAll(keepingCapacity: true)
        animatorLocomotionParameterStateByEntity.removeAll(keepingCapacity: true)
        lastAnimatorParameterSignatureByEntity.removeAll(keepingCapacity: true)
        smoothedFacingDirectionByEntity.removeAll(keepingCapacity: true)
        lastLocomotionAuthorityRootMotionByEntity.removeAll(keepingCapacity: true)
        authorityStabilityByEntity.removeAll(keepingCapacity: true)
    }

    private func rebuildRenderWorldTransformCache(scene: EngineScene) {
        renderWorldTransformCache.removeAll(keepingCapacity: true)
        guard !characterInterpolationStates.isEmpty else { return }

        let alpha = simd_clamp(renderInterpolationAlpha, 0.0, 1.0)
        for (entityId, interpolation) in characterInterpolationStates {
            guard interpolation.initialized,
                  let entity = scene.ecs.entity(with: entityId),
                  let controller = scene.ecs.get(CharacterControllerComponent.self, for: entity),
                  controller.isEnabled,
                  controller.interpolateSubtree,
                  scene.ecs.get(TransformComponent.self, for: entity) != nil else {
                continue
            }

            let prevQuat = simd_quatf(vector: interpolation.prevRotation)
            let currQuat = simd_quatf(vector: interpolation.currRotation)
            let interpolatedQuat = simd_slerp(prevQuat, currQuat, alpha)
            let interpolatedPos = simd_mix(interpolation.prevPosition, interpolation.currPosition, SIMD3<Float>(repeating: alpha))
            let rootScale = scene.ecs.worldTransform(for: entity).scale
            let rootRender = TransformComponent(position: interpolatedPos,
                                                rotation: TransformMath.normalizedQuaternion(interpolatedQuat.vector),
                                                scale: rootScale)
            renderWorldTransformCache[entity.id] = rootRender
            buildRenderWorldTransformCacheSubtree(scene: scene,
                                                  root: entity,
                                                  rootRenderTransform: rootRender,
                                                  alpha: alpha)
        }
    }

    private func buildRenderWorldTransformCacheSubtree(scene: EngineScene,
                                                       root: Entity,
                                                       rootRenderTransform: TransformComponent,
                                                       alpha: Float) {
        var visited: Set<UUID> = [root.id]
        var queue: [(entity: Entity, world: TransformComponent)] = [(root, rootRenderTransform)]
        var queueIndex = 0

        while queueIndex < queue.count {
            let current = queue[queueIndex]
            queueIndex += 1
            let parentMatrix = TransformMath.makeMatrix(position: current.world.position,
                                                        rotation: current.world.rotation,
                                                        scale: current.world.scale)
            for child in scene.ecs.getChildren(current.entity) {
                if visited.contains(child.id) {
                    continue
                }
                guard let childLocal = scene.ecs.get(TransformComponent.self, for: child) else { continue }
                var renderLocal = childLocal
                if let pivotInterpolation = pivotInterpolationStates[child.id],
                   pivotInterpolation.initialized {
                    let prevQuat = simd_quatf(vector: pivotInterpolation.prevRotation)
                    let currQuat = simd_quatf(vector: pivotInterpolation.currRotation)
                    let blendedQuat = simd_slerp(prevQuat, currQuat, alpha)
                    renderLocal.rotation = TransformMath.normalizedQuaternion(blendedQuat.vector)
                }
                let localMatrix = TransformMath.makeMatrix(position: renderLocal.position,
                                                           rotation: renderLocal.rotation,
                                                           scale: renderLocal.scale)
                let childWorldMatrix = parentMatrix * localMatrix
                let decomposed = TransformMath.decomposeMatrix(childWorldMatrix)
                let childRender = TransformComponent(position: decomposed.position,
                                                     rotation: decomposed.rotation,
                                                     scale: decomposed.scale)
                renderWorldTransformCache[child.id] = childRender
                visited.insert(child.id)
                queue.append((child, childRender))
            }
        }
    }

    private func sanitizeRootMotionDelta(_ delta: RootMotionDelta) -> RootMotionDelta {
        let position = simd3IsFinite(delta.deltaPos) ? delta.deltaPos : .zero
        let rotation: SIMD4<Float>
        if simd4IsFinite(delta.deltaRot), simd_length_squared(delta.deltaRot) > 1.0e-8 {
            rotation = TransformMath.normalizedQuaternion(delta.deltaRot)
        } else {
            rotation = TransformMath.identityQuaternion
        }
        return RootMotionDelta(deltaPos: position, deltaRot: rotation)
    }

    private func simd3IsFinite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private func simd4IsFinite(_ value: SIMD4<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite && value.w.isFinite
    }

    private struct ResolvedRootMotion {
        let tickResult: AnimationTickResult?
        let snapshot: AnimationFixedTickRuntimeSnapshot
        let enableRootMotion: Bool
        let jumpTriggerLatched: Bool
        let consumeJointName: String
        let consumeJointIndex: Int
        let sourceEntityID: UUID
        let sourceWorldScale: Float
    }

    private func resolveRootMotionForController(scene: EngineScene,
                                                entity: Entity,
                                                controller: CharacterControllerComponent,
                                                currentFixedTick: UInt64) -> ResolvedRootMotion? {
        guard let animatorEntity = resolveAnimatorEntityForController(scene: scene, entity: entity, controller: controller) else {
            return nil
        }
        func readRootMotion(from target: Entity) -> ResolvedRootMotion? {
            guard let animator = scene.ecs.get(AnimatorComponent.self, for: target) else { return nil }
            let poseState = animator.poseRuntimeState
            let fallbackSnapshot = poseState?.fixedTickRuntimeSnapshot
            let canonicalTick = animator.latestAnimationTickResult?.tickIndex == currentFixedTick
                ? animator.latestAnimationTickResult
                : nil
            // Phase-1 compatibility bridge: prefer canonical animation tick truth when available,
            // then project through the compatibility view for existing controller consumers.
            let snapshotFromCanonical: AnimationFixedTickRuntimeSnapshot? = {
                guard let canonical = canonicalTick else {
                    return nil
                }
                let compatibility = AnimationRuntimeCompatibilityView(canonical: canonical)
                return compatibility.fixedTickRuntimeSnapshot(fallback: fallbackSnapshot)
            }()
            guard let snapshot = snapshotFromCanonical ?? fallbackSnapshot else { return nil }
            guard snapshot.tickID == currentFixedTick else { return nil }
            let graph = animator.graphHandle.flatMap { scene.engineContext?.assets.compiledAnimationGraph(handle: $0) }
            let runtimeState = animator.graphRuntimeState
            let jumpTriggerLatched: Bool = {
                guard let graph, let runtimeState else { return false }
                guard let jumpIndex = resolveParameterIndex(in: graph,
                                                            canonicalName: "jumpTrigger",
                                    aliases: ["JumpTrigger", "jump_trigger", "Jump"]) else {
                    return false
                }
                guard jumpIndex >= 0, jumpIndex < runtimeState.triggerParameterValues.count else { return false }
                return runtimeState.triggerParameterValues[jumpIndex] || runtimeState.triggerLatchedParameterIndices.contains(jumpIndex)
            }()
            let sourceScale = scene.ecs.worldTransform(for: target).scale.x
            return ResolvedRootMotion(tickResult: canonicalTick,
                                      snapshot: snapshot,
                                      enableRootMotion: animator.enableRootMotion,
                                      jumpTriggerLatched: jumpTriggerLatched,
                                      consumeJointName: poseState?.rootMotionConsumeBoneName ?? "",
                                      consumeJointIndex: poseState?.rootMotionConsumeJointIndex ?? -1,
                                      sourceEntityID: target.id,
                                      sourceWorldScale: sourceScale)
        }
        return readRootMotion(from: animatorEntity)
    }

    private func resolveAnimatorEntityForController(scene: EngineScene,
                                                    entity: Entity,
                                                    controller: CharacterControllerComponent) -> Entity? {
        if let resolvedID = scene.animatorGraphOwnerEntityID(for: entity.id),
           let resolved = scene.ecs.entity(with: resolvedID) {
            return resolved
        }
        let key = "\(entity.id.uuidString)|animatorResolveFailure"
        if !loggedAnimatorResolveFailures.contains(key) {
            loggedAnimatorResolveFailures.insert(key)
            EngineLoggerContext.log(
                "AnimCC animator resolve failure controllerEntity=\(entity.id.uuidString) visualEntity=\(controller.visualEntityId?.uuidString ?? "<none>") animatorEntity=\(controller.animatorEntityId?.uuidString ?? "<none>")",
                level: .warning,
                category: .scene
            )
        }
        return nil
    }

    private func writeCanonicalAnimatorParameters(scene: EngineScene,
                                                  controllerEntity: Entity,
                                                  controller: CharacterControllerComponent,
                                                  movementSpeed: Float,
                                                  grounded: Bool,
                                                  moving: Bool,
                                                  sprinting: Bool,
                                                  jumpTriggerEdge: Bool) -> AnimatorParameterWriteResult? {
        guard let assets = scene.engineContext?.assets,
              let animatorEntity = resolveAnimatorEntityForController(scene: scene,
                                                                      entity: controllerEntity,
                                                                      controller: controller),
              var animator = scene.ecs.get(AnimatorComponent.self, for: animatorEntity),
              animator.evaluationMode == .graph,
              let graphHandle = animator.graphHandle,
              let compiledGraph = assets.compiledAnimationGraph(handle: graphHandle) else {
            return nil
        }

        var runtimeState = animator.graphRuntimeState ?? AnimationGraphRuntimeInstanceState()
        if runtimeState.graphHandle != graphHandle
            || !runtimeState.hasStorage(parameterCount: compiledGraph.parameters.count,
                                        localVariableCount: compiledGraph.localVariables.count) {
            runtimeState.resetDefaults(from: compiledGraph, graphHandle: graphHandle)
        }

        let movementSpeedIndex = resolveParameterIndex(in: compiledGraph,
                                                       canonicalName: "MovementSpeed",
                                                       aliases: ["movementSpeed", "movement_speed"])
        let groundedIndex = resolveParameterIndex(in: compiledGraph,
                                                  canonicalName: "Grounded",
                                                  aliases: ["grounded"])
        let movingIndex = resolveParameterIndex(in: compiledGraph,
                                                canonicalName: "Moving",
                                                aliases: ["moving", "IsMoving", "isMoving"])
        let sprintingIndex = resolveParameterIndex(in: compiledGraph,
                                                   canonicalName: "Sprinting",
                                                   aliases: ["sprinting", "IsSprinting", "isSprinting"])
        let jumpTriggerIndex = resolveParameterIndex(in: compiledGraph,
                                                     canonicalName: "jumpTrigger",
                                                     aliases: ["JumpTrigger", "jump_trigger", "Jump"])

        var wroteMovementSpeed = false
        if let movementSpeedIndex {
            runtimeState.setFloat(index: movementSpeedIndex, value: max(0.0, movementSpeed))
            wroteMovementSpeed = true
        }
        var wroteGrounded = false
        if let groundedIndex {
            runtimeState.setBool(index: groundedIndex, value: grounded)
            wroteGrounded = true
        }
        var wroteMoving = false
        if let movingIndex {
            runtimeState.setBool(index: movingIndex, value: moving)
            wroteMoving = true
        }
        var wroteSprinting = false
        if let sprintingIndex {
            runtimeState.setBool(index: sprintingIndex, value: sprinting)
            wroteSprinting = true
        }
        var wroteJumpTrigger = false
        if jumpTriggerEdge, let jumpTriggerIndex {
            runtimeState.setTrigger(index: jumpTriggerIndex)
            wroteJumpTrigger = true
        }

        animator.graphRuntimeState = runtimeState
        scene.ecs.add(animator, to: animatorEntity)

        return AnimatorParameterWriteResult(wroteMovementSpeed: wroteMovementSpeed,
                                            wroteGrounded: wroteGrounded,
                                            wroteMoving: wroteMoving,
                                            wroteSprinting: wroteSprinting,
                                            wroteJumpTrigger: wroteJumpTrigger,
                                            animatorEntityID: animatorEntity.id)
    }

    private func resolveParameterIndex(in graph: CompiledAnimationGraph,
                                       canonicalName: String,
                                       aliases: [String] = []) -> Int? {
        let orderedCandidates = [canonicalName] + aliases
        for candidate in orderedCandidates {
            if let index = graph.parameterIndexByName[candidate] {
                return index
            }
        }
        let normalizedCandidates = Set(orderedCandidates.map { normalizedParameterName($0) })
        for (index, parameter) in graph.parameters.enumerated() where normalizedCandidates.contains(normalizedParameterName(parameter.name)) {
            return index
        }
        return nil
    }

    private func normalizedParameterName(_ rawName: String) -> String {
        rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    private func rootMotionRotationMagnitudeRadians(_ delta: RootMotionDelta) -> Float {
        let q = simd_normalize(simd_quatf(vector: TransformMath.normalizedQuaternion(delta.deltaRot)))
        let clamped = simd_clamp(abs(q.real), 0.0, 1.0)
        return 2.0 * acos(clamped)
    }

    private func yawDeltaRadians(from rotation: SIMD4<Float>) -> Float {
        let normalized = simd_quatf(vector: TransformMath.normalizedQuaternion(rotation))
        let forward = normalized.act(TransformMath.localForward)
        let planar = SIMD2<Float>(forward.x, forward.z)
        guard simd_length_squared(planar) > 1.0e-6 else { return 0.0 }
        return atan2(planar.x, planar.y)
    }

    private func runtimeStatePlaybackNormalized(sampleTime: Float, duration: Float) -> Float {
        guard duration > 1.0e-5 else { return 0.0 }
        return simd_clamp(sampleTime / duration, 0.0, 1.0)
    }

    private func wrapRadians(_ value: Float) -> Float {
        var wrapped = value
        while wrapped > .pi {
            wrapped -= 2.0 * .pi
        }
        while wrapped < -.pi {
            wrapped += 2.0 * .pi
        }
        return wrapped
    }

    private func worldYawRadians(from rotation: SIMD4<Float>, fallback: Float) -> Float {
        let normalized = TransformMath.normalizedQuaternion(rotation)
        let worldForward = simd_quatf(vector: normalized).act(TransformMath.localForward)
        let planar = SIMD2<Float>(worldForward.x, worldForward.z)
        if simd_length_squared(planar) > 1.0e-6 {
            return atan2(planar.x, planar.y)
        }
        return fallback
    }

    private func collectLocomotionIntent(entityID: UUID,
                                         controller: CharacterControllerComponent) -> LocomotionIntent {
        let requestedInput = characterMoveRequests[entityID] ?? controller.moveInput
        let lookInput = characterLookRequests[entityID] ?? controller.lookInput
        let sprinting = characterSprintRequests[entityID] ?? controller.wantsSprint
        let local = makeLocalMovementIntent(from: requestedInput)
        return LocomotionIntent(rawInput: requestedInput,
                                lookInput: lookInput,
                                sprinting: sprinting,
                                local: local)
    }

    private func resolveLocomotionAuthority(enableRootMotion: Bool,
                                            entityID: UUID,
                                            animationTick: AnimationTickResult?,
                                            fallbackSnapshot: AnimationFixedTickRuntimeSnapshot) -> AuthorityResolutionResult {
        let desired: AuthorityResolutionResult = {
            guard enableRootMotion else {
                return AuthorityResolutionResult(mode: .controllerDriven,
                                                 rootMotionActive: false,
                                                 reason: "controller_policy_disabled_root_motion")
            }
            guard let animationTick else {
                let legacyActive = fallbackSnapshot.stateWantsRootMotion
                return AuthorityResolutionResult(mode: legacyActive ? .animationRootMotion : .controllerDriven,
                                                 rootMotionActive: legacyActive,
                                                 reason: legacyActive ? "legacy_snapshot_authoritative" : "legacy_snapshot_not_authoritative")
            }
            switch animationTick.rootMotion.mode {
            case .animationRootMotion:
                if animationTick.rootMotion.isActive {
                    return AuthorityResolutionResult(mode: .animationRootMotion,
                                                     rootMotionActive: true,
                                                     reason: "canonical_animation_root_motion")
                }
                return AuthorityResolutionResult(mode: .controllerDriven,
                                                 rootMotionActive: false,
                                                 reason: "canonical_animation_mode_inactive")
            case .controllerDriven:
                return AuthorityResolutionResult(mode: .controllerDriven,
                                                 rootMotionActive: false,
                                                 reason: "canonical_controller_driven")
            case .hybridReserved:
                return AuthorityResolutionResult(mode: .hybridReserved,
                                                 rootMotionActive: false,
                                                 reason: "canonical_hybrid_reserved_mapped_to_controller")
            case .none:
                return AuthorityResolutionResult(mode: .none,
                                                 rootMotionActive: false,
                                                 reason: "canonical_none")
            }
        }()

        let previous = authorityStabilityByEntity[entityID]
        var resolved = desired
        var pendingDropTicks = previous?.pendingDropTicks ?? 0
        let previouslyRootMotionDriven = previous?.mode == .animationRootMotion && previous?.rootMotionActive == true
        let wantsToDropRootMotion = !(desired.mode == .animationRootMotion && desired.rootMotionActive)
        let canUseDropGrace = enableRootMotion && ((animationTick == nil) || (animationTick?.rootMotion.mode == .animationRootMotion))
        if previouslyRootMotionDriven, wantsToDropRootMotion, canUseDropGrace, pendingDropTicks < 1 {
            pendingDropTicks += 1
            resolved = AuthorityResolutionResult(mode: .animationRootMotion,
                                                 rootMotionActive: true,
                                                 reason: "authority_stability_hold_previous_root_motion")
        } else if resolved.mode == .animationRootMotion && resolved.rootMotionActive {
            pendingDropTicks = 0
        } else if !canUseDropGrace {
            pendingDropTicks = 0
        }
        authorityStabilityByEntity[entityID] = AuthorityStabilityState(mode: resolved.mode,
                                                                        rootMotionActive: resolved.rootMotionActive,
                                                                        pendingDropTicks: pendingDropTicks)
        return resolved
    }

    private func buildCharacterMotorCommand(desiredHorizontalVelocity: SIMD3<Float>,
                                            rootMotionLocalDelta: SIMD3<Float>,
                                            rootMotionActive: Bool,
                                            characterYawQuat: simd_quatf) -> CharacterMotorCommand {
        guard rootMotionActive else {
            return CharacterMotorCommand(desiredHorizontalVelocity: desiredHorizontalVelocity,
                                         rootMotionWorldDelta: .zero,
                                         rootMotionLocalDelta: .zero,
                                         usesRootMotion: false,
                                         bypassedInputDirectionReconstruction: true)
        }
        var worldDelta = characterYawQuat.act(rootMotionLocalDelta)
        worldDelta.y = 0.0
        return CharacterMotorCommand(desiredHorizontalVelocity: desiredHorizontalVelocity,
                                     rootMotionWorldDelta: worldDelta,
                                     rootMotionLocalDelta: rootMotionLocalDelta,
                                     usesRootMotion: true,
                                     bypassedInputDirectionReconstruction: true)
    }

    private func makeLocalMovementIntent(from rawInput: SIMD2<Float>) -> LocalMovementIntent {
        let magnitude = simd_length(rawInput)
        let direction = magnitude > 1.0e-5 ? (rawInput / magnitude) : .zero
        return LocalMovementIntent(raw: rawInput, direction: direction, magnitude: magnitude)
    }

    private func makePlanarMovementBasis(cameraYawQuat: simd_quatf,
                                         fallbackForward: SIMD3<Float>) -> PlanarMovementBasis {
        var forward = cameraYawQuat.act(fallbackForward)
        forward.y = 0.0
        if simd_length_squared(forward) > 1.0e-6 {
            forward = simd_normalize(forward)
        } else {
            forward = fallbackForward
        }

        var right = simd_cross(forward, SIMD3<Float>(0.0, 1.0, 0.0))
        if simd_length_squared(right) > 1.0e-6 {
            right = simd_normalize(right)
        } else {
            right = SIMD3<Float>(1.0, 0.0, 0.0)
        }
        return PlanarMovementBasis(forward: forward, right: right)
    }

    private func projectLocalIntentDirectionToWorld(_ localDirection: SIMD2<Float>,
                                                    basis: PlanarMovementBasis) -> SIMD3<Float> {
        (basis.right * localDirection.x) + (basis.forward * localDirection.y)
    }

    private func projectLocalRootDeltaToWorld(_ localRootDelta: SIMD3<Float>,
                                              basis: PlanarMovementBasis) -> SIMD3<Float> {
        (basis.right * localRootDelta.x) + (basis.forward * localRootDelta.z)
    }

    private func expectedDirectionSigns(intentKey: String) -> (forwardPositive: Bool?, rightPositive: Bool?) {
        switch intentKey {
        case "W": return (true, nil)
        case "S": return (false, nil)
        case "A": return (nil, false)
        case "D": return (nil, true)
        case "WA": return (true, false)
        case "WD": return (true, true)
        case "SA": return (false, false)
        case "SD": return (false, true)
        default: return (nil, nil)
        }
    }

    private func signedExpectationPass(value: Float,
                                       expectedPositive: Bool?,
                                       tolerance: Float = 1.0e-4) -> Bool {
        guard let expectedPositive else { return true }
        return expectedPositive ? (value > tolerance) : (value < -tolerance)
    }

    private func validateMovementConvention(intentKey: String,
                                            rawInput: SIMD2<Float>,
                                            normalizedDirection: SIMD2<Float>,
                                            localRootDelta: SIMD3<Float>,
                                            forward: SIMD3<Float>,
                                            right: SIMD3<Float>,
                                            worldDelta: SIMD3<Float>,
                                            usedFallbackDisplacement: Bool) -> String {
        let expected = expectedDirectionSigns(intentKey: intentKey)
        let rawInputPass = signedExpectationPass(value: rawInput.y, expectedPositive: expected.forwardPositive)
            && signedExpectationPass(value: rawInput.x, expectedPositive: expected.rightPositive)
        if !rawInputPass {
            return "FAIL(stage=inputMapping)"
        }

        let normalizedPass = signedExpectationPass(value: normalizedDirection.y, expectedPositive: expected.forwardPositive)
            && signedExpectationPass(value: normalizedDirection.x, expectedPositive: expected.rightPositive)
        if !normalizedPass {
            return "FAIL(stage=localDirectionNormalization)"
        }

        let localRootMagnitude = simd_length(SIMD2<Float>(localRootDelta.x, localRootDelta.z))
        _ = localRootMagnitude

        let basisOrthogonalPass = abs(simd_dot(forward, right)) <= 1.0e-3
            && simd_length_squared(forward) >= 0.99
            && simd_length_squared(right) >= 0.99
        if !basisOrthogonalPass {
            return "FAIL(stage=basisGeneration)"
        }

        let dotForward = simd_dot(worldDelta, forward)
        let dotRight = simd_dot(worldDelta, right)
        let worldProjectionPass = signedExpectationPass(value: dotForward, expectedPositive: expected.forwardPositive)
            && signedExpectationPass(value: dotRight, expectedPositive: expected.rightPositive)
        if !worldProjectionPass {
            return usedFallbackDisplacement
                ? "FAIL(stage=fallbackMismatch)"
                : "FAIL(stage=worldProjection)"
        }

        return "PASS"
    }
}
private struct DefaultCharacterGroundProvider: CharacterGroundProvider {
    func resolveGround(scene _: EngineScene,
                       physicsSystem: PhysicsSystem,
                       entity _: Entity,
                       controller _: CharacterControllerComponent,
                       characterHandle: UInt64) -> CharacterGroundState {
        let grounded = physicsSystem.characterIsGrounded(handle: characterHandle)
        let groundBody = grounded ? physicsSystem.characterGroundBodyId(handle: characterHandle) : 0
        let groundNormal = physicsSystem.characterGroundNormal(handle: characterHandle)
        let groundVelocity = groundBody != 0 ? (physicsSystem.bodyVelocity(bodyId: groundBody) ?? .zero) : .zero
        let movingPlatform = simd_length_squared(groundVelocity) > 1.0e-6
        return CharacterGroundState(isGrounded: grounded,
                                    groundNormal: groundNormal,
                                    groundBodyId: groundBody,
                                    groundVelocity: groundVelocity,
                                    isMovingPlatform: movingPlatform,
                                    terrainSample: nil)
    }
}
