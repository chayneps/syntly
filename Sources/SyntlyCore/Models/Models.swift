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
}

// MARK: - Rewrite Presets (On-Demand Selection Mode)

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

// MARK: - Authentication Provider Mode

public enum AuthProviderMode: String, CaseIterable, Identifiable, Codable {
    case auto = "auto"
    case geminiCLI = "gemini_cli"
    case apiKey = "api_key"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Automatic (API Key if set, otherwise Gemini CLI)"
        case .geminiCLI: return "Local Gemini CLI (Google Account / Subscription)"
        case .apiKey: return "Google AI Studio API Key (Direct REST)"
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
