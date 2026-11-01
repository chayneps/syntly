import Foundation
import SwiftUI

// MARK: - Issue Categories (Color-Coded)

public enum IssueCategory: String, Codable, CaseIterable, Identifiable {
    case correctness = "correctness"
    case clarity = "clarity"
    case tone = "tone"
    case fluency = "fluency"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .correctness: return "Correctness"
        case .clarity: return "Clarity & Conciseness"
        case .tone: return "Tone & Delivery"
        case .fluency: return "Fluency"
        }
    }

    public var shortLabel: String {
        switch self {
        case .correctness: return "Correctness"
        case .clarity: return "Clarity"
        case .tone: return "Tone"
        case .fluency: return "Fluency"
        }
    }

    public var badgeColor: Color {
        switch self {
        case .correctness: return Color(red: 0.92, green: 0.26, blue: 0.24) // Red
        case .clarity: return Color(red: 0.18, green: 0.50, blue: 0.93)     // Blue
        case .tone: return Color(red: 0.58, green: 0.31, blue: 0.88)        // Purple
        case .fluency: return Color(red: 0.13, green: 0.68, blue: 0.46)     // Green
        }
    }

    public var iconName: String {
        switch self {
        case .correctness: return "checkmark.seal.fill"
        case .clarity: return "sparkles"
        case .tone: return "waveform.path.ecg"
        case .fluency: return "text.bubble.fill"
        }
    }
}

// MARK: - Writing Issue Model

public struct WritingIssue: Identifiable, Codable, Equatable {
    public let id: UUID
    public let original: String
    public let replacement: String
    public let category: IssueCategory
    public let explanation: String
    /// UTF-16 range (`CFRange`-compatible) in the source text if resolved
    public var utf16Location: Int?
    public var utf16Length: Int?
    public var isLocalSpellcheck: Bool

    public init(
        id: UUID = UUID(),
        original: String,
        replacement: String,
        category: IssueCategory,
        explanation: String,
        utf16Location: Int? = nil,
        utf16Length: Int? = nil,
        isLocalSpellcheck: Bool = false
    ) {
        self.id = id
        self.original = original
        self.replacement = replacement
        self.category = category
        self.explanation = explanation
        self.utf16Location = utf16Location
        self.utf16Length = utf16Length
        self.isLocalSpellcheck = isLocalSpellcheck
    }
}

// MARK: - Gemini Proofread Response Schema

public struct ProofreadResult: Codable, Equatable {
    public struct RawIssue: Codable, Equatable {
        public let original: String
        public let replacement: String
        public let category: String
        public let explanation: String

        public init(original: String, replacement: String, category: String, explanation: String) {
            self.original = original
            self.replacement = replacement
            self.category = category
            self.explanation = explanation
        }
    }

    public let issues: [RawIssue]
    public let rewrittenText: String?

    public init(issues: [RawIssue], rewrittenText: String? = nil) {
        self.issues = issues
        self.rewrittenText = rewrittenText
    }

    enum CodingKeys: String, CodingKey {
        case issues
        case rewrittenText
        case rewritten_text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Support both "rewrittenText" and "rewritten_text"
        if let text = try? container.decodeIfPresent(String.self, forKey: .rewrittenText) {
            self.rewrittenText = text
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .rewritten_text) {
            self.rewrittenText = text
        } else {
            self.rewrittenText = nil
        }

        // Resilient issues decoding: if issues is an array of RawIssue, decode it;
        // if it's an array of strings or missing/null, default to empty array []
        if let decodedIssues = try? container.decodeIfPresent([RawIssue].self, forKey: .issues) {
            self.issues = decodedIssues
        } else {
            self.issues = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(issues, forKey: .issues)
        try container.encodeIfPresent(rewrittenText, forKey: .rewrittenText)
    }
}

// MARK: - Rewrite Presets (On-Demand Selection Mode)

public enum RewriteModifier: String, CaseIterable, Identifiable, Codable {
    case makeConcise = "make_concise"
    case bulletPoints = "bullet_points"
    case beDirect = "be_direct"
    case soundNatural = "sound_natural"
    case fixOnly = "fix_only"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .makeConcise: return "Make Concise"
        case .bulletPoints: return "Bullet Points"
        case .beDirect: return "Be Direct"
        case .soundNatural: return "Sound Natural"
        case .fixOnly: return "Fix Only"
        }
    }

    public var iconName: String {
        switch self {
        case .makeConcise: return "arrow.down.right.and.arrow.up.left"
        case .bulletPoints: return "list.bullet"
        case .beDirect: return "bolt.fill"
        case .soundNatural: return "leaf.fill"
        case .fixOnly: return "checkmark.shield.fill"
        }
    }

    public var instruction: String {
        switch self {
        case .makeConcise:
            return "Make the text tight and concise by cutting unnecessary words, redundancies, and filler while preserving all facts and meaning."
        case .bulletPoints:
            return "Format the main points and message into clear, scannable bullet points."
        case .beDirect:
            return "Use an active, direct, and confident voice. Eliminate timid hedging, apologetic phrasing, and hesitation (e.g. 'I just wanted to check', 'maybe', 'I think')."
        case .soundNatural:
            return "Ensure phrasing and idioms flow smoothly and naturally to a native English speaker, fixing any awkward or stiff translations."
        case .fixOnly:
            return "Correct all spelling, punctuation, and grammar mistakes strictly without altering the author's original sentence structure or wording style."
        }
    }
}

public enum RewritePreset: String, CaseIterable, Identifiable {
    case fixGrammar = "fix_grammar"
    case concise = "concise"
    case professional = "professional"
    case friendly = "friendly"
    case natural = "natural"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fixGrammar: return "Fix Mistakes"
        case .concise: return "Make Concise"
        case .professional: return "Professional"
        case .friendly: return "Friendly"
        case .natural: return "Sound Natural"
        }
    }

    public var iconName: String {
        switch self {
        case .fixGrammar: return "wand.and.stars"
        case .concise: return "arrow.down.right.and.arrow.up.left"
        case .professional: return "briefcase.fill"
        case .friendly: return "face.smiling.fill"
        case .natural: return "leaf.fill"
        }
    }

    public var instruction: String {
        switch self {
        case .fixGrammar:
            return "Fix all grammar, spelling, and punctuation mistakes while preserving the author's original voice and meaning."
        case .concise:
            return "Rewrite this text to be clear, tight, and concise by removing unnecessary filler words while keeping the exact meaning."
        case .professional:
            return "Rewrite this text in a polished, confident, and professional tone suitable for workplace communication."
        case .friendly:
            return "Rewrite this text in a warm, approachable, and friendly tone."
        case .natural:
            return "Rewrite this text so that it reads smoothly and naturally to a native English speaker."
        }
    }
}

// MARK: - API Provider Preset

public enum APIProviderPreset: String, CaseIterable, Identifiable, Codable {
    case cliProxy = "cli_proxy"
    case lmStudio = "lm_studio"
    case ollama = "ollama"
    case kiro = "kiro"
    case openAI = "openai"
    case openRouter = "openrouter"
    case googleAI = "google_ai"
    case custom = "custom"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cliProxy: return "CLI Proxy API (127.0.0.1:8317)"
        case .lmStudio: return "LM Studio (localhost:1234)"
        case .ollama: return "Ollama (localhost:11434)"
        case .kiro: return "Kiro Gateway"
        case .openAI: return "OpenAI Official"
        case .openRouter: return "OpenRouter"
        case .googleAI: return "Google AI Studio (OpenAI-compatible)"
        case .custom: return "Custom OpenAI Endpoint"
        }
    }

    public var defaultEndpoint: String {
        switch self {
        case .cliProxy: return "http://127.0.0.1:8317/v1"
        case .lmStudio: return "http://localhost:1234/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .kiro: return "https://api.kirogateway.com/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .googleAI: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .custom: return "http://127.0.0.1:8000/v1"
        }
    }

    public var defaultModel: String {
        switch self {
        case .cliProxy: return "gemini-3.8-flash-high"
        case .lmStudio: return "default"
        case .ollama: return "llama3.2"
        case .kiro: return "gpt-4o-mini"
        case .openAI: return "gpt-4o-mini"
        case .openRouter: return "google/gemini-2.5-flash"
        case .googleAI: return "gemini-2.5-flash"
        case .custom: return "gpt-4o-mini"
        }
    }

    public var requiresToken: Bool {
        switch self {
        case .lmStudio, .ollama:
            return false
        default:
            return true
        }
    }
}

// MARK: - Connection Test State

public struct ModelTestResult: Identifiable, Equatable, Sendable {
    public var id: String { "\(role)-\(model)" }
    public let role: String
    public let model: String
    public let latencyMs: Int
    public let isSuccess: Bool
    public let errorMessage: String?

    public init(role: String, model: String, latencyMs: Int, isSuccess: Bool, errorMessage: String? = nil) {
        self.role = role
        self.model = model
        self.latencyMs = latencyMs
        self.isSuccess = isSuccess
        self.errorMessage = errorMessage
    }
}

public enum ConnectionTestState: Equatable, Sendable {
    case idle
    case testing(message: String)
    case success(latencyMs: Int, model: String, details: String)
    case completed(results: [ModelTestResult])
    case failure(message: String)

    public static var testing: ConnectionTestState {
        .testing(message: "Testing endpoint…")
    }

    public var isTesting: Bool {
        if case .testing = self { return true }
        return false
    }
}

// MARK: - Authentication Provider Mode (Backward Compatibility)

public enum AuthProviderMode: String, CaseIterable, Identifiable, Codable {
    case auto = "auto"
    case cliProxy = "cli_proxy"
    case geminiCLI = "gemini_cli"
    case apiKey = "api_key"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Automatic"
        case .cliProxy: return "OpenAI-compatible / CLI Proxy API"
        case .geminiCLI: return "Gemini CLI"
        case .apiKey: return "Direct API Key"
        }
    }
}

// MARK: - English Dialect

public enum EnglishDialect: String, CaseIterable, Identifiable, Codable {
    case us = "American English (US)"
    case uk = "British English (UK)"
    case ca = "Canadian English (CA)"
    case au = "Australian English (AU)"

    public var id: String { rawValue }
}

// MARK: - Floating Pill Visual State

public enum PillVisualState: Equatable {
    case allClear
    case checking
    case issuesFound(count: Int, topCategory: IssueCategory)
    case paused(reason: String)
    case error(message: String)
}

// MARK: - Per-App Floating Pill Offset

public struct AppPillOffset: Codable, Equatable, Sendable {
    public var dx: CGFloat
    public var dy: CGFloat

    public init(dx: CGFloat, dy: CGFloat) {
        self.dx = dx
        self.dy = dy
    }
}

// MARK: - Saved Writing Style Rule

public struct SavedStyleRule: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var instruction: String

    public init(id: UUID = UUID(), name: String, instruction: String) {
        self.id = id
        self.name = name
        self.instruction = instruction
    }
}
