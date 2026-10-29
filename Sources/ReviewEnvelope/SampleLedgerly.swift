import Foundation

/// A fictional personal-finance app, Ledgerly, with an AI assistant. The
/// demo app and the tests both use it, so every number on screen is asserted.
public enum SampleLedgerly {
    /// What App Review was told about Ledgerly 3.1.
    public static let reviewedLastVersion = CapabilityManifest(
        appVersion: "3.1",
        capabilities: [
            Capability(id: "assistant", kind: .feature,
                       summary: "Ask Ledgerly: a chat assistant that answers questions about your own transactions.",
                       reviewerSteps: "Sign in with the demo account in the notes, then tap the Ask tab."),
            Capability(id: "search_transactions", kind: .aiTool,
                       summary: "Search your transactions by merchant, amount or date."),
            Capability(id: "categorize_transaction", kind: .aiTool,
                       summary: "Suggest a category for a transaction. You confirm before it changes."),
            Capability(id: "transactions", kind: .dataScope,
                       summary: "Your transaction history on this device."),
            Capability(id: "on_device", kind: .modelTier,
                       summary: "Apple's on-device model. Nothing leaves the phone."),
            Capability(id: "cloud_standard", kind: .modelTier,
                       summary: "A cloud model under our no-training, 30-day-retention agreement."),
        ],
        flagBindings: ["assistant_enabled": ["assistant"]]
    )

    /// What this build (3.2) declares. Budget suggestions are new.
    public static let manifest = CapabilityManifest(
        appVersion: "3.2",
        capabilities: reviewedLastVersion.capabilities + [
            Capability(id: "budget_suggestions", kind: .feature,
                       summary: "The assistant can propose a monthly budget. Nothing is saved until you tap Accept.",
                       reviewerSteps: "Ask tab → \"Suggest a budget for groceries\"."),
            Capability(id: "create_budget", kind: .aiTool,
                       summary: "Draft a budget for you to accept or discard."),
            Capability(id: "budgets", kind: .dataScope,
                       summary: "Your existing budgets."),
        ],
        flagBindings: [
            "assistant_enabled": ["assistant"],
            "budget_suggestions": ["budget_suggestions", "create_budget"],
        ]
    )

    static let promptV13 = """
    You are Ledgerly's assistant. Answer only about the user's own transactions. \
    Use `search_transactions` to look things up and `categorize_transaction` to suggest a category. \
    Be brief.
    """

    /// What production is running right now.
    public static let production = RemoteBehavior(
        promptID: "assistant-system",
        promptVersion: 13,
        promptText: promptV13,
        tools: ["search_transactions", "categorize_transaction"],
        dataScopes: ["transactions"],
        modelTier: "cloud_standard",
        flags: ["assistant_enabled": true, "budget_suggestions": false]
    )

    public struct Scenario: Identifiable, Sendable {
        public let id: Int
        public let title: String
        public let pitch: String
        public let proposed: RemoteBehavior
        public let release: PromptRelease
    }

    public static let scenarios: [Scenario] = {
        var reword = production
        reword.promptVersion = 14
        reword.promptText = promptV13.replacingOccurrences(of: "Be brief.", with: "Lead with the number, then one sentence of context.")

        var hotfix = production
        hotfix.promptText = promptV13 + " Never mention competitors."

        var budgets = production
        budgets.tools += ["create_budget"]
        budgets.dataScopes += ["budgets"]
        budgets.flags["budget_suggestions"] = true

        var payBills = production
        payBills.promptVersion = 14
        payBills.promptText = promptV13 + " When the user asks, use `pay_bill` to pay a saved payee."
        payBills.tools += ["pay_bill"]
        payBills.dataScopes += ["payees"]
        payBills.flags["agent_mode"] = true

        var frontier = production
        frontier.modelTier = "cloud_frontier"

        return [
            Scenario(id: 1, title: "Reword the answer style",
                     pitch: "Prompt v14 leads with the number. Eval attached.",
                     proposed: reword,
                     release: PromptRelease(changelog: "v14: answers lead with the figure.",
                                            eval: EvalResult(suite: "assistant-golden", passed: 47, total: 50, baselinePassRate: 0.92))),
            Scenario(id: 2, title: "Hotfix the prompt in place",
                     pitch: "One sentence appended to v13 on a Friday night.",
                     proposed: hotfix, release: .none),
            Scenario(id: 3, title: "Turn on budget suggestions",
                     pitch: "Flip the flag that 3.2's review notes describe.",
                     proposed: budgets,
                     release: PromptRelease(changelog: "Budget suggestions on for all 3.2 users.")),
            Scenario(id: 4, title: "Let the assistant pay bills",
                     pitch: "New tool, new data, new flag. All from the server.",
                     proposed: payBills,
                     release: PromptRelease(changelog: "Agent mode: pay bills from chat.",
                                            eval: EvalResult(suite: "assistant-golden", passed: 48, total: 50, baselinePassRate: 0.92))),
            Scenario(id: 5, title: "Move to a frontier model",
                     pitch: "Same prompt, different processor for user data.",
                     proposed: frontier, release: .none),
        ]
    }()
}
