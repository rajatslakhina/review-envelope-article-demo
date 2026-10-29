/// Everything the server can change about the AI feature without a new
/// binary: the system prompt, the tools the model may call, the data it may
/// read, the model tier, and feature flags.
public struct RemoteBehavior: Codable, Hashable, Sendable {
    public var promptID: String
    public var promptVersion: Int
    public var promptText: String
    public var tools: [String]
    public var dataScopes: [String]
    public var modelTier: String
    public var flags: [String: Bool]

    public init(
        promptID: String,
        promptVersion: Int,
        promptText: String,
        tools: [String],
        dataScopes: [String],
        modelTier: String,
        flags: [String: Bool] = [:]
    ) {
        self.promptID = promptID
        self.promptVersion = promptVersion
        self.promptText = promptText
        self.tools = tools
        self.dataScopes = dataScopes
        self.modelTier = modelTier
        self.flags = flags
    }

    /// Flags that are on, sorted for stable output.
    public var enabledFlags: [String] {
        flags.filter(\.value).map(\.key).sorted()
    }
}

/// The evidence attached to a prompt change. A prompt is shipped like a
/// release, so it needs release notes and a passing eval run.
public struct PromptRelease: Codable, Hashable, Sendable {
    public var changelog: String?
    public var eval: EvalResult?

    public init(changelog: String? = nil, eval: EvalResult? = nil) {
        self.changelog = changelog
        self.eval = eval
    }

    public static let none = PromptRelease()
}

/// One eval-suite run against the proposed prompt.
public struct EvalResult: Codable, Hashable, Sendable {
    public let suite: String
    public let passed: Int
    public let total: Int
    /// Pass rate of the prompt currently in production on the same suite.
    public let baselinePassRate: Double

    public init(suite: String, passed: Int, total: Int, baselinePassRate: Double) {
        self.suite = suite
        self.passed = passed
        self.total = total
        self.baselinePassRate = baselinePassRate
    }

    /// `nil` when the suite ran zero cases: an empty run is not evidence.
    public var passRate: Double? {
        guard total > 0, passed >= 0, passed <= total else { return nil }
        return Double(passed) / Double(total)
    }
}

/// Finds tool-shaped identifiers the prompt text names in backticks, such as
/// `` `pay_bill` ``. A prompt that tells the model about a tool is pointing at
/// a capability even if the tool list hasn't changed yet.
public enum PromptToolReferences {
    public static func extract(from prompt: String) -> [String] {
        let segments = prompt.split(separator: "`", omittingEmptySubsequences: false)
        var found: [String] = []
        // Odd-indexed segments sit between a pair of backticks.
        for (index, segment) in segments.enumerated() where index % 2 == 1 && index < segments.count - 1 {
            let word = String(segment)
            if isToolShaped(word), !found.contains(word) {
                found.append(word)
            }
        }
        return found
    }

    /// snake_case with at least one underscore: lowercase letters, digits, `_`.
    static func isToolShaped(_ word: String) -> Bool {
        guard word.contains("_"), let first = word.first, first.isLetter, first.isLowercase else {
            return false
        }
        return word.allSatisfy { ($0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "_" }
    }
}
