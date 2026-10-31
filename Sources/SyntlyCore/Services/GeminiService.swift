import Foundation
import AppKit
import CryptoKit

public enum GeminiServiceError: LocalizedError {
    case noAuthenticationAvailable
    case invalidResponse(String)
    case httpError(statusCode: Int, message: String)
    case cliError(String)

    public var errorDescription: String? {
        switch self {
        case .noAuthenticationAvailable:
            return "Please connect your free Google Gemini API key above to start checking your writing."
        case .invalidResponse(let detail):
            return "Could not parse Gemini response: \(detail)"
        case .httpError(let code, let msg):
            return "Gemini API HTTP \(code): \(msg)"
        case .cliError(let msg):
            return "Gemini CLI error: \(msg)"
        }
    }
}

public final class GeminiService {
    public static let shared = GeminiService()

    private let settings: AppSettings
    private let urlSession: URLSession
    private var cache: [String: [WritingIssue]] = [:]
    private let cacheLock = NSLock()
    private let maxCacheEntries = 200

    public init(settings: AppSettings = .shared, urlSession: URLSession = .shared) {
        self.settings = settings
        self.urlSession = urlSession
    }

    // MARK: - SHA-256 Paragraph Cache

    public static func cacheKey(for text: String, dialect: EnglishDialect, dictionary: [String]) -> String {
        let dictJoined = dictionary.sorted().joined(separator: ",")
        let payload = "\(dialect.rawValue)|\(dictJoined)|\(text)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func cachedIssues(for text: String) -> [WritingIssue]? {
        let key = Self.cacheKey(for: text, dialect: settings.dialect, dictionary: settings.personalDictionary)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    public func storeCache(_ issues: [WritingIssue], for text: String) {
        let key = Self.cacheKey(for: text, dialect: settings.dialect, dictionary: settings.personalDictionary)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if cache.count >= maxCacheEntries, let firstKey = cache.keys.first {
            cache.removeValue(forKey: firstKey)
        }
        cache[key] = issues
    }

    public func clearCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.removeAll()
    }

    // MARK: - Instant Local Spellcheck Pass (<5ms)

    public func runLocalSpellcheck(on text: String) -> [WritingIssue] {
        guard settings.enableLocalSpellcheck else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return [] }

        let checker = NSSpellChecker.shared
        let nsString = text as NSString
        var issues: [WritingIssue] = []
        var searchOffset = 0

        while searchOffset < nsString.length {
            let misspelledRange = checker.checkSpelling(
                of: text,
                startingAt: searchOffset,
                language: nil,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            )

            guard misspelledRange.location != NSNotFound, misspelledRange.length > 0 else {
                break
            }

            let word = nsString.substring(with: misspelledRange)
            searchOffset = misspelledRange.location + misspelledRange.length

            // Skip words in personal dictionary
            if settings.personalDictionary.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
                continue
            }

            let guesses = checker.guesses(
                forWordRange: misspelledRange,
                in: text,
                language: nil,
                inSpellDocumentWithTag: 0
            ) ?? []

            if let topGuess = guesses.first, topGuess != word {
                issues.append(
                    WritingIssue(
                        original: word,
                        replacement: topGuess,
                        category: .correctness,
                        explanation: "Possible spelling mistake.",
                        utf16Location: misspelledRange.location,
                        utf16Length: misspelledRange.length,
                        isLocalSpellcheck: true
                    )
                )
            }
        }

        return issues
    }

    // MARK: - Live Proofread (Structured JSON Issues)

    public func proofread(text: String) async throws -> [WritingIssue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return [] }

        if let cached = cachedIssues(for: text) {
            return cached
        }

        let prompt = Self.buildProofreadPrompt(
            text: text,
            dialect: settings.dialect,
            personalDictionary: settings.personalDictionary,
            customInstruction: settings.customStyleInstruction
        )

        let rawJSON = try await generateJSON(prompt: prompt, model: settings.liveModel, isProofreadSchema: true)
        let parsed = try Self.parseProofreadJSON(rawJSON)
        let resolved = Self.resolveIssues(parsed.issues, in: text, dictionary: settings.personalDictionary)

        storeCache(resolved, for: text)
        return resolved
    }

    // MARK: - Full Rewrite / Tone Adjustment

    public func rewrite(text: String, preset: RewritePreset, customPrompt: String? = nil) async throws -> String {
        let instruction = customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? customPrompt!
            : preset.instruction

        let prompt = """
        You are Syntly, an expert writing assistant using \(settings.dialect.rawValue).
        Task: \(instruction)

        Return ONLY valid JSON with this exact structure:
        {"issues": [], "rewrittenText": "<your rewritten text here>"}

        Text to rewrite:
        \"\"\"
        \(text)
        \"\"\"
        """

        let rawJSON = try await generateJSON(prompt: prompt, model: settings.rewriteModel, isProofreadSchema: true)
        if let parsed = try? Self.parseProofreadJSON(rawJSON),
           let rewritten = parsed.rewrittenText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rewritten.isEmpty {
            return rewritten
        }

        return Self.stripCodeFences(rawJSON).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Prompt Builder & JSON Parser

    public static func buildProofreadPrompt(
        text: String,
        dialect: EnglishDialect,
        personalDictionary: [String],
        customInstruction: String
    ) -> String {
        let dictLine = personalDictionary.isEmpty
            ? ""
            : "Never flag these custom dictionary words: \(personalDictionary.joined(separator: ", "))."
        let styleLine = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : "Additional user preference: \(customInstruction)"

        return """
        You are Syntly, a real-time inline writing assistant for \(dialect.rawValue).
        Analyze the user's text as they type and identify genuine mistakes or high-value improvements.
        \(dictLine)
        \(styleLine)

        Rules:
        1. Each issue's "original" field MUST be an exact, verbatim substring from the input text (include 1-3 surrounding words if a single word appears multiple times so its location is unambiguous).
        2. "replacement" MUST be the exact drop-in replacement for "original".
        3. "category" MUST be one of: "correctness", "clarity", "tone", "fluency".
        4. "explanation" MUST be a concise 1-sentence reason (under 15 words).
        5. If the text has no issues, return {"issues": []}.
        6. Output ONLY valid JSON matching:
        {"issues": [{"original": "...", "replacement": "...", "category": "correctness|clarity|tone|fluency", "explanation": "..."}]}

        Input text:
        \"\"\"
        \(text)
        \"\"\"
        """
    }

    public static func parseProofreadJSON(_ rawOutput: String) throws -> ProofreadResult {
        let cleaned = extractInnerModelJSON(from: rawOutput)
        guard let data = cleaned.data(using: .utf8) else {
            throw GeminiServiceError.invalidResponse("Non-UTF8 output")
        }

        do {
            return try JSONDecoder().decode(ProofreadResult.self, from: data)
        } catch {
            // Try extracting the first `{ ... }` JSON object if surrounded by prose
            if let firstBrace = cleaned.firstIndex(of: "{"),
               let lastBrace = cleaned.lastIndex(of: "}") {
                let slice = String(cleaned[firstBrace...lastBrace])
                if let sliceData = slice.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(ProofreadResult.self, from: sliceData) {
                    return decoded
                }
            }
            throw GeminiServiceError.invalidResponse(error.localizedDescription)
        }
    }

    /// Unwraps Gemini CLI `-o json` outer envelope (`{"response": "..."}`) and strips markdown code fences.
    public static func extractInnerModelJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if this is a Gemini CLI JSON envelope: {"response": "..."}
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let responseStr = obj["response"] as? String {
            return stripCodeFences(responseStr)
        }

        return stripCodeFences(trimmed)
    }

    public static func stripCodeFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            if let firstNewline = result.firstIndex(of: "\n") {
                result = String(result[result.index(after: firstNewline)...])
            }
            if result.hasSuffix("```") {
                result = String(result.dropLast(3))
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolves raw issues against the actual source text to compute UTF-16 `CFRange` offsets.
    public static func resolveIssues(
        _ rawIssues: [ProofreadResult.RawIssue],
        in sourceText: String,
        dictionary: [String]
    ) -> [WritingIssue] {
        let nsText = sourceText as NSString
        var results: [WritingIssue] = []
        var usedLocations = Set<Int>()

        for raw in rawIssues {
            let orig = raw.original
            let repl = raw.replacement
            guard !orig.isEmpty, orig != repl else { continue }

            // Skip if original is in personal dictionary
            if dictionary.contains(where: { $0.caseInsensitiveCompare(orig) == .orderedSame }) {
                continue
            }

            let category = IssueCategory(rawValue: raw.category.lowercased()) ?? .correctness

            // Find occurrence in sourceText
            var searchRange = NSRange(location: 0, length: nsText.length)
            var matchedRange: NSRange?

            while searchRange.location < nsText.length {
                let found = nsText.range(of: orig, options: [], range: searchRange)
                guard found.location != NSNotFound else { break }
                if !usedLocations.contains(found.location) {
                    matchedRange = found
                    usedLocations.insert(found.location)
                    break
                }
                let nextLoc = found.location + max(1, found.length)
                searchRange = NSRange(location: nextLoc, length: nsText.length - nextLoc)
            }

            if let range = matchedRange {
                results.append(
                    WritingIssue(
                        original: orig,
                        replacement: repl,
                        category: category,
                        explanation: raw.explanation,
                        utf16Location: range.location,
                        utf16Length: range.length,
                        isLocalSpellcheck: false
                    )
                )
            }
        }

        return results.sorted { ($0.utf16Location ?? 0) < ($1.utf16Location ?? 0) }
    }

    // MARK: - Transport Dispatch (REST API + Gemini CLI Bridge)

    private func generateJSON(prompt: String, model: String, isProofreadSchema: Bool) async throws -> String {
        let apiKey = settings.activeAPIKey()
        let cliPath = settings.detectedGeminiCLIPath ?? AppSettings.locateGeminiBinary()

        switch settings.authMode {
        case .apiKey:
            guard let key = apiKey else {
                throw GeminiServiceError.noAuthenticationAvailable
            }
            return try await callDirectREST(prompt: prompt, model: model, apiKey: key, isProofreadSchema: isProofreadSchema)

        case .geminiCLI:
            guard let path = cliPath else {
                throw GeminiServiceError.noAuthenticationAvailable
            }
            return try await callGeminiCLI(prompt: prompt, model: model, binaryPath: path)

        case .auto:
            if let key = apiKey, !key.isEmpty {
                return try await callDirectREST(prompt: prompt, model: model, apiKey: key, isProofreadSchema: isProofreadSchema)
            } else {
                throw GeminiServiceError.noAuthenticationAvailable
            }
        }
    }

    // MARK: - Direct Gemini REST API (`generativelanguage.googleapis.com`)

    private func callDirectREST(
        prompt: String,
        model: String,
        apiKey: String,
        isProofreadSchema: Bool
    ) async throws -> String {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw GeminiServiceError.invalidResponse("Malformed URL")
        }

        var generationConfig: [String: Any] = [
            "temperature": 0.1,
            "responseMimeType": "application/json"
        ]

        if isProofreadSchema {
            generationConfig["responseSchema"] = [
                "type": "OBJECT",
                "properties": [
                    "issues": [
                        "type": "ARRAY",
                        "items": [
                            "type": "OBJECT",
                            "properties": [
                                "original": ["type": "STRING"],
                                "replacement": ["type": "STRING"],
                                "category": ["type": "STRING"],
                                "explanation": ["type": "STRING"]
                            ],
                            "required": ["original", "replacement", "category", "explanation"]
                        ]
                    ],
                    "rewrittenText": ["type": "STRING"]
                ],
                "required": ["issues"]
            ]
        }

        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": prompt]]
                ]
            ],
            "generationConfig": generationConfig
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiServiceError.invalidResponse("No HTTP response")
        }

        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GeminiServiceError.httpError(statusCode: http.statusCode, message: bodyText)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw GeminiServiceError.invalidResponse("Missing candidate text in REST response")
        }

        return text
    }

    // MARK: - Local Gemini CLI Bridge (Single-Turn, Zero Tools)

    private func callGeminiCLI(prompt: String, model: String, binaryPath: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binaryPath)
                // Run in non-interactive headless JSON mode with extensions disabled so 1 check = 1 request
                process.arguments = [
                    "-m", model,
                    "-p", prompt,
                    "-o", "json",
                    "-e", "none"
                ]

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let outStr = String(data: outData, encoding: .utf8) ?? ""
                    let errStr = String(data: errData, encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 && !outStr.isEmpty {
                        continuation.resume(returning: outStr)
                    } else {
                        continuation.resume(throwing: GeminiServiceError.cliError(errStr.isEmpty ? outStr : errStr))
                    }
                } catch {
                    continuation.resume(throwing: GeminiServiceError.cliError(error.localizedDescription))
                }
            }
        }
    }
}
