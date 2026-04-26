/// AnimationSystem.swift
/// Minimal animation scaffolding for update-time evaluation and render snapshot prep.
/// Created by Kaden Cringle.

import Foundation
import simd
import QuartzCore

public struct AnimationSnapshotPayload {
    public struct BonePaletteRange {
        public let startIndex: Int
        public let count: Int

        public init(startIndex: Int, count: Int) {
            self.startIndex = startIndex
            self.count = count
        }
    }

    public struct SkinnedEntry {
        public let entity: Entity
        public let skeletonHandle: AssetHandle?
        public let clipHandle: AssetHandle?
        public let playbackTime: Float
        public let isPlaying: Bool
        public let evaluatedJointCount: Int
        public let bonePaletteRange: BonePaletteRange?

        public init(entity: Entity,
                    skeletonHandle: AssetHandle?,
                    clipHandle: AssetHandle?,
                    playbackTime: Float,
                    isPlaying: Bool,
                    evaluatedJointCount: Int,
                    bonePaletteRange: BonePaletteRange?) {
            self.entity = entity
            self.skeletonHandle = skeletonHandle
            self.clipHandle = clipHandle
            self.playbackTime = playbackTime
            self.isPlaying = isPlaying
            self.evaluatedJointCount = evaluatedJointCount
            self.bonePaletteRange = bonePaletteRange
        }
    }

    public let skinnedEntries: [SkinnedEntry]
    public let bonePaletteMatrices: [matrix_float4x4]

    public init(skinnedEntries: [SkinnedEntry], bonePaletteMatrices: [matrix_float4x4]) {
        self.skinnedEntries = skinnedEntries
        self.bonePaletteMatrices = bonePaletteMatrices
    }
}

public final class AnimationSystem {
    private enum EvaluationTimeline {
        case variable
        case fixed(tickID: UInt64)
    }

    private struct RootMotionTracker {
        var previousClipHandle: AssetHandle
        var previousSampleTime: Float
        var previousClipDuration: Float
        var previousRootTransform: TransformComponent
    }
    private struct BonePaletteBuildResult {
        let matrices: [matrix_float4x4]
        let bindPolicy: String
        let importedInverseBindCount: Int
        let nonFiniteMatrixCount: Int
    }

    private var loggedRuntimeSummaryKeys: Set<String> = []
    private var loggedRuntimeIssueKeys: Set<String> = []
    private var animationGraphDebugLoggingEnabled: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["MCE_ANIM_GRAPH_DEBUG"] == "1"
#else
        false
#endif
    }
    private struct TimingAverages {
        var updateMS: Double = 0
        var graphEvalMS: Double = 0
        var samplePoseMS: Double = 0
        var blendMS: Double = 0
        var localToGlobalMS: Double = 0
        var paletteMS: Double = 0
        var frameCount: Int = 0
    }
    private var timingAverages = TimingAverages()
    private var loggedTriggerDiagnosticsKeys: Set<String> = []
    private var lastStateMachineSignatureByKey: [String: String] = [:]
    private var loggedBlend2DDiagnosticsKeys: Set<String> = []
    private var transitionGraphDebugSampleCountsByKey: [String: Int] = [:]
    private var rootMotionTrackersByEntity: [UUID: [String: RootMotionTracker]] = [:]
    private var rootMotionDebugCounterByEntity: [UUID: Int] = [:]
    private var rootMotionExtractionDebugCountersByEntity: [UUID: [String: Int]] = [:]
    private var fixedTickCounter: UInt64 = 0
    private var loggedFixedStepMismatchKeys: Set<String> = []
    private var loggedMissingRootMotionPolicyKeys: Set<String> = []
    private var loggedResolvedRootMotionPolicyKeys: Set<String> = []
    private var loggedControllerBindingFailureKeys: Set<String> = []
    private var loggedSnapshotCoherenceKeys: Set<String> = []
    private var loggedCanonicalContractIssueKeys: Set<String> = []
    private var loggedCanonicalMultiNodeKeys: Set<String> = []
    private var loggedCanonicalSurrogateStateIDKeys: Set<String> = []
    private var loggedCanonicalBridgeAuthoredMappingKeys: Set<String> = []
    private var loggedTransitionRootMotionInvalidSourceKeys: Set<String> = []
    private struct ClipDiagnosticState {
        var lastClipHandle: AssetHandle?
        var pendingSummaryClipHandle: AssetHandle?
    }
    private var clipDiagnosticStateByEntity: [UUID: ClipDiagnosticState] = [:]

    public struct SnapshotPreparation {
        public let skinnedEntityCount: Int
        public let payload: AnimationSnapshotPayload?

        public init(skinnedEntityCount: Int = 0, payload: AnimationSnapshotPayload? = nil) {
            self.skinnedEntityCount = skinnedEntityCount
            self.payload = payload
        }
    }

    public init() {}

    public func update(scene: EngineScene, dt: Float) {
        evaluate(scene: scene, dt: dt, timeline: .variable)
    }

    public func fixedStepGameplay(scene: EngineScene, fixedDelta: Float) {
        fixedTickCounter &+= 1
        evaluate(scene: scene, dt: fixedDelta, timeline: .fixed(tickID: fixedTickCounter))
    }

    private func evaluate(scene: EngineScene, dt: Float, timeline: EvaluationTimeline) {
        guard let assets = scene.engineContext?.assets else { return }
        let updateStart = CACurrentMediaTime()
        let controllerDrivenAnimators = resolveControllerDrivenAnimatorIDs(scene: scene)
        if case let .fixed(tickID) = timeline, tickID % 30 == 0 {
            let resolved = controllerDrivenAnimators.map(\.uuidString).sorted().joined(separator: ",")
            EngineLoggerContext.log(
                "AnimationSystem fixed-step evaluation tickID=\(tickID) animatorEntities=[\(resolved)]",
                level: .debug,
                category: .scene
            )
        }
        var activeAnimatorEntities = Set<UUID>()
        if case .variable = timeline {
            activeAnimatorEntities.formUnion(controllerDrivenAnimators)
        }
        scene.ecs.viewDeterministic(AnimatorComponent.self) { entity, animator in
            let entityID = entity.id
            let controllerDrivenByBinding = controllerDrivenAnimators.contains(entityID)
            var updated = animator
            let isControllerDriven = updated.isControllerDriven || controllerDrivenByBinding
            let previewControllerDrivenInEdit = {
                guard case .variable = timeline else { return false }
                return isControllerDriven && scene.transformAuthorityMode == .edit
            }()
            if updated.isControllerDriven != isControllerDriven {
                updated.isControllerDriven = isControllerDriven
            }
            switch timeline {
            case .variable where isControllerDriven && !previewControllerDrivenInEdit:
                let key = "\(entityID.uuidString)|variableTimelineForControllerBoundAnimator"
                if !loggedFixedStepMismatchKeys.contains(key) {
                    loggedFixedStepMismatchKeys.insert(key)
                    EngineLoggerContext.log(
                        "Animator fixed-step ownership violation entity=\(entityID.uuidString) reason=controllerBoundAnimatorSkippedInVariableUpdate",
                        level: .warning,
                        category: .scene
                    )
                }
                return
            case .fixed where !isControllerDriven:
                return
            default:
                break
            }
            activeAnimatorEntities.insert(entityID)
            let skinnedMesh = scene.ecs.get(SkinnedMeshComponent.self, for: entity)
            let skeleton = skinnedMesh?.skeletonHandle.flatMap { assets.skeleton(handle: $0) }
            let useGraphMode = updated.evaluationMode == .graph && updated.graphHandle != nil
            let fixedTickID: UInt64? = {
                if case let .fixed(tickID) = timeline { return tickID }
                return nil
            }()
            let evaluationDeltaTime = previewControllerDrivenInEdit ? 0.0 : dt
            if useGraphMode {
                evaluateGraphMode(scene: scene,
                                  assets: assets,
                                  entity: entity,
                                  dt: evaluationDeltaTime,
                                  fixedTickID: fixedTickID,
                                  skinnedMesh: skinnedMesh,
                                  skeleton: skeleton,
                                  animator: &updated)
                clipDiagnosticStateByEntity[entityID] = ClipDiagnosticState(lastClipHandle: nil, pendingSummaryClipHandle: nil)
            } else {
                evaluateClipMode(scene: scene,
                                 entity: entity,
                                 dt: evaluationDeltaTime,
                                 fixedTickID: fixedTickID,
                                 skinnedMesh: skinnedMesh,
                                 skeleton: skeleton,
                                 animator: &updated)
            }
            if let fixedTickID {
                updated.latestAnimationTickResult = assembleCanonicalAnimationTickResult(entityID: entityID,
                                                                                         fixedTickID: fixedTickID,
                                                                                         dt: dt,
                                                                                         assets: assets,
                                                                                         animator: updated)
                applyCanonicalCompatibilityBridge(animator: &updated)
            }
            scene.ecs.add(updated, to: entity)
        }
        rootMotionTrackersByEntity = rootMotionTrackersByEntity.filter { activeAnimatorEntities.contains($0.key) }
        rootMotionDebugCounterByEntity = rootMotionDebugCounterByEntity.filter { activeAnimatorEntities.contains($0.key) }
        rootMotionExtractionDebugCountersByEntity = rootMotionExtractionDebugCountersByEntity.filter { activeAnimatorEntities.contains($0.key) }
        let updateElapsedMS = (CACurrentMediaTime() - updateStart) * 1000.0
        timingAverages.updateMS += updateElapsedMS
        timingAverages.frameCount += 1
        if timingAverages.frameCount >= 120 {
            let divisor = max(Double(timingAverages.frameCount), 1.0)
            logRuntimeIssueOnce(
                key: "animationPerfSummary",
                level: .debug,
                message: """
                AnimationSystem perf summary(avg over \(timingAverages.frameCount) frames)
                updateMS=\(timingAverages.updateMS / divisor)
                graphEvalMS=\(timingAverages.graphEvalMS / divisor)
                samplePoseMS=\(timingAverages.samplePoseMS / divisor)
                blendMS=\(timingAverages.blendMS / divisor)
                localToGlobalMS=\(timingAverages.localToGlobalMS / divisor)
                paletteMS=\(timingAverages.paletteMS / divisor)
                """
            )
            timingAverages = TimingAverages()
        }
    }

    private func resolveControllerDrivenAnimatorIDs(scene: EngineScene) -> Set<UUID> {
        var boundAnimatorIDs: Set<UUID> = []
        scene.ecs.viewDeterministic(CharacterControllerComponent.self) { entity, controller in
            if let animatorEntity = resolveBoundAnimatorEntity(scene: scene, entity: entity, controller: controller) {
                boundAnimatorIDs.insert(animatorEntity.id)
            } else {
                let key = "\(entity.id.uuidString)|unresolvedControllerAnimatorBinding"
                if !loggedControllerBindingFailureKeys.contains(key) {
                    loggedControllerBindingFailureKeys.insert(key)
                    EngineLoggerContext.log(
                        "AnimationSystem controller animator unresolved controllerEntity=\(entity.id.uuidString) visualEntity=\(controller.visualEntityId?.uuidString ?? "<none>") animatorEntity=\(controller.animatorEntityId?.uuidString ?? "<none>")",
                        level: .warning,
                        category: .scene
                    )
                }
            }
        }
        return boundAnimatorIDs
    }

    private func resolveBoundAnimatorEntity(scene: EngineScene,
                                            entity: Entity,
                                            controller: CharacterControllerComponent) -> Entity? {
        _ = controller
        guard let animatorEntityID = scene.animatorGraphOwnerEntityID(for: entity.id) else { return nil }
        return scene.ecs.entity(with: animatorEntityID)
    }

    public func prepareSnapshot(scene: EngineScene, layerFilterMask: LayerMask) -> SnapshotPreparation {
        guard let assets = scene.engineContext?.assets else {
            return SnapshotPreparation()
        }
        var skinnedEntries: [AnimationSnapshotPayload.SkinnedEntry] = []
        var bonePaletteMatrices: [matrix_float4x4] = []
        let skinnedCount = scene.ecs.viewTransformMeshRendererArray().reduce(into: 0) { count, entry in
            let layer = scene.ecs.get(LayerComponent.self, for: entry.0)?.index ?? LayerCatalog.defaultLayerIndex
            guard layerFilterMask.contains(layerIndex: layer) else { return }
            if let skinnedMesh = scene.ecs.get(SkinnedMeshComponent.self, for: entry.0) {
                let animator = scene.ecs.get(AnimatorComponent.self, for: entry.0)
                let paletteRange: AnimationSnapshotPayload.BonePaletteRange?
                if let skeletonHandle = skinnedMesh.skeletonHandle,
                   let skeleton = assets.skeleton(handle: skeletonHandle) {
                    let poseState = animator?.poseRuntimeState
                    let localPose = poseState?.localPose ?? []
                    let globalPose = poseState?.globalPose ?? []
                    let paletteStart = bonePaletteMatrices.count
                    let paletteStartTime = CACurrentMediaTime()
                    let paletteResult = makeBonePalette(skeleton: skeleton, globalPose: globalPose, assets: assets)
                    timingAverages.paletteMS += (CACurrentMediaTime() - paletteStartTime) * 1000.0
                    bonePaletteMatrices.append(contentsOf: paletteResult.matrices)
                    paletteRange = paletteResult.matrices.isEmpty
                        ? nil
                        : AnimationSnapshotPayload.BonePaletteRange(startIndex: paletteStart, count: paletteResult.matrices.count)
                    let activeClipHandle = animator?.clipHandle
                    let forceSummary = shouldForceRuntimeSummary(entityId: entry.0.id, clipHandle: activeClipHandle)
                    logRuntimeSummaryOnce(
                        engineContext: scene.engineContext,
                        entity: entry.0,
                        animator: animator,
                        skinnedMesh: skinnedMesh,
                        skeleton: skeleton,
                        clip: activeClipHandle.flatMap { assets.animationClip(handle: $0) },
                        mesh: scene.ecs.get(MeshRendererComponent.self, for: entry.0)?.meshHandle.flatMap { assets.mesh(handle: $0) },
                        localPose: localPose,
                        globalPose: globalPose,
                        evaluatedJointCount: globalPose.count,
                        bindPolicy: paletteResult.bindPolicy,
                        importedInverseBindCount: paletteResult.importedInverseBindCount,
                        nonFinitePaletteMatrixCount: paletteResult.nonFiniteMatrixCount,
                        forceLog: forceSummary
                    )
                    if forceSummary {
                        markRuntimeSummaryForcedHandled(entityId: entry.0.id, clipHandle: activeClipHandle)
                    }
                } else {
                    paletteRange = nil
                }
                skinnedEntries.append(
                    AnimationSnapshotPayload.SkinnedEntry(
                        entity: entry.0,
                        skeletonHandle: skinnedMesh.skeletonHandle,
                        clipHandle: animator?.clipHandle,
                        playbackTime: animator?.playbackTime ?? 0.0,
                        isPlaying: animator?.isPlaying ?? false,
                        evaluatedJointCount: animator?.poseRuntimeState?.globalPose.count ?? 0,
                        bonePaletteRange: paletteRange
                    )
                )
                count += 1
            }
        }
        let payload = skinnedEntries.isEmpty
            ? nil
            : AnimationSnapshotPayload(skinnedEntries: skinnedEntries, bonePaletteMatrices: bonePaletteMatrices)
        return SnapshotPreparation(skinnedEntityCount: skinnedCount, payload: payload)
    }

    private func makeBonePalette(skeleton: SkeletonAsset,
                                 globalPose: [TransformComponent],
                                 assets: AssetManager? = nil) -> BonePaletteBuildResult {
        let jointCount = min(skeleton.joints.count, globalPose.count)
        guard jointCount > 0 else {
            return BonePaletteBuildResult(matrices: [], bindPolicy: "none", importedInverseBindCount: 0, nonFiniteMatrixCount: 0)
        }

        let bindLocalPose: [TransformComponent] = skeleton.joints.map { joint in
            TransformComponent(position: joint.bindLocalPosition,
                               rotation: joint.bindLocalRotation,
                               scale: joint.bindLocalScale)
        }
        let bindGlobalMatrices = globalMatrices(from: bindLocalPose, skeleton: skeleton, assets: assets)

        var palette = Array(repeating: matrix_identity_float4x4, count: jointCount)
        var importedInverseBindCount = 0
        var nonFiniteMatrixCount = 0
        for jointIndex in 0..<jointCount {
            let pose = globalPose[jointIndex]
            let animatedGlobal = TransformMath.makeMatrix(position: pose.position,
                                                          rotation: pose.rotation,
                                                          scale: pose.scale)
            let inverseBind: matrix_float4x4
            if let imported = skeleton.joints[jointIndex].inverseBindGlobalMatrix,
               matrixIsFinite(imported) {
                inverseBind = imported
                importedInverseBindCount += 1
            } else {
                inverseBind = simd_inverse(bindGlobalMatrices[jointIndex])
            }
            let matrix = animatedGlobal * inverseBind
            if !matrixIsFinite(matrix) {
                nonFiniteMatrixCount += 1
            }
            palette[jointIndex] = matrix
        }
        let bindPolicy: String
        if importedInverseBindCount == 0 {
            bindPolicy = "reconstructedBindInverseOnly"
        } else if importedInverseBindCount == jointCount {
            bindPolicy = "importedInverseBindPreferred"
        } else {
            bindPolicy = "mixedImportedAndReconstructedInverseBind"
        }
        return BonePaletteBuildResult(
            matrices: palette,
            bindPolicy: bindPolicy,
            importedInverseBindCount: importedInverseBindCount,
            nonFiniteMatrixCount: nonFiniteMatrixCount
        )
    }

    private func nextPlaybackTime(current: Float,
                                  dt: Float,
                                  duration: Float,
                                  isLooping: Bool) -> Float {
        guard duration > 0 else { return max(0.0, current + dt) }
        let advanced = current + dt
        if isLooping {
            let wrapped = advanced.truncatingRemainder(dividingBy: duration)
            return wrapped >= 0 ? wrapped : (wrapped + duration)
        }
        return simd_clamp(advanced, 0.0, duration)
    }

    private func evaluateGraphMode(scene: EngineScene,
                                   assets: AssetManager,
                                   entity: Entity,
                                   dt: Float,
                                   fixedTickID: UInt64?,
                                   skinnedMesh: SkinnedMeshComponent?,
                                   skeleton: SkeletonAsset?,
                                   animator: inout AnimatorComponent) {
        guard let graphHandle = animator.graphHandle else {
            animator.evaluationMode = .clip
            animator.graphRuntimeState = nil
            if let skeleton {
                animator.poseRuntimeState = makeBindPoseState(skeleton: skeleton,
                                                              playbackTime: animator.playbackTime,
                                                              assets: assets)
            } else {
                animator.poseRuntimeState = nil
            }
            return
        }

        guard let compiledGraph = assets.compiledAnimationGraph(handle: graphHandle) else {
            let graphPath = scene.engineContext?.assetDatabase?.assetURL(for: graphHandle)?.path ?? "<unresolved>"
            logRuntimeIssueOnce(
                key: "graphCompileFailure|\(entity.id.uuidString)|\(graphHandle.rawValue.uuidString)",
                message: "Animator graph compile/load failure entity=\(entity.id.uuidString)\nactiveGraphHandle=\(graphHandle.rawValue.uuidString)\nactiveGraphPath=\(graphPath)\naction=bindPoseOnly",
                level: .warning
            )
            if let skeleton {
                animator.poseRuntimeState = makeBindPoseState(skeleton: skeleton,
                                                              playbackTime: animator.playbackTime,
                                                              assets: assets)
            } else {
                animator.poseRuntimeState = nil
            }
            return
        }

        var runtimeState = animator.graphRuntimeState ?? AnimationGraphRuntimeInstanceState()
        if runtimeState.graphHandle != graphHandle ||
            !runtimeState.hasStorage(parameterCount: compiledGraph.parameters.count,
                                     localVariableCount: compiledGraph.localVariables.count) {
            runtimeState.resetDefaults(from: compiledGraph, graphHandle: graphHandle)
        }

        let graphPath = scene.engineContext?.assetDatabase?.assetURL(for: graphHandle)?.path ?? "<unresolved>"
        guard let skeleton else {
            logRuntimeIssueOnce(
                key: "graphNoSkeleton|\(entity.id.uuidString)|\(graphHandle.rawValue.uuidString)",
                message: "Animator graph evaluation skipped entity=\(entity.id.uuidString)\nactiveGraphHandle=\(graphHandle.rawValue.uuidString)\nactiveGraphPath=\(graphPath)\nreason=missingSkeleton\nevaluatedPose=false",
                level: .warning
            )
            animator.poseRuntimeState = nil
            animator.graphRuntimeState = runtimeState
            return
        }

        guard let outputSourceNodeIndex = graphOutputSourceNodeIndex(compiledGraph: compiledGraph) else {
            logRuntimeIssueOnce(
                key: "graphNoOutputInput|\(entity.id.uuidString)|\(graphHandle.rawValue.uuidString)",
                message: "Animator graph evaluation fallback entity=\(entity.id.uuidString)\nactiveGraphHandle=\(graphHandle.rawValue.uuidString)\nactiveGraphPath=\(graphPath)\nactiveOutputNode=\(compiledGraph.nodes[compiledGraph.outputNodeIndex].id.uuidString)\nactiveOutputSourceNode=<none>\nreason=outputPoseHasNoIncomingLink\nevaluatedPose=false",
                level: .warning
            )
            animator.poseRuntimeState = makeBindPoseState(skeleton: skeleton,
                                                          playbackTime: animator.playbackTime,
                                                          assets: assets)
            animator.graphRuntimeState = runtimeState
            return
        }

        let sourceNode = compiledGraph.nodes[outputSourceNodeIndex]
        if animator.isPlaying, dt > 0 {
            let playbackStep = dt * max(0.0, animator.playbackSpeed)
            animator.playbackTime = max(0.0, animator.playbackTime + playbackStep)
            if runtimeState.transitionDurationSeconds > 0 {
                runtimeState.transitionElapsedSeconds = min(runtimeState.transitionDurationSeconds,
                                                            runtimeState.transitionElapsedSeconds + playbackStep)
            }
        }

        let rootSelection = resolveRootJointSelection(skeleton: skeleton, skinnedMesh: skinnedMesh)
        var evaluationContext = GraphEvaluationContext(compiledGraph: compiledGraph,
                                                       assets: assets,
                                                       skeleton: skeleton,
                                                       rootJointIndex: rootSelection.index,
                                                       rootBoneName: rootSelection.name,
                                                       entityID: entity.id,
                                                       graphHandle: graphHandle,
                                                       runtimeState: runtimeState,
                                                       isPlaying: animator.isPlaying,
                                                       deltaTime: dt * max(0.0, animator.playbackSpeed),
                                                       isLooping: animator.isLooping,
                                                       fixedTickID: fixedTickID,
                                                       rootMotionTranslationJointOverride: nil,
                                                       rootMotionRotationJointOverride: nil)
        evaluationContext.valueContext.captureDebugTrace = runtimeState.captureDebugTrace
        let graphEvalStart = CACurrentMediaTime()
        guard let graphResult = evaluateGraphNodePose(nodeIndex: outputSourceNodeIndex, context: &evaluationContext) else {
            logRuntimeIssueOnce(
                key: "graphEvalFailed|\(entity.id.uuidString)|\(graphHandle.rawValue.uuidString)|\(sourceNode.id.uuidString)",
                message: "Animator graph evaluation fallback entity=\(entity.id.uuidString)\nactiveGraphHandle=\(graphHandle.rawValue.uuidString)\nactiveGraphPath=\(graphPath)\nactiveOutputNode=\(compiledGraph.nodes[compiledGraph.outputNodeIndex].id.uuidString)\nactiveOutputSourceNode=\(sourceNode.id.uuidString)\nactiveOutputSourceType=\(sourceNode.type.rawValue)\nreason=nodeEvaluationFailed\nevaluatedPose=false",
                level: .warning
            )
            animator.poseRuntimeState = makeBindPoseState(skeleton: skeleton,
                                                          playbackTime: animator.playbackTime,
                                                          assets: assets)
            animator.graphRuntimeState = runtimeState
            return
        }
        let graphEvalElapsedMS = (CACurrentMediaTime() - graphEvalStart) * 1000.0

        runtimeState = evaluationContext.runtimeState
        if runtimeState.captureDebugTrace {
            runtimeState.debugTraceEntries = evaluationContext.valueContext.debugTraceEntries.map {
                AnimationGraphDebugTraceEntry(nodeID: $0.nodeID,
                                              nodeType: $0.nodeType,
                                              nodeTitle: $0.nodeTitle,
                                              outputSummary: $0.outputSummary)
            }
        } else if !runtimeState.debugTraceEntries.isEmpty {
            runtimeState.debugTraceEntries.removeAll(keepingCapacity: true)
        }
        runtimeState.currentStateNodeID = sourceNode.id
        animator.graphRuntimeState = runtimeState
        let localToGlobalStart = CACurrentMediaTime()
        let graphSampleStart = max(0.0, graphResult.sampleTime - max(evaluationContext.deltaTime, 0.0))
        let rootMotionSample = makeRootMotionSample(tickID: fixedTickID,
                                                    delta: graphResult.rootMotionDelta,
                                                    sourceStateName: graphResult.currentStateName,
                                                    sourceNodeID: sourceNode.id,
                                                    sampleStartTime: graphSampleStart,
                                                    sampleEndTime: graphResult.sampleTime,
                                                    isValid: graphResult.usesRootMotion && animator.enableRootMotion && graphResult.rootMotionValid)
        let fixedTickRuntimeSnapshot: AnimationFixedTickRuntimeSnapshot? = fixedTickID.map {
            makeFixedTickRuntimeSnapshot(fixedTickID: $0,
                                         compiledGraph: compiledGraph,
                                         runtimeState: runtimeState,
                                         graphResult: graphResult)
        }
        animator.poseRuntimeState = makePoseState(skeleton: skeleton,
                                                  localPose: graphResult.localPose,
                                                  sampleTime: graphResult.sampleTime,
                                                  sampleDuration: graphResult.sampleDuration,
                                                  rootMotionDelta: graphResult.rootMotionDelta,
                                                  rootMotionSample: rootMotionSample,
                                                  usesRootMotion: graphResult.usesRootMotion && animator.enableRootMotion,
                                                  currentStateName: graphResult.currentStateName,
                                                  rootMotionBoneName: graphResult.rootMotionBoneName,
                                                  rootMotionJointIndex: graphResult.rootMotionJointIndex,
                                                  rootMotionTrackConsumed: graphResult.rootMotionTrackConsumed,
                                                  rootMotionTranslationBoneName: graphResult.rootMotionTranslationBoneName,
                                                  rootMotionTranslationJointIndex: graphResult.rootMotionTranslationJointIndex,
                                                  rootMotionRotationBoneName: graphResult.rootMotionRotationBoneName,
                                                  rootMotionRotationJointIndex: graphResult.rootMotionRotationJointIndex,
                                                  rootMotionConsumeBoneName: graphResult.rootMotionConsumeBoneName,
                                                  rootMotionConsumeJointIndex: graphResult.rootMotionConsumeJointIndex,
                                                  fixedTickRuntimeSnapshot: fixedTickRuntimeSnapshot,
                                                  assets: assets)
        let localToGlobalElapsedMS = (CACurrentMediaTime() - localToGlobalStart) * 1000.0
        timingAverages.graphEvalMS += graphEvalElapsedMS
        timingAverages.samplePoseMS += evaluationContext.samplePoseTimeMS
        timingAverages.blendMS += evaluationContext.blendTimeMS
        timingAverages.localToGlobalMS += localToGlobalElapsedMS
    }

    private func graphOutputSourceNodeIndex(compiledGraph: CompiledAnimationGraph) -> Int? {
        let candidates = compiledGraph.links
            .filter { $0.toNodeIndex == compiledGraph.outputNodeIndex }
            .sorted { lhs, rhs in
                if lhs.toSlotIndex == rhs.toSlotIndex {
                    return lhs.fromNodeIndex < rhs.fromNodeIndex
                }
                return lhs.toSlotIndex < rhs.toSlotIndex
            }
        return candidates.first?.fromNodeIndex
    }

    private struct GraphNodeEvaluationResult {
        let localPose: [TransformComponent]
        let sampleTime: Float
        let sampleDuration: Float
        let rootMotionDelta: RootMotionDelta
        let rootMotionSample: RootMotionRuntimeSample?
        let rootMotionValid: Bool
        let rootMotionSampleHasNonZeroDelta: Bool
        let authoredUsesRootMotion: Bool
        let usesRootMotion: Bool
        let currentStateName: String
        let rootMotionBoneName: String
        let rootMotionJointIndex: Int
        let rootMotionTrackConsumed: Bool
        let rootMotionTranslationBoneName: String
        let rootMotionTranslationJointIndex: Int
        let rootMotionRotationBoneName: String
        let rootMotionRotationJointIndex: Int
        let rootMotionConsumeBoneName: String
        let rootMotionConsumeJointIndex: Int
        let diagnosticClipHandle: String?

        init(localPose: [TransformComponent],
             sampleTime: Float,
             sampleDuration: Float,
             rootMotionDelta: RootMotionDelta,
             rootMotionSample: RootMotionRuntimeSample? = nil,
             rootMotionValid: Bool? = nil,
             authoredUsesRootMotion: Bool = false,
             usesRootMotion: Bool,
             currentStateName: String,
             rootMotionBoneName: String,
             rootMotionJointIndex: Int,
             rootMotionTrackConsumed: Bool,
             rootMotionTranslationBoneName: String = "",
             rootMotionTranslationJointIndex: Int = -1,
             rootMotionRotationBoneName: String = "",
             rootMotionRotationJointIndex: Int = -1,
             rootMotionConsumeBoneName: String = "",
             rootMotionConsumeJointIndex: Int = -1,
             diagnosticClipHandle: String?) {
            self.localPose = localPose
            self.sampleTime = sampleTime
            self.sampleDuration = sampleDuration
            self.rootMotionDelta = rootMotionDelta
            self.rootMotionSample = rootMotionSample
            if let rootMotionValid {
                self.rootMotionValid = rootMotionValid
            } else {
                let translationMagnitude = simd_length(rootMotionDelta.deltaPos)
                let deltaRotation = simd_quatf(vector: TransformMath.normalizedQuaternion(rootMotionDelta.deltaRot))
                let rotationRadians = 2.0 * acos(simd_clamp(abs(deltaRotation.real), 0.0, 1.0))
                self.rootMotionValid = translationMagnitude > 1.0e-6 || rotationRadians > 1.0e-5
            }
            self.rootMotionSampleHasNonZeroDelta = self.rootMotionValid
            self.authoredUsesRootMotion = authoredUsesRootMotion
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
            self.diagnosticClipHandle = diagnosticClipHandle
        }
    }

    private enum RootMotionChannelMode: String {
        case none
        case animation
        case controller
    }

    private enum TransitionRootMotionPolicy: String {
        case sourceDominant
        case targetDominant
        case blended
        case none
    }

    private enum TransitionRootMotionType: String {
        case falseToFalse
        case falseToTrue
        case trueToFalse
        case trueToTrue
    }

    private struct RootMotionPolicy {
        let translationMode: RootMotionChannelMode
        let rotationMode: RootMotionChannelMode
        let allowDuringTransition: Bool
        let transitionPolicy: TransitionRootMotionPolicy
        let consumeTranslation: Bool
        let consumeRotation: Bool

        var applyTranslation: Bool { translationMode == .animation }
        var applyRotation: Bool { rotationMode == .animation }
    }

    private struct RootMotionChannels {
        let translationJointIndex: Int
        let rotationJointIndex: Int
        let consumeJointIndex: Int
        let translationJointName: String
        let rotationJointName: String
        let consumeJointName: String
    }
    private struct RootMotionExtractionChannels {
        let translationJointIndex: Int
        let rotationJointIndex: Int
        let translationJointName: String
        let rotationJointName: String
    }
    private struct TransitionRootMotionSelection {
        let selectedDelta: RootMotionDelta
        let blendedDelta: RootMotionDelta
        let authoredUsesRootMotion: Bool
        let usesRootMotion: Bool
        let trackConsumed: Bool
        let authorityState: String
        let currentStateName: String
        let rootMotionBoneName: String
        let rootMotionJointIndex: Int
        let consumeJointName: String
        let consumeJointIndex: Int
        let sampleTime: Float
        let sampleDuration: Float
        let translationJointName: String
        let translationJointIndex: Int
        let rotationJointName: String
        let rotationJointIndex: Int
        let transitionType: TransitionRootMotionType
        let transitionPolicy: TransitionRootMotionPolicy
    }

    private struct NodeSampleTimes {
        let previous: Float
        let current: Float
    }

    private struct GraphEvaluationContext {
        let compiledGraph: CompiledAnimationGraph
        let assets: AssetManager
        let skeleton: SkeletonAsset
        let rootJointIndex: Int
        let rootBoneName: String
        let entityID: UUID
        let graphHandle: AnimationGraphHandle
        var runtimeState: AnimationGraphRuntimeInstanceState
        let isPlaying: Bool
        let deltaTime: Float
        let isLooping: Bool
        let fixedTickID: UInt64?
        var rootMotionTranslationJointOverride: Int?
        var rootMotionRotationJointOverride: Int?
        var activeStateNameForRootMotionDiagnostics: String = ""
        var valueContext = GraphValueEvaluationContext()
        var samplePoseTimeMS: Double = 0
        var blendTimeMS: Double = 0
    }

    private enum GraphRuntimeValue {
        case pose(GraphNodeEvaluationResult)
        case float(Float)
        case bool(Bool)
        case int(Int)
    }

    private struct GraphEvaluationTraceEntry {
        let nodeID: UUID
        let nodeType: String
        let nodeTitle: String
        let outputSummary: String
    }

    private struct GraphValueEvaluationContext {
        var valuesByNodeID: [UUID: GraphRuntimeValue] = [:]
        var evaluationStack: [UUID] = []
        var captureDebugTrace = false
        var debugTraceEntries: [GraphEvaluationTraceEntry] = []
    }

    private struct TransitionSelection {
        let transition: AnimationGraphTransitionDefinition
        let durationSeconds: Float
        let synchronize: Bool
    }

    private struct TransitionGraphRuntimeInstance {
        let transitionID: UUID
        let nodes: [AnimationGraphTransitionGraphNodeDefinition]
        let links: [AnimationGraphTransitionGraphLinkDefinition]
        let outputNodeIndex: Int
        let nodeIndexByID: [UUID: Int]
    }

    private struct TransitionGraphOutput {
        let transition: Bool
        let synchronize: Bool
        let durationOverride: Float?
        let triggerIndicesToConsume: Set<Int>
    }

    private struct TransitionGraphEvaluationContext {
        let runtime: TransitionGraphRuntimeInstance
        let compiledGraph: CompiledAnimationGraph
        var runtimeState: AnimationGraphRuntimeInstanceState
        var valueContext = GraphValueEvaluationContext()
        var triggerIndicesToConsume: Set<Int> = []
    }

    private func runtimeValueSummary(_ value: GraphRuntimeValue) -> String {
        switch value {
        case let .pose(pose):
            return "pose(t=\(pose.sampleTime),d=\(pose.sampleDuration))"
        case let .float(value):
            return "float(\(value))"
        case let .bool(value):
            return "bool(\(value))"
        case let .int(value):
            return "int(\(value))"
        }
    }

    private func beginGraphNodeEvaluation(nodeID: UUID,
                                          valueContext: inout GraphValueEvaluationContext) -> Bool {
        if valueContext.evaluationStack.contains(nodeID) {
            return false
        }
        valueContext.evaluationStack.append(nodeID)
        return true
    }

    private func endGraphNodeEvaluation(nodeID: UUID,
                                        valueContext: inout GraphValueEvaluationContext) {
        if valueContext.evaluationStack.last == nodeID {
            _ = valueContext.evaluationStack.popLast()
            return
        }
        valueContext.evaluationStack.removeAll(where: { $0 == nodeID })
    }

    private func storeGraphNodeValue(_ value: GraphRuntimeValue,
                                     nodeID: UUID,
                                     nodeType: String,
                                     nodeTitle: String,
                                     valueContext: inout GraphValueEvaluationContext) {
        valueContext.valuesByNodeID[nodeID] = value
        guard valueContext.captureDebugTrace else { return }
        if valueContext.debugTraceEntries.count >= 2048 {
            valueContext.debugTraceEntries.removeFirst(valueContext.debugTraceEntries.count - 2047)
        }
        valueContext.debugTraceEntries.append(
            GraphEvaluationTraceEntry(nodeID: nodeID,
                                      nodeType: nodeType,
                                      nodeTitle: nodeTitle,
                                      outputSummary: runtimeValueSummary(value))
        )
    }

    private func scalarRuntimeValue(_ value: GraphRuntimeValue) -> GraphRuntimeValue? {
        switch value {
        case .pose:
            return nil
        case .float, .bool, .int:
            return value
        }
    }

    private func poseRuntimeValue(_ value: GraphRuntimeValue) -> GraphNodeEvaluationResult? {
        switch value {
        case let .pose(pose):
            return pose
        default:
            return nil
        }
    }

    private func evaluateCompiledNodeValue(nodeIndex: Int,
                                           context: inout GraphEvaluationContext) -> GraphRuntimeValue? {
        guard nodeIndex >= 0, nodeIndex < context.compiledGraph.nodes.count else { return nil }
        let node = context.compiledGraph.nodes[nodeIndex]
        if let cached = context.valueContext.valuesByNodeID[node.id] {
            return cached
        }
        guard beginGraphNodeEvaluation(nodeID: node.id, valueContext: &context.valueContext) else {
            return nil
        }
        defer { endGraphNodeEvaluation(nodeID: node.id, valueContext: &context.valueContext) }
        let result: GraphRuntimeValue?
        switch node.type {
        case .clipPlayer:
            result = evaluateClipPlayerNode(node: node, context: &context).map(GraphRuntimeValue.pose)
        case .blend1D:
            result = evaluateBlend1DNode(node: node, context: &context).map(GraphRuntimeValue.pose)
        case .blend2D:
            result = evaluateBlend2DNode(node: node, context: &context).map(GraphRuntimeValue.pose)
        case .blendList,
             .layeredBlend,
             .select,
             .poseCache,
             .aimOffset,
             .lookAt,
             .twoBoneIK,
             .strideWarp,
             .orientationWarp,
             .motionMatch,
             .rootMotionModifier:
            result = evaluatePassThroughPoseNode(nodeIndex: nodeIndex, context: &context).map(GraphRuntimeValue.pose)
        case .additiveClip:
            result = evaluateClipPlayerNode(node: node, context: &context).map(GraphRuntimeValue.pose)
        case .stateMachine:
            result = evaluateStateMachineNode(node: node, context: &context).map(GraphRuntimeValue.pose)
        case .parameterFloat,
             .parameterBool,
             .parameterInt,
             .parameterTrigger,
             .parameter:
            result = evaluateParameterNodeValue(node: node, context: &context)
        case .localFloat:
            result = evaluateLocalVariableNodeValue(node: node, expectedType: .float, context: &context)
        case .localBool:
            result = evaluateLocalVariableNodeValue(node: node, expectedType: .bool, context: &context)
        case .localInt:
            result = evaluateLocalVariableNodeValue(node: node, expectedType: .int, context: &context)
        case .setLocalFloat:
            result = evaluateSetLocalNodeValue(nodeIndex: nodeIndex, node: node, expectedType: .float, context: &context)
        case .setLocalBool:
            result = evaluateSetLocalNodeValue(nodeIndex: nodeIndex, node: node, expectedType: .bool, context: &context)
        case .setLocalInt:
            result = evaluateSetLocalNodeValue(nodeIndex: nodeIndex, node: node, expectedType: .int, context: &context)
        default:
            result = nil
        }
        if let result {
            storeGraphNodeValue(result,
                                nodeID: node.id,
                                nodeType: node.type.rawValue,
                                nodeTitle: node.title,
                                valueContext: &context.valueContext)
        }
        return result
    }

    private func evaluateGraphNodePose(nodeIndex: Int,
                                       context: inout GraphEvaluationContext) -> GraphNodeEvaluationResult? {
        guard let value = evaluateCompiledNodeValue(nodeIndex: nodeIndex, context: &context) else { return nil }
        return poseRuntimeValue(value)
    }

    private func evaluatePassThroughPoseNode(nodeIndex: Int,
                                             context: inout GraphEvaluationContext) -> GraphNodeEvaluationResult? {
        let candidates = context.compiledGraph.links
            .filter { $0.toNodeIndex == nodeIndex }
            .sorted { lhs, rhs in
                if lhs.toSlotIndex == rhs.toSlotIndex {
                    return lhs.fromNodeIndex < rhs.fromNodeIndex
                }
                return lhs.toSlotIndex < rhs.toSlotIndex
            }
        for candidate in candidates {
            if let result = evaluateGraphNodePose(nodeIndex: candidate.fromNodeIndex, context: &context) {
                return result
            }
        }
        return nil
    }

    private func evaluateClipPlayerNode(node: CompiledAnimationGraph.Node,
                                        context: inout GraphEvaluationContext) -> GraphNodeEvaluationResult? {
        guard let clipHandle = node.clipHandle,
              let clip = context.assets.animationClip(handle: clipHandle) else { return nil }
        let sampleTimes = advanceAndResolveNodeSampleTime(nodeID: node.id,
                                                          duration: clip.durationSeconds,
                                                          isLooping: context.isLooping,
                                                          context: &context)
        let sampleStart = CACurrentMediaTime()
        let localPose = evaluateLocalPose(skeleton: context.skeleton, clip: clip, playbackTime: sampleTimes.current, assets: context.assets)
        context.samplePoseTimeMS += (CACurrentMediaTime() - sampleStart) * 1000.0
        let extractionChannels = resolveExtractionChannelsForClip(skeleton: context.skeleton,
                                                                  clip: clip,
                                                                  preferredRootJointIndex: context.rootJointIndex,
                                                                  translationJointIndexOverride: context.rootMotionTranslationJointOverride,
                                                                  rotationJointIndexOverride: context.rootMotionRotationJointOverride)
        let rootMotion = sampleClipRootMotionDelta(skeleton: context.skeleton,
                                                   clip: clip,
                                                   rootJointIndex: context.rootJointIndex,
                                                   trackerEntityID: context.entityID,
                                                   trackerKey: "graph:\(node.id.uuidString)|clip:\(clip.handle.rawValue.uuidString)|single",
                                                   translationJointIndexOverride: context.rootMotionTranslationJointOverride,
                                                   rotationJointIndexOverride: context.rootMotionRotationJointOverride,
                                                   previousTime: sampleTimes.previous,
                                                   currentTime: sampleTimes.current,
                                                   isLooping: context.isLooping,
                                                   sourceStateName: context.activeStateNameForRootMotionDiagnostics,
                                                   assets: context.assets)
        return GraphNodeEvaluationResult(localPose: localPose,
                                         sampleTime: sampleTimes.current,
                                         sampleDuration: max(clip.durationSeconds, 0.0),
                                         rootMotionDelta: rootMotion,
                                         usesRootMotion: false,
                                         currentStateName: "",
                                         rootMotionBoneName: context.rootBoneName,
                                         rootMotionJointIndex: context.rootJointIndex,
                                         rootMotionTrackConsumed: false,
                                         rootMotionTranslationBoneName: extractionChannels.translationJointName,
                                         rootMotionTranslationJointIndex: extractionChannels.translationJointIndex,
                                         rootMotionRotationBoneName: extractionChannels.rotationJointName,
                                         rootMotionRotationJointIndex: extractionChannels.rotationJointIndex,
                                         diagnosticClipHandle: clipHandle.rawValue.uuidString)
    }

    private func evaluateBlend1DNode(node: CompiledAnimationGraph.Node,
                                     context: inout GraphEvaluationContext) -> GraphNodeEvaluationResult? {
        guard let blend = node.blend1D, !blend.samples.isEmpty else { return nil }
        let parameterValue = resolvedBlendInputFloat(nodeIndex: node.index,
                                                     inputSlot: 0,
                                                     fallbackParameterName: blend.parameterName,
                                                     context: &context)
        let sortedSamples = blend.samples.sorted { $0.threshold < $1.threshold }
        let representativeDuration = sortedSamples.reduce(Float(0.0)) { current, sample in
            guard let clip = context.assets.animationClip(handle: sample.clipHandle) else { return current }
            return max(current, clip.durationSeconds)
        }
        let lowerUpper = neighboringBlend1DSamples(samples: sortedSamples, value: parameterValue)
        switch lowerUpper {
        case let (lower?, upper?) where lower.clipHandle == upper.clipHandle || abs(upper.threshold - lower.threshold) <= 1.0e-5:
            guard let clip = context.assets.animationClip(handle: lower.clipHandle) else { return nil }
            // Single-clip output must advance on that clip's own duration. Using a representative
            // blend duration (for example walk=1.033s while run=0.7s) causes periodic loop seams.
            let clipNodeSampleTimes = advanceAndResolveNodeSampleTime(nodeID: node.id,
                                                                      duration: clip.durationSeconds,
                                                                      isLooping: context.isLooping,
                                                                      context: &context)
            let sampleTime = resolveClipSampleTime(nodeTime: clipNodeSampleTimes.current,
                                                   duration: clip.durationSeconds,
                                                   isLooping: context.isLooping)
            let previousTime = resolveClipSampleTime(nodeTime: clipNodeSampleTimes.previous,
                                                     duration: clip.durationSeconds,
                                                     isLooping: context.isLooping)
            let sampleStart = CACurrentMediaTime()
            let localPose = evaluateLocalPose(skeleton: context.skeleton, clip: clip, playbackTime: sampleTime, assets: context.assets)
            context.samplePoseTimeMS += (CACurrentMediaTime() - sampleStart) * 1000.0
            let extractionChannels = resolveExtractionChannelsForClip(skeleton: context.skeleton,
                                                                      clip: clip,
                                                                      preferredRootJointIndex: context.rootJointIndex,
                                                                      translationJointIndexOverride: context.rootMotionTranslationJointOverride,
                                                                      rotationJointIndexOverride: context.rootMotionRotationJointOverride)
            let rootMotion = sampleClipRootMotionDelta(skeleton: context.skeleton,
                                                       clip: clip,
                                                       rootJointIndex: context.rootJointIndex,
                                                       trackerEntityID: context.entityID,
                                                       trackerKey: "graph:\(node.id.uuidString)|clip:\(clip.handle.rawValue.uuidString)|exact",
                                                       translationJointIndexOverride: context.rootMotionTranslationJointOverride,
                                                       rotationJointIndexOverride: context.rootMotionRotationJointOverride,
                                                       previousTime: previousTime,
                                                       currentTime: sampleTime,
                                                       isLooping: context.isLooping,
                                                       sourceStateName: context.activeStateNameForRootMotionDiagnostics,
                                                       assets: context.assets)
            return GraphNodeEvaluationResult(localPose: localPose,
                                             sampleTime: sampleTime,
                                             sampleDuration: max(clip.durationSeconds, 0.0),
                                             rootMotionDelta: rootMotion,
                                             usesRootMotion: false,
                                             currentStateName: "",
                                             rootMotionBoneName: context.rootBoneName,
                                             rootMotionJointIndex: context.rootJointIndex,
                                             rootMotionTrackConsumed: false,
                                             rootMotionTranslationBoneName: extractionChannels.translationJointName,
                                             rootMotionTranslationJointIndex: extractionChannels.translationJointIndex,
                                             rootMotionRotationBoneName: extractionChannels.rotationJointName,
                                             rootMotionRotationJointIndex: extractionChannels.rotationJointIndex,
                                             diagnosticClipHandle: lower.clipHandle.rawValue.uuidString)
        case let (lower?, upper?):
            guard let lowerClip = context.assets.animationClip(handle: lower.clipHandle),
                  let upperClip = context.assets.animationClip(handle: upper.clipHandle) else { return nil }
            let t = simd_clamp((parameterValue - lower.threshold) / max(upper.threshold - lower.threshold, 1.0e-5), 0.0, 1.0)
            let representativeNodeSampleTimes = advanceAndResolveNodeSampleTime(nodeID: node.id,
                                                                                duration: representativeDuration,
                                                                                isLooping: context.isLooping,
                                                                                context: &context)
            let lowerTime = resolveClipSampleTime(nodeTime: representativeNodeSampleTimes.current,
                                                  duration: lowerClip.durationSeconds,
                                                  isLooping: context.isLooping)
            let upperTime = resolveClipSampleTime(nodeTime: representativeNodeSampleTimes.current,
                                                  duration: upperClip.durationSeconds,
                                                  isLooping: context.isLooping)
            let lowerPreviousTime = resolveClipSampleTime(nodeTime: representativeNodeSampleTimes.previous,
                                                          duration: lowerClip.durationSeconds,
                                                          isLooping: context.isLooping)
            let upperPreviousTime = resolveClipSampleTime(nodeTime: representativeNodeSampleTimes.previous,
                                                          duration: upperClip.durationSeconds,
                                                          isLooping: context.isLooping)
            let sampleStart = CACurrentMediaTime()
            let lowerLocalPose = evaluateLocalPose(skeleton: context.skeleton, clip: lowerClip, playbackTime: lowerTime, assets: context.assets)
            let upperLocalPose = evaluateLocalPose(skeleton: context.skeleton, clip: upperClip, playbackTime: upperTime, assets: context.assets)
            context.samplePoseTimeMS += (CACurrentMediaTime() - sampleStart) * 1000.0
            let lowerExtractionChannels = resolveExtractionChannelsForClip(skeleton: context.skeleton,
                                                                           clip: lowerClip,
                                                                           preferredRootJointIndex: context.rootJointIndex,
                                                                           translationJointIndexOverride: context.rootMotionTranslationJointOverride,
                                                                           rotationJointIndexOverride: context.rootMotionRotationJointOverride)
            let upperExtractionChannels = resolveExtractionChannelsForClip(skeleton: context.skeleton,
                                                                           clip: upperClip,
                                                                           preferredRootJointIndex: context.rootJointIndex,
                                                                           translationJointIndexOverride: context.rootMotionTranslationJointOverride,
                                                                           rotationJointIndexOverride: context.rootMotionRotationJointOverride)
            let lowerRootMotion = sampleClipRootMotionDelta(skeleton: context.skeleton,
                                                            clip: lowerClip,
                                                            rootJointIndex: context.rootJointIndex,
                                                            trackerEntityID: context.entityID,
                                                            trackerKey: "graph:\(node.id.uuidString)|clip:\(lowerClip.handle.rawValue.uuidString)|lower",
                                                            translationJointIndexOverride: context.rootMotionTranslationJointOverride,
                                                            rotationJointIndexOverride: context.rootMotionRotationJointOverride,
                                                            previousTime: lowerPreviousTime,
                                                            currentTime: lowerTime,
                                                            isLooping: context.isLooping,
                                                            sourceStateName: context.activeStateNameForRootMotionDiagnostics,
                                                            assets: context.assets)
            let upperRootMotion = sampleClipRootMotionDelta(skeleton: context.skeleton,
                                                            clip: upperClip,
                                                            rootJointIndex: context.rootJointIndex,
                                                            trackerEntityID: context.entityID,
                                                            trackerKey: "graph:\(node.id.uuidString)|clip:\(upperClip.handle.rawValue.uuidString)|upper",
                                                            translationJointIndexOverride: context.rootMotionTranslationJointOverride,
                                                            rotationJointIndexOverride: context.rootMotionRotationJointOverride,
                                                            previousTime: upperPreviousTime,
                                                            currentTime: upperTime,
                                                            isLooping: context.isLooping,
                                                            sourceStateName: context.activeStateNameForRootMotionDiagnostics,
                                                            assets: context.assets)
            let blendStart = CACurrentMediaTime()
            let blendedLocal = blendLocalPoses(lowerLocalPose,
                                               upperLocalPose,
                                               weight: t,
                                               skeleton: context.skeleton,
                                               assets: context.assets)
            let blendedRootMotion = blendRootMotionDeltas(lowerRootMotion, upperRootMotion, weight: t)
            context.blendTimeMS += (CACurrentMediaTime() - blendStart) * 1000.0
            let matchingTranslationSource = lowerExtractionChannels.translationJointIndex == upperExtractionChannels.translationJointIndex
            let matchingRotationSource = lowerExtractionChannels.rotationJointIndex == upperExtractionChannels.rotationJointIndex
            return GraphNodeEvaluationResult(localPose: blendedLocal,
                                             sampleTime: representativeNodeSampleTimes.current,
                                             sampleDuration: max(representativeDuration, 0.0),
                                             rootMotionDelta: blendedRootMotion,
                                             usesRootMotion: false,
                                             currentStateName: "",
                                             rootMotionBoneName: context.rootBoneName,
                                             rootMotionJointIndex: context.rootJointIndex,
                                             rootMotionTrackConsumed: false,
                                             rootMotionTranslationBoneName: matchingTranslationSource ? lowerExtractionChannels.translationJointName : "<mixed>",
                                             rootMotionTranslationJointIndex: matchingTranslationSource ? lowerExtractionChannels.translationJointIndex : -1,
                                             rootMotionRotationBoneName: matchingRotationSource ? lowerExtractionChannels.rotationJointName : "<mixed>",
                                             rootMotionRotationJointIndex: matchingRotationSource ? lowerExtractionChannels.rotationJointIndex : -1,
                                             diagnosticClipHandle: "\(lower.clipHandle.rawValue.uuidString),\(upper.clipHandle.rawValue.uuidString)")
        case let (single?, nil), let (nil, single?):
            guard let clip = context.assets.animationClip(handle: single.clipHandle) else { return nil }
            let clipNodeSampleTimes = advanceAndResolveNodeSampleTime(nodeID: node.id,
                                                                      duration: clip.durationSeconds,
                                                                      isLooping: context.isLooping,
                                                                      context: &context)
            let sampleTime = resolveClipSampleTime(nodeTime: clipNodeSampleTimes.current,
                                                   duration: clip.durationSeconds,
                                                   isLooping: context.isLooping)
            let previousTime = resolveClipSampleTime(nodeTime: clipNodeSampleTimes.previous,
                                                     duration: clip.durationSeconds,
                                                     isLooping: context.isLooping)
            let sampleStart = CACurrentMediaTime()
            let localPose = evaluateLocalPose(skeleton: context.skeleton, clip: clip, playbackTime: sampleTime, assets: context.assets)
            context.samplePoseTimeMS += (CACurrentMediaTime() - sampleStart) * 1000.0
            let extractionChannels = resolveExtractionChannelsForClip(skeleton: context.skeleton,
                                                                      clip: clip,
                                                                      preferredRootJointIndex: context.rootJointIndex,
                                                                      translationJointIndexOverride: context.rootMotionTranslationJointOverride,
                                                                      rotationJointIndexOverride: context.rootMotionRotationJointOverride)
            let rootMotion = sampleClipRootMotionDelta(skeleton: context.skeleton,
                                                       clip: clip,
                                                       rootJointIndex: context.rootJointIndex,
                                                       trackerEntityID: context.entityID,
                                                       trackerKey: "graph:\(node.id.uuidString)|clip:\(clip.handle.rawValue.uuidString)|singleFallback",
                                                       translationJointIndexOverride: context.rootMotionTranslationJointOverride,
                                                       rotationJointIndexOverride: context.rootMotionRotationJointOverride,
                                                       previousTime: previousTime,
                                                       currentTime: sampleTime,
                                                       isLooping: context.isLooping,
                                                       sourceStateName: context.activeStateNameForRootMotionDiagnostics,
                                                       assets: context.assets)
            return GraphNodeEvaluationResult(localPose: localPose,
                                             sampleTime: sampleTime,
                                             sampleDuration: max(clip.durationSeconds, 0.0),
                                             rootMotionDelta: rootMotion,
                                             usesRootMotion: false,
                                             currentStateName: "",
                                             rootMotionBoneName: context.rootBoneName,
                                             rootMotionJointIndex: context.rootJointIndex,
                                             rootMotionTrackConsumed: false,
                                             rootMotionTranslationBoneName: extractionChannels.translationJointName,
                                             rootMotionTranslationJointIndex: extractionChannels.translationJointIndex,
                                             rootMotionRotationBoneName: extractionChannels.rotationJointName,
                                             rootMotionRotationJointIndex: extractionChannels.rotationJointIndex,
                                             diagnosticClipHandle: single.clipHandle.rawValue.uuidString)
        default:
            return nil
        }
    }

    private func evaluateBlend2DNode(node: CompiledAnimationGraph.Node,
                                     context: inout GraphEvaluationContext) -> GraphNodeEvaluationResult? {
        guard let blend = node.blend2D, !blend.samples.isEmpty else { return nil }
        let px = resolvedBlendInputFloat(nodeIndex: node.index,
                                         inputSlot: 0,
                                         fallbackParameterName: blend.parameterXName,
                                         context: &context)
        let py = resolvedBlendInputFloat(nodeIndex: node.index,
                                         inputSlot: 1,
                                         fallbackParameterName: blend.parameterYName,
                                         context: &context)
        let originalPoint = SIMD2<Float>(px, py)
        var parameterPoint = originalPoint
        let locomotionNode = isLocomotionBlendNode(node)
        let cardinalStrafeIntent = locomotionNode
            && abs(parameterPoint.x) >= 0.75
            && abs(parameterPoint.y) <= 0.2
        // For pure cardinal strafe, lock to exact side sample to prevent forward contamination.
        if cardinalStrafeIntent {
            parameterPoint = SIMD2<Float>(parameterPoint.x < 0.0 ? -1.0 : 1.0, 0.0)
        } else if locomotionNode,
                  abs(parameterPoint.x) >= 0.85,
                  abs(parameterPoint.y) <= 0.15 {
            parameterPoint.y = 0.0
        }

        let representativeDuration = blend.samples.reduce(Float(0.0)) { current, sample in
            guard let clip = context.assets.animationClip(handle: sample.clipHandle) else { return current }
            return max(current, clip.durationSeconds)
        }
        let nodeSampleTimes = advanceAndResolveNodeSampleTime(nodeID: node.id,
                                                              duration: representativeDuration,
                                                              isLooping: context.isLooping,
                                                              context: &context)

        var localPoses: [[TransformComponent]] = []
        var rootMotions: [RootMotionDelta] = []
        var extractionChannelsBySample: [RootMotionExtractionChannels] = []
        var weights: [Float] = []
        var diagnosticHandles: [String] = []
        let epsilon: Float = 1.0e-4
        var exactMatchHandle: AssetHandle?
        for sample in blend.samples {
            let delta = parameterPoint - sample.position
            let distance = simd_length(delta)
            if distance <= epsilon {
                exactMatchHandle = sample.clipHandle
                break
            }
        }

        if let exactMatchHandle, let clip = context.assets.animationClip(handle: exactMatchHandle) {
            let sampleTime = resolveClipSampleTime(nodeTime: nodeSampleTimes.current,
                                                   duration: clip.durationSeconds,
                                                   isLooping: context.isLooping)
            let previousTime = resolveClipSampleTime(nodeTime: nodeSampleTimes.previous,
                                                     duration: clip.durationSeconds,
                                                     isLooping: context.isLooping)
            let sampleStart = CACurrentMediaTime()
            let localPose = evaluateLocalPose(skeleton: context.skeleton, clip: clip, playbackTime: sampleTime, assets: context.assets)
            context.samplePoseTimeMS += (CACurrentMediaTime() - sampleStart) * 1000.0
            let extractionChannels = resolveExtractionChannelsForClip(skeleton: context.skeleton,
                                                                      clip: clip,
                                                                      preferredRootJointIndex: context.rootJointIndex,
                                                                      translationJointIndexOverride: context.rootMotionTranslationJointOverride,
                                                                      rotationJointIndexOverride: context.rootMotionRotationJointOverride)
            let sampledRootMotion = sampleClipRootMotionDelta(skeleton: context.skeleton,
                                                              clip: clip,
                                                              rootJointIndex: context.rootJointIndex,
                                                              trackerEntityID: context.entityID,
                                                              trackerKey: "graph:\(node.id.uuidString)|clip:\(clip.handle.rawValue.uuidString)|blend2DExact",
                                                              translationJointIndexOverride: context.rootMotionTranslationJointOverride,
                                                              rotationJointIndexOverride: context.rootMotionRotationJointOverride,
                                                              previousTime: previousTime,
                                                              currentTime: sampleTime,
                                                              isLooping: context.isLooping,
                                                              sourceStateName: context.activeStateNameForRootMotionDiagnostics,
                                                              assets: context.assets)
            let rootMotion = cardinalStrafeIntent
                ? constrainCardinalStrafeRootMotion(sampledRootMotion, inputX: originalPoint.x)
                : sampledRootMotion
            maybeLogLocomotionBlendSelection(node: node,
                                             originalPoint: originalPoint,
                                             adjustedPoint: parameterPoint,
                                             samples: ["\(clip.name)=1.0"],
                                             blendedDelta: rootMotion,
                                             context: context,
                                             cardinalStrafeIntent: cardinalStrafeIntent)
            return GraphNodeEvaluationResult(localPose: localPose,
                                             sampleTime: sampleTime,
                                             sampleDuration: max(clip.durationSeconds, 0.0),
                                             rootMotionDelta: rootMotion,
                                             usesRootMotion: false,
                                             currentStateName: "",
                                             rootMotionBoneName: context.rootBoneName,
                                             rootMotionJointIndex: context.rootJointIndex,
                                             rootMotionTrackConsumed: false,
                                             rootMotionTranslationBoneName: extractionChannels.translationJointName,
                                             rootMotionTranslationJointIndex: extractionChannels.translationJointIndex,
                                             rootMotionRotationBoneName: extractionChannels.rotationJointName,
                                             rootMotionRotationJointIndex: extractionChannels.rotationJointIndex,
                                             diagnosticClipHandle: exactMatchHandle.rawValue.uuidString)
        }

        let nearestSamples = blend.samples
            .sorted { lhs, rhs in
                let lhsDistance = simd_length_squared(parameterPoint - lhs.position)
                let rhsDistance = simd_length_squared(parameterPoint - rhs.position)
                return lhsDistance < rhsDistance
            }
            .prefix(4)
        var weightedDiagnostics: [(name: String, weight: Float)] = []
        let sampleStart = CACurrentMediaTime()
        for sample in nearestSamples {
            guard let clip = context.assets.animationClip(handle: sample.clipHandle) else { continue }
            let delta = parameterPoint - sample.position
            let distance = max(simd_length(delta), epsilon)
            let weight = 1.0 / distance
            let sampleTime = resolveClipSampleTime(nodeTime: nodeSampleTimes.current,
                                                   duration: clip.durationSeconds,
                                                   isLooping: context.isLooping)
            let previousTime = resolveClipSampleTime(nodeTime: nodeSampleTimes.previous,
                                                     duration: clip.durationSeconds,
                                                     isLooping: context.isLooping)
            localPoses.append(evaluateLocalPose(skeleton: context.skeleton, clip: clip, playbackTime: sampleTime, assets: context.assets))
            extractionChannelsBySample.append(
                resolveExtractionChannelsForClip(skeleton: context.skeleton,
                                                 clip: clip,
                                                 preferredRootJointIndex: context.rootJointIndex,
                                                 translationJointIndexOverride: context.rootMotionTranslationJointOverride,
                                                 rotationJointIndexOverride: context.rootMotionRotationJointOverride)
            )
            rootMotions.append(sampleClipRootMotionDelta(skeleton: context.skeleton,
                                                         clip: clip,
                                                         rootJointIndex: context.rootJointIndex,
                                                         trackerEntityID: context.entityID,
                                                         trackerKey: "graph:\(node.id.uuidString)|clip:\(clip.handle.rawValue.uuidString)|blend2DNearest",
                                                         translationJointIndexOverride: context.rootMotionTranslationJointOverride,
                                                         rotationJointIndexOverride: context.rootMotionRotationJointOverride,
                                                         previousTime: previousTime,
                                                         currentTime: sampleTime,
                                                         isLooping: context.isLooping,
                                                         sourceStateName: context.activeStateNameForRootMotionDiagnostics,
                                                         assets: context.assets))
            weights.append(weight)
            weightedDiagnostics.append((clip.name, weight))
            diagnosticHandles.append(sample.clipHandle.rawValue.uuidString)
        }
        context.samplePoseTimeMS += (CACurrentMediaTime() - sampleStart) * 1000.0

        guard !localPoses.isEmpty else { return nil }
        let blendStart = CACurrentMediaTime()
        let blendedLocal = blendLocalPoses(localPoses: localPoses,
                                           weights: weights,
                                           skeleton: context.skeleton,
                                           assets: context.assets)
        let sampledBlendedRootMotion = blendRootMotionDeltas(rootMotions, weights: weights)
        let blendedRootMotion = cardinalStrafeIntent
            ? constrainCardinalStrafeRootMotion(sampledBlendedRootMotion, inputX: originalPoint.x)
            : sampledBlendedRootMotion
        let sampleSummary = weightedDiagnostics.map { "\($0.name)=\($0.weight)" }
        maybeLogLocomotionBlendSelection(node: node,
                                         originalPoint: originalPoint,
                                         adjustedPoint: parameterPoint,
                                         samples: sampleSummary,
                                         blendedDelta: blendedRootMotion,
                                         context: context,
                                         cardinalStrafeIntent: cardinalStrafeIntent)
        maybeLogBlend2DDiagnostics(node: node,
                                   point: parameterPoint,
                                   originalPoint: originalPoint,
                                   weights: sampleSummary,
                                   blendedDelta: blendedRootMotion,
                                   context: context)
        context.blendTimeMS += (CACurrentMediaTime() - blendStart) * 1000.0
        let primaryChannels = extractionChannelsBySample.first
        let mixedTranslationSource = extractionChannelsBySample.contains { $0.translationJointIndex != primaryChannels?.translationJointIndex }
        let mixedRotationSource = extractionChannelsBySample.contains { $0.rotationJointIndex != primaryChannels?.rotationJointIndex }
        return GraphNodeEvaluationResult(localPose: blendedLocal,
                                         sampleTime: nodeSampleTimes.current,
                                         sampleDuration: max(representativeDuration, 0.0),
                                         rootMotionDelta: blendedRootMotion,
                                         usesRootMotion: false,
                                         currentStateName: "",
                                         rootMotionBoneName: context.rootBoneName,
                                         rootMotionJointIndex: context.rootJointIndex,
                                         rootMotionTrackConsumed: false,
                                         rootMotionTranslationBoneName: mixedTranslationSource ? "<mixed>" : (primaryChannels?.translationJointName ?? ""),
                                         rootMotionTranslationJointIndex: mixedTranslationSource ? -1 : (primaryChannels?.translationJointIndex ?? -1),
                                         rootMotionRotationBoneName: mixedRotationSource ? "<mixed>" : (primaryChannels?.rotationJointName ?? ""),
                                         rootMotionRotationJointIndex: mixedRotationSource ? -1 : (primaryChannels?.rotationJointIndex ?? -1),
                                         diagnosticClipHandle: diagnosticHandles.joined(separator: ","))
    }

    private func advanceAndResolveNodeSampleTime(nodeID: UUID,
                                                 duration: Float,
                                                 isLooping: Bool,
                                                 context: inout GraphEvaluationContext) -> NodeSampleTimes {
        let stored = context.runtimeState.nodeLocalTimes[nodeID] ?? 0.0
        let current = resolveClipSampleTime(nodeTime: stored,
                                            duration: duration,
                                            isLooping: isLooping)
        let next: Float
        if context.isPlaying, context.deltaTime > 0 {
            next = nextPlaybackTime(current: current,
                                    dt: context.deltaTime,
                                    duration: duration,
                                    isLooping: isLooping)
        } else {
            next = current
        }
        context.runtimeState.nodeLocalTimes[nodeID] = next
        return NodeSampleTimes(previous: current, current: next)
    }

    private func resolveClipSampleTime(nodeTime: Float,
                                       duration: Float,
                                       isLooping: Bool) -> Float {
        return nextPlaybackTime(current: nodeTime, dt: 0.0, duration: duration, isLooping: isLooping)
    }

    private func neighboringBlend1DSamples(samples: [AnimationGraphBlend1DSampleDefinition],
                                           value: Float) -> (AnimationGraphBlend1DSampleDefinition?, AnimationGraphBlend1DSampleDefinition?) {
        guard !samples.isEmpty else { return (nil, nil) }
        if samples.count == 1 { return (samples[0], nil) }
        if value <= samples[0].threshold { return (samples[0], nil) }
        if value >= samples[samples.count - 1].threshold { return (samples[samples.count - 1], nil) }
        for i in 0..<(samples.count - 1) {
            let a = samples[i]
            let b = samples[i + 1]
            if value >= a.threshold && value <= b.threshold {
                return (a, b)
            }
        }
        return (samples[samples.count - 1], nil)
    }

    private func evaluateStateMachineNode(node: CompiledAnimationGraph.Node,
                                          context: inout GraphEvaluationContext) -> GraphNodeEvaluationResult? {
        guard let machine = node.stateMachine, !machine.states.isEmpty else { return nil }
        guard let currentState = resolveStateMachineCurrentState(machine: machine, stateMachineNodeID: node.id, context: &context) else {
            return nil
        }

        guard let currentStatePose = evaluateStateMachineStatePose(state: currentState, stateMachineNodeID: node.id, context: &context) else {
            return nil
        }
        let currentNormalizedTime = stateNormalizedTime(for: currentStatePose)

        if let nextStateID = context.runtimeState.stateMachineNextStateByNodeID[node.id],
           let nextState = machine.states.first(where: { $0.id == nextStateID }) {
            var transitionElapsed = context.runtimeState.stateMachineTransitionElapsedByNodeID[node.id] ?? 0.0
            let transitionDuration = max(context.runtimeState.stateMachineTransitionDurationByNodeID[node.id] ?? 0.0, 0.0)
            if context.isPlaying, context.deltaTime > 0 {
                transitionElapsed += context.deltaTime
            }
            let alpha = transitionDuration <= 1.0e-5 ? 1.0 : simd_clamp(transitionElapsed / transitionDuration, 0.0, 1.0)

            guard let nextStatePose = evaluateStateMachineStatePose(state: nextState, stateMachineNodeID: node.id, context: &context) else {
                context.runtimeState.stateMachineNextStateByNodeID.removeValue(forKey: node.id)
                context.runtimeState.stateMachineTransitionElapsedByNodeID.removeValue(forKey: node.id)
                context.runtimeState.stateMachineTransitionDurationByNodeID.removeValue(forKey: node.id)
                context.runtimeState.stateMachineTransitionSynchronizeByNodeID.removeValue(forKey: node.id)
                return currentStatePose
            }

            let blendedLocal = blendLocalPoses(currentStatePose.localPose,
                                               nextStatePose.localPose,
                                               weight: alpha,
                                               skeleton: context.skeleton,
                                               assets: context.assets)
            let sourcePolicy = rootMotionPolicy(for: currentState)
            let targetPolicy = rootMotionPolicy(for: nextState)
            let transitionType = classifyTransitionRootMotionType(sourceUsesRootMotion: currentStatePose.usesRootMotion,
                                                                  targetUsesRootMotion: nextStatePose.usesRootMotion)
            let transitionPolicy = resolveTransitionRootMotionPolicy(sourcePolicy: sourcePolicy,
                                                                     targetPolicy: targetPolicy,
                                                                     sourceUsesRootMotion: currentStatePose.usesRootMotion,
                                                                     targetUsesRootMotion: nextStatePose.usesRootMotion)
            let transitionSelection = selectTransitionRootMotion(sourcePose: currentStatePose,
                                                                 targetPose: nextStatePose,
                                                                 blendWeight: alpha,
                                                                 policy: transitionPolicy,
                                                                 transitionType: transitionType)
            if alpha >= 1.0 - 1.0e-5 {
                context.runtimeState.stateMachineCurrentStateByNodeID[node.id] = nextState.id
                context.runtimeState.stateMachineNextStateByNodeID.removeValue(forKey: node.id)
                context.runtimeState.stateMachineTransitionElapsedByNodeID.removeValue(forKey: node.id)
                context.runtimeState.stateMachineTransitionDurationByNodeID.removeValue(forKey: node.id)
                context.runtimeState.stateMachineTransitionSynchronizeByNodeID.removeValue(forKey: node.id)
                context.runtimeState.stateMachineStateElapsedByNodeID[node.id] = 0.0
                resetStateMachineEntryPlayback(stateMachineNodeID: node.id, state: nextState, context: &context)
                emitStateMachineDiagnostic(node: node, machine: machine, context: &context, reason: "transitionCompleted")
                EngineLoggerContext.log(
                    "AnimRootMotion transition completion handoff entity=\(context.entityID.uuidString) tickID=\(context.fixedTickID ?? 0) alpha=\(alpha) committedTargetState=\(nextState.name.isEmpty ? nextState.id.uuidString : nextState.name) returnedStateName=\(nextStatePose.currentStateName.isEmpty ? "<none>" : nextStatePose.currentStateName) returnedUsesRM=\(nextStatePose.usesRootMotion) translationJoint=\(nextStatePose.rootMotionTranslationBoneName.isEmpty ? "<none>" : nextStatePose.rootMotionTranslationBoneName)#\(nextStatePose.rootMotionTranslationJointIndex) sampleTime=\(nextStatePose.sampleTime) duration=\(nextStatePose.sampleDuration)",
                    level: .debug,
                    category: .scene
                )
                return nextStatePose
            } else {
                context.runtimeState.stateMachineTransitionElapsedByNodeID[node.id] = transitionElapsed
            }
            logTransitionRootMotionDiagnostic(stateMachineNodeID: node.id,
                                              sourceStateID: currentState.id,
                                              targetStateID: nextState.id,
                                              sourceStateName: currentState.name,
                                              targetStateName: nextState.name,
                                              sourceWeight: 1.0 - alpha,
                                              targetWeight: alpha,
                                              alpha: alpha,
                                              sourcePose: currentStatePose,
                                              targetPose: nextStatePose,
                                              blendedRootDelta: transitionSelection.blendedDelta,
                                              selectedRootDelta: transitionSelection.selectedDelta,
                                              transitionType: transitionSelection.transitionType,
                                              transitionPolicy: transitionSelection.transitionPolicy,
                                              selectedAuthorityState: transitionSelection.authorityState,
                                              context: &context)
            EngineLoggerContext.log(
                "AnimRootMotion transition selection entity=\(context.entityID.uuidString) sourceState=\(currentState.name.isEmpty ? currentState.id.uuidString : currentState.name) targetState=\(nextState.name.isEmpty ? nextState.id.uuidString : nextState.name) sourceUsesRM=\(currentStatePose.usesRootMotion) targetUsesRM=\(nextStatePose.usesRootMotion) selectedAuthorityState=\(transitionSelection.authorityState) returnedDelta=\(transitionSelection.selectedDelta.deltaPos)",
                level: .debug,
                category: .scene
            )
            return GraphNodeEvaluationResult(localPose: blendedLocal,
                                             sampleTime: transitionSelection.sampleTime,
                                             sampleDuration: transitionSelection.sampleDuration,
                                             rootMotionDelta: transitionSelection.selectedDelta,
                                             authoredUsesRootMotion: transitionSelection.authoredUsesRootMotion,
                                             usesRootMotion: transitionSelection.usesRootMotion,
                                             currentStateName: transitionSelection.currentStateName,
                                             rootMotionBoneName: transitionSelection.rootMotionBoneName,
                                             rootMotionJointIndex: transitionSelection.rootMotionJointIndex,
                                             rootMotionTrackConsumed: transitionSelection.trackConsumed,
                                             rootMotionTranslationBoneName: transitionSelection.translationJointName,
                                             rootMotionTranslationJointIndex: transitionSelection.translationJointIndex,
                                             rootMotionRotationBoneName: transitionSelection.rotationJointName,
                                             rootMotionRotationJointIndex: transitionSelection.rotationJointIndex,
                                             rootMotionConsumeBoneName: transitionSelection.consumeJointName,
                                             rootMotionConsumeJointIndex: transitionSelection.consumeJointIndex,
                                             diagnosticClipHandle: [currentStatePose.diagnosticClipHandle, nextStatePose.diagnosticClipHandle]
                                                .compactMap { $0 }
                                                .joined(separator: ","))
        }

        if context.isPlaying, context.deltaTime > 0 {
            let elapsed = (context.runtimeState.stateMachineStateElapsedByNodeID[node.id] ?? 0.0) + context.deltaTime
            context.runtimeState.stateMachineStateElapsedByNodeID[node.id] = elapsed
        }

        if let transitionSelection = firstPassingTransition(machine: machine,
                                                            fromStateID: currentState.id,
                                                            currentNormalizedTime: currentNormalizedTime,
                                                            context: &context),
           let destinationState = machine.states.first(where: { $0.id == transitionSelection.transition.toStateID }) {
            if transitionSelection.synchronize {
                synchronizeStateEntryPlayback(stateMachineNodeID: node.id,
                                              sourcePose: currentStatePose,
                                              destinationState: destinationState,
                                              context: &context)
            }
            let transitionDuration = max(transitionSelection.durationSeconds, 0.0)
            if transitionDuration <= 1.0e-5 {
                context.runtimeState.stateMachineCurrentStateByNodeID[node.id] = destinationState.id
                context.runtimeState.stateMachineStateElapsedByNodeID[node.id] = 0.0
                context.runtimeState.stateMachineNextStateByNodeID.removeValue(forKey: node.id)
                context.runtimeState.stateMachineTransitionElapsedByNodeID.removeValue(forKey: node.id)
                context.runtimeState.stateMachineTransitionDurationByNodeID.removeValue(forKey: node.id)
                context.runtimeState.stateMachineTransitionSynchronizeByNodeID.removeValue(forKey: node.id)
                if !transitionSelection.synchronize {
                    resetStateMachineEntryPlayback(stateMachineNodeID: node.id, state: destinationState, context: &context)
                }
                emitStateMachineDiagnostic(node: node, machine: machine, context: &context, reason: "transitionInstant")
                return evaluateStateMachineStatePose(state: destinationState, stateMachineNodeID: node.id, context: &context)
            }

            context.runtimeState.stateMachineNextStateByNodeID[node.id] = destinationState.id
            context.runtimeState.stateMachineTransitionElapsedByNodeID[node.id] = 0.0
            context.runtimeState.stateMachineTransitionDurationByNodeID[node.id] = transitionDuration
            context.runtimeState.stateMachineTransitionSynchronizeByNodeID[node.id] = transitionSelection.synchronize
            if !transitionSelection.synchronize {
                resetStateMachineEntryPlayback(stateMachineNodeID: node.id, state: destinationState, context: &context)
            }
            emitStateMachineDiagnostic(node: node, machine: machine, context: &context, reason: "transitionStarted")
            if let destinationPose = evaluateStateMachineStatePose(state: destinationState, stateMachineNodeID: node.id, context: &context) {
                if destinationState.name.caseInsensitiveCompare("JumpStart") == .orderedSame {
                    let sourceName = currentState.name.isEmpty ? currentState.id.uuidString : currentState.name
                    let destinationName = destinationState.name.isEmpty ? destinationState.id.uuidString : destinationState.name
                    EngineLoggerContext.log(
                        "Animator JumpStart entry sourceState=\(sourceName) destinationState=\(destinationName) entryPlaybackTime=\(destinationPose.sampleTime) normalized=\(stateNormalizedTime(for: destinationPose)) entity=\(context.entityID.uuidString)",
                        level: .debug,
                        category: .scene
                    )
                }
                let blendedLocal = blendLocalPoses(currentStatePose.localPose,
                                                   destinationPose.localPose,
                                                   weight: 0.0,
                                                   skeleton: context.skeleton,
                                                   assets: context.assets)
                let sourcePolicy = rootMotionPolicy(for: currentState)
                let targetPolicy = rootMotionPolicy(for: destinationState)
                let transitionType = classifyTransitionRootMotionType(sourceUsesRootMotion: currentStatePose.usesRootMotion,
                                                                      targetUsesRootMotion: destinationPose.usesRootMotion)
                let transitionPolicy = resolveTransitionRootMotionPolicy(sourcePolicy: sourcePolicy,
                                                                         targetPolicy: targetPolicy,
                                                                         sourceUsesRootMotion: currentStatePose.usesRootMotion,
                                                                         targetUsesRootMotion: destinationPose.usesRootMotion)
                let transitionSelection = selectTransitionRootMotion(sourcePose: currentStatePose,
                                                                     targetPose: destinationPose,
                                                                     blendWeight: 0.0,
                                                                     policy: transitionPolicy,
                                                                     transitionType: transitionType)
                logTransitionRootMotionDiagnostic(stateMachineNodeID: node.id,
                                                  sourceStateID: currentState.id,
                                                  targetStateID: destinationState.id,
                                                  sourceStateName: currentState.name,
                                                  targetStateName: destinationState.name,
                                                  sourceWeight: 1.0,
                                                  targetWeight: 0.0,
                                                  alpha: 0.0,
                                                  sourcePose: currentStatePose,
                                                  targetPose: destinationPose,
                                                  blendedRootDelta: transitionSelection.blendedDelta,
                                                  selectedRootDelta: transitionSelection.selectedDelta,
                                                  transitionType: transitionSelection.transitionType,
                                                  transitionPolicy: transitionSelection.transitionPolicy,
                                                  selectedAuthorityState: transitionSelection.authorityState,
                                                  context: &context)
                EngineLoggerContext.log(
                    "AnimRootMotion transition selection entity=\(context.entityID.uuidString) sourceState=\(currentState.name.isEmpty ? currentState.id.uuidString : currentState.name) targetState=\(destinationState.name.isEmpty ? destinationState.id.uuidString : destinationState.name) sourceUsesRM=\(currentStatePose.usesRootMotion) targetUsesRM=\(destinationPose.usesRootMotion) selectedAuthorityState=\(transitionSelection.authorityState) returnedDelta=\(transitionSelection.selectedDelta.deltaPos)",
                    level: .debug,
                    category: .scene
                )
                return GraphNodeEvaluationResult(localPose: blendedLocal,
                                                 sampleTime: transitionSelection.sampleTime,
                                                 sampleDuration: transitionSelection.sampleDuration,
                                                 rootMotionDelta: transitionSelection.selectedDelta,
                                                 authoredUsesRootMotion: transitionSelection.authoredUsesRootMotion,
                                                 usesRootMotion: transitionSelection.usesRootMotion,
                                                 currentStateName: transitionSelection.currentStateName,
                                                 rootMotionBoneName: transitionSelection.rootMotionBoneName,
                                                 rootMotionJointIndex: transitionSelection.rootMotionJointIndex,
                                                 rootMotionTrackConsumed: transitionSelection.trackConsumed,
                                                 rootMotionTranslationBoneName: transitionSelection.translationJointName,
                                                 rootMotionTranslationJointIndex: transitionSelection.translationJointIndex,
                                                 rootMotionRotationBoneName: transitionSelection.rotationJointName,
                                                 rootMotionRotationJointIndex: transitionSelection.rotationJointIndex,
                                                 rootMotionConsumeBoneName: transitionSelection.consumeJointName,
                                                 rootMotionConsumeJointIndex: transitionSelection.consumeJointIndex,
                                                 diagnosticClipHandle: [currentStatePose.diagnosticClipHandle, destinationPose.diagnosticClipHandle]
                                                    .compactMap { $0 }
                                                    .joined(separator: ","))
            }
        }

        return currentStatePose
    }

    private func selectTransitionRootMotion(sourcePose: GraphNodeEvaluationResult,
                                            targetPose: GraphNodeEvaluationResult,
                                            blendWeight: Float,
                                            policy: TransitionRootMotionPolicy,
                                            transitionType: TransitionRootMotionType) -> TransitionRootMotionSelection {
        let t = simd_clamp(blendWeight, 0.0, 1.0)
        let blendedDelta = blendRootMotionDeltas(sourcePose.rootMotionDelta, targetPose.rootMotionDelta, weight: t)
        let sourceChannels = resolvedActiveRootMotionChannels(primary: sourcePose, secondary: targetPose)
        let targetChannels = resolvedActiveRootMotionChannels(primary: targetPose, secondary: sourcePose)
        let metadataPose = t >= 0.5 ? targetPose : sourcePose
        let metadataSecondary = t >= 0.5 ? sourcePose : targetPose
        let blendedChannels = resolvedActiveRootMotionChannels(primary: metadataPose, secondary: metadataSecondary)
        switch policy {
        case .sourceDominant:
            // Controlled fade-out prevents large late transition spikes while preserving authored stop-out.
            let fadedSourceDelta = scaleRootMotionDelta(sourcePose.rootMotionDelta, scale: max(0.0, 1.0 - t))
            return TransitionRootMotionSelection(selectedDelta: fadedSourceDelta,
                                                blendedDelta: blendedDelta,
                                                authoredUsesRootMotion: sourcePose.authoredUsesRootMotion,
                                                usesRootMotion: true,
                                                trackConsumed: sourcePose.rootMotionTrackConsumed,
                                                authorityState: "source_fade_out",
                                                currentStateName: sourcePose.currentStateName,
                                                rootMotionBoneName: sourceChannels.consumeName,
                                                rootMotionJointIndex: sourceChannels.consumeIndex,
                                                consumeJointName: sourceChannels.consumeName,
                                                consumeJointIndex: sourceChannels.consumeIndex,
                                                sampleTime: sourcePose.sampleTime,
                                                sampleDuration: sourcePose.sampleDuration,
                                                translationJointName: sourceChannels.translationName,
                                                translationJointIndex: sourceChannels.translationIndex,
                                                rotationJointName: sourceChannels.rotationName,
                                                rotationJointIndex: sourceChannels.rotationIndex,
                                                transitionType: transitionType,
                                                transitionPolicy: policy)
        case .blended:
            return TransitionRootMotionSelection(selectedDelta: blendedDelta,
                                                blendedDelta: blendedDelta,
                                                authoredUsesRootMotion: metadataPose.authoredUsesRootMotion,
                                                usesRootMotion: true,
                                                trackConsumed: sourcePose.rootMotionTrackConsumed || targetPose.rootMotionTrackConsumed,
                                                authorityState: "blended",
                                                currentStateName: metadataPose.currentStateName,
                                                rootMotionBoneName: blendedChannels.consumeName,
                                                rootMotionJointIndex: blendedChannels.consumeIndex,
                                                consumeJointName: blendedChannels.consumeName,
                                                consumeJointIndex: blendedChannels.consumeIndex,
                                                sampleTime: metadataPose.sampleTime,
                                                sampleDuration: metadataPose.sampleDuration,
                                                translationJointName: blendedChannels.translationName,
                                                translationJointIndex: blendedChannels.translationIndex,
                                                rotationJointName: blendedChannels.rotationName,
                                                rotationJointIndex: blendedChannels.rotationIndex,
                                                transitionType: transitionType,
                                                transitionPolicy: policy)
        case .targetDominant:
            // Entering a root-motion state should immediately use target authored root motion.
            return TransitionRootMotionSelection(selectedDelta: targetPose.rootMotionDelta,
                                                blendedDelta: blendedDelta,
                                                authoredUsesRootMotion: targetPose.authoredUsesRootMotion,
                                                usesRootMotion: true,
                                                trackConsumed: targetPose.rootMotionTrackConsumed,
                                                authorityState: "target_immediate",
                                                currentStateName: targetPose.currentStateName,
                                                rootMotionBoneName: targetChannels.consumeName,
                                                rootMotionJointIndex: targetChannels.consumeIndex,
                                                consumeJointName: targetChannels.consumeName,
                                                consumeJointIndex: targetChannels.consumeIndex,
                                                sampleTime: targetPose.sampleTime,
                                                sampleDuration: targetPose.sampleDuration,
                                                translationJointName: targetChannels.translationName,
                                                translationJointIndex: targetChannels.translationIndex,
                                                rotationJointName: targetChannels.rotationName,
                                                rotationJointIndex: targetChannels.rotationIndex,
                                                transitionType: transitionType,
                                                transitionPolicy: policy)
        case .none:
            return TransitionRootMotionSelection(selectedDelta: .zero,
                                                blendedDelta: blendedDelta,
                                                authoredUsesRootMotion: false,
                                                usesRootMotion: false,
                                                trackConsumed: false,
                                                authorityState: "none",
                                                currentStateName: sourcePose.currentStateName,
                                                rootMotionBoneName: sourcePose.rootMotionBoneName,
                                                rootMotionJointIndex: sourcePose.rootMotionJointIndex,
                                                consumeJointName: sourcePose.rootMotionConsumeBoneName,
                                                consumeJointIndex: sourcePose.rootMotionConsumeJointIndex,
                                                sampleTime: sourcePose.sampleTime,
                                                sampleDuration: sourcePose.sampleDuration,
                                                translationJointName: "",
                                                translationJointIndex: -1,
                                                rotationJointName: "",
                                                rotationJointIndex: -1,
                                                transitionType: transitionType,
                                                transitionPolicy: policy)
        }
    }

    private func classifyTransitionRootMotionType(sourceUsesRootMotion: Bool,
                                                  targetUsesRootMotion: Bool) -> TransitionRootMotionType {
        switch (sourceUsesRootMotion, targetUsesRootMotion) {
        case (false, false):
            return .falseToFalse
        case (false, true):
            return .falseToTrue
        case (true, false):
            return .trueToFalse
        case (true, true):
            return .trueToTrue
        }
    }

    private func resolveTransitionRootMotionPolicy(sourcePolicy: RootMotionPolicy,
                                                   targetPolicy: RootMotionPolicy,
                                                   sourceUsesRootMotion: Bool,
                                                   targetUsesRootMotion: Bool) -> TransitionRootMotionPolicy {
        let sourceAllowed = sourceUsesRootMotion && sourcePolicy.allowDuringTransition
        let targetAllowed = targetUsesRootMotion && targetPolicy.allowDuringTransition
        switch (sourceAllowed, targetAllowed) {
        case (true, false):
            return .sourceDominant
        case (true, true):
            return .blended
        case (false, true):
            return .targetDominant
        case (false, false):
            return .none
        }
    }

    private func scaleRootMotionDelta(_ delta: RootMotionDelta, scale: Float) -> RootMotionDelta {
        let clamped = max(0.0, scale)
        let deltaRotation = simd_quatf(vector: TransformMath.normalizedQuaternion(delta.deltaRot))
        let scaledRotation = simd_slerp(simd_quatf(vector: TransformMath.identityQuaternion), deltaRotation, clamped)
        return RootMotionDelta(deltaPos: delta.deltaPos * clamped,
                               deltaRot: TransformMath.normalizedQuaternion(scaledRotation.vector))
    }

    private struct RootMotionActiveChannels {
        let translationName: String
        let translationIndex: Int
        let rotationName: String
        let rotationIndex: Int
        let consumeName: String
        let consumeIndex: Int
    }

    private func resolvedActiveRootMotionChannels(primary: GraphNodeEvaluationResult,
                                                  secondary: GraphNodeEvaluationResult) -> RootMotionActiveChannels {
        let translation = resolvePreferredJoint(primaryName: primary.rootMotionTranslationBoneName,
                                                primaryIndex: primary.rootMotionTranslationJointIndex,
                                                secondaryName: secondary.rootMotionTranslationBoneName,
                                                secondaryIndex: secondary.rootMotionTranslationJointIndex,
                                                fallbackName: primary.rootMotionBoneName,
                                                fallbackIndex: primary.rootMotionJointIndex)
        let rotation = resolvePreferredJoint(primaryName: primary.rootMotionRotationBoneName,
                                             primaryIndex: primary.rootMotionRotationJointIndex,
                                             secondaryName: secondary.rootMotionRotationBoneName,
                                             secondaryIndex: secondary.rootMotionRotationJointIndex,
                                             fallbackName: primary.rootMotionBoneName,
                                             fallbackIndex: primary.rootMotionJointIndex)
        let consume = resolvePreferredJoint(primaryName: primary.rootMotionConsumeBoneName,
                                            primaryIndex: primary.rootMotionConsumeJointIndex,
                                            secondaryName: secondary.rootMotionConsumeBoneName,
                                            secondaryIndex: secondary.rootMotionConsumeJointIndex,
                                            fallbackName: primary.rootMotionBoneName,
                                            fallbackIndex: primary.rootMotionJointIndex)
        return RootMotionActiveChannels(translationName: translation.name,
                                        translationIndex: translation.index,
                                        rotationName: rotation.name,
                                        rotationIndex: rotation.index,
                                        consumeName: consume.name,
                                        consumeIndex: consume.index)
    }

    private func resolvePreferredJoint(primaryName: String,
                                       primaryIndex: Int,
                                       secondaryName: String,
                                       secondaryIndex: Int,
                                       fallbackName: String,
                                       fallbackIndex: Int) -> (name: String, index: Int) {
        if primaryIndex >= 0 {
            return (primaryName.isEmpty ? "<joint>" : primaryName, primaryIndex)
        }
        if secondaryIndex >= 0 {
            return (secondaryName.isEmpty ? "<joint>" : secondaryName, secondaryIndex)
        }
        if fallbackIndex >= 0 {
            return (fallbackName.isEmpty ? "<joint>" : fallbackName, fallbackIndex)
        }
        return ("", -1)
    }

    private func logTransitionRootMotionDiagnostic(stateMachineNodeID: UUID,
                                                   sourceStateID: UUID,
                                                   targetStateID: UUID,
                                                   sourceStateName: String,
                                                   targetStateName: String,
                                                   sourceWeight: Float,
                                                   targetWeight: Float,
                                                   alpha: Float,
                                                   sourcePose: GraphNodeEvaluationResult,
                                                   targetPose: GraphNodeEvaluationResult,
                                                   blendedRootDelta: RootMotionDelta,
                                                   selectedRootDelta: RootMotionDelta,
                                                   transitionType: TransitionRootMotionType,
                                                   transitionPolicy: TransitionRootMotionPolicy,
                                                   selectedAuthorityState: String,
                                                   context: inout GraphEvaluationContext) {
        let key = "transitionRootMotion|\(context.entityID.uuidString)|\(stateMachineNodeID.uuidString)"
        let count = (transitionGraphDebugSampleCountsByKey[key] ?? 0) + 1
        transitionGraphDebugSampleCountsByKey[key] = count
        let blendedMagnitude = simd_length(blendedRootDelta.deltaPos)
        let shouldLog = animationGraphDebugLoggingEnabled ? (count % 10 == 0) : (blendedMagnitude > 0.75 || count % 60 == 0)
        guard shouldLog else { return }
        EngineLoggerContext.log(
            """
            AnimRootMotion transition transitionType=\(transitionType.rawValue) policy=\(transitionPolicy.rawValue) alpha=\(alpha) sourceStateID=\(sourceStateID.uuidString) targetStateID=\(targetStateID.uuidString) transitionSourceState=\(sourceStateName.isEmpty ? "<none>" : sourceStateName) transitionTargetState=\(targetStateName.isEmpty ? "<none>" : targetStateName) sourceWeight=\(sourceWeight) targetWeight=\(targetWeight) sourceSampleTime=\(sourcePose.sampleTime) sourceDuration=\(sourcePose.sampleDuration) targetSampleTime=\(targetPose.sampleTime) targetDuration=\(targetPose.sampleDuration) sourceRootDelta=\(sourcePose.rootMotionDelta.deltaPos) targetRootDelta=\(targetPose.rootMotionDelta.deltaPos) blendedRootDelta=\(blendedRootDelta.deltaPos) selectedRootDelta=\(selectedRootDelta.deltaPos) selectedAuthorityState=\(selectedAuthorityState)
            """,
            level: .debug,
            category: .scene
        )
        if transitionPolicy != .none {
            let missingTranslationSource = sourcePose.rootMotionTranslationJointIndex < 0 && targetPose.rootMotionTranslationJointIndex < 0
            let missingRotationSource = sourcePose.rootMotionRotationJointIndex < 0 && targetPose.rootMotionRotationJointIndex < 0
            if missingTranslationSource || missingRotationSource {
                let invalidKey = "transitionRootMotionInvalidSource|\(context.entityID.uuidString)|\(stateMachineNodeID.uuidString)|\(sourceStateID.uuidString)|\(targetStateID.uuidString)|\(transitionType.rawValue)"
                if !loggedTransitionRootMotionInvalidSourceKeys.contains(invalidKey) {
                    loggedTransitionRootMotionInvalidSourceKeys.insert(invalidKey)
                    let sourceTranslationName = sourcePose.rootMotionTranslationBoneName.isEmpty ? "<none>" : sourcePose.rootMotionTranslationBoneName
                    let targetTranslationName = targetPose.rootMotionTranslationBoneName.isEmpty ? "<none>" : targetPose.rootMotionTranslationBoneName
                    let sourceRotationName = sourcePose.rootMotionRotationBoneName.isEmpty ? "<none>" : sourcePose.rootMotionRotationBoneName
                    let targetRotationName = targetPose.rootMotionRotationBoneName.isEmpty ? "<none>" : targetPose.rootMotionRotationBoneName
                    EngineLoggerContext.log(
                        "AnimRootMotion transition source invalid while RM active entity=\(context.entityID.uuidString) stateMachineNodeID=\(stateMachineNodeID.uuidString) transitionType=\(transitionType.rawValue) policy=\(transitionPolicy.rawValue) sourceStateID=\(sourceStateID.uuidString) targetStateID=\(targetStateID.uuidString) sourceTranslationJoint=\(sourceTranslationName)#\(sourcePose.rootMotionTranslationJointIndex) targetTranslationJoint=\(targetTranslationName)#\(targetPose.rootMotionTranslationJointIndex) sourceRotationJoint=\(sourceRotationName)#\(sourcePose.rootMotionRotationJointIndex) targetRotationJoint=\(targetRotationName)#\(targetPose.rootMotionRotationJointIndex)",
                        level: .warning,
                        category: .scene
                    )
                }
            }
        }
    }

    private func emitStateMachineDiagnostic(node: CompiledAnimationGraph.Node,
                                            machine: AnimationGraphStateMachineScaffold,
                                            context: inout GraphEvaluationContext,
                                            reason: String) {
        guard animationGraphDebugLoggingEnabled else { return }
        let nextStateName: String
        if let nextStateID = context.runtimeState.stateMachineNextStateByNodeID[node.id],
           let nextState = machine.states.first(where: { $0.id == nextStateID }) {
            nextStateName = nextState.name.isEmpty ? nextState.id.uuidString : nextState.name
        } else {
            nextStateName = "<none>"
        }
        let currentStateName: String
        if let currentStateID = context.runtimeState.stateMachineCurrentStateByNodeID[node.id],
           let currentState = machine.states.first(where: { $0.id == currentStateID }) {
            currentStateName = currentState.name.isEmpty ? currentState.id.uuidString : currentState.name
        } else {
            currentStateName = "<unset>"
        }
        logStateMachineSignatureIfChanged(entityID: context.entityID,
                                          graphHandle: context.graphHandle,
                                          nodeID: node.id,
                                          currentStateName: currentStateName,
                                          nextStateName: nextStateName,
                                          reason: reason)
    }

    private func resolveStateMachineCurrentState(machine: AnimationGraphStateMachineScaffold,
                                                 stateMachineNodeID: UUID,
                                                 context: inout GraphEvaluationContext) -> AnimationGraphStateDefinition? {
        if let currentStateID = context.runtimeState.stateMachineCurrentStateByNodeID[stateMachineNodeID],
           let currentState = machine.states.first(where: { $0.id == currentStateID }) {
            return currentState
        }
        let fallbackState: AnimationGraphStateDefinition?
        if let defaultStateID = machine.defaultStateID {
            fallbackState = machine.states.first(where: { $0.id == defaultStateID })
        } else {
            fallbackState = machine.states.first
        }
        if let fallbackState {
            context.runtimeState.stateMachineCurrentStateByNodeID[stateMachineNodeID] = fallbackState.id
            context.runtimeState.stateMachineStateElapsedByNodeID[stateMachineNodeID] = 0.0
            resetStateMachineEntryPlayback(stateMachineNodeID: stateMachineNodeID, state: fallbackState, context: &context)
        }
        return fallbackState
    }

    private func resetStateMachineEntryPlayback(stateMachineNodeID: UUID,
                                                state: AnimationGraphStateDefinition,
                                                context: inout GraphEvaluationContext) {
        context.runtimeState.nodeLocalTimes[state.id] = 0.0
        if let nodeID = state.nodeID {
            context.runtimeState.nodeLocalTimes[nodeID] = 0.0
            if let nodeIndex = context.compiledGraph.nodes.firstIndex(where: { $0.id == nodeID }) {
                context.valueContext.valuesByNodeID.removeValue(forKey: context.compiledGraph.nodes[nodeIndex].id)
            }
        }
        if let machineNodeIndex = context.compiledGraph.nodes.firstIndex(where: { $0.id == stateMachineNodeID }) {
            context.valueContext.valuesByNodeID.removeValue(forKey: context.compiledGraph.nodes[machineNodeIndex].id)
        }
    }

    private func synchronizeStateEntryPlayback(stateMachineNodeID: UUID,
                                               sourcePose: GraphNodeEvaluationResult,
                                               destinationState: AnimationGraphStateDefinition,
                                               context: inout GraphEvaluationContext) {
        let sourceDuration = max(sourcePose.sampleDuration, 0.0)
        guard sourceDuration > 1.0e-5 else {
            resetStateMachineEntryPlayback(stateMachineNodeID: stateMachineNodeID,
                                           state: destinationState,
                                           context: &context)
            return
        }
        let sourceNormalized = simd_clamp(sourcePose.sampleTime / sourceDuration, 0.0, 1.0)
        let destinationDuration: Float = {
            if let clipHandle = destinationState.clipHandle,
               let clip = context.assets.animationClip(handle: clipHandle) {
                return max(clip.durationSeconds, 0.0)
            }
            return sourceDuration
        }()
        let synchronizedTime = destinationDuration > 1.0e-5 ? (sourceNormalized * destinationDuration) : 0.0
        context.runtimeState.nodeLocalTimes[destinationState.id] = synchronizedTime
        if let destinationNodeID = destinationState.nodeID {
            context.runtimeState.nodeLocalTimes[destinationNodeID] = synchronizedTime
        }
    }

    private func evaluateStateMachineStatePose(state: AnimationGraphStateDefinition,
                                               stateMachineNodeID: UUID,
                                               context: inout GraphEvaluationContext) -> GraphNodeEvaluationResult? {
        let policy = rootMotionPolicy(for: state)
        let effectiveUsesRootMotion = effectiveUsesRootMotion(for: state, policy: policy)
        let stateChannels = resolveStateRootMotionChannels(state: state,
                                                           skeleton: context.skeleton,
                                                           clip: state.clipHandle.flatMap { context.assets.animationClip(handle: $0) },
                                                           preferredRootJointIndex: context.rootJointIndex)
        let hasExplicitTranslationSource = !(state.rootMotion?.translationSourceJointName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasExplicitRotationSource = !(state.rootMotion?.rotationSourceJointName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasExplicitConsumeJoint = !(state.rootMotion?.consumeJointName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let consumeTranslationJointIndex = hasExplicitConsumeJoint ? stateChannels.consumeJointIndex : stateChannels.translationJointIndex
        let consumeRotationJointIndex = hasExplicitConsumeJoint ? stateChannels.consumeJointIndex : stateChannels.rotationJointIndex
        let previousTranslationOverride = context.rootMotionTranslationJointOverride
        let previousRotationOverride = context.rootMotionRotationJointOverride
        let previousDiagnosticStateName = context.activeStateNameForRootMotionDiagnostics
        let usesDirectStateClip = state.clipHandle != nil
        context.rootMotionTranslationJointOverride = (hasExplicitTranslationSource || usesDirectStateClip) ? stateChannels.translationJointIndex : nil
        context.rootMotionRotationJointOverride = (hasExplicitRotationSource || usesDirectStateClip) ? stateChannels.rotationJointIndex : nil
        context.activeStateNameForRootMotionDiagnostics = state.name
        defer {
            context.rootMotionTranslationJointOverride = previousTranslationOverride
            context.rootMotionRotationJointOverride = previousRotationOverride
            context.activeStateNameForRootMotionDiagnostics = previousDiagnosticStateName
        }

        if let stateNodeID = state.nodeID {
            guard let nodeIndex = context.compiledGraph.nodes.firstIndex(where: { $0.id == stateNodeID }) else { return nil }
            guard context.compiledGraph.nodes[nodeIndex].id != stateMachineNodeID else { return nil }
            guard let evaluated = evaluateGraphNodePose(nodeIndex: nodeIndex, context: &context) else { return nil }
            let filteredRootMotion = RootMotionDelta(
                deltaPos: (effectiveUsesRootMotion && policy.applyTranslation) ? evaluated.rootMotionDelta.deltaPos : .zero,
                deltaRot: (effectiveUsesRootMotion && policy.applyRotation) ? evaluated.rootMotionDelta.deltaRot : TransformMath.identityQuaternion
            )
            let translationJointName = evaluated.rootMotionTranslationBoneName.isEmpty
                ? stateChannels.translationJointName
                : evaluated.rootMotionTranslationBoneName
            let translationJointIndex = evaluated.rootMotionTranslationJointIndex >= 0
                ? evaluated.rootMotionTranslationJointIndex
                : stateChannels.translationJointIndex
            let rotationJointName = evaluated.rootMotionRotationBoneName.isEmpty
                ? stateChannels.rotationJointName
                : evaluated.rootMotionRotationBoneName
            let rotationJointIndex = evaluated.rootMotionRotationJointIndex >= 0
                ? evaluated.rootMotionRotationJointIndex
                : stateChannels.rotationJointIndex
            // For graph-driven states (no direct clip on the state), consume joints must
            // follow evaluated extraction channels unless an explicit consume joint is set.
            // Otherwise we can extract from hips but consume root, which causes visual drift/snap.
            let resolvedConsumeTranslationJointIndex = hasExplicitConsumeJoint
                ? stateChannels.consumeJointIndex
                : (translationJointIndex >= 0 ? translationJointIndex : stateChannels.translationJointIndex)
            let resolvedConsumeRotationJointIndex = hasExplicitConsumeJoint
                ? stateChannels.consumeJointIndex
                : (rotationJointIndex >= 0 ? rotationJointIndex : stateChannels.rotationJointIndex)
            let consumeJointIndex = resolvedConsumeTranslationJointIndex
            let consumeJointName: String = {
                guard consumeJointIndex >= 0, consumeJointIndex < context.skeleton.joints.count else {
                    return stateChannels.consumeJointName
                }
                return context.skeleton.joints[consumeJointIndex].name
            }()
            let consumedPose = effectiveUsesRootMotion
                ? consumeRootMotionTracks(in: evaluated.localPose,
                                          skeleton: context.skeleton,
                                          translationJointIndex: resolvedConsumeTranslationJointIndex,
                                          rotationJointIndex: resolvedConsumeRotationJointIndex,
                                          consumeTranslation: policy.consumeTranslation,
                                          consumeRotation: policy.consumeRotation)
                : evaluated.localPose
            return GraphNodeEvaluationResult(localPose: consumedPose,
                                             sampleTime: evaluated.sampleTime,
                                             sampleDuration: evaluated.sampleDuration,
                                             rootMotionDelta: filteredRootMotion,
                                             authoredUsesRootMotion: state.usesRootMotion,
                                             usesRootMotion: effectiveUsesRootMotion,
                                             currentStateName: state.name,
                                             rootMotionBoneName: consumeJointName,
                                             rootMotionJointIndex: consumeJointIndex,
                                             rootMotionTrackConsumed: effectiveUsesRootMotion && (policy.consumeTranslation || policy.consumeRotation),
                                             rootMotionTranslationBoneName: translationJointName,
                                             rootMotionTranslationJointIndex: translationJointIndex,
                                             rootMotionRotationBoneName: rotationJointName,
                                             rootMotionRotationJointIndex: rotationJointIndex,
                                             rootMotionConsumeBoneName: consumeJointName,
                                             rootMotionConsumeJointIndex: consumeJointIndex,
                                             diagnosticClipHandle: evaluated.diagnosticClipHandle)
        }

        guard let clipHandle = state.clipHandle,
              let clip = context.assets.animationClip(handle: clipHandle) else { return nil }
        let shouldLoop = state.isOneShot ? false : context.isLooping
        let sampleTimes = advanceAndResolveNodeSampleTime(nodeID: state.id,
                                                          duration: clip.durationSeconds,
                                                          isLooping: shouldLoop,
                                                          context: &context)
        let sampleStart = CACurrentMediaTime()
        let localPose = evaluateLocalPose(skeleton: context.skeleton, clip: clip, playbackTime: sampleTimes.current, assets: context.assets)
        context.samplePoseTimeMS += (CACurrentMediaTime() - sampleStart) * 1000.0
        let rootMotion = sampleClipRootMotionDelta(skeleton: context.skeleton,
                                                   clip: clip,
                                                   rootJointIndex: context.rootJointIndex,
                                                   trackerEntityID: context.entityID,
                                                   trackerKey: "graphState:\(state.id.uuidString)|clip:\(clip.handle.rawValue.uuidString)",
                                                   translationJointIndexOverride: stateChannels.translationJointIndex,
                                                   rotationJointIndexOverride: stateChannels.rotationJointIndex,
                                                   previousTime: sampleTimes.previous,
                                                   currentTime: sampleTimes.current,
                                                   isLooping: shouldLoop,
                                                   sourceStateName: state.name,
                                                   assets: context.assets)
        let filteredRootMotion = RootMotionDelta(
            deltaPos: (effectiveUsesRootMotion && policy.applyTranslation) ? rootMotion.deltaPos : .zero,
            deltaRot: (effectiveUsesRootMotion && policy.applyRotation) ? rootMotion.deltaRot : TransformMath.identityQuaternion
        )
        let outputPose = effectiveUsesRootMotion
            ? consumeRootMotionTracks(in: localPose,
                                      skeleton: context.skeleton,
                                      translationJointIndex: consumeTranslationJointIndex,
                                      rotationJointIndex: consumeRotationJointIndex,
                                      consumeTranslation: policy.consumeTranslation,
                                      consumeRotation: policy.consumeRotation)
            : localPose
        return GraphNodeEvaluationResult(localPose: outputPose,
                                         sampleTime: sampleTimes.current,
                                         sampleDuration: max(clip.durationSeconds, 0.0),
                                         rootMotionDelta: filteredRootMotion,
                                         authoredUsesRootMotion: state.usesRootMotion,
                                         usesRootMotion: effectiveUsesRootMotion,
                                         currentStateName: state.name,
                                         rootMotionBoneName: stateChannels.consumeJointName,
                                         rootMotionJointIndex: stateChannels.consumeJointIndex,
                                         rootMotionTrackConsumed: effectiveUsesRootMotion && (policy.consumeTranslation || policy.consumeRotation),
                                         rootMotionTranslationBoneName: stateChannels.translationJointName,
                                         rootMotionTranslationJointIndex: stateChannels.translationJointIndex,
                                         rootMotionRotationBoneName: stateChannels.rotationJointName,
                                         rootMotionRotationJointIndex: stateChannels.rotationJointIndex,
                                         rootMotionConsumeBoneName: stateChannels.consumeJointName,
                                         rootMotionConsumeJointIndex: stateChannels.consumeJointIndex,
                                         diagnosticClipHandle: clipHandle.rawValue.uuidString)
    }

    private func rootMotionPolicy(for state: AnimationGraphStateDefinition) -> RootMotionPolicy {
        guard state.usesRootMotion else {
            return disabledRootMotionPolicy()
        }
        if let configured = state.rootMotion {
            let policy = makeRootMotionPolicy(usesRootMotion: state.usesRootMotion,
                                              applyTranslation: configured.applyTranslation ?? true,
                                              applyRotation: configured.applyRotation ?? true,
                                              consumeTranslation: configured.consumeTranslation ?? true,
                                              consumeRotation: configured.consumeRotation ?? true)
            logResolvedRootMotionPolicyIfNeeded(state: state, policy: policy)
            return policy
        }
        let key = "\(state.id.uuidString)|missingRootMotionPolicy"
        if !loggedMissingRootMotionPolicyKeys.contains(key) {
            loggedMissingRootMotionPolicyKeys.insert(key)
            EngineLoggerContext.log(
                "Animator state missing explicit root-motion policy stateID=\(state.id.uuidString) stateName=\(state.name.isEmpty ? "<unnamed>" : state.name) action=useDefaultEnabledRuntimeRootMotionPolicy",
                level: .warning,
                category: .scene
            )
        }
        let policy = makeRootMotionPolicy(usesRootMotion: true,
                                          applyTranslation: true,
                                          applyRotation: true,
                                          consumeTranslation: true,
                                          consumeRotation: true)
        logResolvedRootMotionPolicyIfNeeded(state: state, policy: policy)
        return policy
    }

    private func effectiveUsesRootMotion(for state: AnimationGraphStateDefinition,
                                         policy: RootMotionPolicy) -> Bool {
        guard state.usesRootMotion else { return false }
        return policy.applyTranslation || policy.applyRotation || policy.consumeTranslation || policy.consumeRotation
    }

    private func disabledRootMotionPolicy() -> RootMotionPolicy {
        RootMotionPolicy(translationMode: .none,
                         rotationMode: .none,
                         allowDuringTransition: false,
                         transitionPolicy: .none,
                         consumeTranslation: false,
                         consumeRotation: false)
    }

    private func makeRootMotionPolicy(usesRootMotion: Bool,
                                      applyTranslation: Bool,
                                      applyRotation: Bool,
                                      consumeTranslation: Bool,
                                      consumeRotation: Bool) -> RootMotionPolicy {
        guard usesRootMotion else {
            return disabledRootMotionPolicy()
        }
        let translationMode: RootMotionChannelMode = applyTranslation ? .animation : (consumeTranslation ? .controller : .none)
        let rotationMode: RootMotionChannelMode = applyRotation ? .animation : (consumeRotation ? .controller : .none)
        let allowDuringTransition = applyTranslation || applyRotation || consumeTranslation || consumeRotation
        let transitionPolicy: TransitionRootMotionPolicy = allowDuringTransition ? .blended : .none
        return RootMotionPolicy(translationMode: translationMode,
                                rotationMode: rotationMode,
                                allowDuringTransition: allowDuringTransition,
                                transitionPolicy: transitionPolicy,
                                consumeTranslation: consumeTranslation,
                                consumeRotation: consumeRotation)
    }

    private func logResolvedRootMotionPolicyIfNeeded(state: AnimationGraphStateDefinition,
                                                     policy: RootMotionPolicy) {
        let key = state.id.uuidString
        guard !loggedResolvedRootMotionPolicyKeys.contains(key) else { return }
        loggedResolvedRootMotionPolicyKeys.insert(key)
        EngineLoggerContext.log(
            "AnimRootMotion policy resolved stateID=\(state.id.uuidString) stateName=\(state.name.isEmpty ? "<unnamed>" : state.name) translationMode=\(policy.translationMode.rawValue) rotationMode=\(policy.rotationMode.rawValue) allowDuringTransition=\(policy.allowDuringTransition) transitionPolicy=\(policy.transitionPolicy.rawValue)",
            level: .debug,
            category: .scene
        )
    }

    private func resolveStateRootMotionChannels(state: AnimationGraphStateDefinition,
                                                skeleton: SkeletonAsset,
                                                clip: AnimationClipAsset?,
                                                preferredRootJointIndex: Int) -> RootMotionChannels {
        let translationConfiguredIndex = state.rootMotion?.translationSourceJointName.flatMap {
            jointIndex(named: $0, skeleton: skeleton)
        }
        let rotationConfiguredIndex = state.rootMotion?.rotationSourceJointName.flatMap {
            jointIndex(named: $0, skeleton: skeleton)
        }
        let consumeConfiguredIndex = state.rootMotion?.consumeJointName.flatMap {
            jointIndex(named: $0, skeleton: skeleton)
        }
        let channelPair: (translationJointIndex: Int, rotationJointIndex: Int)
        if let clip {
            channelPair = resolveRootMotionChannels(skeleton: skeleton,
                                                    clip: clip,
                                                    preferredRootJointIndex: preferredRootJointIndex,
                                                    translationJointIndexOverride: translationConfiguredIndex,
                                                    rotationJointIndexOverride: rotationConfiguredIndex)
        } else {
            let fallbackJoint = fallbackRootMotionJointIndex(skeleton: skeleton,
                                                             preferredRootJointIndex: preferredRootJointIndex)
            let translation = translationConfiguredIndex ?? fallbackJoint
            let rotation = rotationConfiguredIndex ?? fallbackJoint
            channelPair = (translationJointIndex: translation, rotationJointIndex: rotation)
        }
        let consumeJointIndex = consumeConfiguredIndex ?? channelPair.translationJointIndex
        let translationName = skeleton.joints.indices.contains(channelPair.translationJointIndex)
            ? skeleton.joints[channelPair.translationJointIndex].name
            : ""
        let rotationName = skeleton.joints.indices.contains(channelPair.rotationJointIndex)
            ? skeleton.joints[channelPair.rotationJointIndex].name
            : ""
        let consumeName = skeleton.joints.indices.contains(consumeJointIndex)
            ? skeleton.joints[consumeJointIndex].name
            : ""
        return RootMotionChannels(translationJointIndex: channelPair.translationJointIndex,
                                  rotationJointIndex: channelPair.rotationJointIndex,
                                  consumeJointIndex: consumeJointIndex,
                                  translationJointName: translationName,
                                  rotationJointName: rotationName,
                                  consumeJointName: consumeName)
    }

    private func resolveExtractionChannelsForClip(skeleton: SkeletonAsset,
                                                  clip: AnimationClipAsset,
                                                  preferredRootJointIndex: Int,
                                                  translationJointIndexOverride: Int?,
                                                  rotationJointIndexOverride: Int?) -> RootMotionExtractionChannels {
        let channels = resolveRootMotionChannels(skeleton: skeleton,
                                                 clip: clip,
                                                 preferredRootJointIndex: preferredRootJointIndex,
                                                 translationJointIndexOverride: translationJointIndexOverride,
                                                 rotationJointIndexOverride: rotationJointIndexOverride)
        let translationName = skeleton.joints.indices.contains(channels.translationJointIndex)
            ? skeleton.joints[channels.translationJointIndex].name
            : ""
        let rotationName = skeleton.joints.indices.contains(channels.rotationJointIndex)
            ? skeleton.joints[channels.rotationJointIndex].name
            : ""
        return RootMotionExtractionChannels(translationJointIndex: channels.translationJointIndex,
                                            rotationJointIndex: channels.rotationJointIndex,
                                            translationJointName: translationName,
                                            rotationJointName: rotationName)
    }

    private func makeFixedTickRuntimeSnapshot(fixedTickID: UInt64,
                                              compiledGraph: CompiledAnimationGraph,
                                              runtimeState: AnimationGraphRuntimeInstanceState,
                                              graphResult: GraphNodeEvaluationResult) -> AnimationFixedTickRuntimeSnapshot {
        var stateByID: [UUID: AnimationGraphStateDefinition] = [:]
        var stateIDsByName: [String: [UUID]] = [:]
        for node in compiledGraph.nodes {
            guard let machine = node.stateMachine else { continue }
            for state in machine.states {
                stateByID[state.id] = state
                let key = state.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                stateIDsByName[key, default: []].append(state.id)
            }
        }
        let runtimeCurrentStateID = runtimeState.stateMachineCurrentStateByNodeID
            .sorted(by: { $0.key.uuidString < $1.key.uuidString })
            .first?.value
        let runtimeNextStateID = runtimeState.stateMachineNextStateByNodeID
            .sorted(by: { $0.key.uuidString < $1.key.uuidString })
            .first?.value
        let runtimeCurrentState = runtimeCurrentStateID.flatMap { stateByID[$0] }
        let graphStateName = graphResult.currentStateName.trimmingCharacters(in: .whitespacesAndNewlines)
        let graphStateLookupKey = graphStateName.lowercased()
        let graphDerivedStateID = stateIDsByName[graphStateLookupKey]?
            .sorted(by: { $0.uuidString < $1.uuidString })
            .first
        let currentStateID: UUID? = {
            if let runtimeCurrentStateID {
                return runtimeCurrentStateID
            }
            return graphDerivedStateID
        }()
        let nextStateID = runtimeNextStateID
        let currentStateName: String = {
            if runtimeCurrentStateID != nil {
                return runtimeCurrentState?.name ?? ""
            }
            return graphStateName
        }()
        let nextStateName = nextStateID.flatMap { stateByID[$0]?.name } ?? ""
        let authoredUsesRootMotion: Bool = {
            if runtimeCurrentStateID != nil {
                return runtimeCurrentState?.usesRootMotion ?? false
            }
            return graphResult.authoredUsesRootMotion
        }()
        let effectiveUsesRootMotion = graphResult.usesRootMotion
        let stateWantsRootMotion = authoredUsesRootMotion && effectiveUsesRootMotion
        let sampleHasNonZeroDelta = graphResult.rootMotionSampleHasNonZeroDelta
        let sampleValid = graphResult.rootMotionValid
        let localDelta = graphResult.rootMotionDelta.deltaPos
        let rotationDelta = graphResult.rootMotionDelta.deltaRot
        let transitionBlendActive = runtimeState.stateMachineTransitionDurationByNodeID.contains {
            let nodeID = $0.key
            let duration = $0.value
            guard duration > 1.0e-5 else { return false }
            let elapsed = runtimeState.stateMachineTransitionElapsedByNodeID[nodeID] ?? 0.0
            let hasNextState = runtimeState.stateMachineNextStateByNodeID[nodeID] != nil
            return hasNextState && elapsed < duration
        }
        if let runtimeCurrentStateID,
           let runtimeCurrentState = stateByID[runtimeCurrentStateID] {
            let mismatch = runtimeCurrentState.name.caseInsensitiveCompare(currentStateName) != .orderedSame
                || runtimeCurrentState.usesRootMotion != authoredUsesRootMotion
            if mismatch {
                let coherenceKey = "\(fixedTickID)|\(compiledGraph.outputNodeIndex)|\(runtimeCurrentStateID.uuidString)|\(currentStateName)"
                if !loggedSnapshotCoherenceKeys.contains(coherenceKey) {
                    loggedSnapshotCoherenceKeys.insert(coherenceKey)
                    EngineLoggerContext.log(
                        "AnimRootMotion snapshot coherence mismatch tickID=\(fixedTickID) runtimeCurrentState=\(runtimeCurrentState.name.isEmpty ? runtimeCurrentStateID.uuidString : runtimeCurrentState.name) graphReportedState=\(currentStateName.isEmpty ? "<none>" : currentStateName) runtimeAuthoredUsesRM=\(runtimeCurrentState.usesRootMotion) graphAuthoredUsesRM=\(authoredUsesRootMotion) graphEffectiveUsesRM=\(effectiveUsesRootMotion)",
                        level: .warning,
                        category: .scene
                    )
                }
            }
        }
        return AnimationFixedTickRuntimeSnapshot(
            tickID: fixedTickID,
            currentStateID: currentStateID,
            currentStateName: currentStateName,
            nextStateID: nextStateID,
            nextStateName: nextStateName,
            authoredUsesRootMotion: authoredUsesRootMotion,
            stateWantsRootMotion: stateWantsRootMotion,
            effectiveUsesRootMotion: effectiveUsesRootMotion,
            sampleHasNonZeroDelta: sampleHasNonZeroDelta,
            rootMotionSampleValid: sampleValid,
            rootMotionTrackConsumed: graphResult.rootMotionTrackConsumed,
            translationSourceJointIndex: graphResult.rootMotionTranslationJointIndex,
            translationSourceJointName: graphResult.rootMotionTranslationBoneName,
            rotationSourceJointIndex: graphResult.rootMotionRotationJointIndex,
            rotationSourceJointName: graphResult.rootMotionRotationBoneName,
            localRootDeltaTranslation: localDelta,
            worldRootDeltaTranslation: graphResult.rootMotionDelta.deltaPos,
            rootDeltaRotation: rotationDelta,
            sampleTime: graphResult.sampleTime,
            sampleDuration: graphResult.sampleDuration,
            isTransitionBlend: transitionBlendActive
        )
    }

    private func jointIndex(named rawName: String, skeleton: SkeletonAsset) -> Int? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let exact = skeleton.joints.firstIndex(where: { $0.name == trimmed }) {
            return exact
        }
        return skeleton.joints.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame })
    }

    private func stateNormalizedTime(for result: GraphNodeEvaluationResult) -> Float {
        guard result.sampleDuration > 1.0e-5 else { return 0.0 }
        return simd_clamp(result.sampleTime / result.sampleDuration, 0.0, 1.0)
    }

    private func assembleCanonicalAnimationTickResult(entityID: UUID,
                                                      fixedTickID: UInt64,
                                                      dt: Float,
                                                      assets: AssetManager,
                                                      animator: AnimatorComponent) -> AnimationTickResult {
        let poseState = animator.poseRuntimeState
        let snapshot = poseState?.fixedTickRuntimeSnapshot
        let graphId = resolveAnimationContractGraphID(animator: animator)
        let compiledGraph = animator.graphHandle.flatMap { assets.compiledAnimationGraph(handle: $0) }
        let nodeSelection = selectCanonicalStateMachineNode(runtimeState: animator.graphRuntimeState,
                                                            snapshot: snapshot)
        logMixedCanonicalNodeSelectionIfNeeded(entityID: entityID,
                                               graphID: graphId,
                                               chosenNodeID: nodeSelection.chosenNodeID,
                                               conflictingNodeIDs: nodeSelection.conflictingNodeIDs)
        let resolvedState = resolveCanonicalStateSnapshot(graphID: graphId,
                                                          nodeSelection: nodeSelection,
                                                          runtimeState: animator.graphRuntimeState,
                                                          snapshot: snapshot,
                                                          poseState: poseState,
                                                          compiledGraph: compiledGraph,
                                                          assets: assets,
                                                          entityID: entityID)

        let stateResult = StateMachineTickResult(
            graphId: graphId,
            activeStateId: resolvedState.activeStateID,
            activeStateName: resolvedState.activeStateName,
            isInTransition: resolvedState.isInTransition,
            transition: resolvedState.transition,
            stateTime: resolvedState.stateTime,
            normalizedStateTime: resolvedState.normalizedStateTime
        )

        let rootDelta = snapshot.map {
            RootMotionDelta(deltaPos: $0.localRootDeltaTranslation, deltaRot: $0.rootDeltaRotation)
        } ?? (poseState?.rootMotionDelta ?? .zero)
        let activeStateUUID = nodeSelection.chosenNodeID
            .flatMap { animator.graphRuntimeState?.stateMachineCurrentStateByNodeID[$0] }
            ?? snapshot?.currentStateID
        let activeStateDefinition = stateDefinition(for: activeStateUUID,
                                                    nodeID: nodeSelection.chosenNodeID,
                                                    compiledGraph: compiledGraph)
        let statePolicy = activeStateDefinition.map { rootMotionPolicy(for: $0) }
            ?? rootMotionPolicyFromSnapshot(snapshot: snapshot, poseState: poseState)
        let stateHasAuthoredRootMotion = activeStateDefinition?.usesRootMotion
            ?? snapshot?.authoredUsesRootMotion
            ?? poseState?.usesRootMotion
            ?? false
        let hasAuthoredMotion = snapshot.map(rootMotionHasAuthoredMotionFromExtraction) ?? false
        let rootMotionIsActive = (snapshot?.effectiveUsesRootMotion ?? false) && animator.enableRootMotion
        let rootSource: RootMotionSource = resolvedState.isInTransition ? .transitionBlend : (resolvedState.activeStateName.isEmpty ? .none : .state)
        let rootRotation = simd_quatf(vector: TransformMath.normalizedQuaternion(rootDelta.deltaRot))
        let effectiveTranslation = (rootMotionIsActive && statePolicy.translationMode == .animation) ? rootDelta.deltaPos : .zero
        let effectiveRotation = (rootMotionIsActive && statePolicy.rotationMode == .animation)
            ? rootRotation
            : simd_quatf(vector: TransformMath.identityQuaternion)
        let effectiveMode: LocomotionAuthorityMode = {
            guard rootMotionIsActive else { return .controllerDriven }
            let policyHasAnimatedChannel = statePolicy.translationMode == .animation || statePolicy.rotationMode == .animation
            let policyHasRootMotionIntent = policyHasAnimatedChannel || statePolicy.consumeTranslation || statePolicy.consumeRotation
            return policyHasRootMotionIntent ? .animationRootMotion : .controllerDriven
        }()
        let rootMotion = RootMotionFrame(
            mode: effectiveMode,
            authoredDeltaLocal: rootDelta.deltaPos,
            authoredDeltaRotationLocal: rootRotation,
            effectiveDeltaLocal: effectiveTranslation,
            effectiveDeltaRotationLocal: effectiveRotation,
            stateHasAuthoredRootMotion: stateHasAuthoredRootMotion,
            hasAuthoredMotion: hasAuthoredMotion,
            isActive: rootMotionIsActive,
            source: rootSource
        )

        let canonical = AnimationTickResult(
            entity: entityID,
            tickIndex: fixedTickID,
            dt: dt,
            stateMachine: stateResult,
            rootMotion: rootMotion,
            animatorWrites: AnimatorParameterWriteSet(),
            debug: nil
        )
        validateCanonicalAnimationTickResult(canonical)
        return canonical
    }

    private struct CanonicalStateNodeSelection {
        let chosenNodeID: UUID?
        let conflictingNodeIDs: [UUID]
    }

    private struct CanonicalStateResolution {
        let activeStateID: String
        let activeStateName: String
        let isInTransition: Bool
        let transition: TransitionTickInfo?
        let stateTime: Float
        let normalizedStateTime: Float
    }

    private func selectCanonicalStateMachineNode(runtimeState: AnimationGraphRuntimeInstanceState?,
                                                 snapshot: AnimationFixedTickRuntimeSnapshot?) -> CanonicalStateNodeSelection {
        guard let runtimeState else {
            return CanonicalStateNodeSelection(chosenNodeID: nil, conflictingNodeIDs: [])
        }
        var candidateNodeIDs = Set<UUID>()
        candidateNodeIDs.formUnion(runtimeState.stateMachineCurrentStateByNodeID.keys)
        candidateNodeIDs.formUnion(runtimeState.stateMachineNextStateByNodeID.keys)
        candidateNodeIDs.formUnion(runtimeState.stateMachineTransitionDurationByNodeID.keys)
        candidateNodeIDs.formUnion(runtimeState.stateMachineTransitionElapsedByNodeID.keys)
        candidateNodeIDs.formUnion(runtimeState.stateMachineStateElapsedByNodeID.keys)
        guard !candidateNodeIDs.isEmpty else {
            return CanonicalStateNodeSelection(chosenNodeID: nil, conflictingNodeIDs: [])
        }

        let sortedCandidates = candidateNodeIDs.sorted(by: { $0.uuidString < $1.uuidString })
        let chosenNodeID: UUID
        if let snapshotStateID = snapshot?.currentStateID {
            let matchingNodes = sortedCandidates.filter { runtimeState.stateMachineCurrentStateByNodeID[$0] == snapshotStateID }
            if let firstMatch = matchingNodes.first {
                chosenNodeID = firstMatch
            } else {
                chosenNodeID = sortedCandidates[0]
            }
        } else {
            chosenNodeID = sortedCandidates[0]
        }
        let conflicts = sortedCandidates.filter { $0 != chosenNodeID }
        return CanonicalStateNodeSelection(chosenNodeID: chosenNodeID, conflictingNodeIDs: conflicts)
    }

    private func resolveCanonicalStateSnapshot(graphID: AssetHandle,
                                               nodeSelection: CanonicalStateNodeSelection,
                                               runtimeState: AnimationGraphRuntimeInstanceState?,
                                               snapshot: AnimationFixedTickRuntimeSnapshot?,
                                               poseState: AnimationPoseRuntimeState?,
                                               compiledGraph: CompiledAnimationGraph?,
                                               assets: AssetManager,
                                               entityID: UUID) -> CanonicalStateResolution {
        let fallbackStateTime = snapshot?.sampleTime ?? poseState?.sampleTime ?? 0.0
        let fallbackDuration = snapshot?.sampleDuration ?? poseState?.sampleDuration ?? 0.0
        let fallbackNormalized = normalizedStateTime(sampleTime: fallbackStateTime, sampleDuration: fallbackDuration)
        guard let runtimeState,
              let nodeID = nodeSelection.chosenNodeID else {
            let fallbackName = snapshot?.currentStateName ?? poseState?.currentStateName ?? ""
            let fallbackID = stableCanonicalStateID(graphID: graphID,
                                                    nodeID: nil,
                                                    stateID: snapshot?.currentStateID,
                                                    stateName: fallbackName,
                                                    entityID: entityID)
            let isInTransition = snapshot?.isTransitionBlend == true
            let transition: TransitionTickInfo? = {
                guard isInTransition else { return nil }
                let targetID = stableCanonicalStateID(graphID: graphID,
                                                      nodeID: nil,
                                                      stateID: snapshot?.nextStateID,
                                                      stateName: snapshot?.nextStateName ?? "",
                                                      entityID: entityID)
                return TransitionTickInfo(sourceStateId: fallbackID,
                                          targetStateId: targetID,
                                          normalizedTime: 0.0,
                                          duration: 0.0,
                                          phase: .active)
            }()
            return CanonicalStateResolution(activeStateID: fallbackID,
                                            activeStateName: fallbackName,
                                            isInTransition: isInTransition,
                                            transition: transition,
                                            stateTime: fallbackStateTime,
                                            normalizedStateTime: fallbackNormalized)
        }

        let currentStateUUID = runtimeState.stateMachineCurrentStateByNodeID[nodeID] ?? snapshot?.currentStateID
        let nextStateUUID = runtimeState.stateMachineNextStateByNodeID[nodeID] ?? snapshot?.nextStateID
        let elapsedTransition = max(runtimeState.stateMachineTransitionElapsedByNodeID[nodeID] ?? 0.0, 0.0)
        let transitionDuration = max(runtimeState.stateMachineTransitionDurationByNodeID[nodeID] ?? 0.0, 0.0)
        let isInTransition = nextStateUUID != nil && transitionDuration > 1.0e-5 && elapsedTransition < transitionDuration
        let transitionNormalized = transitionDuration > 1.0e-5 ? simd_clamp(elapsedTransition / transitionDuration, 0.0, 1.0) : 1.0
        let currentName = stateName(for: currentStateUUID,
                                    nodeID: nodeID,
                                    compiledGraph: compiledGraph) ?? snapshot?.currentStateName ?? poseState?.currentStateName ?? ""
        let nextName = stateName(for: nextStateUUID,
                                 nodeID: nodeID,
                                 compiledGraph: compiledGraph) ?? snapshot?.nextStateName ?? ""
        let activeStateID = stableCanonicalStateID(graphID: graphID,
                                                   nodeID: nodeID,
                                                   stateID: currentStateUUID,
                                                   stateName: currentName,
                                                   entityID: entityID)
        let targetStateID = stableCanonicalStateID(graphID: graphID,
                                                   nodeID: nodeID,
                                                   stateID: nextStateUUID,
                                                   stateName: nextName,
                                                   entityID: entityID)
        let stateElapsed = max(runtimeState.stateMachineStateElapsedByNodeID[nodeID] ?? fallbackStateTime, 0.0)
        let stateDuration = stateDurationSeconds(nodeID: nodeID,
                                                 stateID: currentStateUUID,
                                                 compiledGraph: compiledGraph,
                                                 assets: assets) ?? fallbackDuration
        let normalized = normalizedStateTime(sampleTime: stateElapsed, sampleDuration: stateDuration)
        let transition: TransitionTickInfo? = isInTransition
            ? TransitionTickInfo(sourceStateId: activeStateID,
                                 targetStateId: targetStateID,
                                 normalizedTime: transitionNormalized,
                                 duration: transitionDuration,
                                 phase: transitionPhase(normalized: transitionNormalized))
            : nil
        return CanonicalStateResolution(activeStateID: activeStateID,
                                        activeStateName: currentName,
                                        isInTransition: isInTransition,
                                        transition: transition,
                                        stateTime: stateElapsed,
                                        normalizedStateTime: normalized)
    }

    private func resolveAnimationContractGraphID(animator: AnimatorComponent) -> AssetHandle {
        if let graph = animator.graphHandle {
            return graph
        }
        if let clip = animator.clipHandle {
            return clip
        }
        return AssetHandle(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID())
    }

    private func stableCanonicalStateID(graphID: AssetHandle,
                                        nodeID: UUID?,
                                        stateID: UUID?,
                                        stateName: String,
                                        entityID: UUID) -> String {
        if let stateID {
            return stateID.uuidString
        }
        let normalizedName = stateName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let surrogate = "surrogate:\(graphID.rawValue.uuidString):\(nodeID?.uuidString ?? "no-node"):\(normalizedName.isEmpty ? "unnamed" : normalizedName)"
        let key = "\(entityID.uuidString)|\(graphID.rawValue.uuidString)|\(nodeID?.uuidString ?? "no-node")|\(normalizedName)"
        if !loggedCanonicalSurrogateStateIDKeys.contains(key) {
            loggedCanonicalSurrogateStateIDKeys.insert(key)
            EngineLoggerContext.log(
                "Animation canonical state id using deterministic surrogate entity=\(entityID.uuidString) graphId=\(graphID.rawValue.uuidString) nodeId=\(nodeID?.uuidString ?? "<none>") stateName=\(stateName.isEmpty ? "<empty>" : stateName)",
                level: .warning,
                category: .scene
            )
        }
        return surrogate
    }

    private func stateName(for stateID: UUID?,
                           nodeID: UUID,
                           compiledGraph: CompiledAnimationGraph?) -> String? {
        guard let stateID,
              let compiledGraph else { return nil }
        guard let node = compiledGraph.nodes.first(where: { $0.id == nodeID }),
              let machine = node.stateMachine,
              let state = machine.states.first(where: { $0.id == stateID }) else {
            return nil
        }
        return state.name
    }

    private func stateDefinition(for stateID: UUID?,
                                 nodeID: UUID?,
                                 compiledGraph: CompiledAnimationGraph?) -> AnimationGraphStateDefinition? {
        guard let stateID,
              let nodeID,
              let compiledGraph,
              let node = compiledGraph.nodes.first(where: { $0.id == nodeID }),
              let machine = node.stateMachine else {
            return nil
        }
        return machine.states.first(where: { $0.id == stateID })
    }

    private func stateDurationSeconds(nodeID: UUID,
                                      stateID: UUID?,
                                      compiledGraph: CompiledAnimationGraph?,
                                      assets: AssetManager) -> Float? {
        guard let stateID,
              let compiledGraph,
              let node = compiledGraph.nodes.first(where: { $0.id == nodeID }),
              let machine = node.stateMachine,
              let state = machine.states.first(where: { $0.id == stateID }),
              let clipHandle = state.clipHandle,
              let clip = assets.animationClip(handle: clipHandle) else {
            return nil
        }
        return max(clip.durationSeconds, 0.0)
    }

    private func rootMotionPolicyFromSnapshot(snapshot: AnimationFixedTickRuntimeSnapshot?,
                                              poseState: AnimationPoseRuntimeState?) -> RootMotionPolicy {
        if let snapshot {
            let uses = snapshot.authoredUsesRootMotion
            let applyTranslation = uses && snapshot.effectiveUsesRootMotion
            let applyRotation = uses && snapshot.effectiveUsesRootMotion
            let consumeTranslation = uses
            let consumeRotation = uses
            return makeRootMotionPolicy(usesRootMotion: uses,
                                        applyTranslation: applyTranslation,
                                        applyRotation: applyRotation,
                                        consumeTranslation: consumeTranslation,
                                        consumeRotation: consumeRotation)
        }
        let uses = poseState?.usesRootMotion ?? false
        return makeRootMotionPolicy(usesRootMotion: uses,
                                    applyTranslation: uses,
                                    applyRotation: uses,
                                    consumeTranslation: uses,
                                    consumeRotation: uses)
    }

    private func logMixedCanonicalNodeSelectionIfNeeded(entityID: UUID,
                                                        graphID: AssetHandle,
                                                        chosenNodeID: UUID?,
                                                        conflictingNodeIDs: [UUID]) {
        guard !conflictingNodeIDs.isEmpty else { return }
        let key = "\(entityID.uuidString)|\(graphID.rawValue.uuidString)|\(chosenNodeID?.uuidString ?? "none")"
        guard !loggedCanonicalMultiNodeKeys.contains(key) else { return }
        loggedCanonicalMultiNodeKeys.insert(key)
        let conflicts = conflictingNodeIDs.map(\.uuidString).joined(separator: ",")
        EngineLoggerContext.log(
            "Animation canonical multi-node state selection entity=\(entityID.uuidString) graphId=\(graphID.rawValue.uuidString) chosenPrimaryNodeId=\(chosenNodeID?.uuidString ?? "<none>") conflictingNodeIds=[\(conflicts)]",
            level: .warning,
            category: .scene
        )
    }

    private func transitionPhase(normalized: Float) -> TransitionTickPhase {
        if normalized <= 1.0e-4 {
            return .entering
        }
        if normalized >= 0.9999 {
            return .exiting
        }
        return .active
    }

    private func normalizedStateTime(sampleTime: Float, sampleDuration: Float) -> Float {
        guard sampleDuration > 1.0e-5 else { return 0.0 }
        return simd_clamp(sampleTime / sampleDuration, 0.0, 1.0)
    }

    private func rootMotionHasAuthoredMotionFromExtraction(_ snapshot: AnimationFixedTickRuntimeSnapshot) -> Bool {
        if snapshot.rootMotionSampleValid || snapshot.sampleHasNonZeroDelta {
            return true
        }
        let deltaMagnitude = simd_length(snapshot.localRootDeltaTranslation)
        let rotation = simd_quatf(vector: TransformMath.normalizedQuaternion(snapshot.rootDeltaRotation))
        let rotationRadians = 2.0 * acos(simd_clamp(abs(rotation.real), 0.0, 1.0))
        return deltaMagnitude > 1.0e-6 || rotationRadians > 1.0e-5
    }

    private func validateCanonicalAnimationTickResult(_ result: AnimationTickResult) {
        if result.stateMachine.isInTransition && result.stateMachine.transition == nil {
            let key = "canonicalMissingTransition|\(result.entity.uuidString)|\(result.tickIndex)"
            logCanonicalContractIssueOnce(key: key,
                                         message: "Animation canonical result inconsistency entity=\(result.entity.uuidString) tickID=\(result.tickIndex) issue=isInTransitionWithoutTransitionInfo")
        }
        if !result.stateMachine.isInTransition && result.stateMachine.transition != nil {
            let key = "canonicalUnexpectedTransition|\(result.entity.uuidString)|\(result.tickIndex)"
            logCanonicalContractIssueOnce(key: key,
                                         message: "Animation canonical result inconsistency entity=\(result.entity.uuidString) tickID=\(result.tickIndex) issue=transitionInfoPresentWhileNotInTransition")
        }
        if result.rootMotion.mode == .animationRootMotion && !result.rootMotion.isActive {
            let key = "canonicalRootMotionModeMismatch|\(result.entity.uuidString)|\(result.tickIndex)"
            logCanonicalContractIssueOnce(key: key,
                                         message: "Animation canonical result inconsistency entity=\(result.entity.uuidString) tickID=\(result.tickIndex) issue=animationRootMotionModeButInactive")
        }
        if !result.stateMachine.activeStateId.isEmpty && result.stateMachine.activeStateName.isEmpty {
            let key = "canonicalStateNameMissing|\(result.entity.uuidString)|\(result.tickIndex)"
            logCanonicalContractIssueOnce(key: key,
                                         message: "Animation canonical result inconsistency entity=\(result.entity.uuidString) tickID=\(result.tickIndex) issue=activeStateIdPresentButActiveStateNameEmpty")
        }
    }

    private func logCanonicalContractIssueOnce(key: String, message: String) {
        guard !loggedCanonicalContractIssueKeys.contains(key) else { return }
        loggedCanonicalContractIssueKeys.insert(key)
        EngineLoggerContext.log(message, level: .warning, category: .scene)
    }

    private func applyCanonicalCompatibilityBridge(animator: inout AnimatorComponent) {
        guard let canonical = animator.latestAnimationTickResult else { return }
        guard var poseState = animator.poseRuntimeState else { return }
        let compatibilityView = AnimationRuntimeCompatibilityView(canonical: canonical)
        // Temporary phase-1 bridge: legacy runtime fields mirror canonical tick output.
        poseState.usesRootMotion = compatibilityView.usesRootMotion
        poseState.rootMotionDelta = compatibilityView.rootMotionDelta(fallback: poseState.rootMotionDelta)
        poseState.rootMotionSample = compatibilityView.rootMotionSample(fallback: poseState.rootMotionSample)
        let bridgedSnapshot = compatibilityView.fixedTickRuntimeSnapshot(fallback: poseState.fixedTickRuntimeSnapshot)
        if bridgedSnapshot.authoredUsesRootMotion != canonical.rootMotion.stateHasAuthoredRootMotion {
            let key = "\(canonical.entity.uuidString)|\(canonical.tickIndex)|bridgeAuthoredRootMotionSource"
            if !loggedCanonicalBridgeAuthoredMappingKeys.contains(key) {
                loggedCanonicalBridgeAuthoredMappingKeys.insert(key)
                EngineLoggerContext.log(
                    "Animation compatibility bridge authored-root-motion mapping inconsistency entity=\(canonical.entity.uuidString) tickID=\(canonical.tickIndex) stateHasAuthoredRootMotion=\(canonical.rootMotion.stateHasAuthoredRootMotion) bridgedAuthoredUsesRootMotion=\(bridgedSnapshot.authoredUsesRootMotion)",
                    level: .warning,
                    category: .scene
                )
            }
        }
        poseState.fixedTickRuntimeSnapshot = bridgedSnapshot
        animator.poseRuntimeState = poseState
    }

    private func firstPassingTransition(machine: AnimationGraphStateMachineScaffold,
                                        fromStateID: UUID,
                                        currentNormalizedTime: Float,
                                        context: inout GraphEvaluationContext) -> TransitionSelection? {
        for transition in machine.transitions where transition.fromStateID == fromStateID {
            if let minimumNormalizedTime = transition.minimumNormalizedTime,
               currentNormalizedTime < minimumNormalizedTime {
                continue
            }
            if transition.transitionGraph != nil {
                guard let transitionOutput = evaluateTransitionGraph(transition: transition, context: &context),
                      transitionOutput.transition else {
                    continue
                }
                for triggerIndex in transitionOutput.triggerIndicesToConsume {
                    context.runtimeState.clearTrigger(index: triggerIndex)
                }
                let duration = max(transitionOutput.durationOverride ?? transition.durationSeconds, 0.0)
                return TransitionSelection(transition: transition,
                                           durationSeconds: duration,
                                           synchronize: transitionOutput.synchronize)
            }
            var triggersToConsume = Set<Int>()
            if transitionConditionsPass(transition.conditions,
                                        context: &context,
                                        triggerIndicesToConsume: &triggersToConsume) {
                for triggerIndex in triggersToConsume {
                    context.runtimeState.clearTrigger(index: triggerIndex)
                }
                return TransitionSelection(transition: transition,
                                           durationSeconds: max(transition.durationSeconds, 0.0),
                                           synchronize: false)
            }
        }
        return nil
    }

    private func evaluateTransitionGraph(transition: AnimationGraphTransitionDefinition,
                                         context: inout GraphEvaluationContext) -> TransitionGraphOutput? {
        guard let reference = transition.transitionGraph,
              let runtime = makeTransitionGraphRuntime(transitionID: transition.id,
                                                       reference: reference,
                                                       assets: context.assets) else {
            return nil
        }
        var evaluationContext = TransitionGraphEvaluationContext(runtime: runtime,
                                                                 compiledGraph: context.compiledGraph,
                                                                 runtimeState: context.runtimeState)
        guard runtime.outputNodeIndex >= 0,
              runtime.outputNodeIndex < runtime.nodes.count else { return nil }
        let transitionInput = evaluateTransitionGraphInput(nodeIndex: runtime.outputNodeIndex,
                                                           slot: 0,
                                                           context: &evaluationContext)
        let synchronizeInput = evaluateTransitionGraphInput(nodeIndex: runtime.outputNodeIndex,
                                                            slot: 1,
                                                            context: &evaluationContext)
        let durationInput = evaluateTransitionGraphInput(nodeIndex: runtime.outputNodeIndex,
                                                         slot: 2,
                                                         context: &evaluationContext)
        let outputNode = runtime.nodes[runtime.outputNodeIndex]
        let transitionDefault = outputNode.boolValue ?? false
        let durationDefault = outputNode.floatValue.map { max(0.0, $0) }

        let shouldTransition = transitionInput.map(coerceScalarToBool) ?? transitionDefault
        let synchronizeDefault = outputNode.synchronizeValue ?? false
        let synchronize = synchronizeInput.map(coerceScalarToBool) ?? synchronizeDefault
        let durationOverride = durationInput.map { max(0.0, coerceScalarToFloat($0)) } ?? durationDefault
        if animationGraphDebugLoggingEnabled {
            let groundedIndex = graphParameterIndex(name: "Grounded", compiledGraph: context.compiledGraph)
            let movementSpeedIndex = graphParameterIndex(name: "MovementSpeed", compiledGraph: context.compiledGraph)
            let groundedValue: Bool? = {
                guard let groundedIndex,
                      groundedIndex >= 0,
                      groundedIndex < evaluationContext.runtimeState.boolParameterValues.count else { return nil }
                return evaluationContext.runtimeState.boolParameterValues[groundedIndex]
            }()
            let movementSpeedValue: Float? = {
                guard let movementSpeedIndex,
                      movementSpeedIndex >= 0,
                      movementSpeedIndex < evaluationContext.runtimeState.floatParameterValues.count else { return nil }
                return evaluationContext.runtimeState.floatParameterValues[movementSpeedIndex]
            }()
            let debugKey = "\(context.entityID.uuidString)|\(transition.id.uuidString)"
            let sampleCount = (transitionGraphDebugSampleCountsByKey[debugKey] ?? 0) + 1
            transitionGraphDebugSampleCountsByKey[debugKey] = sampleCount
            if sampleCount % 30 == 0 {
                let groundedSummary = groundedValue.map { String($0) } ?? "<unset>"
                let movementSpeedSummary = movementSpeedValue.map { String($0) } ?? "<unset>"
                let durationSummary = durationOverride.map { String($0) } ?? "<none>"
                EngineLoggerContext.log(
                    "AnimGraph transition eval entity=\(context.entityID.uuidString) transitionID=\(transition.id.uuidString) transition=\(shouldTransition) grounded=\(groundedSummary) movementSpeed=\(movementSpeedSummary) durationOverride=\(durationSummary)",
                    level: .debug,
                    category: .scene
                )
            }
        }
        context.runtimeState = evaluationContext.runtimeState
        return TransitionGraphOutput(transition: shouldTransition,
                                     synchronize: synchronize,
                                     durationOverride: durationOverride,
                                     triggerIndicesToConsume: shouldTransition ? evaluationContext.triggerIndicesToConsume : [])
    }

    private func makeTransitionGraphRuntime(transitionID: UUID,
                                            reference: AnimationGraphTransitionGraphReference,
                                            assets: AssetManager) -> TransitionGraphRuntimeInstance? {
        let graphDefinition: AnimationGraphTransitionGraphDefinition?
        if let inlineGraph = reference.inlineGraph {
            graphDefinition = inlineGraph
        } else if let graphHandle = reference.graphHandle,
                  let graphAsset = assets.animationGraph(handle: graphHandle) {
            let nodes = graphAsset.nodes.map { node in
                AnimationGraphTransitionGraphNodeDefinition(id: node.id,
                                                            type: node.type.rawValue,
                                                            title: node.title,
                                                            position: node.position,
                                                            parameterName: node.parameterName,
                                                            floatValue: nil,
                                                            boolValue: nil)
            }
            let links = graphAsset.links.map { link in
                AnimationGraphTransitionGraphLinkDefinition(id: link.id,
                                                            fromNodeID: link.fromNodeID,
                                                            fromSlotIndex: link.fromSlotIndex,
                                                            toNodeID: link.toNodeID,
                                                            toSlotIndex: link.toSlotIndex)
            }
            graphDefinition = AnimationGraphTransitionGraphDefinition(id: reference.transitionGraphID ?? UUID(),
                                                                      outputNodeID: graphAsset.outputNodeID,
                                                                      nodes: nodes,
                                                                      links: links)
        } else {
            graphDefinition = nil
        }
        guard let graphDefinition else { return nil }
        let nodeIndexByID = Dictionary(uniqueKeysWithValues: graphDefinition.nodes.enumerated().map { ($0.element.id, $0.offset) })
        let outputNodeID = graphDefinition.outputNodeID
            ?? graphDefinition.nodes.first(where: { normalizedTransitionGraphNodeType($0.type) == "transitionoutput" })?.id
        guard let outputNodeID,
              let outputNodeIndex = nodeIndexByID[outputNodeID] else { return nil }
        let orderedLinks = graphDefinition.links.sorted { lhs, rhs in
            if lhs.toNodeID == rhs.toNodeID {
                if lhs.toSlotIndex == rhs.toSlotIndex {
                    if lhs.fromSlotIndex == rhs.fromSlotIndex {
                        return lhs.fromNodeID.uuidString < rhs.fromNodeID.uuidString
                    }
                    return lhs.fromSlotIndex < rhs.fromSlotIndex
                }
                return lhs.toSlotIndex < rhs.toSlotIndex
            }
            return lhs.toNodeID.uuidString < rhs.toNodeID.uuidString
        }
        return TransitionGraphRuntimeInstance(transitionID: transitionID,
                                              nodes: graphDefinition.nodes,
                                              links: orderedLinks,
                                              outputNodeIndex: outputNodeIndex,
                                              nodeIndexByID: nodeIndexByID)
    }

    private func normalizedTransitionGraphNodeType(_ rawType: String) -> String {
        rawType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private func transitionGraphParameterName(for node: AnimationGraphTransitionGraphNodeDefinition) -> String? {
        let explicit = node.parameterName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !explicit.isEmpty { return explicit }
        let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private func evaluateTransitionGraphInput(nodeIndex: Int,
                                              slot: Int,
                                              context: inout TransitionGraphEvaluationContext) -> GraphRuntimeValue? {
        guard let sourceNodeIndex = transitionGraphIncomingSourceNodeIndex(toNodeIndex: nodeIndex,
                                                                           toSlotIndex: slot,
                                                                           runtime: context.runtime),
              sourceNodeIndex >= 0,
              sourceNodeIndex < context.runtime.nodes.count else {
            return nil
        }
        return evaluateTransitionGraphNodeValue(nodeIndex: sourceNodeIndex, context: &context)
    }

    private func transitionGraphIncomingSourceNodeIndex(toNodeIndex: Int,
                                                        toSlotIndex: Int,
                                                        runtime: TransitionGraphRuntimeInstance) -> Int? {
        let destinationNodeID = runtime.nodes[toNodeIndex].id
        let sourceLink = runtime.links.first { link in
            link.toNodeID == destinationNodeID && link.toSlotIndex == toSlotIndex
        }
        guard let sourceLink else { return nil }
        return runtime.nodeIndexByID[sourceLink.fromNodeID]
    }

    private func evaluateTransitionGraphNodeValue(nodeIndex: Int,
                                                  context: inout TransitionGraphEvaluationContext) -> GraphRuntimeValue? {
        guard nodeIndex >= 0, nodeIndex < context.runtime.nodes.count else { return nil }
        let node = context.runtime.nodes[nodeIndex]
        if let cached = context.valueContext.valuesByNodeID[node.id] {
            return cached
        }
        guard beginGraphNodeEvaluation(nodeID: node.id, valueContext: &context.valueContext) else {
            return nil
        }
        defer { endGraphNodeEvaluation(nodeID: node.id, valueContext: &context.valueContext) }
        let nodeType = normalizedTransitionGraphNodeType(node.type)
        let result: GraphRuntimeValue?
        switch nodeType {
        case "floatconstant":
            result = .float(node.floatValue ?? 0.0)
        case "boolconstant":
            result = .bool(node.boolValue ?? false)
        case "comparefloatgreater":
            let lhs = evaluateTransitionGraphInput(nodeIndex: nodeIndex, slot: 0, context: &context).map(coerceScalarToFloat) ?? 0.0
            let rhs = evaluateTransitionGraphInput(nodeIndex: nodeIndex, slot: 1, context: &context).map(coerceScalarToFloat) ?? 0.0
            result = .bool(lhs > rhs)
        case "comparefloatless":
            let lhs = evaluateTransitionGraphInput(nodeIndex: nodeIndex, slot: 0, context: &context).map(coerceScalarToFloat) ?? 0.0
            let rhs = evaluateTransitionGraphInput(nodeIndex: nodeIndex, slot: 1, context: &context).map(coerceScalarToFloat) ?? 0.0
            result = .bool(lhs < rhs)
        case "comparefloatequal":
            let lhs = evaluateTransitionGraphInput(nodeIndex: nodeIndex, slot: 0, context: &context).map(coerceScalarToFloat) ?? 0.0
            let rhs = evaluateTransitionGraphInput(nodeIndex: nodeIndex, slot: 1, context: &context).map(coerceScalarToFloat) ?? 0.0
            result = .bool(abs(lhs - rhs) <= 1.0e-5)
        case "and":
            let lhs = evaluateTransitionGraphInput(nodeIndex: nodeIndex, slot: 0, context: &context).map(coerceScalarToBool) ?? false
            let rhs = evaluateTransitionGraphInput(nodeIndex: nodeIndex, slot: 1, context: &context).map(coerceScalarToBool) ?? false
            result = .bool(lhs && rhs)
        case "or":
            let lhs = evaluateTransitionGraphInput(nodeIndex: nodeIndex, slot: 0, context: &context).map(coerceScalarToBool) ?? false
            let rhs = evaluateTransitionGraphInput(nodeIndex: nodeIndex, slot: 1, context: &context).map(coerceScalarToBool) ?? false
            result = .bool(lhs || rhs)
        case "not":
            let input = evaluateTransitionGraphInput(nodeIndex: nodeIndex, slot: 0, context: &context).map(coerceScalarToBool) ?? false
            result = .bool(!input)
        case "parameterfloat",
             "parameterbool",
             "parameterint",
             "parametertrigger",
             "parameter":
            result = evaluateTransitionGraphParameterNodeValue(node: node,
                                                               nodeType: nodeType,
                                                               context: &context)
        case "localfloat",
             "localbool",
             "localint":
            result = evaluateTransitionGraphLocalNodeValue(node: node,
                                                           nodeType: nodeType,
                                                           context: &context)
        case "setlocalfloat",
             "setlocalbool",
             "setlocalint":
            result = evaluateTransitionGraphSetLocalNodeValue(nodeIndex: nodeIndex,
                                                              node: node,
                                                              nodeType: nodeType,
                                                              context: &context)
        default:
            result = nil
        }
        if let result {
            storeGraphNodeValue(result,
                                nodeID: node.id,
                                nodeType: node.type,
                                nodeTitle: node.title,
                                valueContext: &context.valueContext)
        }
        return result
    }

    private func evaluateTransitionGraphParameterNodeValue(node: AnimationGraphTransitionGraphNodeDefinition,
                                                           nodeType: String,
                                                           context: inout TransitionGraphEvaluationContext) -> GraphRuntimeValue? {
        guard let parameterName = transitionGraphParameterName(for: node),
              let parameterIndex = graphParameterIndex(name: parameterName, compiledGraph: context.compiledGraph),
              parameterIndex >= 0,
              parameterIndex < context.compiledGraph.parameters.count else { return nil }
        let parameter = context.compiledGraph.parameters[parameterIndex]
        switch nodeType {
        case "parameterfloat":
            guard parameter.type == .float else { return nil }
            return .float(context.runtimeState.floatParameterValues[parameterIndex])
        case "parameterbool":
            guard parameter.type == .bool else { return nil }
            return .bool(context.runtimeState.boolParameterValues[parameterIndex])
        case "parameterint":
            guard parameter.type == .int else { return nil }
            return .int(context.runtimeState.intParameterValues[parameterIndex])
        case "parametertrigger":
            guard parameter.type == .trigger else { return nil }
            let active = context.runtimeState.triggerParameterValues[parameterIndex]
                || context.runtimeState.triggerLatchedParameterIndices.contains(parameterIndex)
            if active {
                context.triggerIndicesToConsume.insert(parameterIndex)
            }
            return .bool(active)
        case "parameter":
            switch parameter.type {
            case .float:
                return .float(context.runtimeState.floatParameterValues[parameterIndex])
            case .bool:
                return .bool(context.runtimeState.boolParameterValues[parameterIndex])
            case .int:
                return .int(context.runtimeState.intParameterValues[parameterIndex])
            case .trigger:
                let active = context.runtimeState.triggerParameterValues[parameterIndex]
                    || context.runtimeState.triggerLatchedParameterIndices.contains(parameterIndex)
                if active {
                    context.triggerIndicesToConsume.insert(parameterIndex)
                }
                return .bool(active)
            }
        default:
            return nil
        }
    }

    private func evaluateTransitionGraphLocalNodeValue(node: AnimationGraphTransitionGraphNodeDefinition,
                                                       nodeType: String,
                                                       context: inout TransitionGraphEvaluationContext) -> GraphRuntimeValue? {
        guard let localName = transitionGraphParameterName(for: node),
              let localIndex = localVariableIndex(name: localName, compiledGraph: context.compiledGraph),
              localIndex >= 0,
              localIndex < context.compiledGraph.localVariables.count else { return nil }
        let local = context.compiledGraph.localVariables[localIndex]
        switch nodeType {
        case "localfloat":
            guard local.type == .float else { return nil }
            return .float(context.runtimeState.floatLocalVariableValues[localIndex])
        case "localbool":
            guard local.type == .bool else { return nil }
            return .bool(context.runtimeState.boolLocalVariableValues[localIndex])
        case "localint":
            guard local.type == .int else { return nil }
            return .int(context.runtimeState.intLocalVariableValues[localIndex])
        default:
            return nil
        }
    }

    private func evaluateTransitionGraphSetLocalNodeValue(nodeIndex: Int,
                                                          node: AnimationGraphTransitionGraphNodeDefinition,
                                                          nodeType: String,
                                                          context: inout TransitionGraphEvaluationContext) -> GraphRuntimeValue? {
        guard let localName = transitionGraphParameterName(for: node),
              let localIndex = localVariableIndex(name: localName, compiledGraph: context.compiledGraph),
              localIndex >= 0,
              localIndex < context.compiledGraph.localVariables.count else { return nil }
        let local = context.compiledGraph.localVariables[localIndex]
        let expectedType: AnimationGraphLocalVariableType
        switch nodeType {
        case "setlocalfloat":
            expectedType = .float
        case "setlocalbool":
            expectedType = .bool
        case "setlocalint":
            expectedType = .int
        default:
            return nil
        }
        guard local.type == expectedType else { return nil }
        let incomingValue = evaluateTransitionGraphInput(nodeIndex: nodeIndex, slot: 0, context: &context) ?? {
            switch expectedType {
            case .float:
                return .float(context.runtimeState.floatLocalVariableValues[localIndex])
            case .bool:
                return .bool(context.runtimeState.boolLocalVariableValues[localIndex])
            case .int:
                return .int(context.runtimeState.intLocalVariableValues[localIndex])
            }
        }()
        switch expectedType {
        case .float:
            let value = coerceScalarToFloat(incomingValue)
            context.runtimeState.setLocalFloat(index: localIndex, value: value)
            return .float(value)
        case .bool:
            let value = coerceScalarToBool(incomingValue)
            context.runtimeState.setLocalBool(index: localIndex, value: value)
            return .bool(value)
        case .int:
            let value = coerceScalarToInt(incomingValue)
            context.runtimeState.setLocalInt(index: localIndex, value: value)
            return .int(value)
        }
    }

    private func transitionConditionsPass(_ conditions: [AnimationGraphConditionDefinition],
                                          context: inout GraphEvaluationContext,
                                          triggerIndicesToConsume: inout Set<Int>) -> Bool {
        for condition in conditions {
            if !transitionConditionPasses(condition,
                                          context: &context,
                                          triggerIndicesToConsume: &triggerIndicesToConsume) {
                return false
            }
        }
        return true
    }

    private func transitionConditionPasses(_ condition: AnimationGraphConditionDefinition,
                                           context: inout GraphEvaluationContext,
                                           triggerIndicesToConsume: inout Set<Int>) -> Bool {
        let op = normalizedConditionOperator(condition.op)
        guard let parameterIndex = graphParameterIndex(name: condition.parameterName,
                                                       compiledGraph: context.compiledGraph),
              parameterIndex >= 0,
              parameterIndex < context.runtimeState.floatParameterValues.count else { return false }
        let parameterType = context.compiledGraph.parameters[parameterIndex].type

        let defaultFloat = condition.floatValue ?? 0.0
        let defaultInt = condition.intValue ?? 0
        let defaultBool = condition.boolValue ?? true

        switch parameterType {
        case .float:
            let effectiveOp = op.isEmpty ? ">" : op
            let value = context.runtimeState.floatParameterValues[parameterIndex]
            switch effectiveOp {
            case ">", "gt":
                return value > defaultFloat
            case ">=", "gte", "ge":
                return value >= defaultFloat
            case "<", "lt":
                return value < defaultFloat
            case "<=", "lte", "le":
                return value <= defaultFloat
            case "!=", "neq", "not":
                return abs(value - defaultFloat) > 1.0e-5
            default:
                return abs(value - defaultFloat) <= 1.0e-5
            }
        case .int:
            let effectiveOp = op.isEmpty ? ">" : op
            let value = context.runtimeState.intParameterValues[parameterIndex]
            switch effectiveOp {
            case "!=", "neq", "not":
                return value != defaultInt
            case ">", "gt":
                return value > defaultInt
            case ">=", "gte", "ge":
                return value >= defaultInt
            case "<", "lt":
                return value < defaultInt
            case "<=", "lte", "le":
                return value <= defaultInt
            default:
                return value == defaultInt
            }
        case .bool:
            let effectiveOp = op.isEmpty ? "istrue" : op
            let value = context.runtimeState.boolParameterValues[parameterIndex]
            switch effectiveOp {
            case "!=", "neq", "not":
                return value != defaultBool
            case "istrue", "true":
                return value
            case "isfalse", "false":
                return !value
            default:
                return value == defaultBool
            }
        case .trigger:
            let effectiveOp = op.isEmpty ? "istrue" : op
            let value = context.runtimeState.triggerParameterValues[parameterIndex]
            let active = value || context.runtimeState.triggerLatchedParameterIndices.contains(parameterIndex)
            let passes: Bool
            switch effectiveOp {
            case "isfalse", "false":
                passes = !active
            case "!=", "neq", "not":
                passes = active != defaultBool
            default:
                passes = active == defaultBool
            }
            if passes && active {
                triggerIndicesToConsume.insert(parameterIndex)
            }
            return passes
        }
    }

    private func normalizedConditionOperator(_ rawOperator: String) -> String {
        let normalized = rawOperator
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch normalized {
        case ">", "gt", "greater", "greaterthan":
            return ">"
        case ">=", "gte", "ge", "greaterorequal", "greaterthanorequal":
            return ">="
        case "<", "lt", "less", "lessthan":
            return "<"
        case "<=", "lte", "le", "lessorequal", "lessthanorequal":
            return "<="
        case "==", "=", "eq", "equal", "equals":
            return "=="
        case "!=", "<>", "neq", "notequal", "not":
            return "!="
        case "true", "istrue":
            return "istrue"
        case "false", "isfalse":
            return "isfalse"
        default:
            return normalized
        }
    }

    private func isLocomotionBlendNode(_ node: CompiledAnimationGraph.Node) -> Bool {
        let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return title.contains("locomotion")
    }

    private func constrainCardinalStrafeRootMotion(_ delta: RootMotionDelta,
                                                   inputX: Float) -> RootMotionDelta {
        let sign: Float = inputX < 0.0 ? -1.0 : 1.0
        let planarMagnitude = simd_length(SIMD2<Float>(delta.deltaPos.x, delta.deltaPos.z))
        let constrained = SIMD3<Float>(sign * planarMagnitude, 0.0, 0.0)
        return RootMotionDelta(deltaPos: constrained, deltaRot: delta.deltaRot)
    }

    private func maybeLogLocomotionBlendSelection(node: CompiledAnimationGraph.Node,
                                                  originalPoint: SIMD2<Float>,
                                                  adjustedPoint: SIMD2<Float>,
                                                  samples: [String],
                                                  blendedDelta: RootMotionDelta,
                                                  context: GraphEvaluationContext,
                                                  cardinalStrafeIntent: Bool) {
#if DEBUG
        guard isLocomotionBlendNode(node) else { return }
        let significantAdjustment = simd_length(originalPoint - adjustedPoint) > 0.1
        guard cardinalStrafeIntent || significantAdjustment else { return }
        let sector = cardinalStrafeIntent ? (originalPoint.x < 0.0 ? "left" : "right") : "adjusted"
        let key = "\(context.entityID.uuidString)|\(context.graphHandle.rawValue.uuidString)|\(node.id.uuidString)|\(sector)"
        guard !loggedBlend2DDiagnosticsKeys.contains(key) else { return }
        loggedBlend2DDiagnosticsKeys.insert(key)
        let sampleSummary = samples.isEmpty ? "<none>" : samples.joined(separator: ", ")
        EngineLoggerContext.log(
            "Animator locomotion blend selection entity=\(context.entityID.uuidString) node=\(node.title) inputPoint=\(originalPoint) adjustedPoint=\(adjustedPoint) samples=\(sampleSummary) blendedLocalRootDelta=\(blendedDelta.deltaPos)",
            level: .debug,
            category: .scene
        )
#endif
    }

    private func maybeLogBlend2DDiagnostics(node: CompiledAnimationGraph.Node,
                                            point: SIMD2<Float>,
                                            originalPoint: SIMD2<Float>,
                                            weights: [String],
                                            blendedDelta: RootMotionDelta,
                                            context: GraphEvaluationContext) {
#if DEBUG
        guard isLocomotionBlendNode(node) else { return }
        let strafeIntent = abs(point.x) >= 0.85 && abs(point.y) <= 0.2
        guard strafeIntent else { return }
        let forwardDominant = abs(blendedDelta.deltaPos.z) > (abs(blendedDelta.deltaPos.x) * 1.4 + 0.02)
        guard forwardDominant else { return }
        let key = "\(context.entityID.uuidString)|\(context.graphHandle.rawValue.uuidString)|\(node.id.uuidString)|strafeForwardBias"
        guard !loggedBlend2DDiagnosticsKeys.contains(key) else { return }
        loggedBlend2DDiagnosticsKeys.insert(key)
        let sampleSummary = weights.isEmpty ? "<none>" : weights.joined(separator: ", ")
        EngineLoggerContext.log(
            "Animator locomotion blend strafe-forward-bias entity=\(context.entityID.uuidString) node=\(node.title) inputPoint=\(originalPoint) adjustedPoint=\(point) blendedLocalRootDelta=\(blendedDelta.deltaPos) samples=\(sampleSummary)",
            level: .warning,
            category: .scene
        )
#endif
    }

    private func graphParameterIndex(name: String,
                                     compiledGraph: CompiledAnimationGraph) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return compiledGraph.parameterIndexByName[trimmed]
    }

    private func incomingSourceNodeIndex(toNodeIndex: Int,
                                         toSlotIndex: Int,
                                         compiledGraph: CompiledAnimationGraph) -> Int? {
        let candidates = compiledGraph.links
            .filter { $0.toNodeIndex == toNodeIndex && $0.toSlotIndex == toSlotIndex }
            .sorted { lhs, rhs in
                if lhs.fromSlotIndex == rhs.fromSlotIndex {
                    return lhs.fromNodeIndex < rhs.fromNodeIndex
                }
                return lhs.fromSlotIndex < rhs.fromSlotIndex
            }
        return candidates.first?.fromNodeIndex
    }

    private func parameterName(for node: CompiledAnimationGraph.Node) -> String? {
        let explicit = node.parameterName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !explicit.isEmpty { return explicit }
        let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private func localVariableIndex(name: String,
                                    compiledGraph: CompiledAnimationGraph) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return compiledGraph.localVariableIndexByName[trimmed]
    }

    private func evaluateScalarNodeValue(nodeIndex: Int,
                                         context: inout GraphEvaluationContext) -> GraphRuntimeValue? {
        guard let value = evaluateCompiledNodeValue(nodeIndex: nodeIndex, context: &context) else { return nil }
        return scalarRuntimeValue(value)
    }

    private func evaluateParameterNodeValue(node: CompiledAnimationGraph.Node,
                                            context: inout GraphEvaluationContext) -> GraphRuntimeValue? {
        guard let parameterName = parameterName(for: node),
              let parameterIndex = graphParameterIndex(name: parameterName, compiledGraph: context.compiledGraph),
              parameterIndex >= 0,
              parameterIndex < context.compiledGraph.parameters.count else { return nil }
        let parameter = context.compiledGraph.parameters[parameterIndex]
        switch node.type {
        case .parameterFloat:
            guard parameter.type == .float else { return nil }
            return .float(context.runtimeState.floatParameterValues[parameterIndex])
        case .parameterBool:
            guard parameter.type == .bool else { return nil }
            return .bool(context.runtimeState.boolParameterValues[parameterIndex])
        case .parameterInt:
            guard parameter.type == .int else { return nil }
            return .int(context.runtimeState.intParameterValues[parameterIndex])
        case .parameterTrigger:
            guard parameter.type == .trigger else { return nil }
            let active = context.runtimeState.triggerParameterValues[parameterIndex]
                || context.runtimeState.triggerLatchedParameterIndices.contains(parameterIndex)
            return .bool(active)
        case .parameter:
            switch parameter.type {
            case .float:
                return .float(context.runtimeState.floatParameterValues[parameterIndex])
            case .bool:
                return .bool(context.runtimeState.boolParameterValues[parameterIndex])
            case .int:
                return .int(context.runtimeState.intParameterValues[parameterIndex])
            case .trigger:
                let active = context.runtimeState.triggerParameterValues[parameterIndex]
                    || context.runtimeState.triggerLatchedParameterIndices.contains(parameterIndex)
                return .bool(active)
            }
        default:
            return nil
        }
    }

    private func evaluateLocalVariableNodeValue(node: CompiledAnimationGraph.Node,
                                                expectedType: AnimationGraphLocalVariableType,
                                                context: inout GraphEvaluationContext) -> GraphRuntimeValue? {
        guard let localName = parameterName(for: node),
              let localIndex = localVariableIndex(name: localName, compiledGraph: context.compiledGraph),
              localIndex >= 0,
              localIndex < context.compiledGraph.localVariables.count else { return nil }
        let local = context.compiledGraph.localVariables[localIndex]
        guard local.type == expectedType else { return nil }
        switch expectedType {
        case .float:
            return .float(context.runtimeState.floatLocalVariableValues[localIndex])
        case .bool:
            return .bool(context.runtimeState.boolLocalVariableValues[localIndex])
        case .int:
            return .int(context.runtimeState.intLocalVariableValues[localIndex])
        }
    }

    private func coerceScalarToFloat(_ value: GraphRuntimeValue) -> Float {
        switch value {
        case let .float(v):
            return v
        case let .bool(v):
            return v ? 1.0 : 0.0
        case let .int(v):
            return Float(v)
        case .pose:
            return 0.0
        }
    }

    private func coerceScalarToBool(_ value: GraphRuntimeValue) -> Bool {
        switch value {
        case let .bool(v):
            return v
        case let .float(v):
            return abs(v) > 1.0e-5
        case let .int(v):
            return v != 0
        case .pose:
            return false
        }
    }

    private func coerceScalarToInt(_ value: GraphRuntimeValue) -> Int {
        switch value {
        case let .int(v):
            return v
        case let .float(v):
            return Int(v.rounded())
        case let .bool(v):
            return v ? 1 : 0
        case .pose:
            return 0
        }
    }

    private func evaluateSetLocalNodeValue(nodeIndex: Int,
                                           node: CompiledAnimationGraph.Node,
                                           expectedType: AnimationGraphLocalVariableType,
                                           context: inout GraphEvaluationContext) -> GraphRuntimeValue? {
        guard let localName = parameterName(for: node),
              let localIndex = localVariableIndex(name: localName, compiledGraph: context.compiledGraph),
              localIndex >= 0,
              localIndex < context.compiledGraph.localVariables.count else { return nil }
        let local = context.compiledGraph.localVariables[localIndex]
        guard local.type == expectedType else { return nil }
        let incomingValue: GraphRuntimeValue = {
            guard let sourceNodeIndex = incomingSourceNodeIndex(toNodeIndex: nodeIndex,
                                                                toSlotIndex: 0,
                                                                compiledGraph: context.compiledGraph),
                  let linked = evaluateScalarNodeValue(nodeIndex: sourceNodeIndex, context: &context) else {
                switch expectedType {
                case .float:
                    return .float(context.runtimeState.floatLocalVariableValues[localIndex])
                case .bool:
                    return .bool(context.runtimeState.boolLocalVariableValues[localIndex])
                case .int:
                    return .int(context.runtimeState.intLocalVariableValues[localIndex])
                }
            }
            return linked
        }()
        switch expectedType {
        case .float:
            let value = coerceScalarToFloat(incomingValue)
            context.runtimeState.setLocalFloat(index: localIndex, value: value)
            return .float(value)
        case .bool:
            let value = coerceScalarToBool(incomingValue)
            context.runtimeState.setLocalBool(index: localIndex, value: value)
            return .bool(value)
        case .int:
            let value = coerceScalarToInt(incomingValue)
            context.runtimeState.setLocalInt(index: localIndex, value: value)
            return .int(value)
        }
    }

    private func resolvedBlendInputFloat(nodeIndex: Int,
                                         inputSlot: Int,
                                         fallbackParameterName: String,
                                         context: inout GraphEvaluationContext) -> Float {
        if let sourceNodeIndex = incomingSourceNodeIndex(toNodeIndex: nodeIndex,
                                                         toSlotIndex: inputSlot,
                                                         compiledGraph: context.compiledGraph),
           let linkedValue = evaluateScalarNodeValue(nodeIndex: sourceNodeIndex, context: &context) {
            return coerceScalarToFloat(linkedValue)
        }
        return graphParameterFloat(name: fallbackParameterName,
                                   compiledGraph: context.compiledGraph,
                                   runtimeState: context.runtimeState)
    }

    private func graphParameterFloat(name: String,
                                     compiledGraph: CompiledAnimationGraph,
                                     runtimeState: AnimationGraphRuntimeInstanceState) -> Float {
        guard let index = graphParameterIndex(name: name, compiledGraph: compiledGraph),
              index >= 0,
              index < runtimeState.floatParameterValues.count else { return 0.0 }
        switch compiledGraph.parameters[index].type {
        case .float:
            return runtimeState.floatParameterValues[index]
        case .int:
            return Float(runtimeState.intParameterValues[index])
        case .bool:
            return runtimeState.boolParameterValues[index] ? 1.0 : 0.0
        case .trigger:
            let value = runtimeState.triggerParameterValues[index] || runtimeState.triggerLatchedParameterIndices.contains(index)
            return value ? 1.0 : 0.0
        }
    }

    // Ozz is the primary runtime backend for local-space pose blending.
    // Legacy math is kept as a narrow fallback when Ozz runtime assets are unavailable.
    private func blendLocalPoses(_ a: [TransformComponent],
                                 _ b: [TransformComponent],
                                 weight: Float,
                                 skeleton: SkeletonAsset,
                                 assets: AssetManager? = nil) -> [TransformComponent] {
        let count = min(a.count, b.count)
        guard count > 0 else { return [] }
        let t = simd_clamp(weight, 0.0, 1.0)
        if let assets,
           let skeletonRuntime = assets.ozzSkeletonRuntime(handle: skeleton.handle),
           let blendingContext = skeletonRuntime.blendingContext(maxLayers: 2),
           let blended = OzzRuntimeBridge.blendLocalPoses(skeletonRuntime: skeletonRuntime,
                                                          blendingContext: blendingContext,
                                                          localPoses: [a, b],
                                                          weights: [1.0 - t, t],
                                                          expectedJointCount: count),
           blended.count == count {
            return blended
        }

        return blendLocalPosesFallback(a, b, weight: t, count: count)
    }

    private func blendLocalPoses(localPoses: [[TransformComponent]],
                                 weights: [Float],
                                 skeleton: SkeletonAsset,
                                 assets: AssetManager? = nil) -> [TransformComponent] {
        guard !localPoses.isEmpty, localPoses.count == weights.count else { return [] }
        let jointCount = localPoses.map(\.count).min() ?? 0
        guard jointCount > 0 else { return [] }
        if let assets,
           let skeletonRuntime = assets.ozzSkeletonRuntime(handle: skeleton.handle),
           let blendingContext = skeletonRuntime.blendingContext(maxLayers: localPoses.count),
           let blended = OzzRuntimeBridge.blendLocalPoses(skeletonRuntime: skeletonRuntime,
                                                          blendingContext: blendingContext,
                                                          localPoses: localPoses,
                                                          weights: weights,
                                                          expectedJointCount: jointCount),
           blended.count == jointCount {
            return blended
        }

        return blendLocalPosesFallback(localPoses: localPoses, weights: weights, jointCount: jointCount)
    }

    // Ozz BlendingJob is the primary path for root-motion delta blending.
    // Legacy blend math remains only as a runtime-availability fallback.
    private func blendRootMotionDeltas(_ a: RootMotionDelta,
                                       _ b: RootMotionDelta,
                                       weight: Float) -> RootMotionDelta {
        let t = simd_clamp(weight, 0.0, 1.0)
        if let ozzBlended = OzzRuntimeBridge.blendRootMotionDeltas([a, b], weights: [1.0 - t, t]) {
            return ozzBlended
        }
        return blendRootMotionDeltasFallback(a, b, weight: t)
    }

    private func blendRootMotionDeltas(_ deltas: [RootMotionDelta],
                                       weights: [Float]) -> RootMotionDelta {
        guard !deltas.isEmpty, deltas.count == weights.count else { return .zero }
        let sum = max(weights.reduce(0, +), 1.0e-6)
        var normalized = weights.map { max(0.0, $0) / sum }
        if normalized.allSatisfy({ $0 <= 1.0e-6 }) {
            normalized = Array(repeating: 1.0 / Float(deltas.count), count: deltas.count)
        }
        if let ozzBlended = OzzRuntimeBridge.blendRootMotionDeltas(deltas, weights: normalized) {
            return ozzBlended
        }
        return blendRootMotionDeltasFallback(deltas, weights: normalized)
    }

    private func resolveRootJointSelection(skeleton: SkeletonAsset,
                                           skinnedMesh: SkinnedMeshComponent?) -> (index: Int, name: String) {
        func jointDepth(_ index: Int) -> Int {
            guard index >= 0, index < skeleton.joints.count else { return Int.max / 2 }
            var depth = 0
            var cursor = index
            var visited: Set<Int> = []
            while cursor >= 0, cursor < skeleton.joints.count, !visited.contains(cursor) {
                visited.insert(cursor)
                let parent = skeleton.joints[cursor].parentIndex
                if parent < 0 { break }
                depth += 1
                cursor = parent
            }
            return depth
        }

        func scoreName(_ name: String) -> Int {
            let lowered = name.lowercased()
            if lowered.contains("translation") { return 4 }
            if lowered.contains("root") { return 3 }
            if lowered.contains("hips") || lowered.contains("pelvis") { return 2 }
            return 0
        }

        if let configured = skinnedMesh?.rootBoneName.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty,
           let index = skeleton.joints.firstIndex(where: { $0.name == configured }) {
            return (index, configured)
        }
        if let bestIndex = skeleton.joints.indices.max(by: { lhs, rhs in
            let lhsScore = scoreName(skeleton.joints[lhs].name)
            let rhsScore = scoreName(skeleton.joints[rhs].name)
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            let lhsDepth = jointDepth(lhs)
            let rhsDepth = jointDepth(rhs)
            if lhsDepth != rhsDepth { return lhsDepth > rhsDepth }
            return lhs > rhs
        }), scoreName(skeleton.joints[bestIndex].name) > 0 {
            return (bestIndex, skeleton.joints[bestIndex].name)
        }
        if let rootIndex = skeleton.joints.firstIndex(where: { $0.parentIndex < 0 }) {
            return (rootIndex, skeleton.joints[rootIndex].name)
        }
        if let first = skeleton.joints.first {
            return (0, first.name)
        }
        return (0, "")
    }

    // Root motion extraction remains graph-controlled, but extraction math is Ozz-backed.
    // Legacy extraction is retained only if Ozz runtime objects are unavailable.
    private func sampleClipRootMotionDelta(skeleton: SkeletonAsset,
                                           clip: AnimationClipAsset,
                                           rootJointIndex: Int,
                                           trackerEntityID: UUID? = nil,
                                           trackerKey: String? = nil,
                                           translationJointIndexOverride: Int? = nil,
                                           rotationJointIndexOverride: Int? = nil,
                                           previousTime: Float,
                                           currentTime: Float,
                                           isLooping: Bool,
                                           sourceStateName: String? = nil,
                                           assets: AssetManager? = nil) -> RootMotionDelta {
        let duration = max(clip.durationSeconds, 0.0)
        let channels = resolveRootMotionChannels(skeleton: skeleton,
                                                 clip: clip,
                                                 preferredRootJointIndex: rootJointIndex,
                                                 translationJointIndexOverride: translationJointIndexOverride,
                                                 rotationJointIndexOverride: rotationJointIndexOverride)
        let curr = resolveClipSampleTime(nodeTime: currentTime, duration: duration, isLooping: isLooping)
        let currentRoot = sampleRootMotionTransform(clip: clip,
                                                    channels: channels,
                                                    time: curr)

        guard let trackerEntityID, let trackerKey else {
            let prev = resolveClipSampleTime(nodeTime: previousTime, duration: duration, isLooping: isLooping)
            return integrateRootMotionWithoutTracker(clip: clip,
                                                     channels: channels,
                                                     previousSampleTime: prev,
                                                     currentSampleTime: curr,
                                                     clipDuration: duration,
                                                     isLooping: isLooping).delta
        }

        var trackers = rootMotionTrackersByEntity[trackerEntityID] ?? [:]
        let currentClipHandle = clip.handle
        guard duration > 1.0e-6 else {
            trackers[trackerKey] = RootMotionTracker(previousClipHandle: currentClipHandle,
                                                     previousSampleTime: curr,
                                                     previousClipDuration: duration,
                                                     previousRootTransform: currentRoot)
            rootMotionTrackersByEntity[trackerEntityID] = trackers
            return .zero
        }

        guard let previousTracker = trackers[trackerKey] else {
            trackers[trackerKey] = RootMotionTracker(previousClipHandle: currentClipHandle,
                                                     previousSampleTime: curr,
                                                     previousClipDuration: duration,
                                                     previousRootTransform: currentRoot)
            rootMotionTrackersByEntity[trackerEntityID] = trackers
            return .zero
        }

        let clipChanged = previousTracker.previousClipHandle != currentClipHandle
            || abs(previousTracker.previousClipDuration - duration) > 1.0e-4
        if clipChanged {
            trackers[trackerKey] = RootMotionTracker(previousClipHandle: currentClipHandle,
                                                     previousSampleTime: curr,
                                                     previousClipDuration: duration,
                                                     previousRootTransform: currentRoot)
            rootMotionTrackersByEntity[trackerEntityID] = trackers
            return .zero
        }

        let previousSampleTime = previousTracker.previousSampleTime
        let largeJumpThreshold = max(duration * 0.5, 0.25)
        let loopWrapCandidate = isLooping && curr < previousSampleTime
        let unwrappedForwardStep = (curr + duration) - previousSampleTime
        // Treat looping wraps as valid forward progression. Large absolute jumps are only
        // considered invalid when there is no wrap candidate.
        let isExpectedLoopWrapStep = loopWrapCandidate && unwrappedForwardStep >= 0.0
        if abs(curr - previousSampleTime) > largeJumpThreshold && !isExpectedLoopWrapStep {
            trackers[trackerKey] = RootMotionTracker(previousClipHandle: currentClipHandle,
                                                     previousSampleTime: curr,
                                                     previousClipDuration: duration,
                                                     previousRootTransform: currentRoot)
            rootMotionTrackersByEntity[trackerEntityID] = trackers
            return .zero
        }

        let integrated = integrateRootMotionWithoutTracker(clip: clip,
                                                            channels: channels,
                                                            previousSampleTime: previousSampleTime,
                                                            currentSampleTime: curr,
                                                            clipDuration: duration,
                                                            isLooping: isLooping)
        var delta = integrated.delta
        let planarMagnitude = simd_length(SIMD2<Float>(delta.deltaPos.x, delta.deltaPos.z))
        if planarMagnitude > 2.0 {
            delta = .zero
            trackers[trackerKey] = RootMotionTracker(previousClipHandle: currentClipHandle,
                                                     previousSampleTime: curr,
                                                     previousClipDuration: duration,
                                                     previousRootTransform: currentRoot)
            rootMotionTrackersByEntity[trackerEntityID] = trackers
            return delta
        }

        trackers[trackerKey] = RootMotionTracker(previousClipHandle: currentClipHandle,
                                                 previousSampleTime: curr,
                                                 previousClipDuration: duration,
                                                 previousRootTransform: currentRoot)
        rootMotionTrackersByEntity[trackerEntityID] = trackers

        let detailKey = trackerKey
        var detailCounters = rootMotionExtractionDebugCountersByEntity[trackerEntityID] ?? [:]
        let detailCount = (detailCounters[detailKey] ?? 0) + 1
        detailCounters[detailKey] = detailCount
        rootMotionExtractionDebugCountersByEntity[trackerEntityID] = detailCounters

        let translationJointName = skeleton.joints.indices.contains(channels.translationJointIndex)
            ? skeleton.joints[channels.translationJointIndex].name
            : "<invalid:\(channels.translationJointIndex)>"
        let rotationJointName = skeleton.joints.indices.contains(channels.rotationJointIndex)
            ? skeleton.joints[channels.rotationJointIndex].name
            : "<invalid:\(channels.rotationJointIndex)>"
        let stateName: String = {
            guard let sourceStateName else { return "<none>" }
            let trimmed = sourceStateName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "<none>" : trimmed
        }()
        let translationDeltaMagnitude = simd_length(delta.deltaPos)
        let deltaRotationQuat = simd_quatf(vector: TransformMath.normalizedQuaternion(delta.deltaRot))
        let rotationDeltaRadians = 2.0 * acos(simd_clamp(abs(deltaRotationQuat.real), 0.0, 1.0))
        let shouldEmitAuditLog: Bool = {
            let debugCount = (rootMotionDebugCounterByEntity[trackerEntityID] ?? 0) + 1
            rootMotionDebugCounterByEntity[trackerEntityID] = debugCount
            if animationGraphDebugLoggingEnabled {
                return debugCount % 30 == 0
            }
            let nearZeroDelta = translationDeltaMagnitude <= 1.0e-5 && planarMagnitude <= 1.0e-5
            let cadence = nearZeroDelta ? 45 : 180
            return detailCount % cadence == 0
        }()
        if shouldEmitAuditLog {
            EngineLoggerContext.log(
                """
                AnimRootMotion sample entity=\(trackerEntityID.uuidString) state=\(stateName) clip=\(clip.name) clipID=\(currentClipHandle.rawValue.uuidString) sourceTranslationJoint=\(translationJointName)[\(channels.translationJointIndex)] sourceRotationJoint=\(rotationJointName)[\(channels.rotationJointIndex)] previousTime=\(previousSampleTime) currentTime=\(curr) wrapped=\(integrated.loopDetected) previousTransform(pos=\(previousTracker.previousRootTransform.position),rot=\(previousTracker.previousRootTransform.rotation)) currentTransform(pos=\(currentRoot.position),rot=\(currentRoot.rotation)) deltaTranslationMagnitude=\(translationDeltaMagnitude) deltaRotationRadians=\(rotationDeltaRadians) deltaPlanarMagnitude=\(planarMagnitude) sampleCount=\(detailCount)
                """,
                level: .debug,
                category: .scene
            )
        }
        return delta
    }

    private func integrateRootMotionWithoutTracker(clip: AnimationClipAsset,
                                                   channels: (translationJointIndex: Int, rotationJointIndex: Int),
                                                   previousSampleTime: Float,
                                                   currentSampleTime: Float,
                                                   clipDuration: Float,
                                                   isLooping: Bool) -> (delta: RootMotionDelta, loopDetected: Bool) {
        let previousRootTransform = sampleRootMotionTransform(clip: clip,
                                                              channels: channels,
                                                              time: previousSampleTime)
        let currentRootTransform = sampleRootMotionTransform(clip: clip,
                                                             channels: channels,
                                                             time: currentSampleTime)
        if !isLooping || currentSampleTime >= previousSampleTime {
            let deltaPos = currentRootTransform.position - previousRootTransform.position
            let deltaRot = simd_normalize(simd_mul(simd_quatf(vector: currentRootTransform.rotation),
                                                   simd_inverse(simd_quatf(vector: previousRootTransform.rotation)))).vector
            return (RootMotionDelta(deltaPos: deltaPos, deltaRot: deltaRot), false)
        }

        let rootAtEnd = sampleRootMotionTransform(clip: clip, channels: channels, time: clipDuration)
        let rootAtStart = sampleRootMotionTransform(clip: clip, channels: channels, time: 0.0)
        let deltaPos = (rootAtEnd.position - previousRootTransform.position)
            + (currentRootTransform.position - rootAtStart.position)
        let preWrapRotation = simd_normalize(simd_mul(simd_quatf(vector: rootAtEnd.rotation),
                                                      simd_inverse(simd_quatf(vector: previousRootTransform.rotation))))
        let postWrapRotation = simd_normalize(simd_mul(simd_quatf(vector: currentRootTransform.rotation),
                                                       simd_inverse(simd_quatf(vector: rootAtStart.rotation))))
        let deltaRot = simd_normalize(simd_mul(postWrapRotation, preWrapRotation)).vector
        return (RootMotionDelta(deltaPos: deltaPos, deltaRot: deltaRot), true)
    }

    private func sampleRootMotionTransform(clip: AnimationClipAsset,
                                           channels: (translationJointIndex: Int, rotationJointIndex: Int),
                                           time: Float) -> TransformComponent {
        let translationTrack = clip.tracks.first(where: { $0.jointIndex == channels.translationJointIndex })
        let rotationTrack = clip.tracks.first(where: { $0.jointIndex == channels.rotationJointIndex })
        let position = translationTrack.flatMap { sampleTranslation($0.translations, time: time) } ?? .zero
        let rotation = rotationTrack.flatMap { sampleRotation($0.rotations, time: time) } ?? TransformMath.identityQuaternion
        return TransformComponent(position: position,
                                  rotation: TransformMath.normalizedQuaternion(rotation),
                                  scale: SIMD3<Float>(repeating: 1.0))
    }

    private func sampleRootMotionDeltaSingleSpan(skeleton: SkeletonAsset,
                                                 clip: AnimationClipAsset,
                                                 rootJointIndex: Int,
                                                 translationJointIndexOverride: Int? = nil,
                                                 rotationJointIndexOverride: Int? = nil,
                                                 fromTime: Float,
                                                 toTime: Float,
                                                 assets: AssetManager? = nil) -> RootMotionDelta {
        guard rootJointIndex >= 0, rootJointIndex < skeleton.joints.count else { return .zero }
        let channels = resolveRootMotionChannels(skeleton: skeleton,
                                                 clip: clip,
                                                 preferredRootJointIndex: rootJointIndex,
                                                 translationJointIndexOverride: translationJointIndexOverride,
                                                 rotationJointIndexOverride: rotationJointIndexOverride)
        let clipTrackDelta = sampleRootMotionDeltaFromClipTracks(clip: clip,
                                                                 channels: channels,
                                                                 fromTime: fromTime,
                                                                 toTime: toTime)
        if let assets,
           let skeletonRuntime = assets.ozzSkeletonRuntime(handle: skeleton.handle),
           let animationRuntime = assets.ozzAnimationRuntime(handle: clip.handle),
           let rootMotionRuntime = assets.ozzRootMotionRuntime(skeletonHandle: skeleton.handle, clipHandle: clip.handle),
           let ozzDelta = OzzRuntimeBridge.extractRootMotionDelta(skeletonRuntime: skeletonRuntime,
                                                                  animationRuntime: animationRuntime,
                                                                  rootMotionRuntime: rootMotionRuntime,
                                                                  translationJointIndex: channels.translationJointIndex,
                                                                  rotationJointIndex: channels.rotationJointIndex,
                                                                  previousTimeSeconds: fromTime,
                                                                  currentTimeSeconds: toTime) {
            if simd_length_squared(ozzDelta.deltaPos) <= 1.0e-10,
               simd_length_squared(clipTrackDelta.deltaPos) > 1.0e-8 {
                return RootMotionDelta(deltaPos: clipTrackDelta.deltaPos, deltaRot: ozzDelta.deltaRot)
            }
            return ozzDelta
        }
        let fallbackDelta = sampleRootMotionDeltaSingleSpanFallback(skeleton: skeleton,
                                                                    clip: clip,
                                                                    channels: channels,
                                                                    fromTime: fromTime,
                                                                    toTime: toTime,
                                                                    assets: assets)
        if simd_length_squared(fallbackDelta.deltaPos) <= 1.0e-10,
           simd_length_squared(clipTrackDelta.deltaPos) > 1.0e-8 {
            return RootMotionDelta(deltaPos: clipTrackDelta.deltaPos, deltaRot: fallbackDelta.deltaRot)
        }
        return fallbackDelta
    }

    private func consumeRootMotionTracks(in localPose: [TransformComponent],
                                         skeleton: SkeletonAsset,
                                         translationJointIndex: Int,
                                         rotationJointIndex: Int,
                                         consumeTranslation: Bool,
                                         consumeRotation: Bool) -> [TransformComponent] {
        guard consumeTranslation || consumeRotation else { return localPose }
        var consumed = localPose
        if consumeTranslation {
            guard translationJointIndex >= 0,
                  translationJointIndex < consumed.count,
                  translationJointIndex < skeleton.joints.count else { return localPose }
            let bindJoint = skeleton.joints[translationJointIndex]
            var translationJoint = consumed[translationJointIndex]
            translationJoint.position = bindJoint.bindLocalPosition
            consumed[translationJointIndex] = translationJoint
        }
        if consumeRotation {
            guard rotationJointIndex >= 0,
                  rotationJointIndex < consumed.count,
                  rotationJointIndex < skeleton.joints.count else { return localPose }
            let bindJoint = skeleton.joints[rotationJointIndex]
            var rotationJoint = consumed[rotationJointIndex]
            rotationJoint.rotation = bindJoint.bindLocalRotation
            consumed[rotationJointIndex] = rotationJoint
        }
        return consumed
    }

    private func resolveRootMotionChannels(skeleton: SkeletonAsset,
                                           clip: AnimationClipAsset,
                                           preferredRootJointIndex: Int,
                                           translationJointIndexOverride: Int? = nil,
                                           rotationJointIndexOverride: Int? = nil) -> (translationJointIndex: Int, rotationJointIndex: Int) {
        if let translationJointIndexOverride,
           let rotationJointIndexOverride,
           translationJointIndexOverride >= 0,
           translationJointIndexOverride < skeleton.joints.count,
           rotationJointIndexOverride >= 0,
           rotationJointIndexOverride < skeleton.joints.count {
            return (translationJointIndexOverride, rotationJointIndexOverride)
        }
        let translationJointIndex = resolveTranslationChannelJointIndex(skeleton: skeleton,
                                                                        clip: clip,
                                                                        preferredRootJointIndex: preferredRootJointIndex)
        let rotationJointIndex = resolveRotationChannelJointIndex(skeleton: skeleton,
                                                                  preferredRootJointIndex: preferredRootJointIndex,
                                                                  clip: clip)
        if let translationJointIndexOverride,
           translationJointIndexOverride >= 0,
           translationJointIndexOverride < skeleton.joints.count {
            return (translationJointIndexOverride, rotationJointIndex)
        }
        if let rotationJointIndexOverride,
           rotationJointIndexOverride >= 0,
           rotationJointIndexOverride < skeleton.joints.count {
            return (translationJointIndex, rotationJointIndexOverride)
        }
        return (translationJointIndex, rotationJointIndex)
    }

    private func resolveTranslationChannelJointIndex(skeleton: SkeletonAsset,
                                                     clip: AnimationClipAsset,
                                                     preferredRootJointIndex: Int) -> Int {
        let fallbackJoint = fallbackRootMotionJointIndex(skeleton: skeleton,
                                                         preferredRootJointIndex: preferredRootJointIndex)
        if hasMeaningfulTranslationTrack(clip: clip, jointIndex: fallbackJoint) {
            return fallbackJoint
        }
        if let authoredHips = deterministicLocomotionTranslationJointIndex(skeleton: skeleton,
                                                                           clip: clip,
                                                                           rootJointIndex: fallbackJoint) {
            return authoredHips
        }
        // Keep channel selection stable when clips are authored in-place.
        return fallbackJoint
    }

    private func resolveRotationChannelJointIndex(skeleton: SkeletonAsset,
                                                  preferredRootJointIndex: Int,
                                                  clip: AnimationClipAsset? = nil) -> Int {
        let fallbackJoint = fallbackRootMotionJointIndex(skeleton: skeleton,
                                                         preferredRootJointIndex: preferredRootJointIndex)
        if let clip {
            guard hasMeaningfulRotationTrack(clip: clip, jointIndex: fallbackJoint) else {
                // Keep channel selection stable when clips are authored in-place.
                return fallbackJoint
            }
        }
        return fallbackJoint
    }

    private func fallbackRootMotionJointIndex(skeleton: SkeletonAsset,
                                              preferredRootJointIndex: Int) -> Int {
        guard !skeleton.joints.isEmpty else { return max(preferredRootJointIndex, 0) }

        if preferredRootJointIndex >= 0,
           preferredRootJointIndex < skeleton.joints.count,
           isAutoRootMotionCandidate(skeleton.joints[preferredRootJointIndex], requireRootOrHips: true) {
            return preferredRootJointIndex
        }
        if let skeletonRoot = skeleton.joints.firstIndex(where: { $0.parentIndex < 0 }),
           !looksLikeExtremityJoint(name: skeleton.joints[skeletonRoot].name) {
            return skeletonRoot
        }
        if let namedRoot = skeleton.joints.firstIndex(where: { joint in
            let name = joint.name.lowercased()
            return name.contains("root") && !looksLikeExtremityJoint(name: name)
        }) {
            return namedRoot
        }
        if let hipsOrPelvis = skeleton.joints.firstIndex(where: { joint in
            isAutoRootMotionCandidate(joint, requireRootOrHips: false)
        }) {
            return hipsOrPelvis
        }
        if let rootLike = skeleton.joints.firstIndex(where: { joint in
            !looksLikeExtremityJoint(name: joint.name)
        }) {
            return rootLike
        }
        return min(max(preferredRootJointIndex, 0), skeleton.joints.count - 1)
    }

    private func isAutoRootMotionCandidate(_ joint: SkeletonAsset.Joint, requireRootOrHips: Bool) -> Bool {
        let name = joint.name.lowercased()
        if looksLikeExtremityJoint(name: name) {
            return false
        }
        let isRootLike = joint.parentIndex < 0 || name.contains("root")
        let isHipsLike = name.contains("hips") || name.contains("pelvis")
        return requireRootOrHips ? (isRootLike || isHipsLike) : isHipsLike
    }

    private func looksLikeExtremityJoint(name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("hand")
            || lowered.contains("finger")
            || lowered.contains("thumb")
            || lowered.contains("foot")
            || lowered.contains("toe")
            || lowered.contains("ankle")
            || lowered.contains("wrist")
    }

    // Deterministic authored locomotion source selection for skeletons where RootNode is static and hips carries travel.
    private func deterministicLocomotionTranslationJointIndex(skeleton: SkeletonAsset,
                                                              clip: AnimationClipAsset,
                                                              rootJointIndex: Int) -> Int? {
        guard !skeleton.joints.isEmpty else { return nil }
        let candidateIndices = skeleton.joints.indices.filter { index in
            let name = skeleton.joints[index].name.lowercased()
            return name.contains("hips") || name.contains("pelvis")
        }
        guard !candidateIndices.isEmpty else { return nil }

        if let directChild = candidateIndices.first(where: { skeleton.joints[$0].parentIndex == rootJointIndex }),
           hasMeaningfulTranslationTrack(clip: clip, jointIndex: directChild) {
            return directChild
        }
        return candidateIndices.first(where: { hasMeaningfulTranslationTrack(clip: clip, jointIndex: $0) })
    }

    private func sampleRootMotionDeltaFromClipTracks(clip: AnimationClipAsset,
                                                     channels: (translationJointIndex: Int, rotationJointIndex: Int),
                                                     fromTime: Float,
                                                     toTime: Float) -> RootMotionDelta {
        let translationTrack = clip.tracks.first(where: { $0.jointIndex == channels.translationJointIndex })
        let rotationTrack = clip.tracks.first(where: { $0.jointIndex == channels.rotationJointIndex })

        let fromTranslation = translationTrack.flatMap { sampleTranslation($0.translations, time: fromTime) } ?? .zero
        let toTranslation = translationTrack.flatMap { sampleTranslation($0.translations, time: toTime) } ?? fromTranslation

        var prevRotationVector = rotationTrack.flatMap { sampleRotation($0.rotations, time: fromTime) } ?? TransformMath.identityQuaternion
        if !simd4IsFinite(prevRotationVector) || simd_length_squared(prevRotationVector) <= 1.0e-8 {
            prevRotationVector = TransformMath.identityQuaternion
        }
        var currRotationVector = rotationTrack.flatMap { sampleRotation($0.rotations, time: toTime) } ?? prevRotationVector
        if !simd4IsFinite(currRotationVector) || simd_length_squared(currRotationVector) <= 1.0e-8 {
            currRotationVector = prevRotationVector
        }

        let prevRotation = simd_quatf(vector: TransformMath.normalizedQuaternion(prevRotationVector))
        let currRotation = simd_quatf(vector: TransformMath.normalizedQuaternion(currRotationVector))
        let worldDelta = toTranslation - fromTranslation
        let localDeltaRaw = prevRotation.inverse.act(worldDelta)
        let localDelta = simd3IsFinite(localDeltaRaw) ? localDeltaRaw : .zero
        let deltaRotation = simd_normalize(prevRotation.inverse * currRotation).vector
        let safeDeltaRotation = simd4IsFinite(deltaRotation)
            ? TransformMath.normalizedQuaternion(deltaRotation)
            : TransformMath.identityQuaternion

        return RootMotionDelta(deltaPos: localDelta, deltaRot: safeDeltaRotation)
    }

    private func hasMeaningfulTranslationTrack(clip: AnimationClipAsset, jointIndex: Int) -> Bool {
        guard let track = clip.tracks.first(where: { $0.jointIndex == jointIndex }),
              track.translations.count > 1 else { return false }
        let first = track.translations[0].value
        return track.translations.contains(where: { simd_length($0.value - first) > 1.0e-4 })
    }

    private func hasMeaningfulRotationTrack(clip: AnimationClipAsset, jointIndex: Int) -> Bool {
        guard let track = clip.tracks.first(where: { $0.jointIndex == jointIndex }),
              track.rotations.count > 1 else { return false }
        let first = simd_quatf(vector: TransformMath.normalizedQuaternion(track.rotations[0].value))
        return track.rotations.contains { sample in
            let q = simd_quatf(vector: TransformMath.normalizedQuaternion(sample.value))
            let dotValue = abs(simd_dot(first.vector, q.vector))
            return dotValue < 0.9999
        }
    }

    private func simd3IsFinite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private func simd4IsFinite(_ value: SIMD4<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite && value.w.isFinite
    }

    private func makeRootMotionSample(tickID: UInt64?,
                                      delta: RootMotionDelta,
                                      sourceStateName: String,
                                      sourceNodeID: UUID?,
                                      sampleStartTime: Float,
                                      sampleEndTime: Float,
                                      isValid: Bool) -> RootMotionRuntimeSample? {
        guard let tickID else { return nil }
        return RootMotionRuntimeSample(tickID: tickID,
                                       deltaTranslationLocal: delta.deltaPos,
                                       deltaRotationLocal: delta.deltaRot,
                                       sourceStateName: sourceStateName,
                                       sourceNodeID: sourceNodeID,
                                       sampleStartTime: sampleStartTime,
                                       sampleEndTime: sampleEndTime,
                                       isValid: isValid)
    }

    private func evaluateClipMode(scene: EngineScene,
                                  entity: Entity,
                                  dt: Float,
                                  fixedTickID: UInt64?,
                                  skinnedMesh: SkinnedMeshComponent?,
                                  skeleton: SkeletonAsset?,
                                  animator: inout AnimatorComponent) {
        animator.graphRuntimeState = nil
        let assets = scene.engineContext?.assets
        let previousPlaybackTime = animator.playbackTime
        let clipHandle = animator.clipHandle
        let clip = clipHandle.flatMap { assets?.animationClip(handle: $0) }
        let clipMetadata = clipHandle.flatMap { scene.engineContext?.assetDatabase?.metadata(for: $0) }
        let clipAssociatedSkeletonHandle = assetHandle(from: clipMetadata?.importSettings["skeletonHandle"])
        let skinnedSkeletonHandle = skinnedMesh?.skeletonHandle
        let clipSkeletonMatches = (clipAssociatedSkeletonHandle != nil) && (clipAssociatedSkeletonHandle == skinnedSkeletonHandle)
        var diagnosticState = clipDiagnosticStateByEntity[entity.id] ?? ClipDiagnosticState(lastClipHandle: nil, pendingSummaryClipHandle: nil)
        if diagnosticState.lastClipHandle != clipHandle {
            diagnosticState.lastClipHandle = clipHandle
            diagnosticState.pendingSummaryClipHandle = clipHandle
        }

        if animator.isPlaying, dt > 0 {
            let playbackStep = dt * max(0.0, animator.playbackSpeed)
            animator.playbackTime = nextPlaybackTime(current: animator.playbackTime,
                                                     dt: playbackStep,
                                                     duration: clip?.durationSeconds ?? 0.0,
                                                     isLooping: animator.isLooping)
            if let duration = clip?.durationSeconds,
               duration > 0,
               !animator.isLooping,
               animator.playbackTime >= duration {
                animator.isPlaying = false
            }
        }

        if let handle = clipHandle, clip == nil {
            let clipPath = scene.engineContext?.assetDatabase?.assetURL(for: handle)?.path ?? "<unresolved>"
            logRuntimeIssueOnce(
                key: "unresolvedClip|\(entity.id.uuidString)|\(handle.rawValue.uuidString)",
                message: "Animator clip resolve failure entity=\(entity.id.uuidString)\nactiveClipHandle=\(handle.rawValue.uuidString)\nactiveClipPath=\(clipPath)\nreason=clipAssetMissingForHandle",
                level: .warning
            )
        }

        if clipAssociatedSkeletonHandle == nil, let activeClipHandle = clipHandle {
            let clipPath = scene.engineContext?.assetDatabase?.assetURL(for: activeClipHandle)?.path ?? "<unresolved>"
            logRuntimeIssueOnce(
                key: "clipSkeletonUnset|\(entity.id.uuidString)|\(activeClipHandle.rawValue.uuidString)",
                message: "Animator clip missing skeleton association entity=\(entity.id.uuidString)\nactiveClipHandle=\(activeClipHandle.rawValue.uuidString)\nactiveClipPath=\(clipPath)\naction=bindPoseOnly",
                level: .warning
            )
        }

        if clipAssociatedSkeletonHandle != nil, !clipSkeletonMatches, let activeClipHandle = clipHandle {
            let clipPath = scene.engineContext?.assetDatabase?.assetURL(for: activeClipHandle)?.path ?? "<unresolved>"
            let clipImportScaleApplied = clipMetadata?.importSettings["importScaleApplied"] ?? "<unset>"
            let clipImportScaleSource = clipMetadata?.importSettings["importScaleSource"] ?? "<unset>"
            logRuntimeIssueOnce(
                key: "clipSkeletonMismatch|\(entity.id.uuidString)|\(activeClipHandle.rawValue.uuidString)|\(skinnedSkeletonHandle?.rawValue.uuidString ?? "<none>")",
                message: "Animator clip/skeleton mismatch entity=\(entity.id.uuidString)\nactiveClipHandle=\(activeClipHandle.rawValue.uuidString)\nactiveClipPath=\(clipPath)\nactiveClipImportScaleApplied=\(clipImportScaleApplied)\nactiveClipImportScaleSource=\(clipImportScaleSource)\nactiveClipSkeletonAssociationHandle=\(clipAssociatedSkeletonHandle?.rawValue.uuidString ?? "<none>")\nskinnedMeshSkeletonHandle=\(skinnedSkeletonHandle?.rawValue.uuidString ?? "<none>")\naction=poseEvaluationSkipped",
                level: .warning
            )
        }

        if let skeleton, let clip, clipSkeletonMatches {
            if let activeClipHandle = clipHandle {
                logRuntimeIssueOnce(
                    key: "clipEvaluating|\(entity.id.uuidString)|\(activeClipHandle.rawValue.uuidString)",
                    message: "Animator clip evaluation active entity=\(entity.id.uuidString)\nactiveClipHandle=\(activeClipHandle.rawValue.uuidString)\naction=evaluatingClip",
                    level: .debug
                )
            }
            let rootSelection = resolveRootJointSelection(skeleton: skeleton, skinnedMesh: skinnedMesh)
            animator.poseRuntimeState = evaluatePose(skeleton: skeleton,
                                                     clip: clip,
                                                     entityID: entity.id,
                                                     assets: assets,
                                                     previousPlaybackTime: previousPlaybackTime,
                                                     playbackTime: animator.playbackTime,
                                                     isLooping: animator.isLooping,
                                                     rootJointIndex: rootSelection.index,
                                                     rootBoneName: rootSelection.name,
                                                     usesRootMotion: animator.enableRootMotion,
                                                     fixedTickID: fixedTickID,
                                                     currentStateName: "")
        } else if let skeleton {
            animator.poseRuntimeState = makeBindPoseState(skeleton: skeleton,
                                                          playbackTime: animator.playbackTime,
                                                          assets: assets)
        } else {
            animator.poseRuntimeState = nil
        }
        clipDiagnosticStateByEntity[entity.id] = diagnosticState
    }

    private func evaluatePose(skeleton: SkeletonAsset,
                              clip: AnimationClipAsset,
                              entityID: UUID,
                              assets: AssetManager?,
                              previousPlaybackTime: Float,
                              playbackTime: Float,
                              isLooping: Bool,
                              rootJointIndex: Int,
                              rootBoneName: String,
                              usesRootMotion: Bool,
                              fixedTickID: UInt64?,
                              currentStateName: String) -> AnimationPoseRuntimeState {
        let sampledLocalPose = evaluateLocalPose(skeleton: skeleton,
                                               clip: clip,
                                               playbackTime: playbackTime,
                                               assets: assets)
        let rootMotionDelta = sampleClipRootMotionDelta(skeleton: skeleton,
                                                        clip: clip,
                                                        rootJointIndex: rootJointIndex,
                                                        trackerEntityID: entityID,
                                                        trackerKey: "clipMode|\(clip.handle.rawValue.uuidString)|root:\(rootJointIndex)",
                                                        previousTime: previousPlaybackTime,
                                                        currentTime: playbackTime,
                                                        isLooping: isLooping,
                                                        sourceStateName: currentStateName,
                                                        assets: assets)
        let consumedRootTrack = usesRootMotion
        let outputLocalPose = consumedRootTrack
            ? consumeRootMotionTracks(in: sampledLocalPose,
                                      skeleton: skeleton,
                                      translationJointIndex: rootJointIndex,
                                      rotationJointIndex: rootJointIndex,
                                      consumeTranslation: true,
                                      consumeRotation: true)
            : sampledLocalPose
        let globalPose = makeGlobalPose(localPose: outputLocalPose,
                                        skeleton: skeleton,
                                        assets: assets)
        let fixedTickRuntimeSnapshot: AnimationFixedTickRuntimeSnapshot? = fixedTickID.map {
            let sampleHasNonZeroDelta: Bool = {
                let rotation = simd_quatf(vector: TransformMath.normalizedQuaternion(rootMotionDelta.deltaRot))
                let radians = 2.0 * acos(simd_clamp(abs(rotation.real), 0.0, 1.0))
                return simd_length(rootMotionDelta.deltaPos) > 1.0e-6 || radians > 1.0e-5
            }()
            return AnimationFixedTickRuntimeSnapshot(tickID: $0,
                                              currentStateName: currentStateName,
                                              authoredUsesRootMotion: usesRootMotion,
                                              stateWantsRootMotion: usesRootMotion,
                                              effectiveUsesRootMotion: usesRootMotion,
                                              sampleHasNonZeroDelta: sampleHasNonZeroDelta,
                                              rootMotionSampleValid: sampleHasNonZeroDelta,
                                              rootMotionTrackConsumed: consumedRootTrack,
                                              translationSourceJointIndex: rootJointIndex,
                                              translationSourceJointName: rootBoneName,
                                              rotationSourceJointIndex: rootJointIndex,
                                              rotationSourceJointName: rootBoneName,
                                              localRootDeltaTranslation: rootMotionDelta.deltaPos,
                                              worldRootDeltaTranslation: rootMotionDelta.deltaPos,
                                              rootDeltaRotation: rootMotionDelta.deltaRot,
                                              sampleTime: playbackTime,
                                              sampleDuration: max(clip.durationSeconds, 0.0),
                                              isTransitionBlend: false)
        }
        return AnimationPoseRuntimeState(sampleTime: playbackTime,
                                         sampleDuration: max(clip.durationSeconds, 0.0),
                                         localPose: outputLocalPose,
                                         globalPose: globalPose,
                                         rootMotionDelta: rootMotionDelta,
                                         rootMotionSample: makeRootMotionSample(tickID: fixedTickID,
                                                                                delta: rootMotionDelta,
                                                                                sourceStateName: currentStateName,
                                                                                sourceNodeID: nil,
                                                                                sampleStartTime: previousPlaybackTime,
                                                                                sampleEndTime: playbackTime,
                                                                                isValid: usesRootMotion),
                                         usesRootMotion: usesRootMotion,
                                         currentStateName: currentStateName,
                                         rootMotionBoneName: rootBoneName,
                                         rootMotionJointIndex: rootJointIndex,
                                         rootMotionTrackConsumed: consumedRootTrack,
                                         rootMotionTranslationBoneName: rootBoneName,
                                         rootMotionTranslationJointIndex: rootJointIndex,
                                         rootMotionRotationBoneName: rootBoneName,
                                         rootMotionRotationJointIndex: rootJointIndex,
                                         rootMotionConsumeBoneName: rootBoneName,
                                         rootMotionConsumeJointIndex: rootJointIndex,
                                         fixedTickRuntimeSnapshot: fixedTickRuntimeSnapshot)
    }

    // Ozz SamplingJob is the primary local-pose sampling path.
    // Legacy keyframe interpolation is retained only as fallback.
    private func evaluateLocalPose(skeleton: SkeletonAsset,
                                   clip: AnimationClipAsset,
                                   playbackTime: Float,
                                   assets: AssetManager? = nil) -> [TransformComponent] {
        if let assets,
           let skeletonRuntime = assets.ozzSkeletonRuntime(handle: skeleton.handle),
           let animationRuntime = assets.ozzAnimationRuntime(handle: clip.handle),
           let samplingContext = animationRuntime.context(maxSoaTracks: skeletonRuntime.maxSoaTracks),
           let ozzPose = OzzRuntimeBridge.sampleLocalPose(skeletonRuntime: skeletonRuntime,
                                                          animationRuntime: animationRuntime,
                                                          samplingContext: samplingContext,
                                                          timeSeconds: playbackTime,
                                                          expectedJointCount: skeleton.joints.count),
           ozzPose.count == skeleton.joints.count {
            return ozzPose
        }
        return evaluateLocalPoseFallback(skeleton: skeleton, clip: clip, playbackTime: playbackTime)
    }

    private func makeGlobalPose(localPose: [TransformComponent],
                                skeleton: SkeletonAsset,
                                assets: AssetManager? = nil) -> [TransformComponent] {
        let globalMatrices = globalMatrices(from: localPose, skeleton: skeleton, assets: assets)
        var globalPose = Array(repeating: TransformComponent(), count: globalMatrices.count)
        for jointIndex in 0..<globalMatrices.count {
            let decomposed = TransformMath.decomposeMatrix(globalMatrices[jointIndex])
            globalPose[jointIndex] = TransformComponent(position: decomposed.position,
                                                        rotation: decomposed.rotation,
                                                        scale: decomposed.scale)
        }
        return globalPose
    }

    private func makeBindPoseState(skeleton: SkeletonAsset,
                                   playbackTime: Float,
                                   assets: AssetManager? = nil) -> AnimationPoseRuntimeState {
        let localPose = skeleton.joints.map { joint in
            TransformComponent(position: joint.bindLocalPosition,
                               rotation: joint.bindLocalRotation,
                               scale: joint.bindLocalScale)
        }
        let globalPose = makeGlobalPose(localPose: localPose, skeleton: skeleton, assets: assets)
        let selection = resolveRootJointSelection(skeleton: skeleton, skinnedMesh: nil)
        return AnimationPoseRuntimeState(sampleTime: playbackTime,
                                         sampleDuration: 0.0,
                                         localPose: localPose,
                                         globalPose: globalPose,
                                         rootMotionBoneName: selection.name,
                                         rootMotionJointIndex: selection.index,
                                         rootMotionTrackConsumed: false,
                                         rootMotionTranslationBoneName: selection.name,
                                         rootMotionTranslationJointIndex: selection.index,
                                         rootMotionRotationBoneName: selection.name,
                                         rootMotionRotationJointIndex: selection.index,
                                         rootMotionConsumeBoneName: selection.name,
                                         rootMotionConsumeJointIndex: selection.index)
    }

    private func makePoseState(skeleton: SkeletonAsset,
                               localPose: [TransformComponent],
                               sampleTime: Float,
                               sampleDuration: Float = 0.0,
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
                               fixedTickRuntimeSnapshot: AnimationFixedTickRuntimeSnapshot? = nil,
                               assets: AssetManager? = nil) -> AnimationPoseRuntimeState {
        guard !localPose.isEmpty else {
            return makeBindPoseState(skeleton: skeleton, playbackTime: sampleTime, assets: assets)
        }
        let globalPose = makeGlobalPose(localPose: localPose, skeleton: skeleton, assets: assets)
        return AnimationPoseRuntimeState(sampleTime: sampleTime,
                                         sampleDuration: max(0.0, sampleDuration),
                                         localPose: localPose,
                                         globalPose: globalPose,
                                         rootMotionDelta: rootMotionDelta,
                                         rootMotionSample: rootMotionSample,
                                         usesRootMotion: usesRootMotion,
                                         currentStateName: currentStateName,
                                         rootMotionBoneName: rootMotionBoneName,
                                         rootMotionJointIndex: rootMotionJointIndex,
                                         rootMotionTrackConsumed: rootMotionTrackConsumed,
                                         rootMotionTranslationBoneName: rootMotionTranslationBoneName,
                                         rootMotionTranslationJointIndex: rootMotionTranslationJointIndex,
                                         rootMotionRotationBoneName: rootMotionRotationBoneName,
                                         rootMotionRotationJointIndex: rootMotionRotationJointIndex,
                                         rootMotionConsumeBoneName: rootMotionConsumeBoneName,
                                         rootMotionConsumeJointIndex: rootMotionConsumeJointIndex,
                                         fixedTickRuntimeSnapshot: fixedTickRuntimeSnapshot)
    }

    private func sampleTranslation(_ keyframes: [AnimationClipAsset.TranslationKeyframe], time: Float) -> SIMD3<Float>? {
        sampleVector3Keyframes(keyframes.map { ($0.time, $0.value) }, time: time)
    }

    private func sampleScale(_ keyframes: [AnimationClipAsset.ScaleKeyframe], time: Float) -> SIMD3<Float>? {
        sampleVector3Keyframes(keyframes.map { ($0.time, $0.value) }, time: time)
    }

    private func sampleRotation(_ keyframes: [AnimationClipAsset.RotationKeyframe], time: Float) -> SIMD4<Float>? {
        guard !keyframes.isEmpty else { return nil }
        if keyframes.count == 1 { return keyframes[0].value }
        if time <= keyframes[0].time { return keyframes[0].value }
        if time >= keyframes[keyframes.count - 1].time { return keyframes[keyframes.count - 1].value }

        for i in 0..<(keyframes.count - 1) {
            let a = keyframes[i]
            let b = keyframes[i + 1]
            guard time >= a.time, time <= b.time else { continue }
            let span = max(b.time - a.time, 1.0e-6)
            let t = simd_clamp((time - a.time) / span, 0.0, 1.0)
            let qa = simd_quatf(real: a.value.w, imag: SIMD3<Float>(a.value.x, a.value.y, a.value.z))
            let qb = simd_quatf(real: b.value.w, imag: SIMD3<Float>(b.value.x, b.value.y, b.value.z))
            let q = simd_slerp(qa, qb, t)
            return TransformMath.normalizedQuaternion(SIMD4<Float>(q.imag.x, q.imag.y, q.imag.z, q.real))
        }
        return keyframes[keyframes.count - 1].value
    }

    private func sampleVector3Keyframes(_ keyframes: [(Float, SIMD3<Float>)], time: Float) -> SIMD3<Float>? {
        guard !keyframes.isEmpty else { return nil }
        if keyframes.count == 1 { return keyframes[0].1 }
        if time <= keyframes[0].0 { return keyframes[0].1 }
        if time >= keyframes[keyframes.count - 1].0 { return keyframes[keyframes.count - 1].1 }

        for i in 0..<(keyframes.count - 1) {
            let a = keyframes[i]
            let b = keyframes[i + 1]
            guard time >= a.0, time <= b.0 else { continue }
            let span = max(b.0 - a.0, 1.0e-6)
            let t = simd_clamp((time - a.0) / span, 0.0, 1.0)
            return a.1 + ((b.1 - a.1) * t)
        }
        return keyframes[keyframes.count - 1].1
    }

    // Ozz LocalToModelJob is the primary hierarchy solve for model-space matrices.
    // Legacy parent-chain multiplication is retained only as fallback.
    private func globalMatrices(from localPose: [TransformComponent],
                                skeleton: SkeletonAsset,
                                assets: AssetManager? = nil) -> [matrix_float4x4] {
        let jointCount = min(skeleton.joints.count, localPose.count)
        guard jointCount > 0 else { return [] }
        if let assets,
           let skeletonRuntime = assets.ozzSkeletonRuntime(handle: skeleton.handle),
           let localToModelContext = skeletonRuntime.context(),
           let modelMatrices = OzzRuntimeBridge.localToModelMatrices(skeletonRuntime: skeletonRuntime,
                                                                     localToModelContext: localToModelContext,
                                                                     localPose: localPose,
                                                                     expectedJointCount: jointCount),
           modelMatrices.count == jointCount {
            return modelMatrices
        }
        return globalMatricesFallback(from: localPose, skeleton: skeleton, jointCount: jointCount)
    }

    private func blendLocalPosesFallback(_ a: [TransformComponent],
                                         _ b: [TransformComponent],
                                         weight: Float,
                                         count: Int) -> [TransformComponent] {
        var output = Array(repeating: TransformComponent(), count: count)
        for i in 0..<count {
            let pa = a[i]
            let pb = b[i]
            let blendedPosition = pa.position + ((pb.position - pa.position) * weight)
            let blendedScale = pa.scale + ((pb.scale - pa.scale) * weight)
            let qa = simd_quatf(real: pa.rotation.w, imag: SIMD3<Float>(pa.rotation.x, pa.rotation.y, pa.rotation.z))
            let qb = simd_quatf(real: pb.rotation.w, imag: SIMD3<Float>(pb.rotation.x, pb.rotation.y, pb.rotation.z))
            let q = simd_slerp(qa, qb, weight)
            output[i] = TransformComponent(position: blendedPosition,
                                           rotation: SIMD4<Float>(q.imag.x, q.imag.y, q.imag.z, q.real),
                                           scale: blendedScale)
        }
        return output
    }

    private func blendLocalPosesFallback(localPoses: [[TransformComponent]],
                                         weights: [Float],
                                         jointCount: Int) -> [TransformComponent] {
        let weightSum = max(weights.reduce(0, +), 1.0e-6)
        var normalizedWeights = weights.map { $0 / weightSum }
        if normalizedWeights.isEmpty {
            normalizedWeights = Array(repeating: 1.0 / Float(localPoses.count), count: localPoses.count)
        }

        var output = Array(repeating: TransformComponent(), count: jointCount)
        for jointIndex in 0..<jointCount {
            var blendedPosition = SIMD3<Float>(repeating: 0.0)
            var blendedScale = SIMD3<Float>(repeating: 0.0)
            let firstRotation = localPoses[0][jointIndex].rotation
            var accumRotation = SIMD4<Float>(repeating: 0.0)
            for poseIndex in 0..<localPoses.count {
                let pose = localPoses[poseIndex][jointIndex]
                let w = normalizedWeights[poseIndex]
                blendedPosition += pose.position * w
                blendedScale += pose.scale * w

                var q = TransformMath.normalizedQuaternion(pose.rotation)
                if simd_dot(firstRotation, q) < 0.0 {
                    q = -q
                }
                accumRotation += q * w
            }
            output[jointIndex] = TransformComponent(position: blendedPosition,
                                                    rotation: TransformMath.normalizedQuaternion(accumRotation),
                                                    scale: blendedScale)
        }
        return output
    }

    private func blendRootMotionDeltasFallback(_ a: RootMotionDelta,
                                               _ b: RootMotionDelta,
                                               weight: Float) -> RootMotionDelta {
        let blendedPosition = simd_mix(a.deltaPos, b.deltaPos, SIMD3<Float>(repeating: weight))
        let qa = simd_quatf(vector: TransformMath.normalizedQuaternion(a.deltaRot))
        let qb = simd_quatf(vector: TransformMath.normalizedQuaternion(b.deltaRot))
        let blendedRotation = simd_slerp(qa, qb, weight).vector
        return RootMotionDelta(deltaPos: blendedPosition, deltaRot: blendedRotation)
    }

    private func blendRootMotionDeltasFallback(_ deltas: [RootMotionDelta],
                                               weights: [Float]) -> RootMotionDelta {
        var result = deltas[0]
        var consumed = weights[0]
        if deltas.count == 1 { return result }
        for i in 1..<deltas.count {
            let nextWeight = weights[i]
            let t = nextWeight / max(consumed + nextWeight, 1.0e-6)
            result = blendRootMotionDeltasFallback(result, deltas[i], weight: t)
            consumed += nextWeight
        }
        return result
    }

    private func sampleRootMotionDeltaSingleSpanFallback(skeleton: SkeletonAsset,
                                                         clip: AnimationClipAsset,
                                                         channels: (translationJointIndex: Int, rotationJointIndex: Int),
                                                         fromTime: Float,
                                                         toTime: Float,
                                                         assets: AssetManager?) -> RootMotionDelta {
        let fromLocalPose = evaluateLocalPose(skeleton: skeleton, clip: clip, playbackTime: fromTime, assets: assets)
        let toLocalPose = evaluateLocalPose(skeleton: skeleton, clip: clip, playbackTime: toTime, assets: assets)
        let fromGlobalPose = makeGlobalPose(localPose: fromLocalPose, skeleton: skeleton, assets: assets)
        let toGlobalPose = makeGlobalPose(localPose: toLocalPose, skeleton: skeleton, assets: assets)
        guard channels.translationJointIndex < fromGlobalPose.count,
              channels.translationJointIndex < toGlobalPose.count,
              channels.rotationJointIndex < fromGlobalPose.count,
              channels.rotationJointIndex < toGlobalPose.count else { return .zero }

        let fromTranslationTransform = fromGlobalPose[channels.translationJointIndex]
        let toTranslationTransform = toGlobalPose[channels.translationJointIndex]
        let fromRotationTransform = fromGlobalPose[channels.rotationJointIndex]
        let toRotationTransform = toGlobalPose[channels.rotationJointIndex]

        var previousRotationVector = TransformMath.normalizedQuaternion(fromRotationTransform.rotation)
        if !simd4IsFinite(previousRotationVector) || simd_length_squared(previousRotationVector) <= 1.0e-8 {
            previousRotationVector = TransformMath.identityQuaternion
        }
        var currentRotationVector = TransformMath.normalizedQuaternion(toRotationTransform.rotation)
        if !simd4IsFinite(currentRotationVector) || simd_length_squared(currentRotationVector) <= 1.0e-8 {
            currentRotationVector = TransformMath.identityQuaternion
        }
        let previousRotation = simd_quatf(vector: previousRotationVector)
        let currentRotation = simd_quatf(vector: currentRotationVector)
        let rawDeltaRotation = simd_normalize(simd_inverse(previousRotation) * currentRotation).vector
        let deltaRotation = simd4IsFinite(rawDeltaRotation)
            ? TransformMath.normalizedQuaternion(rawDeltaRotation)
            : TransformMath.identityQuaternion

        let worldTranslationDelta = toTranslationTransform.position - fromTranslationTransform.position
        let localTranslationDeltaRaw = previousRotation.inverse.act(worldTranslationDelta)
        let localTranslationDelta = simd3IsFinite(localTranslationDeltaRaw) ? localTranslationDeltaRaw : .zero

        return RootMotionDelta(deltaPos: localTranslationDelta,
                               deltaRot: deltaRotation)
    }

    private func evaluateLocalPoseFallback(skeleton: SkeletonAsset,
                                           clip: AnimationClipAsset,
                                           playbackTime: Float) -> [TransformComponent] {
        let jointCount = skeleton.joints.count
        guard jointCount > 0 else {
            return []
        }

        var localPose = Array(repeating: TransformComponent(), count: jointCount)
        for jointIndex in 0..<jointCount {
            let joint = skeleton.joints[jointIndex]
            localPose[jointIndex] = TransformComponent(position: joint.bindLocalPosition,
                                                       rotation: joint.bindLocalRotation,
                                                       scale: joint.bindLocalScale)
        }
        for track in clip.tracks {
            guard track.jointIndex >= 0, track.jointIndex < jointCount else { continue }
            var jointLocal = localPose[track.jointIndex]
            if let translation = sampleTranslation(track.translations, time: playbackTime) {
                jointLocal.position = translation
            }
            if let rotation = sampleRotation(track.rotations, time: playbackTime) {
                jointLocal.rotation = rotation
            }
            if let scale = sampleScale(track.scales, time: playbackTime) {
                jointLocal.scale = scale
            }
            localPose[track.jointIndex] = jointLocal
        }
        return localPose
    }

    private func globalMatricesFallback(from localPose: [TransformComponent],
                                        skeleton: SkeletonAsset,
                                        jointCount: Int) -> [matrix_float4x4] {
        let localMatrices: [matrix_float4x4] = localPose.prefix(jointCount).map { local in
            TransformMath.makeMatrix(position: local.position,
                                     rotation: local.rotation,
                                     scale: local.scale)
        }
        var resolved = Array(repeating: matrix_identity_float4x4, count: jointCount)
        var visitState = Array(repeating: UInt8(0), count: jointCount) // 0=unvisited, 1=visiting, 2=resolved

        func resolve(_ jointIndex: Int) {
            if visitState[jointIndex] == 2 { return }
            if visitState[jointIndex] == 1 {
                resolved[jointIndex] = localMatrices[jointIndex]
                visitState[jointIndex] = 2
                return
            }
            visitState[jointIndex] = 1
            let parentIndex = skeleton.joints[jointIndex].parentIndex
            if parentIndex >= 0, parentIndex < jointCount, parentIndex != jointIndex {
                resolve(parentIndex)
                resolved[jointIndex] = resolved[parentIndex] * localMatrices[jointIndex]
            } else {
                resolved[jointIndex] = localMatrices[jointIndex]
            }
            visitState[jointIndex] = 2
        }

        for jointIndex in 0..<jointCount {
            resolve(jointIndex)
        }
        return resolved
    }

    private func matrixIsFinite(_ matrix: matrix_float4x4) -> Bool {
        for column in 0..<4 {
            let value = matrix[column]
            if !value.x.isFinite || !value.y.isFinite || !value.z.isFinite || !value.w.isFinite {
                return false
            }
        }
        return true
    }

    private func logRuntimeSummaryOnce(engineContext: EngineContext?,
                                       entity: Entity,
                                       animator: AnimatorComponent?,
                                       skinnedMesh: SkinnedMeshComponent,
                                       skeleton: SkeletonAsset,
                                       clip: AnimationClipAsset?,
                                       mesh: MCMesh?,
                                       localPose: [TransformComponent],
                                       globalPose: [TransformComponent],
                                       evaluatedJointCount: Int,
                                       bindPolicy: String,
                                       importedInverseBindCount: Int,
                                       nonFinitePaletteMatrixCount: Int,
                                       forceLog: Bool) {
#if DEBUG
        guard animationGraphDebugLoggingEnabled else { return }
        let key = "\(entity.id.uuidString)|\(skeleton.handle.rawValue.uuidString)|\(clip?.handle.rawValue.uuidString ?? "<none>")"
        if !forceLog {
            guard !loggedRuntimeSummaryKeys.contains(key) else { return }
        }
        loggedRuntimeSummaryKeys.insert(key)
        let indexCount = mesh?.totalIndexCount() ?? 0
        let rootTranslationMagnitude = globalPose.isEmpty ? 0 : simd_length(globalPose[0].position)
        var maxJointTranslationMagnitude: Float = 0
        for joint in globalPose {
            maxJointTranslationMagnitude = max(maxJointTranslationMagnitude, simd_length(joint.position))
        }
        let nonFiniteLocalCount = localPose.reduce(into: 0) { count, pose in
            if !vector3IsFinite(pose.position) || !vector4IsFinite(pose.rotation) || !vector3IsFinite(pose.scale) {
                count += 1
            }
        }
        let nonFiniteGlobalCount = globalPose.reduce(into: 0) { count, pose in
            if !vector3IsFinite(pose.position) || !vector4IsFinite(pose.rotation) || !vector3IsFinite(pose.scale) {
                count += 1
            }
        }

        let clipHandle = animator?.clipHandle
        let clipMeta = clipHandle.flatMap { engineContext?.assetDatabase?.metadata(for: $0) }
        let clipPath = clipHandle.flatMap { engineContext?.assetDatabase?.assetURL(for: $0)?.path } ?? "<unresolved>"
        let clipImportScaleApplied = clipMeta?.importSettings["importScaleApplied"] ?? "<unset>"
        let clipImportScaleSource = clipMeta?.importSettings["importScaleSource"] ?? "<unset>"
        let clipSkeletonAssociation = clipMeta?.importSettings["skeletonHandle"] ?? "<unset>"
        let clipCanonicalJointCount = clipMeta?.importSettings["clipCanonicalJointCountAfterRemap"] ?? "<unset>"
        let clipTargetSkeletonJointCount = clipMeta?.importSettings["targetSkeletonJointCount"] ?? "<unset>"
        let skinnedSkeletonHandle = skinnedMesh.skeletonHandle?.rawValue.uuidString ?? "<none>"
        let skeletonHandleMatch = clipSkeletonAssociation == skinnedSkeletonHandle ? "true" : "false"

        let meshBoundsRadius = mesh?.boundsRadius ?? 0
        let animatedBoundsRisk = meshBoundsRadius > 0
            ? (maxJointTranslationMagnitude > (meshBoundsRadius * 8.0))
            : false
        EngineLoggerContext.log(
            """
            FBX runtime skinning summary entity=\(entity.id.uuidString)
            activeClipHandle=\(clipHandle?.rawValue.uuidString ?? "<none>")
            activeClipPath=\(clipPath)
            activeClipName=\(clip?.name ?? "<none>")
            activeClipImportScaleApplied=\(clipImportScaleApplied)
            activeClipImportScaleSource=\(clipImportScaleSource)
            activeClipSkeletonAssociationHandle=\(clipSkeletonAssociation)
            activeClipCanonicalJointCountAfterRemap=\(clipCanonicalJointCount)
            activeClipTargetSkeletonJointCount=\(clipTargetSkeletonJointCount)
            skinnedMeshSkeletonHandle=\(skinnedSkeletonHandle)
            clipSkeletonHandleMatchesSkinnedMesh=\(skeletonHandleMatch)
            clipEvaluationState=\(clip != nil && skeletonHandleMatch == "true" ? "evaluatingClip" : "bindPoseOnly")
            playbackTime=\(animator?.playbackTime ?? 0)
            playbackSpeed=\(animator?.playbackSpeed ?? 0)
            isPlaying=\(animator?.isPlaying ?? false)
            meshVertexCount=\(mesh?.vertexCount ?? 0)
            meshIndexCount=\(indexCount)
            meshBoundsRadius=\(meshBoundsRadius)
            skinningStreamsPresent=\(mesh?.hasValidSkinningVertexStreams() ?? false)
            evaluatedJointCount=\(evaluatedJointCount)
            skeletonJointCount=\(skeleton.joints.count)
            rootJointTranslationMagnitude=\(rootTranslationMagnitude)
            maxJointTranslationMagnitude=\(maxJointTranslationMagnitude)
            nonFiniteLocalJointTransformCount=\(nonFiniteLocalCount)
            nonFiniteGlobalJointTransformCount=\(nonFiniteGlobalCount)
            nonFinitePaletteMatrixCount=\(nonFinitePaletteMatrixCount)
            importedInverseBindCount=\(importedInverseBindCount)
            bindPolicy=\(bindPolicy)
            animatedBoundsRisk=\(animatedBoundsRisk)
            """,
            level: .debug,
            category: .assets
        )
#endif
    }

    private func vector3IsFinite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private func vector4IsFinite(_ value: SIMD4<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite && value.w.isFinite
    }

    private func assetHandle(from rawValue: String?) -> AssetHandle? {
        guard let rawValue, !rawValue.isEmpty, let uuid = UUID(uuidString: rawValue) else { return nil }
        return AssetHandle(rawValue: uuid)
    }

    private func logStateMachineSignatureIfChanged(entityID: UUID,
                                                   graphHandle: AnimationGraphHandle,
                                                   nodeID: UUID,
                                                   currentStateName: String,
                                                   nextStateName: String,
                                                   reason: String) {
#if DEBUG
        let key = "\(entityID.uuidString)|\(graphHandle.rawValue.uuidString)|\(nodeID.uuidString)"
        let signature = "\(currentStateName)|\(nextStateName)"
        if lastStateMachineSignatureByKey[key] == signature {
            return
        }
        lastStateMachineSignatureByKey[key] = signature
        EngineLoggerContext.log(
            "Animator graph state change entity=\(entityID.uuidString) graph=\(graphHandle.rawValue.uuidString) node=\(nodeID.uuidString) currentState=\(currentStateName) nextState=\(nextStateName) reason=\(reason)",
            level: .debug,
            category: .scene
        )
#endif
    }

    private func logRuntimeIssueOnce(key: String, message: @autoclosure () -> String, level: MCLogLevel) {
#if DEBUG
        guard !loggedRuntimeIssueKeys.contains(key) else { return }
        loggedRuntimeIssueKeys.insert(key)
        EngineLoggerContext.log(
            message(),
            level: level,
            category: .assets
        )
#endif
    }

    private func logRuntimeIssueOnce(key: String, level: MCLogLevel, message: @autoclosure () -> String) {
        #if DEBUG
        guard !loggedRuntimeIssueKeys.contains(key) else { return }
        loggedRuntimeIssueKeys.insert(key)
        EngineLoggerContext.log(
            message(),
            level: level,
            category: .assets
        )
        #endif
    }

    private func shouldForceRuntimeSummary(entityId: UUID, clipHandle: AssetHandle?) -> Bool {
        guard let state = clipDiagnosticStateByEntity[entityId] else { return false }
        return state.pendingSummaryClipHandle == clipHandle
    }

    private func markRuntimeSummaryForcedHandled(entityId: UUID, clipHandle: AssetHandle?) {
        guard var state = clipDiagnosticStateByEntity[entityId] else { return }
        if state.pendingSummaryClipHandle == clipHandle {
            state.pendingSummaryClipHandle = nil
            clipDiagnosticStateByEntity[entityId] = state
        }
    }
}
