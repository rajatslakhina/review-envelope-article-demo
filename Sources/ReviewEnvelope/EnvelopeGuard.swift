/// The client half of the policy. The classifier stops a bad change before
/// it ships. The guard makes sure that a bad change that ships anyway (a
/// typo in a console, a compromised config service, an eager teammate) still
/// cannot turn on behaviour the binary was never reviewed with.
///
/// It fails closed: anything not in the compiled-in manifest is dropped.
public struct EnvelopeGuard: Sendable {
    public let manifest: CapabilityManifest

    public init(manifest: CapabilityManifest) {
        self.manifest = manifest
    }

    public struct Dropped: Hashable, Sendable {
        public let kind: FindingKind
        public let subject: String
    }

    public struct Admission: Sendable {
        /// The behaviour the app will actually run.
        public let admitted: RemoteBehavior
        /// What the server asked for that the binary refused.
        public let dropped: [Dropped]

        public var isClean: Bool { dropped.isEmpty }
    }

    public func admit(_ payload: RemoteBehavior) -> Admission {
        var admitted = payload
        var dropped: [Dropped] = []

        let tools = manifest.declared(.aiTool)
        admitted.tools = payload.tools.filter { tools.contains($0) }
        dropped += payload.tools.filter { !tools.contains($0) }.map { Dropped(kind: .undeclaredTool, subject: $0) }

        let scopes = manifest.declared(.dataScope)
        admitted.dataScopes = payload.dataScopes.filter { scopes.contains($0) }
        dropped += payload.dataScopes.filter { !scopes.contains($0) }.map { Dropped(kind: .undeclaredDataScope, subject: $0) }

        if !manifest.isDeclared(payload.modelTier, as: .modelTier) {
            dropped.append(Dropped(kind: .undeclaredModelTier, subject: payload.modelTier))
            // validate() reports a manifest with no tier; an empty string makes
            // the AI client refuse to send rather than pick a tier itself.
            admitted.modelTier = manifest.defaultModelTier ?? ""
        }

        var flags: [String: Bool] = [:]
        for (flag, isOn) in payload.flags {
            guard isOn else {
                flags[flag] = false
                continue
            }
            guard let unlocks = manifest.flagBindings[flag] else {
                flags[flag] = false
                dropped.append(Dropped(kind: .undeclaredFlag, subject: flag))
                continue
            }
            if unlocks.allSatisfy({ manifest.capability($0) != nil }) {
                flags[flag] = true
            } else {
                flags[flag] = false
                dropped.append(Dropped(kind: .flagUnlocksUndeclaredCapability, subject: flag))
            }
        }
        admitted.flags = flags

        return Admission(admitted: admitted, dropped: dropped.sorted { $0.subject < $1.subject })
    }
}
