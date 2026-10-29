import XCTest
@testable import ReviewEnvelope

final class ManifestTests: XCTestCase {
    func testSampleManifestIsValid() {
        XCTAssertEqual(SampleLedgerly.manifest.validate(), [])
        XCTAssertEqual(SampleLedgerly.reviewedLastVersion.validate(), [])
    }

    func testValidateCatchesDuplicatesMissingStepsUnknownBindingsAndNoTier() {
        let manifest = CapabilityManifest(
            appVersion: "x",
            capabilities: [
                Capability(id: "a", kind: .feature, summary: "A", reviewerSteps: "  "),
                Capability(id: "a", kind: .aiTool, summary: "dup"),
            ],
            flagBindings: ["f": ["ghost"]]
        )
        XCTAssertEqual(manifest.validate(), [
            .featureWithoutReviewerSteps("a"),
            .duplicateID("a"),
            .flagBindsUnknownCapability(flag: "f", capability: "ghost"),
            .noModelTier,
        ])
    }

    func testDiffListsExactlyTheNewCapabilities() {
        let diff = ManifestDiff(from: SampleLedgerly.reviewedLastVersion, to: SampleLedgerly.manifest)
        XCTAssertEqual(diff.added.map(\.id), ["budget_suggestions", "create_budget", "budgets"])
        XCTAssertEqual(diff.removed, [])
    }

    func testReviewNotesNameEveryCapabilityFlagAndWhatIsNew() {
        let notes = ReviewNotes.render(SampleLedgerly.manifest, since: SampleLedgerly.reviewedLastVersion)
        for capability in SampleLedgerly.manifest.capabilities {
            XCTAssertTrue(notes.contains("- \(capability.id): "), capability.id)
        }
        XCTAssertTrue(notes.contains("NEW SINCE 3.1"))
        XCTAssertTrue(notes.contains("- budget_suggestions unlocks: budget_suggestions, create_budget"))
        XCTAssertTrue(notes.contains("To reach it: Sign in with the demo account"))
    }
}

final class ClassifierTests: XCTestCase {
    let classifier = EnvelopeClassifier(manifest: SampleLedgerly.manifest)

    private func review(_ id: Int) -> ChangeReview {
        guard let scenario = SampleLedgerly.scenarios.first(where: { $0.id == id }) else {
            XCTFail("missing scenario \(id)")
            return ChangeReview(findings: [])
        }
        return classifier.review(current: SampleLedgerly.production, proposed: scenario.proposed, release: scenario.release)
    }

    func testNoChangeHasNoFindings() {
        let result = classifier.review(current: SampleLedgerly.production, proposed: SampleLedgerly.production)
        XCTAssertEqual(result.findings, [])
        XCTAssertEqual(result.verdict, .shipAsConfig)
    }

    func testScenarioVerdicts() {
        XCTAssertEqual(SampleLedgerly.scenarios.map { review($0.id).verdict },
                       [.shipWithChangelog, .blocked, .shipWithChangelog, .needsSubmission, .needsSubmission])
    }

    func testRewordWithPassingEvalIsAPromptRelease() {
        XCTAssertEqual(review(1).findings.map(\.kind), [.promptChanged])
    }

    func testInPlaceHotfixIsBlockedThreeWays() {
        XCTAssertEqual(review(2).findings.map(\.kind),
                       [.promptEditedWithoutVersionBump, .promptChangedWithoutChangelog, .promptChangedWithoutEval])
    }

    func testFlagForADeclaredFeatureIsInsideTheEnvelope() {
        let findings = review(3).findings
        XCTAssertEqual(findings.count, 3)
        XCTAssertTrue(findings.allSatisfy { $0.kind == .enablesDeclaredCapability && $0.verdict == .shipWithChangelog })
    }

    func testPayBillsIsANewFeatureEvenWithAPassingEval() {
        let findings = review(4).findings
        let outside = findings.filter { $0.verdict == .needsSubmission }
        XCTAssertEqual(Set(outside.map(\.kind)),
                       [.undeclaredTool, .undeclaredDataScope, .undeclaredFlag, .promptReferencesUndeclaredTool])
        XCTAssertEqual(outside.count, 4)
        // The eval passed, and that changes nothing about the verdict.
        XCTAssertTrue(findings.contains { $0.kind == .promptChanged && $0.verdict == .shipWithChangelog })
    }

    func testUndeclaredModelTierNeedsSubmissionButDeclaredTierIsChangelog() {
        XCTAssertEqual(review(5).findings.map(\.kind), [.undeclaredModelTier])
        var onDevice = SampleLedgerly.production
        onDevice.modelTier = "on_device"
        XCTAssertEqual(classifier.review(current: SampleLedgerly.production, proposed: onDevice).verdict, .shipWithChangelog)
    }

    func testRemovingAToolIsConfiguration() {
        var smaller = SampleLedgerly.production
        smaller.tools = ["search_transactions"]
        let result = classifier.review(current: SampleLedgerly.production, proposed: smaller)
        XCTAssertEqual(result.findings.map(\.kind), [.removesCapability])
        XCTAssertEqual(result.verdict, .shipAsConfig)
    }

    func testEvalRegressionBeyondToleranceBlocks() {
        var next = SampleLedgerly.production
        next.promptVersion = 14
        next.promptText += " Add an emoji."
        let bad = PromptRelease(changelog: "emoji", eval: EvalResult(suite: "s", passed: 44, total: 50, baselinePassRate: 0.92))
        XCTAssertEqual(classifier.review(current: SampleLedgerly.production, proposed: next, release: bad).findings.map(\.kind), [.evalRegressed])
        // Exactly at the tolerance edge (0.90 vs 0.92 with 0.02) still ships.
        let edge = PromptRelease(changelog: "emoji", eval: EvalResult(suite: "s", passed: 45, total: 50, baselinePassRate: 0.92))
        XCTAssertEqual(classifier.review(current: SampleLedgerly.production, proposed: next, release: edge).verdict, .shipWithChangelog)
    }

    func testEmptyEvalRunIsNotEvidence() {
        var next = SampleLedgerly.production
        next.promptVersion = 14
        next.promptText += " x"
        let empty = PromptRelease(changelog: "x", eval: EvalResult(suite: "s", passed: 0, total: 0, baselinePassRate: 0.9))
        let result = classifier.review(current: SampleLedgerly.production, proposed: next, release: empty)
        XCTAssertEqual(result.findings.map(\.kind), [.promptChangedWithoutEval])
        XCTAssertNil(EvalResult(suite: "s", passed: 6, total: 5, baselinePassRate: 1).passRate)
    }

    func testFlagBoundToUndeclaredCapabilityNeedsSubmission() {
        let manifest = CapabilityManifest(
            appVersion: "t",
            capabilities: SampleLedgerly.manifest.capabilities,
            flagBindings: ["sneaky": ["assistant", "pay_bill"]]
        )
        var next = SampleLedgerly.production
        next.flags["sneaky"] = true
        let result = EnvelopeClassifier(manifest: manifest).review(current: SampleLedgerly.production, proposed: next)
        XCTAssertEqual(result.findings.map(\.kind), [.flagUnlocksUndeclaredCapability])
        XCTAssertTrue(result.findings.first?.explanation.contains("pay_bill") ?? false)
    }
}

final class PromptReferenceTests: XCTestCase {
    func testExtractsOnlyBacktickedSnakeCase() {
        let prompt = "Use `pay_bill` or `search_transactions`, never `Pay_Bill`, `x`, `go` or pay_bill bare. `pay_bill` again. Trailing `open_end"
        XCTAssertEqual(PromptToolReferences.extract(from: prompt), ["pay_bill", "search_transactions"])
    }

    func testEmptyAndUnbalancedInput() {
        XCTAssertEqual(PromptToolReferences.extract(from: ""), [])
        XCTAssertEqual(PromptToolReferences.extract(from: "`"), [])
        XCTAssertEqual(PromptToolReferences.extract(from: "``"), [])
    }
}

final class GuardTests: XCTestCase {
    let guardrail = EnvelopeGuard(manifest: SampleLedgerly.manifest)

    func testProductionIsAdmittedUnchanged() {
        let admission = guardrail.admit(SampleLedgerly.production)
        XCTAssertTrue(admission.isClean)
        XCTAssertEqual(admission.admitted, SampleLedgerly.production)
    }

    func testPayBillsPayloadIsStrippedToTheEnvelope() {
        guard let payload = SampleLedgerly.scenarios.first(where: { $0.id == 4 })?.proposed else {
            return XCTFail("missing scenario")
        }
        let admission = guardrail.admit(payload)
        XCTAssertEqual(admission.dropped.map(\.subject), ["agent_mode", "pay_bill", "payees"])
        XCTAssertEqual(admission.admitted.tools, ["search_transactions", "categorize_transaction"])
        XCTAssertEqual(admission.admitted.dataScopes, ["transactions"])
        XCTAssertEqual(admission.admitted.flags["agent_mode"], false)
        XCTAssertEqual(admission.admitted.flags["assistant_enabled"], true)
    }

    func testUndeclaredTierFallsBackToTheFirstDeclaredTier() {
        var payload = SampleLedgerly.production
        payload.modelTier = "cloud_frontier"
        let admission = guardrail.admit(payload)
        XCTAssertEqual(admission.admitted.modelTier, "on_device")
        XCTAssertEqual(admission.dropped.map(\.kind), [.undeclaredModelTier])
    }

    func testManifestWithoutTiersRefusesToPickOne() {
        let bare = EnvelopeGuard(manifest: CapabilityManifest(appVersion: "0", capabilities: []))
        XCTAssertEqual(bare.admit(SampleLedgerly.production).admitted.modelTier, "")
    }
}
