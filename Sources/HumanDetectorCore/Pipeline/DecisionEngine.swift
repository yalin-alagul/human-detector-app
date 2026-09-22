import Foundation

/// The outcome of applying thresholds to raw detector scores.
public struct Decision: Sendable, Equatable {
    public var verdict: Verdict
    public var stage: String
    public var topScore: Float
    public var reason: String

    public init(verdict: Verdict, stage: String, topScore: Float, reason: String) {
        self.verdict = verdict
        self.stage = stage
        self.topScore = topScore
        self.reason = reason
    }
}

/// Maps raw detector scores to `clean` / `review` / `trash`.
///
/// This is deliberately pure: it takes scores and thresholds and returns a
/// verdict. Because inference is stored separately, the calibration UI can
/// re-run this over a cached sample instantly as you drag a slider.
public enum DecisionEngine {
    /// Classify an image according to the chosen goal.
    ///
    /// Detection always answers "is there a human?". The goal only decides which
    /// answer is kept: `removeHumans` keeps the negatives, `keepHumans` keeps the
    /// positives and sends everything with nobody in it to `trash`.
    public static func decide(
        signals: ImageSignals,
        thresholds: ThresholdConfig,
        goal: DetectionGoal
    ) -> Decision {
        apply(goal: goal, to: presenceDecision(signals: signals, thresholds: thresholds))
    }

    /// Map a raw "human present?" decision onto the goal's folder semantics.
    static func apply(goal: DetectionGoal, to presence: Decision) -> Decision {
        guard goal == .keepHumans else { return presence }
        switch presence.verdict {
        case .trash:
            return Decision(
                verdict: .clean,
                stage: presence.stage,
                topScore: presence.topScore,
                reason: "human present (\(presence.reason)) — kept"
            )
        case .clean:
            return Decision(
                verdict: .trash,
                stage: "no-human",
                topScore: presence.topScore,
                reason: "no human detected — moved to trash"
            )
        default:
            return presence
        }
    }

    static func presenceDecision(signals: ImageSignals, thresholds: ThresholdConfig) -> Decision {
        let minArea = Double(thresholds.minimumAreaFraction)

        let person = topScore(signals.personDetections, minArea: minArea)
        let face = topScore(signals.faces, minArea: minArea)
        let human = topScore(signals.humanRects, minArea: minArea)
        let pose = topScore(signals.bodyPoses, minArea: minArea)

        // Stage 1 — trash band.
        if person >= thresholds.yoloTrash {
            return Decision(verdict: .trash, stage: "yolo-person", topScore: person,
                            reason: "person confidence \(fmt(person)) ≥ \(fmt(thresholds.yoloTrash))")
        }
        if face >= thresholds.faceTrash {
            return Decision(verdict: .trash, stage: "face", topScore: face,
                            reason: "face confidence \(fmt(face)) ≥ \(fmt(thresholds.faceTrash))")
        }
        if human >= thresholds.visionHumanTrash {
            return Decision(verdict: .trash, stage: "vision-human", topScore: human,
                            reason: "human-rect confidence \(fmt(human)) ≥ \(fmt(thresholds.visionHumanTrash))")
        }
        if pose >= thresholds.visionPoseTrash {
            return Decision(verdict: .trash, stage: "vision-pose", topScore: pose,
                            reason: "body-pose confidence \(fmt(pose)) ≥ \(fmt(thresholds.visionPoseTrash))")
        }

        // Stage 3 — review band. Track the strongest borderline signal.
        var reviewScore: Float = 0
        var reviewStage = ""

        consider(person, thresholds.yoloReviewLow, "yolo-person", &reviewScore, &reviewStage)
        consider(face, thresholds.faceReviewLow, "face", &reviewScore, &reviewStage)
        consider(human, thresholds.visionHumanReviewLow, "vision-human", &reviewScore, &reviewStage)
        consider(pose, thresholds.visionPoseReviewLow, "vision-pose", &reviewScore, &reviewStage)

        if reviewScore > 0 {
            return Decision(verdict: .review, stage: reviewStage, topScore: reviewScore,
                            reason: "borderline \(reviewStage) score \(fmt(reviewScore))")
        }

        let overall = max(person, max(face, max(human, pose)))
        return Decision(verdict: .clean, stage: "none", topScore: overall,
                        reason: "all signals below review floors")
    }

    /// Highest confidence among detections large enough to matter.
    static func topScore(_ detections: [Detection], minArea: Double) -> Float {
        detections
            .filter { $0.box.area >= minArea }
            .map(\.confidence)
            .max() ?? 0
    }

    private static func consider(
        _ score: Float,
        _ floor: Float,
        _ stage: String,
        _ best: inout Float,
        _ bestStage: inout String
    ) {
        guard score >= floor, score > best else { return }
        best = score
        bestStage = stage
    }

    static func fmt(_ value: Float) -> String {
        String(format: "%.3f", value)
    }
}
