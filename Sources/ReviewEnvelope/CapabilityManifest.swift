import Foundation

/// What kind of thing a capability is.
///
/// The four kinds are the four ways an AI feature's behaviour can change
/// from a server without a new binary: a user-facing feature, a tool the
/// model may call, a slice of user data the model may read, and the model
/// tier the request is sent to.
public enum CapabilityKind: String, Codable, Sendable, CaseIterable {
    case feature
    case aiTool
    case dataScope
    case modelTier
}

/// One reviewed capability: something the app can do that App Review has
/// been told about, in words an end user would also understand.
public struct Capability: Codable, Hashable, Sendable, Identifiable {
    /// Stable identifier, e.g. `"search_transactions"`. Remote payloads refer
    /// to capabilities by this id.
    public let id: String
    public let kind: CapabilityKind
    /// One sentence a user (and a reviewer) can read.
    public let summary: String
    /// How a reviewer reaches it. Required for `.feature`.
    public let reviewerSteps: String?

    public init(id: String, kind: CapabilityKind, summary: String, reviewerSteps: String? = nil) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.reviewerSteps = reviewerSteps
    }
}

/// The reviewed envelope for one app version: every capability the app may
/// ever turn on remotely, plus every remote flag and the capabilities it is
/// allowed to unlock.
///
/// The manifest is compiled into the binary and pasted into App Review notes,
/// so the server and the reviewer are looking at the same list.
public struct CapabilityManifest: Codable, Sendable {
    public let appVersion: String
    public let capabilities: [Capability]
    /// Remote flag name → ids of the capabilities that flag may unlock.
    public let flagBindings: [String: [String]]

    public init(appVersion: String, capabilities: [Capability], flagBindings: [String: [String]] = [:]) {
        self.appVersion = appVersion
        self.capabilities = capabilities
        self.flagBindings = flagBindings
    }

    /// Ids of every declared capability of one kind.
    public func declared(_ kind: CapabilityKind) -> Set<String> {
        Set(capabilities.filter { $0.kind == kind }.map(\.id))
    }

    public func isDeclared(_ id: String, as kind: CapabilityKind) -> Bool {
        capabilities.contains { $0.id == id && $0.kind == kind }
    }

    public func capability(_ id: String) -> Capability? {
        capabilities.first { $0.id == id }
    }

    /// The first declared model tier. The runtime guard falls back to it.
    public var defaultModelTier: String? {
        capabilities.first { $0.kind == .modelTier }?.id
    }

    /// Problems that make the manifest itself unreviewable.
    public func validate() -> [ManifestProblem] {
        var problems: [ManifestProblem] = []
        var seen: Set<String> = []
        for capability in capabilities {
            if !seen.insert(capability.id).inserted {
                problems.append(.duplicateID(capability.id))
            }
            if capability.kind == .feature,
               (capability.reviewerSteps ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append(.featureWithoutReviewerSteps(capability.id))
            }
        }
        for flag in flagBindings.keys.sorted() {
            for id in flagBindings[flag] ?? [] where capability(id) == nil {
                problems.append(.flagBindsUnknownCapability(flag: flag, capability: id))
            }
        }
        if defaultModelTier == nil {
            problems.append(.noModelTier)
        }
        return problems
    }
}

public enum ManifestProblem: Equatable, Sendable, CustomStringConvertible {
    case duplicateID(String)
    case featureWithoutReviewerSteps(String)
    case flagBindsUnknownCapability(flag: String, capability: String)
    case noModelTier

    public var description: String {
        switch self {
        case .duplicateID(let id):
            return "Capability id \"\(id)\" is declared twice."
        case .featureWithoutReviewerSteps(let id):
            return "Feature \"\(id)\" has no reviewer steps, so App Review cannot reach it."
        case .flagBindsUnknownCapability(let flag, let id):
            return "Flag \"\(flag)\" unlocks \"\(id)\", which the manifest does not declare."
        case .noModelTier:
            return "No model tier is declared, so the runtime guard has nothing to fall back to."
        }
    }
}

/// What changed between the manifest App Review last saw and this build's.
/// The `added` list is the "new in this version" paragraph of the review notes.
public struct ManifestDiff: Equatable, Sendable {
    public let added: [Capability]
    public let removed: [Capability]

    public init(from old: CapabilityManifest, to new: CapabilityManifest) {
        let oldIDs = Set(old.capabilities.map(\.id))
        let newIDs = Set(new.capabilities.map(\.id))
        added = new.capabilities.filter { !oldIDs.contains($0.id) }
        removed = old.capabilities.filter { !newIDs.contains($0.id) }
    }
}
