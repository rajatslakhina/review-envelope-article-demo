/// Renders the manifest as a plain-text appendix for the Notes for Review
/// field in App Store Connect, so the reviewer reads the same list the
/// server and the runtime guard enforce.
public enum ReviewNotes {
    public static func render(_ manifest: CapabilityManifest, since previous: CapabilityManifest? = nil) -> String {
        var lines: [String] = []
        lines.append("REMOTELY CONFIGURABLE BEHAVIOUR (\(manifest.appVersion))")
        lines.append("The server can change the AI assistant's prompt, tools, data access, model tier and flags.")
        lines.append("It can only choose from the list below; the app ignores anything else.")

        if let previous {
            let diff = ManifestDiff(from: previous, to: manifest)
            lines.append("")
            lines.append("NEW SINCE \(previous.appVersion)")
            if diff.added.isEmpty {
                lines.append("- Nothing new.")
            } else {
                for capability in diff.added {
                    lines.append("- \(capability.id): \(capability.summary)")
                }
            }
        }

        let sections: [(CapabilityKind, String)] = [
            (.feature, "FEATURES"),
            (.aiTool, "TOOLS THE AI CAN CALL"),
            (.dataScope, "DATA THE AI CAN READ"),
            (.modelTier, "WHERE REQUESTS ARE PROCESSED"),
        ]
        for (kind, heading) in sections {
            let items = manifest.capabilities.filter { $0.kind == kind }
            guard !items.isEmpty else { continue }
            lines.append("")
            lines.append(heading)
            for item in items {
                lines.append("- \(item.id): \(item.summary)")
                if let steps = item.reviewerSteps, !steps.isEmpty {
                    lines.append("  To reach it: \(steps)")
                }
            }
        }

        if !manifest.flagBindings.isEmpty {
            lines.append("")
            lines.append("REMOTE FLAGS")
            for flag in manifest.flagBindings.keys.sorted() {
                let unlocks = (manifest.flagBindings[flag] ?? []).joined(separator: ", ")
                lines.append("- \(flag) unlocks: \(unlocks)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
