import SwiftUI
import ReviewEnvelope

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Launch arguments drive the screenshots in CI:
/// `-tab envelope|changes|guard` and `-scenario 1...5`.
struct RootView: View {
    @State private var tab: String = UserDefaults.standard.string(forKey: "tab") ?? "changes"

    var body: some View {
        TabView(selection: $tab) {
            ChangesView()
                .tabItem { Label("Changes", systemImage: "arrow.triangle.branch") }
                .tag("changes")
            EnvelopeView()
                .tabItem { Label("Envelope", systemImage: "checklist") }
                .tag("envelope")
            GuardView()
                .tabItem { Label("Guard", systemImage: "lock.shield") }
                .tag("guard")
        }
    }
}

extension Verdict {
    var color: Color {
        switch self {
        case .shipAsConfig: return .green
        case .shipWithChangelog: return .teal
        case .blocked: return .orange
        case .needsSubmission: return .red
        }
    }

    var symbol: String {
        switch self {
        case .shipAsConfig: return "checkmark.circle.fill"
        case .shipWithChangelog: return "doc.badge.plus"
        case .blocked: return "exclamationmark.triangle.fill"
        case .needsSubmission: return "xmark.octagon.fill"
        }
    }
}

struct VerdictBadge: View {
    let verdict: Verdict
    var body: some View {
        Label(verdict.title, systemImage: verdict.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(verdict.color)
    }
}

// MARK: - Changes

struct ChangesView: View {
    private let classifier = EnvelopeClassifier(manifest: SampleLedgerly.manifest)
    @State private var path: [Int] = {
        let id = UserDefaults.standard.integer(forKey: "scenario")
        return SampleLedgerly.scenarios.contains { $0.id == id } ? [id] : []
    }()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(SampleLedgerly.scenarios) { scenario in
                        NavigationLink(value: scenario.id) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(scenario.title).font(.headline)
                                Text(scenario.pitch).font(.subheadline).foregroundStyle(.secondary)
                                VerdictBadge(verdict: review(scenario).verdict)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    Text("Proposed server changes vs. the 3.2 envelope")
                } footer: {
                    Text("Same question for every change: is it inside what App Review was told, and is there evidence it does what the changelog says?")
                }
            }
            .navigationTitle("Ledgerly 3.2")
            .navigationDestination(for: Int.self) { id in
                if let scenario = SampleLedgerly.scenarios.first(where: { $0.id == id }) {
                    ScenarioDetail(scenario: scenario, review: review(scenario))
                }
            }
        }
    }

    private func review(_ scenario: SampleLedgerly.Scenario) -> ChangeReview {
        classifier.review(current: SampleLedgerly.production, proposed: scenario.proposed, release: scenario.release)
    }
}

struct ScenarioDetail: View {
    let scenario: SampleLedgerly.Scenario
    let review: ChangeReview

    var body: some View {
        List {
            Section {
                VerdictBadge(verdict: review.verdict).font(.headline)
                Text(scenario.pitch)
            }
            Section("Findings (\(review.findings.count))") {
                ForEach(Array(review.findings.enumerated()), id: \.offset) { _, finding in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: finding.verdict.symbol).foregroundStyle(finding.verdict.color)
                            Text(finding.subject).font(.subheadline.monospaced().weight(.semibold))
                        }
                        Text(finding.explanation).font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle(scenario.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Envelope

struct EnvelopeView: View {
    private let manifest = SampleLedgerly.manifest
    private let added = Set(ManifestDiff(from: SampleLedgerly.reviewedLastVersion, to: SampleLedgerly.manifest).added.map(\.id))

    var body: some View {
        NavigationStack {
            List {
                ForEach(CapabilityKind.allCases, id: \.self) { kind in
                    Section(title(kind)) {
                        ForEach(manifest.capabilities.filter { $0.kind == kind }) { capability in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(capability.id).font(.subheadline.monospaced().weight(.semibold))
                                    if added.contains(capability.id) {
                                        Text("NEW IN 3.2")
                                            .font(.caption2.weight(.bold))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.15), in: Capsule())
                                    }
                                }
                                Text(capability.summary).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Remote flags") {
                    ForEach(manifest.flagBindings.keys.sorted(), id: \.self) { flag in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(flag).font(.subheadline.monospaced().weight(.semibold))
                            Text("unlocks " + (manifest.flagBindings[flag] ?? []).joined(separator: ", "))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Notes for Review appendix") {
                    Text(ReviewNotes.render(manifest, since: SampleLedgerly.reviewedLastVersion))
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Reviewed envelope")
        }
    }

    private func title(_ kind: CapabilityKind) -> String {
        switch kind {
        case .feature: return "Features"
        case .aiTool: return "Tools the AI can call"
        case .dataScope: return "Data the AI can read"
        case .modelTier: return "Where requests run"
        }
    }
}

// MARK: - Guard

struct GuardView: View {
    private let guardrail = EnvelopeGuard(manifest: SampleLedgerly.manifest)
    private let payload = SampleLedgerly.scenarios.first { $0.id == 4 }?.proposed ?? SampleLedgerly.production

    var body: some View {
        let admission = guardrail.admit(payload)
        NavigationStack {
            List {
                Section {
                    Text("The server shipped \"Let the assistant pay bills\" anyway. This is what the 3.2 binary does with it.")
                        .font(.subheadline)
                }
                Section("Server asked for") {
                    row("tools", payload.tools)
                    row("data", payload.dataScopes)
                    row("flags on", payload.enabledFlags)
                }
                Section("Binary refused (\(admission.dropped.count))") {
                    ForEach(admission.dropped, id: \.self) { item in
                        HStack {
                            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                            Text(item.subject).font(.subheadline.monospaced().weight(.semibold))
                            Spacer()
                            Text(item.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("App actually runs") {
                    row("tools", admission.admitted.tools)
                    row("data", admission.admitted.dataScopes)
                    row("flags on", admission.admitted.enabledFlags)
                    row("model", [admission.admitted.modelTier])
                }
            }
            .navigationTitle("Runtime guard")
        }
    }

    private func row(_ label: String, _ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(values.isEmpty ? "none" : values.joined(separator: ", ")).font(.footnote.monospaced())
        }
    }
}
