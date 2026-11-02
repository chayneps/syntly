import Foundation
import AppKit
import CryptoKit

public enum LLMServiceError: LocalizedError {
    case noAuthenticationAvailable
    case invalidURL(String)
    case invalidResponse(String)
    case httpError(statusCode: Int, message: String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .noAuthenticationAvailable:
            return "Please configure your API endpoint and token in Settings."
        case .invalidURL(let msg):
            return "Invalid API URL: \(msg)"
        case .invalidResponse(let detail):
            return "Could not parse model response: \(detail)"
        case .httpError(let code, let msg):
            return "API HTTP \(code): \(msg)"
        case .networkError(let msg):
            return "Network error: \(msg)"
        }
    }
}

public typealias GeminiServiceError = LLMServiceError

public final class LLMService {
    public static let shared = LLMService()

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

    public static func cacheKey(
        for text: String,
        dialect: EnglishDialect,
        dictionary: [String],
        customInstruction: String = ""
    ) -> String {
        let dictJoined = dictionary.sorted().joined(separator: ",")
        let payload = "\(dialect.rawValue)|\(dictJoined)|\(customInstruction)|\(text)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func cachedIssues(for text: String) -> [WritingIssue]? {
        let key = Self.cacheKey(
            for: text,
            dialect: settings.dialect,
            dictionary: settings.personalDictionary,
            customInstruction: settings.customStyleInstruction
        )
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    public func storeCache(_ issues: [WritingIssue], for text: String) {
        let key = Self.cacheKey(
            for: text,
            dialect: settings.dialect,
            dictionary: settings.personalDictionary,
            customInstruction: settings.customStyleInstruction
        )
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

    public func proofread(text: String, model: String? = nil) async throws -> [WritingIssue] {
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

        let targetModel = model ?? settings.liveModel
        let rawJSON = try await generateJSON(prompt: prompt, model: targetModel, isProofreadSchema: true)
        let parsed = try Self.parseProofreadJSON(rawJSON)
        let resolved = Self.resolveIssues(parsed.issues, in: text, dictionary: settings.personalDictionary)

        storeCache(resolved, for: text)
        return resolved
    }

    // MARK: - Full Rewrite / Tone Adjustment

    public func rewrite(text: String, modifiers: Set<RewriteModifier>, customPrompt: String? = nil, model: String? = nil) async throws -> String {
        var instructions: [String] = []
        if let custom = customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            instructions.append(custom)
        }
        for modifier in RewriteModifier.allCases where modifiers.contains(modifier) {
            instructions.append(modifier.instruction)
        }
        if instructions.isEmpty {
            instructions.append("Improve clarity, flow, and natural phrasing while strictly preserving all original facts and intent.")
        }

        let taskDescription = instructions.count > 1
            ? "Tasks:\n" + instructions.map { "- \($0)" }.joined(separator: "\n")
            : "Task: \(instructions.first ?? "")"

        let styleLine = settings.customStyleInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : "\nAdditional user style / persona rule: \(settings.customStyleInstruction)"

        let prompt = """
        You are Synt(ax)ly, an expert writing assistant using \(settings.dialect.rawValue).
        \(taskDescription)\(styleLine)

        Guidelines:
        1. Preserve all core facts, numbers, dates, links, names, and original intent.
        2. Preserve formatting (bullet points, markdown, line breaks) where applicable unless bullet points are requested.
        3. Do NOT add conversational preamble, commentary, or quotes.

        Return ONLY valid JSON with this exact structure:
        {"rewrittenText": "<your rewritten text here>"}

        Text to rewrite:
        \"\"\"
        \(text)
        \"\"\"
        """

        let targetModel = model ?? settings.rewriteModel
        let rawJSON = try await generateJSON(prompt: prompt, model: targetModel, isProofreadSchema: true)
        return Self.extractRewrittenText(from: rawJSON)
    }

    public func rewrite(text: String, preset: RewritePreset, customPrompt: String? = nil, model: String? = nil) async throws -> String {
        let instruction = customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? customPrompt!
            : preset.instruction

        let styleLine = settings.customStyleInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : "\nAdditional user style rule: \(settings.customStyleInstruction)"

        let prompt = """
        You are Synt(ax)ly, an expert writing assistant using \(settings.dialect.rawValue).
        Task: \(instruction)\(styleLine)

        Guidelines:
        1. Preserve all core facts, numbers, dates, links, names, and original intent.
        2. Preserve formatting (bullet points, markdown, line breaks) where applicable.
        3. Do NOT add conversational preamble, commentary, or quotes.

        Return ONLY valid JSON with this exact structure:
        {"rewrittenText": "<your rewritten text here>"}

        Text to rewrite:
        \"\"\"
        \(text)
        \"\"\"
        """

        let targetModel = model ?? settings.rewriteModel
        let rawJSON = try await generateJSON(prompt: prompt, model: targetModel, isProofreadSchema: true)
        return Self.extractRewrittenText(from: rawJSON)
    }

    /// Robustly extracts the rewritten text string from LLM JSON responses, code fences, or plain text.
    public static func extractRewrittenText(from rawOutput: String) -> String {
        let cleaned = extractInnerModelJSON(from: rawOutput)

        // 1. Try decoding via ProofreadResult
        if let parsed = try? parseProofreadJSON(cleaned),
           let rewritten = parsed.rewrittenText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rewritten.isEmpty {
            return rewritten
        }

        // 2. Try JSONSerialization dictionary extraction
        if let data = cleaned.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let text = (obj["rewrittenText"] ?? obj["rewritten_text"] ?? obj["text"] ?? obj["result"] ?? obj["rewritten"] ?? obj["output"]) as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // 3. Try JSON object slice if wrapped in conversational prose
        if let firstBrace = cleaned.firstIndex(of: "{"),
           let lastBrace = cleaned.lastIndex(of: "}") {
            let slice = String(cleaned[firstBrace...lastBrace])
            if let sliceData = slice.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: sliceData) as? [String: Any] {
                if let text = (obj["rewrittenText"] ?? obj["rewritten_text"] ?? obj["text"] ?? obj["result"] ?? obj["rewritten"] ?? obj["output"]) as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        // 4. Regex fallback targeting "rewrittenText": "..."
        if let regex = try? NSRegularExpression(pattern: "\"rewrittenText\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"", options: .caseInsensitive),
           let match = regex.firstMatch(in: cleaned, options: [], range: NSRange(location: 0, length: (cleaned as NSString).length)) {
            let nsCleaned = cleaned as NSString
            let matchRange = match.range(at: 1)
            if matchRange.location != NSNotFound {
                let candidate = nsCleaned.substring(with: matchRange)
                let unescaped = candidate.replacingOccurrences(of: "\\\"", with: "\"")
                                         .replacingOccurrences(of: "\\n", with: "\n")
                if !unescaped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return unescaped.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        // 5. If it does not look like JSON, it is likely already raw text
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.hasPrefix("{") && !trimmed.hasPrefix("[") {
            return trimmed
        }

        return trimmed
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
        You are Synt(ax)ly, a high-precision real-time inline writing assistant for \(dialect.rawValue).
        Analyze the text below as the user types it and detect ONLY unambiguous errors or high-value improvements.
        \(dictLine)
        \(styleLine)

        CORE PRINCIPLES:
        1. High Precision & Minimal Edits: Fix genuine mistakes (spelling, grammar, punctuation, misused words). Do NOT rewrite casual, informal, or stylistic phrasing if it is already grammatically valid.
        2. In-Progress Typing Awareness: The user is actively typing in real-time. Do NOT flag sentence fragments, trailing clauses, or lack of final punctuation at the very end of the input if the sentence appears in-progress.
        3. Code & Identifier Immunity: Never flag or alter URLs, email addresses, file paths, code snippets, camelCase/snake_case variable names, markdown formatting, or @mentions.
        4. Unique Verbatim Matching: "original" MUST be an exact, case-sensitive substring from the input text. If a word appears multiple times, include 1–2 adjacent context words so "original" appears EXACTLY ONCE in the text.
        5. Drop-in Replacement: "replacement" MUST be the exact drop-in replacement for "original" with matching capitalization and punctuation.
        6. Concise Explanations: "explanation" must be a concise reason under 12 words (e.g. "Use contraction they're instead of possessive their").
        7. List Marker Immunity: Never include leading bullet symbols (•, ◦, ▪, -, *) or numbered list prefixes (1., 2.) in "original" or "replacement". Only include the words inside the list item.

        CATEGORIES:
        - "correctness": Objective spelling, grammar, punctuation, and subject-verb/tense errors.
        - "clarity": Wordy redundancy or confusing sentence structure.
        - "tone": Formality or politeness mismatches.
        - "fluency": Unnatural idioms or non-native phrasing.

        OUTPUT FORMAT:
        Output ONLY valid JSON matching this exact structure:
        {"issues": [{"original": "...", "replacement": "...", "category": "correctness|clarity|tone|fluency", "explanation": "..."}]}
        If there are no genuine errors, return: {"issues": []}

        Input text:
        \"\"\"
        \(text)
        \"\"\"
        """
    }

    public static func parseProofreadJSON(_ rawOutput: String) throws -> ProofreadResult {
        let cleaned = extractInnerModelJSON(from: rawOutput)
        guard let data = cleaned.data(using: .utf8) else {
            throw LLMServiceError.invalidResponse("Non-UTF8 output")
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
            throw LLMServiceError.invalidResponse(error.localizedDescription)
        }
    }

    /// Unwraps CLI outer envelope (`{"response": "..."}`) and strips markdown code fences.
    public static func extractInnerModelJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

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

    /// Strips leading bullet or numbered list markers if an LLM included the same prefix in both `original` and `replacement`.
    /// This prevents pasting duplicate bullets (`• • `) into rich-text list items and ensures `utf16Location` points to the words themselves.
    public static func stripSharedListMarkerPrefix(
        original: String,
        replacement: String
    ) -> (original: String, replacement: String) {
        let pattern = #"^(\s*(?:[•◦▪▫▸‣⁃\-\*\+☐☑✓✔]|(?:\d+|[a-zA-Z])[\.\)])\s+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return (original, replacement)
        }

        let nsOrig = original as NSString
        let nsRepl = replacement as NSString
        guard let origMatch = regex.firstMatch(in: original, options: [], range: NSRange(location: 0, length: nsOrig.length)),
              origMatch.range.location == 0,
              origMatch.range.length < nsOrig.length else {
            return (original, replacement)
        }

        let prefix = nsOrig.substring(with: origMatch.range)
        let strippedOrig = nsOrig.substring(from: origMatch.range.length)

        if replacement.hasPrefix(prefix), nsRepl.length > origMatch.range.length {
            let strippedRepl = nsRepl.substring(from: origMatch.range.length)
            return (strippedOrig, strippedRepl)
        }

        if let replMatch = regex.firstMatch(in: replacement, options: [], range: NSRange(location: 0, length: nsRepl.length)),
           replMatch.range.location == 0,
           replMatch.range.length < nsRepl.length {
            let strippedRepl = nsRepl.substring(from: replMatch.range.length)
            return (strippedOrig, strippedRepl)
        }

        return (original, replacement)
    }

    /// Resolves raw issues against the actual source text to compute UTF-16 `CFRange` offsets.
    public static func resolveIssues(
        _ rawIssues: [ProofreadResult.RawIssue],
        in sourceText: String,
        dictionary: [String]
    ) -> [WritingIssue] {
        let nsText = sourceText as NSString
        let normNsText = AXEngine.normalizeTypographicCharacters(sourceText) as NSString
        var results: [WritingIssue] = []
        var usedLocations = Set<Int>()

        for raw in rawIssues {
            let stripped = stripSharedListMarkerPrefix(original: raw.original, replacement: raw.replacement)
            let orig = stripped.original
            let repl = stripped.replacement
            let normOrig = AXEngine.normalizeTypographicCharacters(orig)
            guard !orig.isEmpty, orig != repl, normOrig != AXEngine.normalizeTypographicCharacters(repl) else { continue }

            // Skip if original is in personal dictionary
            if dictionary.contains(where: { $0.caseInsensitiveCompare(orig) == .orderedSame }) {
                continue
            }

            let category = IssueCategory(rawValue: raw.category.lowercased()) ?? .correctness

            // Find occurrence in sourceText, preferring whole-word boundary matches first
            var searchRange = NSRange(location: 0, length: normNsText.length)
            var matchedRange: NSRange?
            var fallbackPartialRange: NSRange?

            while searchRange.location < normNsText.length {
                let found = normNsText.range(of: normOrig, options: [], range: searchRange)
                guard found.location != NSNotFound else { break }
                if !usedLocations.contains(found.location) {
                    if AXEngine.isWholeWordMatch(range: found, of: normOrig, in: normNsText) {
                        matchedRange = found
                        usedLocations.insert(found.location)
                        break
                    } else if fallbackPartialRange == nil {
                        fallbackPartialRange = found
                    }
                }
                let nextLoc = found.location + max(1, found.length)
                searchRange = NSRange(location: nextLoc, length: normNsText.length - nextLoc)
            }

            if matchedRange == nil, let partial = fallbackPartialRange {
                matchedRange = partial
                usedLocations.insert(partial.location)
            }

            if let range = matchedRange {
                let actualOriginalInSource = nsText.substring(with: range)
                results.append(
                    WritingIssue(
                        original: actualOriginalInSource,
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

    // MARK: - URL Normalization (OpenAI Standard Format)

    public static func normalizeChatCompletionsURL(from endpoint: String) -> URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var base = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !base.lowercased().hasPrefix("http://") && !base.lowercased().hasPrefix("https://") {
            base = "http://" + base
        }

        if base.hasSuffix("/chat/completions") {
            return URL(string: base)
        }
        if base.hasSuffix("/v1") || base.hasSuffix("/v1beta/openai") || base.hasSuffix("/v1beta") {
            return URL(string: "\(base)/chat/completions")
        }
        return URL(string: "\(base)/v1/chat/completions")
    }

    public static func normalizeModelsURL(from endpoint: String) -> URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var base = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !base.lowercased().hasPrefix("http://") && !base.lowercased().hasPrefix("https://") {
            base = "http://" + base
        }

        if base.hasSuffix("/chat/completions") {
            base = String(base.dropLast("/chat/completions".count))
        }
        if base.hasSuffix("/v1") || base.hasSuffix("/v1beta/openai") || base.hasSuffix("/v1beta") {
            return URL(string: "\(base)/models")
        }
        return URL(string: "\(base)/v1/models")
    }

    // MARK: - Universal Model Dispatch (OpenAI Chat Completions Protocol)

    private func generateJSON(prompt: String, model: String, isProofreadSchema: Bool) async throws -> String {
        let endpoint = settings.apiEndpoint
        guard let url = Self.normalizeChatCompletionsURL(from: endpoint) else {
            throw LLMServiceError.invalidURL(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25

        if let token = settings.activeAPIToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You are Synt(ax)ly, an expert AI writing assistant. You must return valid JSON only."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.1,
            "response_format": ["type": "json_object"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMServiceError.invalidResponse("No HTTP response received from \(endpoint)")
        }

        // Graceful fallback: If server rejects response_format (HTTP 400), retry without it
        if http.statusCode == 400 {
            let errBody = String(data: data, encoding: .utf8) ?? ""
            if errBody.localizedCaseInsensitiveContains("response_format") {
                payload.removeValue(forKey: "response_format")
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                let (retryData, retryResp) = try await urlSession.data(for: request)
                if let retryHttp = retryResp as? HTTPURLResponse, (200...299).contains(retryHttp.statusCode) {
                    return try Self.parseContentFromAnyResponse(data: retryData)
                }
            }
        }

        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            let concise = Self.extractConciseErrorMessage(from: bodyText, statusCode: http.statusCode)
            throw LLMServiceError.httpError(statusCode: http.statusCode, message: concise)
        }

        return try Self.parseContentFromAnyResponse(data: data)
    }

    // MARK: - Multi-format Response Extractor

    public static func parseContentFromAnyResponse(data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8) ?? ""
            if !text.isEmpty {
                return extractInnerModelJSON(from: text)
            }
            throw LLMServiceError.invalidResponse("Empty or non-JSON response from API")
        }

        // 1. OpenAI Chat Completion format: choices[0].message.content
        if let choices = json["choices"] as? [[String: Any]], let first = choices.first {
            if let message = first["message"] as? [String: Any] {
                if let content = message["content"] as? String {
                    return extractInnerModelJSON(from: content)
                }
                if let contentArray = message["content"] as? [[String: Any]] {
                    let textParts = contentArray.compactMap { $0["text"] as? String }
                    if !textParts.isEmpty {
                        return extractInnerModelJSON(from: textParts.joined(separator: "\n"))
                    }
                }
            }
            if let text = first["text"] as? String {
                return extractInnerModelJSON(from: text)
            }
        }

        // 2. Google Gemini direct format: candidates[0].content.parts[0].text
        if let candidates = json["candidates"] as? [[String: Any]],
           let first = candidates.first,
           let content = first["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]],
           let text = parts.first?["text"] as? String {
            return extractInnerModelJSON(from: text)
        }

        // 3. Fallback: single "response" or "text" key
        if let responseStr = json["response"] as? String {
            return extractInnerModelJSON(from: responseStr)
        }
        if let textStr = json["text"] as? String {
            return extractInnerModelJSON(from: textStr)
        }

        let rawStr = String(data: data, encoding: .utf8) ?? ""
        return extractInnerModelJSON(from: rawStr)
    }

    // MARK: - Test Connection & Model Discovery

    public func testConnection(endpoint: String, token: String?, model: String) async -> ConnectionTestState {
        guard let url = Self.normalizeChatCompletionsURL(from: endpoint) else {
            return .failure(message: "Invalid endpoint URL: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8

        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": "Ping test. Respond with: {\"status\": \"ok\"}"]
            ],
            "max_tokens": 15
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failure(message: "Failed to serialize test payload")
        }
        request.httpBody = body

        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            let (data, response) = try await urlSession.data(for: request)
            let latencyMs = max(1, Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))
            guard let http = response as? HTTPURLResponse else {
                return .failure(message: "No HTTP response received")
            }

            if (200...299).contains(http.statusCode) {
                return .success(
                    latencyMs: latencyMs,
                    model: model,
                    details: "Connected in \(latencyMs)ms! Model '\(model)' is responding."
                )
            } else {
                let bodyStr = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                let concise = Self.extractConciseErrorMessage(from: bodyStr, statusCode: http.statusCode)
                return .failure(message: concise)
            }
        } catch {
            if let urlErr = error as? URLError {
                if urlErr.code == .cannotConnectToHost {
                    return .failure(message: "Could not connect to host at \(url.host ?? endpoint). Make sure your server/proxy is running.")
                } else if urlErr.code == .timedOut {
                    return .failure(message: "Connection timed out after 8s. Verify endpoint URL.")
                }
            }
            return .failure(message: error.localizedDescription)
        }
    }

    public func fetchAvailableModels(endpoint: String, token: String?) async throws -> [String] {
        guard let url = Self.normalizeModelsURL(from: endpoint) else {
            throw LLMServiceError.invalidURL(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6

        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let str = String(data: data, encoding: .utf8) ?? ""
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw LLMServiceError.httpError(statusCode: code, message: Self.extractConciseErrorMessage(from: str, statusCode: code))
        }

        var modelIDs: [String] = []
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // OpenAI format: {"data": [{"id": "model-id"}, ...]}
            if let list = json["data"] as? [[String: Any]] {
                for item in list {
                    if let id = item["id"] as? String, !id.isEmpty {
                        modelIDs.append(id)
                    }
                }
            }
            // Ollama format: {"models": [{"name": "model:tag"}, ...]}
            if let models = json["models"] as? [[String: Any]] {
                for item in models {
                    if let name = item["name"] as? String, !name.isEmpty {
                        modelIDs.append(name)
                    }
                }
            }
        }
        return modelIDs.sorted()
    }

    public static func extractConciseErrorMessage(from body: String, statusCode: Int) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errObj = json["error"] as? [String: Any], let msg = errObj["message"] as? String {
                return "HTTP \(statusCode): \(msg)"
            }
            if let errStr = json["error"] as? String {
                return "HTTP \(statusCode): \(errStr)"
            }
            if let msg = json["message"] as? String {
                return "HTTP \(statusCode): \(msg)"
            }
        }
        if statusCode == 401 {
            return "HTTP 401 Unauthorized: Invalid or missing API token."
        }
        if statusCode == 404 {
            return "HTTP 404 Not Found: Check endpoint URL or model name."
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 120 {
            return "HTTP \(statusCode): \(trimmed.prefix(120))…"
        }
        return "HTTP \(statusCode): \(trimmed)"
    }
}

// Backward-compatible alias
public typealias GeminiService = LLMService
