import Foundation

/// What a remote change is allowed to do, from least to most friction.
public enum Verdict: Int, Comparable, Codable, Sendable, CaseIterable {
    /// Inside the envelope and shrinks or keeps behaviour. Push it.
    case shipAsConfig = 0
    /// Inside the envelope but changes behaviour. Push it with a changelog entry.
    case shipWithChangelog = 1
    /// Might be fine, but the evidence is missing or bad (no changelog, no
    /// eval, eval regressed, prompt edited without a version bump).
    case blocked = 2
    /// Outside the reviewed envelope. This is a new feature: it goes into a
    /// binary, a manifest update and the Notes for Review.
    case needsSubmission = 3

    public static func < (lhs: Verdict, rhs: Verdict) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .shipAsConfig: return "Ship as config"
        case .shipWithChangelog: return "Ship with changelog"
        case .blocked: return "Blocked: missing evidence"
        case .needsSubmission: return "New feature: submit for review"
        }
    }
}

public enum FindingKind: String, Codable, Sendable {
    case undeclaredTool
    case undeclaredDataScope
    case undeclaredModelTier
    case undeclaredFlag
    case flagUnlocksUndeclaredCapability
    case promptReferencesUndeclaredTool
    case enablesDeclaredCapability
    case removesCapability
    case promptChanged
    case promptEditedWithoutVersionBump
    case promptChangedWithoutChangelog
    case promptChangedWithoutEval
    case evalRegressed
}

public struct Finding: Hashable, Codable, Sendable {
    public let kind: FindingKind
    public let subject: String
    public let verdict: Verdict
    public let explanation: String

    public init(kind: FindingKind, subject: String, verdict: Verdict, explanation: String) {
        self.kind = kind
        self.subject = subject
        self.verdict = verdict
        self.explanation = explanation
    }
}

public struct ChangeReview: Sendable {
    public let findings: [Finding]

    /// The strictest finding wins. No findings means nothing changed.
    public var verdict: Verdict {
        findings.map(\.verdict).max() ?? .shipAsConfig
    }
}

/// Classifies a proposed remote change against the reviewed envelope.
///
/// The question it answers is not "is this in the binary?" but "is this
/// behaviour inside what we documented to App Review, and do we have the
/// evidence that it does what the changelog says?"
public struct EnvelopeClassifier: Sendable {
    public let manifest: CapabilityManifest
    /// How far below the production baseline an eval pass rate may fall.
    public let evalTolerance: Double

    public init(manifest: CapabilityManifest, evalTolerance: Double = 0.02) {
        self.manifest = manifest
        self.evalTolerance = max(0, evalTolerance)
    }

    public func review(
        current: RemoteBehavior,
        proposed: RemoteBehavior,
        release: PromptRelease = .none
    ) -> ChangeReview {
        var findings: [Finding] = []
        findings += reviewSet(current.tools, proposed.tools, kind: .aiTool,
                              undeclared: .undeclaredTool, noun: "tool")
        findings += reviewSet(current.dataScopes, proposed.dataScopes, kind: .dataScope,
                              undeclared: .undeclaredDataScope, noun: "data scope")
        findings += reviewModelTier(current.modelTier, proposed.modelTier)
        findings += reviewFlags(current, proposed)
        findings += reviewPrompt(current, proposed, release)
        return ChangeReview(findings: findings)
    }

    private func reviewSet(
        _ current: [String], _ proposed: [String], kind: CapabilityKind,
        undeclared: FindingKind, noun: String
    ) -> [Finding] {
        var findings: [Finding] = []
        let before = Set(current)
        for id in proposed where !before.contains(id) {
            if manifest.isDeclared(id, as: kind) {
                findings.append(Finding(
                    kind: .enablesDeclaredCapability, subject: id, verdict: .shipWithChangelog,
                    explanation: "Turns on the reviewed \(noun) \"\(id)\". Inside the envelope; record it in the changelog."))
            } else {
                findings.append(Finding(
                    kind: undeclared, subject: id, verdict: .needsSubmission,
                    explanation: "The \(noun) \"\(id)\" is not in the \(manifest.appVersion) manifest. App Review has never seen it."))
            }
        }
        let after = Set(proposed)
        for id in current where !after.contains(id) {
            findings.append(Finding(
                kind: .removesCapability, subject: id, verdict: .shipAsConfig,
                explanation: "Turns off the \(noun) \"\(id)\". Shrinking behaviour is configuration."))
        }
        return findings
    }

    private func reviewModelTier(_ current: String, _ proposed: String) -> [Finding] {
        guard current != proposed else { return [] }
        if manifest.isDeclared(proposed, as: .modelTier) {
            return [Finding(
                kind: .enablesDeclaredCapability, subject: proposed, verdict: .shipWithChangelog,
                explanation: "Moves requests from \"\(current)\" to the reviewed tier \"\(proposed)\".")]
        }
        return [Finding(
            kind: .undeclaredModelTier, subject: proposed, verdict: .needsSubmission,
            explanation: "Sends user data to the tier \"\(proposed)\", which the manifest does not declare.")]
    }

    private func reviewFlags(_ current: RemoteBehavior, _ proposed: RemoteBehavior) -> [Finding] {
        var findings: [Finding] = []
        let wasOn = Set(current.enabledFlags)
        for flag in proposed.enabledFlags where !wasOn.contains(flag) {
            guard let unlocks = manifest.flagBindings[flag] else {
                findings.append(Finding(
                    kind: .undeclaredFlag, subject: flag, verdict: .needsSubmission,
                    explanation: "The flag \"\(flag)\" is not bound to any reviewed capability. A switch nobody documented is the textbook dormant feature."))
                continue
            }
            let missing = unlocks.filter { manifest.capability($0) == nil }
            if missing.isEmpty {
                findings.append(Finding(
                    kind: .enablesDeclaredCapability, subject: flag, verdict: .shipWithChangelog,
                    explanation: "Turns on \"\(flag)\", which unlocks only reviewed capabilities: \(unlocks.joined(separator: ", "))."))
            } else {
                findings.append(Finding(
                    kind: .flagUnlocksUndeclaredCapability, subject: flag, verdict: .needsSubmission,
                    explanation: "\"\(flag)\" unlocks \(missing.joined(separator: ", ")), which the manifest does not declare."))
            }
        }
        return findings
    }

    private func reviewPrompt(
        _ current: RemoteBehavior, _ proposed: RemoteBehavior, _ release: PromptRelease
    ) -> [Finding] {
        var findings: [Finding] = []
        let declaredTools = manifest.declared(.aiTool)
        for tool in PromptToolReferences.extract(from: proposed.promptText) where !declaredTools.contains(tool) {
            findings.append(Finding(
                kind: .promptReferencesUndeclaredTool, subject: tool, verdict: .needsSubmission,
                explanation: "The prompt tells the model about \"\(tool)\". Even before the tool ships, the prompt is advertising a capability App Review has not seen."))
        }

        let textChanged = current.promptText != proposed.promptText
        let versionChanged = current.promptID != proposed.promptID || current.promptVersion != proposed.promptVersion
        guard textChanged || versionChanged else { return findings }

        let subject = "\(proposed.promptID) v\(proposed.promptVersion)"
        if textChanged && !versionChanged {
            findings.append(Finding(
                kind: .promptEditedWithoutVersionBump, subject: subject, verdict: .blocked,
                explanation: "The prompt text changed but the version did not. Nobody can tell which prompt a user saw."))
        }
        let changelog = (release.changelog ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if changelog.isEmpty {
            findings.append(Finding(
                kind: .promptChangedWithoutChangelog, subject: subject, verdict: .blocked,
                explanation: "A prompt change is a behaviour change. It needs a changelog entry before it ships."))
        }
        guard let eval = release.eval else {
            findings.append(Finding(
                kind: .promptChangedWithoutEval, subject: subject, verdict: .blocked,
                explanation: "No eval run is attached. \"It read fine\" is not evidence."))
            return findings
        }
        guard let rate = eval.passRate else {
            findings.append(Finding(
                kind: .promptChangedWithoutEval, subject: subject, verdict: .blocked,
                explanation: "The eval run \"\(eval.suite)\" has no valid cases."))
            return findings
        }
        if rate + evalTolerance < eval.baselinePassRate {
            findings.append(Finding(
                kind: .evalRegressed, subject: subject, verdict: .blocked,
                explanation: "\(eval.suite): \(eval.passed)/\(eval.total) is below the production baseline \(percent(eval.baselinePassRate)) by more than \(percent(evalTolerance))."))
        } else {
            findings.append(Finding(
                kind: .promptChanged, subject: subject, verdict: .shipWithChangelog,
                explanation: "\(eval.suite): \(eval.passed)/\(eval.total) against a \(percent(eval.baselinePassRate)) baseline. Ship it as a prompt release."))
        }
        return findings
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
