import XCTest
@testable import SyntlyCore

// MARK: - Mock URLProtocol for End-to-End Gemini API Pipeline Tests

final class MockGeminiURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var capturedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        Self.capturedRequests.append(request)
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - 1. Unit Tests

final class SyntlyUnitTests: XCTestCase {

    func testParseDirectProofreadJSON() throws {
        let json = """
        {
          "issues": [
            {
              "original": "their going",
              "replacement": "they're going",
              "category": "correctness",
              "explanation": "Use the contraction 'they're' instead of 'their'."
            }
          ]
        }
        """

        let parsed = try GeminiService.parseProofreadJSON(json)
        XCTAssertEqual(parsed.issues.count, 1)
        XCTAssertEqual(parsed.issues.first?.original, "their going")
        XCTAssertEqual(parsed.issues.first?.replacement, "they're going")
        XCTAssertEqual(parsed.issues.first?.category, "correctness")
    }

    func testParseGeminiCLIEnvelopeWithCodeFences() throws {
        let cliEnvelope = """
        {
          "response": "```json\\n{\\"issues\\": [{\\"original\\": \\"discuss about\\", \\"replacement\\": \\"discuss\\", \\"category\\": \\"fluency\\", \\"explanation\\": \\"Remove redundant preposition.\\"}]}\\n```"
        }
        """

        let parsed = try GeminiService.parseProofreadJSON(cliEnvelope)
        XCTAssertEqual(parsed.issues.count, 1)
        XCTAssertEqual(parsed.issues.first?.original, "discuss about")
        XCTAssertEqual(parsed.issues.first?.replacement, "discuss")
        XCTAssertEqual(parsed.issues.first?.category, "fluency")
    }

    func testParseJSONEmbeddedInProseAndMalformedError() throws {
        let proseWrapped = """
        Here is the analysis:
        {"issues": [{"original": "due to the fact that", "replacement": "because", "category": "clarity", "explanation": "More concise."}], "rewrittenText": "Because we care."}
        Hope that helps!
        """
        let parsed = try GeminiService.parseProofreadJSON(proseWrapped)
        XCTAssertEqual(parsed.issues.count, 1)
        XCTAssertEqual(parsed.issues.first?.category, "clarity")
        XCTAssertEqual(parsed.rewrittenText, "Because we care.")

        XCTAssertThrowsError(try GeminiService.parseProofreadJSON("not valid json at all"))
    }

    func testExtractRewrittenTextFromVariousFormats() {
        // 1. User's exact bug scenario: model returned array of strings for "issues"
        let withStringIssues = """
        {"issues": ["The greeting and question lack proper capitalization, punctuation, and grammatical structure."], "rewrittenText": "Hi, how can I help?"}
        """
        XCTAssertEqual(GeminiService.extractRewrittenText(from: withStringIssues), "Hi, how can I help?")

        // 2. Wrapped in Markdown code fences
        let withCodeFences = """
        ```json
        {"rewrittenText": "Let me know if you need anything else."}
        ```
        """
        XCTAssertEqual(GeminiService.extractRewrittenText(from: withCodeFences), "Let me know if you need anything else.")

        // 3. Snake_case key
        let withSnakeCase = """
        {"rewritten_text": "Here is the summary."}
        """
        XCTAssertEqual(GeminiService.extractRewrittenText(from: withSnakeCase), "Here is the summary.")

        // 4. Raw plain text (already unformatted)
        let plainText = "Simple plain sentence with no JSON at all."
        XCTAssertEqual(GeminiService.extractRewrittenText(from: plainText), "Simple plain sentence with no JSON at all.")
    }

    func testResolveIssuesUTF16RangesAndDictionaryFilter() {
        let source = "Hello Syntly, their going to discuss about the roadmap."
        let rawIssues = [
            ProofreadResult.RawIssue(
                original: "Syntly",
                replacement: "Shortly",
                category: "correctness",
                explanation: "Unrecognized word."
            ),
            ProofreadResult.RawIssue(
                original: "their going",
                replacement: "they're going",
                category: "correctness",
                explanation: "Use they're."
            ),
            ProofreadResult.RawIssue(
                original: "discuss about",
                replacement: "discuss",
                category: "fluency",
                explanation: "Drop 'about'."
            )
        ]

        let resolved = GeminiService.resolveIssues(rawIssues, in: source, dictionary: ["Syntly"])
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[0].original, "their going")
        XCTAssertEqual(resolved[0].utf16Location, 14)
        XCTAssertEqual(resolved[0].utf16Length, 11)

        XCTAssertEqual(resolved[1].original, "discuss about")
        XCTAssertEqual(resolved[1].category, .fluency)
    }

    func testResolveIssuesHandlesEmojiUTF16OffsetsAndDuplicateOccurrences() {
        // 🚀 is 2 UTF-16 code units (surrogate pair). AXUIElement CFRange uses UTF-16 offsets.
        let source = "🚀 Launch: teh first test and teh second test."
        let rawIssues = [
            ProofreadResult.RawIssue(
                original: "teh",
                replacement: "the",
                category: "correctness",
                explanation: "Typo."
            ),
            ProofreadResult.RawIssue(
                original: "teh",
                replacement: "the",
                category: "correctness",
                explanation: "Typo."
            ),
            ProofreadResult.RawIssue(
                original: "unchanged",
                replacement: "unchanged",
                category: "clarity",
                explanation: "No-op should be ignored."
            )
        ]

        let resolved = GeminiService.resolveIssues(rawIssues, in: source, dictionary: [])
        XCTAssertEqual(resolved.count, 2)

        let nsSource = source as NSString
        let firstRange = NSRange(location: resolved[0].utf16Location!, length: resolved[0].utf16Length!)
        let secondRange = NSRange(location: resolved[1].utf16Location!, length: resolved[1].utf16Length!)

        XCTAssertNotEqual(firstRange.location, secondRange.location, "Duplicate occurrences must resolve to distinct UTF-16 offsets")
        XCTAssertEqual(nsSource.substring(with: firstRange), "teh")
        XCTAssertEqual(nsSource.substring(with: secondRange), "teh")
        XCTAssertEqual(firstRange.location, 11) // "🚀" (2) + " Launch: " (9) = 11
    }

    func testParagraphCacheStoreAndInvalidationOnDialectOrDictionaryChange() {
        let settings = AppSettings()
        settings.dialect = .us
        settings.personalDictionary = ["Syntly"]

        let service = GeminiService(settings: settings)
        service.clearCache()

        let sample = "This sentence has an typo."
        XCTAssertNil(service.cachedIssues(for: sample))

        let issue = WritingIssue(
            original: "an typo",
            replacement: "a typo",
            category: .correctness,
            explanation: "Use 'a' before consonant sounds."
        )
        service.storeCache([issue], for: sample)
        XCTAssertEqual(service.cachedIssues(for: sample)?.count, 1)

        // Changing dialect must produce a distinct cache key
        settings.dialect = .uk
        XCTAssertNil(service.cachedIssues(for: sample))
    }

    func testFocusedTextContextExtractsActiveParagraphByCursor() {
        let multiParagraph = "First paragraph is clean.\nSecond paragraph has their going mistake.\nThird paragraph."
        // Place cursor inside the second paragraph (index 35)
        let ctx = FocusedTextContext(
            appName: "Notes",
            bundleID: "com.apple.Notes",
            pid: 1234,
            fullText: multiParagraph,
            selectedText: nil,
            selectedRange: NSRange(location: 35, length: 0)
        )

        XCTAssertEqual(ctx.activeParagraph, "Second paragraph has their going mistake.\n")
    }

    func testAppSettingsDictionaryBlocklistAndPauseLifecycle() {
        let settings = AppSettings()

        // Personal dictionary case-insensitive deduplication
        let initialCount = settings.personalDictionary.count
        settings.addWordToDictionary("Kubernetes")
        settings.addWordToDictionary("kubernetes")
        XCTAssertEqual(settings.personalDictionary.filter { $0.lowercased() == "kubernetes" }.count, 1)
        settings.removeWordFromDictionary("KUBERNETES")
        XCTAssertEqual(settings.personalDictionary.count, initialCount)

        // Per-app blocklist toggle
        let testBundle = "com.example.testapp"
        XCTAssertFalse(settings.isAppBlocked(bundleID: testBundle))
        settings.toggleAppBlocked(bundleID: testBundle)
        XCTAssertTrue(settings.isAppBlocked(bundleID: testBundle))
        settings.toggleAppBlocked(bundleID: testBundle)
        XCTAssertFalse(settings.isAppBlocked(bundleID: testBundle))

        // Pause / Resume lifecycle
        settings.pauseForOneHour()
        XCTAssertTrue(settings.isCurrentlyPaused())
        settings.resumeMonitoring()
        XCTAssertFalse(settings.isCurrentlyPaused())

        // Per-app pill drag offset memory
        settings.resetAllPillOffsets()
        XCTAssertNil(settings.pillOffset(for: "com.google.Chrome"))
        XCTAssertNil(settings.pillOffset(for: "com.apple.Notes"))

        let chromeOffset = AppPillOffset(dx: -80, dy: 15)
        let notesOffset = AppPillOffset(dx: 20, dy: -40)

        settings.setPillOffset(chromeOffset, for: "com.google.Chrome")
        settings.setPillOffset(notesOffset, for: "com.apple.Notes")

        XCTAssertEqual(settings.pillOffset(for: "com.google.Chrome"), chromeOffset)
        XCTAssertEqual(settings.pillOffset(for: "com.apple.Notes"), notesOffset)
        XCTAssertEqual(settings.appPillOffsets.count, 2)

        // Reset single app offset
        settings.resetPillOffset(for: "com.google.Chrome")
        XCTAssertNil(settings.pillOffset(for: "com.google.Chrome"))
        XCTAssertEqual(settings.pillOffset(for: "com.apple.Notes"), notesOffset)

        // Reset all offsets
        settings.resetAllPillOffsets()
        XCTAssertEqual(settings.appPillOffsets.count, 0)
        XCTAssertNil(settings.pillOffset(for: "com.apple.Notes"))

        // Dock icon & launch at login persistence
        let currentDock = settings.showDockIcon
        settings.showDockIcon = !currentDock
        XCTAssertEqual(settings.showDockIcon, !currentDock)
        settings.showDockIcon = currentDock

        let currentLaunch = settings.launchAtLoginState
        settings.setLaunchAtLogin(!currentLaunch)
        settings.setLaunchAtLogin(currentLaunch)

        // Pill size setting, defaults to compact (original size), and scales cleanly
        XCTAssertEqual(settings.pillSize, .compact)
        XCTAssertEqual(PillSize.compact.iconSize, 20.0)
        XCTAssertEqual(PillSize.compact.panelSize, 32.0)
        XCTAssertEqual(PillSize.medium.iconSize, 26.0)
        XCTAssertEqual(PillSize.medium.panelSize, 40.0)
        XCTAssertEqual(PillSize.large.iconSize, 34.0)
        XCTAssertEqual(PillSize.large.panelSize, 48.0)

        settings.pillSize = .large
        XCTAssertEqual(settings.pillSize, .large)
        settings.pillSize = .compact
        XCTAssertEqual(settings.pillSize, .compact)
    }

    func testMultiModelTestResultsState() {
        let liveResult = ModelTestResult(
            role: "As-You-Type Model",
            model: "gemini-3.5-flash-lite",
            latencyMs: 120,
            isSuccess: true
        )
        let rewriteResult = ModelTestResult(
            role: "Dialog & Rewrite Model",
            model: "gemini-3.8-flash-high",
            latencyMs: 340,
            isSuccess: true
        )
        let failedResult = ModelTestResult(
            role: "Dialog & Rewrite Model",
            model: "invalid-model",
            latencyMs: 0,
            isSuccess: false,
            errorMessage: "404 Not Found"
        )

        XCTAssertEqual(liveResult.id, "As-You-Type Model-gemini-3.5-flash-lite")
        XCTAssertTrue(liveResult.isSuccess)
        XCTAssertEqual(liveResult.latencyMs, 120)

        let successState = ConnectionTestState.completed(results: [liveResult, rewriteResult])
        if case .completed(let results) = successState {
            XCTAssertEqual(results.count, 2)
            XCTAssertTrue(results.allSatisfy { $0.isSuccess })
        } else {
            XCTFail("Expected .completed state")
        }

        let mixedState = ConnectionTestState.completed(results: [liveResult, failedResult])
        if case .completed(let results) = mixedState {
            XCTAssertEqual(results.count, 2)
            XCTAssertFalse(results.allSatisfy { $0.isSuccess })
            XCTAssertTrue(results.contains { $0.isSuccess })
            XCTAssertEqual(results[1].errorMessage, "404 Not Found")
        } else {
            XCTFail("Expected .completed state")
        }
    }

    func testMacOSNLPEngineActiveWordCaretProtection() {
        // User is actively typing "Let try" at the end of the line (caret is at UTF-16 index 7, right after 'y')
        let inProgressText = "Let try"
        let activeRange = MacOSNLPEngine.activeTypingWordRange(in: inProgressText, caretUTF16Location: 7)
        XCTAssertEqual(activeRange, NSRange(location: 4, length: 3))

        // Because caret is touching "try", "Let try" should NOT be flagged while the user is still typing "try..."
        let midWordIssues = MacOSNLPEngine.analyzeLocally(text: inProgressText, caretUTF16Location: 7)
        XCTAssertTrue(midWordIssues.isEmpty, "Must not flag an unfinished word/phrase while the caret is actively inside it")

        // Once the user presses Space ("Let try "), caret is at 8 (after space), so "Let try" is flagged immediately
        let completedWordText = "Let try "
        let completedIssues = MacOSNLPEngine.analyzeLocally(text: completedWordText, caretUTF16Location: 8)
        XCTAssertEqual(completedIssues.first?.original, "Let try")
        XCTAssertEqual(completedIssues.first?.replacement, "Let's try")
    }

    func testMacOSNLPEngineDuplicateWordsArticlesAndBulletLetContractions() {
        let sample = """
        Summary of the the release:
        • Let try an user onboarding flow
        • Let also fix a apple icon and a hour timer
        """
        let issues = MacOSNLPEngine.analyzeLocally(text: sample, caretUTF16Location: nil)

        XCTAssertTrue(issues.contains(where: { $0.original == "the the" && $0.replacement == "the" }))
        XCTAssertTrue(issues.contains(where: { $0.original == "Let try" && $0.replacement == "Let's try" }))
        XCTAssertTrue(issues.contains(where: { $0.original == "an user" && $0.replacement == "a user" }))
        XCTAssertTrue(issues.contains(where: { $0.original == "Let also" && $0.replacement == "Let's also" }))
        XCTAssertTrue(issues.contains(where: { $0.original == "a apple" && $0.replacement == "an apple" }))
        XCTAssertTrue(issues.contains(where: { $0.original == "a hour" && $0.replacement == "an hour" }))
    }

    func testMacOSNLPEngineEntityAndTechnicalIdentifierImmunity() {
        let text = "Ask @pumisake in #release-v2 about cliProxyAPI, JSON, user_id, and v1.0."
        let nsText = text as NSString

        let mentionRange = nsText.range(of: "pumisake")
        XCTAssertTrue(MacOSNLPEngine.isImmuneToken("pumisake", at: mentionRange, in: text))

        let camelRange = nsText.range(of: "cliProxyAPI")
        XCTAssertTrue(MacOSNLPEngine.isImmuneToken("cliProxyAPI", at: camelRange, in: text))

        let acronymRange = nsText.range(of: "JSON")
        XCTAssertTrue(MacOSNLPEngine.isImmuneToken("JSON", at: acronymRange, in: text))

        let snakeRange = nsText.range(of: "user_id")
        XCTAssertTrue(MacOSNLPEngine.isImmuneToken("user_id", at: snakeRange, in: text))
    }

    func testMacOSNLPEngineFusedWordsAndContractionTypos() {
        let text = "We have alot of work and dont want to rush incase we cant finish."
        let issues = MacOSNLPEngine.analyzeLocally(text: text, caretUTF16Location: nil)

        XCTAssertTrue(issues.contains(where: { $0.original == "alot" && $0.replacement == "a lot" }))
        XCTAssertTrue(issues.contains(where: { $0.original == "dont" && $0.replacement == "don't" }))
        XCTAssertTrue(issues.contains(where: { $0.original == "incase" && $0.replacement == "in case" }))
        XCTAssertTrue(issues.contains(where: { $0.original == "cant" && $0.replacement == "can't" }))
    }

    func testConvertDOMSelectionToAXValueOffsetInSlackBullets() {
        let text = "Not sure what's going on here:\n• Let try this\n• Let also try his"
        let ns = text as NSString

        // Line 0: "Not sure what's going on here:\n" (31 chars)
        // Line 1: "• Let try this\n" (15 chars in AX: 2 bullet units, 13 chars in DOM)
        // Line 2: "• Let also try his" (18 chars in AX: 2 bullet units, 16 chars in DOM)

        // Line 1: In DOM, marker is 1 unit at 31, "Let" starts at 32. In AX, "Let" is at 31 + 2 ("• ") = 33
        let line1StartAX = AXEngine.convertDOMSelectionToAXValueOffset(domLocation: 32, in: text)
        XCTAssertEqual(line1StartAX, 33)
        XCTAssertEqual(ns.substring(with: NSRange(location: line1StartAX, length: 3)), "Let")

        // Line 2: In DOM, line 1 is 14 chars (31 + 14 = 45). Line 2 marker is at 45, "Let" starts at 46.
        // In AX: line 2 starts at 46, "Let" is at 46 + 2 ("• ") = 48!
        let line2StartAX = AXEngine.convertDOMSelectionToAXValueOffset(domLocation: 46, in: text)
        XCTAssertEqual(line2StartAX, 48)
        XCTAssertEqual(ns.substring(with: NSRange(location: line2StartAX, length: 3)), "Let")

        // Line 1 bullet-initial detection on text starting with "• Let try this"
        let line1Only = "• Let try this"
        let l1Issues = MacOSNLPEngine.analyzeLocally(text: line1Only, caretUTF16Location: nil)
        XCTAssertTrue(l1Issues.contains(where: { $0.original == "Let try" && $0.replacement == "Let's try" }))
    }

    func testWordBoundaryRejectionPreventsPartialWordReplacement() {
        let text = "Hello this is a tste"
        // "tst" is an exact substring of "tste", but NOT a whole word.
        let range = AXEngine.findBestOccurrenceRange(of: "tst", preferredUTF16Location: 16, in: text)
        XCTAssertEqual(range.location, NSNotFound, "Must NOT match 'tst' inside 'tste'")

        // In resolveIssues:
        let raw = [ProofreadResult.RawIssue(original: "tst", replacement: "test", category: "correctness", explanation: "Typo.")]
        let resolved = GeminiService.resolveIssues(raw, in: text, dictionary: [])
        XCTAssertTrue(resolved.isEmpty, "resolveIssues must reject 'tst' when text contains 'tste'")
    }

    @MainActor
    func testHoverPeekStateAndAutoDismissFlags() {
        let coordinator = WritingAssistantCoordinator()
        XCTAssertFalse(coordinator.openedByHover)
        XCTAssertFalse(coordinator.isPopoverExpanded)

        // 1. Hover peek activates dialog
        coordinator.openedByHover = true
        coordinator.isPopoverExpanded = true
        XCTAssertTrue(coordinator.openedByHover)
        XCTAssertTrue(coordinator.isPopoverExpanded)

        // 2. User clicks on the pill/dialog to pin it -> openedByHover must clear so it won't auto-close on mouseout
        coordinator.openedByHover = false
        XCTAssertFalse(coordinator.openedByHover)
        XCTAssertTrue(coordinator.isPopoverExpanded)

        // 3. Re-enter hover peek mode and test acceptAllIssues clears openedByHover
        coordinator.openedByHover = true
        coordinator.acceptAllIssues()
        XCTAssertFalse(coordinator.openedByHover)
        XCTAssertFalse(coordinator.isPopoverExpanded)

        // 4. Test single issue acceptance resets hover state upon clearing:
        let issue1 = WritingIssue(original: "foo", replacement: "bar", category: .correctness, explanation: "e1")
        coordinator.openedByHover = true
        coordinator.isPopoverExpanded = true
        coordinator.acceptIssue(issue1)
        // With 0 remaining in empty context, acceptIssue clears it:
        XCTAssertFalse(coordinator.openedByHover)
        XCTAssertFalse(coordinator.isPopoverExpanded)

        // 5. Hotkey toggle clears openedByHover:
        coordinator.openedByHover = true
        coordinator.isPopoverExpanded = true
        coordinator.togglePopover()
        XCTAssertFalse(coordinator.openedByHover)
        XCTAssertFalse(coordinator.isPopoverExpanded)
    }

    @MainActor
    func testOpenWritingPadToRewriteExtractsContextAndClosesPopover() {
        let coordinator = WritingAssistantCoordinator()
        var openedPadCalled = false
        coordinator.onOpenWritingPad = {
            openedPadCalled = true
        }

        // Simulate context with active text
        let context = FocusedTextContext(
            appName: "Slack",
            bundleID: "com.tinyspeck.slackmacgap",
            pid: 1234,
            fullText: "Here is a full paragraph to rewrite in Writing Pad.",
            selectedText: "full paragraph to rewrite",
            selectedRange: NSRange(location: 10, length: 25),
            anchorAppKitPoint: CGPoint(x: 200, y: 300)
        )
        coordinator.axEngineDidUpdateContext(context)
        coordinator.isPopoverExpanded = true

        coordinator.openWritingPadToRewrite()

        XCTAssertTrue(openedPadCalled)
        XCTAssertFalse(coordinator.isPopoverExpanded, "Floating dialog must close when opening Writing Pad to rewrite")
        XCTAssertEqual(coordinator.incomingWritingPadText, "full paragraph to rewrite", "Selected text takes priority to bring to Writing Pad")

        // Test without selection: falls back to activeParagraph/fullText
        let contextNoSelection = FocusedTextContext(
            appName: "Slack",
            bundleID: "com.tinyspeck.slackmacgap",
            pid: 1234,
            fullText: "Single active line of text.",
            selectedText: nil,
            selectedRange: NSRange(location: 0, length: 0),
            anchorAppKitPoint: CGPoint(x: 200, y: 300)
        )
        coordinator.axEngineDidUpdateContext(contextNoSelection)
        coordinator.openWritingPadToRewrite()
        XCTAssertEqual(coordinator.incomingWritingPadText, "Single active line of text.")
    }

    func testSentenceSegmentationAndIncrementalSentenceCacheWhileTyping() {
        let settings = AppSettings()
        let service = GeminiService(settings: settings)
        service.clearCache()

        let initialText = "Update:\n• Let try this\n• Everything looks good"
        let resolved = GeminiService.resolveIssues(
            [ProofreadResult.RawIssue(original: "Let try", replacement: "Let's try", category: "correctness", explanation: "Use Let's.")],
            in: initialText,
            dictionary: []
        )
        service.storeCache(resolved, for: initialText)

        // Now user inserts a prefix on line 1 ("Quick Update:\n") and starts typing a 3rd bullet
        let updatedText = "Quick Update:\n• Let try this\n• Everything looks good\n• Typing more"
        let incrementalIssues = service.cachedIssuesForUnchangedSentences(in: updatedText)

        XCTAssertEqual(incrementalIssues.count, 1)
        XCTAssertEqual(incrementalIssues[0].original, "Let try")
        let nsUpdated = updatedText as NSString
        let shiftedRange = NSRange(location: incrementalIssues[0].utf16Location!, length: incrementalIssues[0].utf16Length!)
        XCTAssertEqual(nsUpdated.substring(with: shiftedRange), "Let try")
    }
}

// MARK: - 2. End-to-End (E2E) Pipeline Tests

@MainActor
final class SyntlyEndToEndTests: XCTestCase {

    private var settings: AppSettings!
    private var axEngine: AXEngine!
    private var geminiService: GeminiService!
    private var coordinator: WritingAssistantCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        MockGeminiURLProtocol.capturedRequests = []

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockGeminiURLProtocol.self]
        let mockSession = URLSession(configuration: config)

        settings = AppSettings()
        settings.authMode = .apiKey
        settings.apiKeyInput = "test-e2e-api-key"
        settings.saveAPIKeyFromInput()
        settings.enableAsYouType = true
        settings.enableLocalSpellcheck = false // Isolate deterministic Gemini pipeline
        settings.debounceMs = 50               // Fast 50ms debounce for E2E tests
        settings.resumeMonitoring()

        axEngine = AXEngine()
        geminiService = GeminiService(settings: settings, urlSession: mockSession)
        geminiService.clearCache()

        coordinator = WritingAssistantCoordinator(
            axEngine: axEngine,
            geminiService: geminiService,
            settings: settings
        )
    }

    override func tearDown() async throws {
        settings.clearAPIKey()
        MockGeminiURLProtocol.requestHandler = nil
        MockGeminiURLProtocol.capturedRequests = []
        try await super.tearDown()
    }

    func testEndToEndAsYouTypeDetectionAndSingleIssueReplacement() async throws {
        // 1. Mock Gemini REST API response returning 2 issues (Correctness + Fluency)
        MockGeminiURLProtocol.requestHandler = { request in
            let geminiResponse = """
            {
              "candidates": [
                {
                  "content": {
                    "parts": [
                      {
                        "text": "{\\"issues\\": [{\\"original\\": \\"their going\\", \\"replacement\\": \\"they're going\\", \\"category\\": \\"correctness\\", \\"explanation\\": \\"Use contraction they're.\\"}, {\\"original\\": \\"discuss about\\", \\"replacement\\": \\"discuss\\", \\"category\\": \\"fluency\\", \\"explanation\\": \\"Remove redundant preposition.\\"}]}"
                      }
                    ]
                  }
                }
              ]
            }
            """
            let httpResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (httpResponse, Data(geminiResponse.utf8))
        }

        // 2. Intercept AXEngine text replacement to verify the exact modified text written back to the app
        var textInTargetApp = "Hi team, their going to discuss about the launch."
        axEngine.testReplacementHandler = { _, resultingText in
            textInTargetApp = resultingText
            return true
        }

        // 3. Simulate user typing in Slack
        let slackContext = FocusedTextContext(
            appName: "Slack",
            bundleID: "com.tinyspeck.slackmacgap",
            pid: 4321,
            fullText: textInTargetApp,
            selectedText: nil,
            selectedRange: NSRange(location: textInTargetApp.count, length: 0)
        )
        coordinator.axEngineDidUpdateContext(slackContext)

        // Wait for debounce + mocked network round-trip
        try await Task.sleep(nanoseconds: 220_000_000)

        // 4. Verify Gemini API was called and 2 issues were resolved with accurate UTF-16 ranges
        XCTAssertEqual(MockGeminiURLProtocol.capturedRequests.count, 1)
        XCTAssertEqual(coordinator.issues.count, 2)
        XCTAssertEqual(coordinator.pillState, .issuesFound(count: 2, topCategory: .correctness))
        XCTAssertEqual(coordinator.issues[0].original, "their going")
        XCTAssertEqual(coordinator.issues[0].utf16Location, 9)
        XCTAssertEqual(coordinator.issues[1].original, "discuss about")
        XCTAssertEqual(coordinator.issues[1].category, .fluency)

        // 5. Simulate user pressing Option+Tab / clicking "Accept" on the first issue
        coordinator.acceptIssue(coordinator.issues[0])

        XCTAssertEqual(textInTargetApp, "Hi team, they're going to discuss about the launch.")
        XCTAssertEqual(coordinator.issues.count, 1)
        XCTAssertEqual(coordinator.pillState, .issuesFound(count: 1, topCategory: .fluency))
    }

    func testEndToEndAcceptAllAndAddToDictionary() async throws {
        MockGeminiURLProtocol.requestHandler = { request in
            let geminiResponse = """
            {
              "candidates": [
                {
                  "content": {
                    "parts": [
                      {
                        "text": "{\\"issues\\": [{\\"original\\": \\"their going\\", \\"replacement\\": \\"they're going\\", \\"category\\": \\"correctness\\", \\"explanation\\": \\"Use they're.\\"}, {\\"original\\": \\"due to the fact that\\", \\"replacement\\": \\"because\\", \\"category\\": \\"clarity\\", \\"explanation\\": \\"Be concise.\\"}]}"
                      }
                    ]
                  }
                }
              ]
            }
            """
            let httpResponse = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (httpResponse, Data(geminiResponse.utf8))
        }

        var textInTargetApp = "I think their going late due to the fact that traffic is heavy."
        axEngine.testReplacementHandler = { _, resultingText in
            textInTargetApp = resultingText
            return true
        }

        let notesContext = FocusedTextContext(
            appName: "Notes",
            bundleID: "com.apple.Notes",
            pid: 5555,
            fullText: textInTargetApp
        )
        coordinator.axEngineDidUpdateContext(notesContext)
        try await Task.sleep(nanoseconds: 220_000_000)

        XCTAssertEqual(coordinator.issues.count, 2)

        // Click "Accept All"
        coordinator.acceptAllIssues()

        XCTAssertEqual(textInTargetApp, "I think they're going late because traffic is heavy.")
        XCTAssertEqual(coordinator.issues.count, 0)
        XCTAssertEqual(coordinator.pillState, .allClear)
    }

    func testEndToEndRewriteSelectionFlow() async throws {
        MockGeminiURLProtocol.requestHandler = { request in
            let geminiResponse = """
            {
              "candidates": [
                {
                  "content": {
                    "parts": [
                      {
                        "text": "{\\"issues\\": [], \\"rewrittenText\\": \\"Could you please share the Q4 report by Friday?\\"}"
                      }
                    ]
                  }
                }
              ]
            }
            """
            let httpResponse = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (httpResponse, Data(geminiResponse.utf8))
        }

        var replacedText = ""
        axEngine.testReplacementHandler = { _, resultingText in
            replacedText = resultingText
            return true
        }

        let mailContext = FocusedTextContext(
            appName: "Mail",
            bundleID: "com.apple.mail",
            pid: 6789,
            fullText: "hey give me the q4 report on friday",
            selectedText: "hey give me the q4 report on friday",
            selectedRange: NSRange(location: 0, length: 35)
        )
        coordinator.axEngineDidUpdateContext(mailContext)
        try await Task.sleep(nanoseconds: 100_000_000)

        coordinator.runRewritePreset(.professional)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(coordinator.rewrittenPreview, "Could you please share the Q4 report by Friday?")

        coordinator.applyRewrittenPreview()
        XCTAssertEqual(replacedText, "Could you please share the Q4 report by Friday?")
        XCTAssertNil(coordinator.rewrittenPreview)
    }

    func testEndToEndBlockedAppAndPausedGuardrailsMakeZeroNetworkCalls() async throws {
        MockGeminiURLProtocol.requestHandler = { request in
            XCTFail("Should never call Gemini API when app is blocked or paused")
            let httpResponse = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (httpResponse, Data())
        }

        // 1. Simulate typing inside Terminal (blocked by default)
        let terminalContext = FocusedTextContext(
            appName: "Terminal",
            bundleID: "com.apple.Terminal",
            pid: 9999,
            fullText: "git commit -m 'their going to fix teh bug'"
        )
        coordinator.axEngineDidUpdateContext(terminalContext)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(coordinator.pillState, .paused(reason: "Disabled in Terminal"))
        XCTAssertEqual(MockGeminiURLProtocol.capturedRequests.count, 0)

        // 2. Simulate pausing Syntly globally and typing in Safari
        settings.pauseForOneHour()
        let safariContext = FocusedTextContext(
            appName: "Safari",
            bundleID: "com.apple.Safari",
            pid: 8888,
            fullText: "their going to test this sentence."
        )
        coordinator.axEngineDidUpdateContext(safariContext)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(coordinator.pillState, .paused(reason: "Paused"))
        XCTAssertEqual(MockGeminiURLProtocol.capturedRequests.count, 0)
    }

    // MARK: - Universal OpenAI API & Presets Tests

    func testNormalizeChatCompletionsAndModelsURLs() {
        // Chat completions URL normalization
        let c1 = LLMService.normalizeChatCompletionsURL(from: "http://127.0.0.1:8317")
        XCTAssertEqual(c1?.absoluteString, "http://127.0.0.1:8317/v1/chat/completions")

        let c2 = LLMService.normalizeChatCompletionsURL(from: "http://127.0.0.1:8317/v1")
        XCTAssertEqual(c2?.absoluteString, "http://127.0.0.1:8317/v1/chat/completions")

        let c3 = LLMService.normalizeChatCompletionsURL(from: "http://localhost:1234/v1/")
        XCTAssertEqual(c3?.absoluteString, "http://localhost:1234/v1/chat/completions")

        let c4 = LLMService.normalizeChatCompletionsURL(from: "https://api.openai.com/v1")
        XCTAssertEqual(c4?.absoluteString, "https://api.openai.com/v1/chat/completions")

        let c5 = LLMService.normalizeChatCompletionsURL(from: "https://api.kirogateway.com/v1/chat/completions")
        XCTAssertEqual(c5?.absoluteString, "https://api.kirogateway.com/v1/chat/completions")

        // Models URL normalization
        let m1 = LLMService.normalizeModelsURL(from: "http://127.0.0.1:8317")
        XCTAssertEqual(m1?.absoluteString, "http://127.0.0.1:8317/v1/models")

        let m2 = LLMService.normalizeModelsURL(from: "http://127.0.0.1:8317/v1")
        XCTAssertEqual(m2?.absoluteString, "http://127.0.0.1:8317/v1/models")

        let m3 = LLMService.normalizeModelsURL(from: "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(m3?.absoluteString, "https://api.openai.com/v1/models")
    }

    func testParseOpenAIChatCompletionsResponse() throws {
        let openAIJson = """
        {
          "id": "chatcmpl-123",
          "object": "chat.completion",
          "choices": [
            {
              "index": 0,
              "message": {
                "role": "assistant",
                "content": "{\\"issues\\": [{\\"original\\": \\"teh\\", \\"replacement\\": \\"the\\", \\"category\\": \\"correctness\\", \\"explanation\\": \\"Spelling\\"}]}"
              }
            }
          ]
        }
        """

        let content = try LLMService.parseContentFromAnyResponse(data: Data(openAIJson.utf8))
        let parsed = try LLMService.parseProofreadJSON(content)
        XCTAssertEqual(parsed.issues.count, 1)
        XCTAssertEqual(parsed.issues.first?.original, "teh")
        XCTAssertEqual(parsed.issues.first?.replacement, "the")
    }

    func testAPIProviderPresets() {
        let cliProxy = APIProviderPreset.cliProxy
        XCTAssertEqual(cliProxy.defaultEndpoint, "http://127.0.0.1:8317/v1")
        XCTAssertTrue(cliProxy.requiresToken)

        let lmStudio = APIProviderPreset.lmStudio
        XCTAssertEqual(lmStudio.defaultEndpoint, "http://localhost:1234/v1")
        XCTAssertFalse(lmStudio.requiresToken)

        let ollama = APIProviderPreset.ollama
        XCTAssertEqual(ollama.defaultEndpoint, "http://localhost:11434/v1")
        XCTAssertFalse(ollama.requiresToken)

        let kiro = APIProviderPreset.kiro
        XCTAssertEqual(kiro.defaultEndpoint, "https://api.kirogateway.com/v1")
        XCTAssertTrue(kiro.requiresToken)

        let openAI = APIProviderPreset.openAI
        XCTAssertEqual(openAI.defaultEndpoint, "https://api.openai.com/v1")
        XCTAssertTrue(openAI.requiresToken)
    }

    func testConnectionTestSuccessAndFailure() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockGeminiURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        let service = LLMService(settings: settings, urlSession: mockSession)

        // 1. Success test
        MockGeminiURLProtocol.requestHandler = { request in
            let response = """
            {"choices": [{"message": {"content": "{\\"status\\": \\"ok\\"}"}}]}
            """
            let httpResponse = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (httpResponse, Data(response.utf8))
        }

        let successResult = await service.testConnection(
            endpoint: "http://127.0.0.1:8317/v1",
            token: "test-token",
            model: "gemini-3.8-flash-high"
        )
        if case .success(let latency, let model, _) = successResult {
            XCTAssertGreaterThanOrEqual(latency, 1)
            XCTAssertEqual(model, "gemini-3.8-flash-high")
        } else {
            XCTFail("Expected success, got \(successResult)")
        }

        // 2. 401 Unauthorized failure test
        MockGeminiURLProtocol.requestHandler = { request in
            let errResponse = """
            {"error": {"message": "Invalid API Key"}}
            """
            let httpResponse = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (httpResponse, Data(errResponse.utf8))
        }

        let failureResult = await service.testConnection(
            endpoint: "http://127.0.0.1:8317/v1",
            token: "bad-token",
            model: "gemini-3.8-flash-high"
        )
        if case .failure(let msg) = failureResult {
            XCTAssertTrue(msg.contains("401") || msg.contains("Invalid API Key"))
        } else {
            XCTFail("Expected failure, got \(failureResult)")
        }
    }

    func testFetchAvailableModels() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockGeminiURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        let service = LLMService(settings: settings, urlSession: mockSession)

        MockGeminiURLProtocol.requestHandler = { request in
            let modelsJson = """
            {
              "data": [
                {"id": "gemini-3.8-flash-high"},
                {"id": "gpt-4o-mini"},
                {"id": "claude-3-5-sonnet"}
              ]
            }
            """
            let httpResponse = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (httpResponse, Data(modelsJson.utf8))
        }

        let models = try await service.fetchAvailableModels(endpoint: "http://127.0.0.1:8317/v1", token: "test-token")
        XCTAssertEqual(models, ["claude-3-5-sonnet", "gemini-3.8-flash-high", "gpt-4o-mini"])
    }

    // MARK: - 3. Bullet Point & Numbered List Replacement Tests (Slack / Chromium DOM Drift)

    func testReproduceAndFixSlackBulletPointReplacementShift() throws {
        // Exact text from the user's Slack screenshot:
        let initialSlackText = "Not sure what's going on here:\n• Let try this\n• Let also try his"
        let mockSlack = SimulatedSlackBulletAXAccessor(axValueText: initialSlackText)

        // 1. Reproduce why uncalibrated replacement produced "• LeLet's alsory his":
        // In `kAXValueAttribute`, "Let also" is at UTF-16 range (48, 8).
        let nsValue = initialSlackText as NSString
        let rawRangeInAXValue = nsValue.range(of: "Let also")
        XCTAssertEqual(rawRangeInAXValue, NSRange(location: 48, length: 8))

        // In Slack/Chromium's DOM selection space (`kAXSelectedTextRangeAttribute`), each "• " (2 chars in AXValue)
        // counts as 1 list marker unit ("•"). After 2 bullets, selecting (48, 8) actually selects "t also t"!
        let uncalibratedSelected = mockSlack.selectedTextIfRangeSet(rawRangeInAXValue)
        XCTAssertEqual(uncalibratedSelected, "t also t", "Uncalibrated (48, 8) in Slack DOM selects 't also t' (+2 shift)")
        let corruptedIfUncalibrated = mockSlack.textIfReplacedWithoutCalibration(range: rawRangeInAXValue, replacement: "Let's also")
        XCTAssertEqual(
            corruptedIfUncalibrated,
            "Not sure what's going on here:\n• Let try this\n• LeLet's alsory his",
            "Uncalibrated replacement reproduces the exact screenshot corruption '• LeLet's alsory his'"
        )

        // 2. Verify AXEngine.applyIssueReplacement calibrates the selection to (46, 8) ("Let also") and replaces cleanly:
        axEngine.elementAccessor = mockSlack
        axEngine.setTestingFocusedElement(AXUIElementCreateSystemWide())

        let issue = WritingIssue(
            original: "Let also",
            replacement: "Let's also",
            category: .correctness,
            explanation: "Use contraction Let's instead of verb Let.",
            utf16Location: rawRangeInAXValue.location,
            utf16Length: rawRangeInAXValue.length
        )

        let success = axEngine.applyIssueReplacement(issue, in: initialSlackText)
        XCTAssertTrue(success)
        XCTAssertEqual(mockSlack.selectedRangeInDOM, NSRange(location: 46, length: 8))
        XCTAssertEqual(
            mockSlack.axValueText,
            "Not sure what's going on here:\n• Let try this\n• Let's also try his"
        )
    }

    func testConsecutiveMultiBulletReplacementsIncludingEndOfTextWord() async throws {
        let initialSlackText = "Not sure what's going on here:\n• Let try this\n• Let also try his"
        let mockSlack = SimulatedSlackBulletAXAccessor(axValueText: initialSlackText)
        axEngine.elementAccessor = mockSlack
        axEngine.setTestingFocusedElement(AXUIElementCreateSystemWide())

        MockGeminiURLProtocol.requestHandler = { request in
            let response = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"issues\\": [{\\"original\\": \\"Let try\\", \\"replacement\\": \\"Let's try\\", \\"category\\": \\"correctness\\", \\"explanation\\": \\"Use contraction Let's.\\"}, {\\"original\\": \\"Let also\\", \\"replacement\\": \\"Let's also\\", \\"category\\": \\"correctness\\", \\"explanation\\": \\"Use contraction Let's.\\"}, {\\"original\\": \\"his\\", \\"replacement\\": \\"this\\", \\"category\\": \\"correctness\\", \\"explanation\\": \\"Typo for this.\\"}]}"
                  }
                }
              ]
            }
            """
            let httpResponse = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (httpResponse, Data(response.utf8))
        }

        // Cursor is on the 2nd bullet point (location 55), just like when typing a bulleted list in Slack
        let slackContext = FocusedTextContext(
            appName: "Slack",
            bundleID: "com.tinyspeck.slackmacgap",
            pid: 4321,
            fullText: initialSlackText,
            selectedText: nil,
            selectedRange: NSRange(location: 55, length: 0)
        )
        coordinator.axEngineDidUpdateContext(slackContext)
        try await Task.sleep(nanoseconds: 220_000_000)

        XCTAssertEqual(coordinator.issues.count, 3)
        XCTAssertEqual(coordinator.issues[0].original, "Let try")
        XCTAssertEqual(coordinator.issues[1].original, "Let also")
        XCTAssertEqual(coordinator.issues[2].original, "his")

        // 1. Accept first bullet issue ("Let try" -> "Let's try")
        coordinator.acceptIssue(coordinator.issues[0])
        XCTAssertEqual(
            mockSlack.axValueText,
            "Not sure what's going on here:\n• Let's try this\n• Let also try his"
        )
        XCTAssertEqual(coordinator.issues.count, 2)

        // 2. Accept second bullet issue ("Let also" -> "Let's also") immediately without re-polling
        coordinator.acceptIssue(coordinator.issues[0])
        XCTAssertEqual(
            mockSlack.axValueText,
            "Not sure what's going on here:\n• Let's try this\n• Let's also try his"
        )
        XCTAssertEqual(coordinator.issues.count, 1)

        // 3. Accept third issue at the very end of the 2nd bullet ("his" -> "this")
        coordinator.acceptIssue(coordinator.issues[0])
        XCTAssertEqual(
            mockSlack.axValueText,
            "Not sure what's going on here:\n• Let's try this\n• Let's also try this"
        )
        XCTAssertEqual(coordinator.issues.count, 0)
    }

    func testDuplicatePhraseAcrossMultipleBulletsReplacesTargetedBullet() {
        // Both bullets contain "Let try"
        let initialSlackText = "Action items:\n• Let try option A\n• Let try option B"
        let mockSlack = SimulatedSlackBulletAXAccessor(axValueText: initialSlackText)
        axEngine.elementAccessor = mockSlack
        axEngine.setTestingFocusedElement(AXUIElementCreateSystemWide())

        let rawIssues = [
            ProofreadResult.RawIssue(original: "Let try", replacement: "Let's try", category: "correctness", explanation: "Use Let's."),
            ProofreadResult.RawIssue(original: "Let try", replacement: "Let's try", category: "correctness", explanation: "Use Let's.")
        ]
        let resolved = GeminiService.resolveIssues(rawIssues, in: initialSlackText, dictionary: [])
        XCTAssertEqual(resolved.count, 2)
        XCTAssertNotEqual(resolved[0].utf16Location, resolved[1].utf16Location)

        // User clicks Accept on the 2nd bullet's issue FIRST:
        let secondBulletIssue = resolved[1]
        let ok = axEngine.applyIssueReplacement(secondBulletIssue, in: initialSlackText)
        XCTAssertTrue(ok)
        XCTAssertEqual(
            mockSlack.axValueText,
            "Action items:\n• Let try option A\n• Let's try option B",
            "Accepting the 2nd bullet's issue must replace the 2nd bullet, not the 1st bullet"
        )
    }

    func testNumberedListOffsetDriftAndSharedListMarkerStripping() {
        // 1. Test stripping shared bullet/numbered list prefixes if an LLM includes them in original & replacement
        let strippedBullet = GeminiService.stripSharedListMarkerPrefix(
            original: "• Let also",
            replacement: "• Let's also"
        )
        XCTAssertEqual(strippedBullet.original, "Let also")
        XCTAssertEqual(strippedBullet.replacement, "Let's also")

        let strippedNumbered = GeminiService.stripSharedListMarkerPrefix(
            original: "2. Let also",
            replacement: "2. Let's also"
        )
        XCTAssertEqual(strippedNumbered.original, "Let also")
        XCTAssertEqual(strippedNumbered.replacement, "Let's also")

        // 2. Test numbered list replacement in Chromium where "1. " (3 chars) counts as 1 unit in DOM selection (-2 drift per item)
        let numberedText = "Steps:\n1. Let try this\n2. Let also try his"
        let mockNumbered = SimulatedSlackBulletAXAccessor(axValueText: numberedText)
        axEngine.elementAccessor = mockNumbered
        axEngine.setTestingFocusedElement(AXUIElementCreateSystemWide())

        let resolved = GeminiService.resolveIssues(
            [ProofreadResult.RawIssue(original: "• Let also", replacement: "• Let's also", category: "correctness", explanation: "Fix")],
            in: numberedText,
            dictionary: []
        )
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].original, "Let also")

        let success = axEngine.applyIssueReplacement(resolved[0], in: numberedText)
        XCTAssertTrue(success)
        XCTAssertEqual(
            mockNumbered.axValueText,
            "Steps:\n1. Let try this\n2. Let's also try his"
        )
    }

    func testEmojiAndZWJSequencesWithBulletsReplacement() {
        // Surrogate pair 🚀 (2 UTF-16 units), skin-tone modifier 👋🏽 (4 UTF-16 units), and ZWJ sequence 👩‍💻 (5 UTF-16 units)
        let emojiBulletText = "Hey 👋🏽 team 🚀:\n• 👩‍💻 Let try this\n• Let also deploy 🚀 tonight"
        let mockSlack = SimulatedSlackBulletAXAccessor(axValueText: emojiBulletText)
        axEngine.elementAccessor = mockSlack
        axEngine.setTestingFocusedElement(AXUIElementCreateSystemWide())

        let rawIssues = [
            ProofreadResult.RawIssue(original: "Let try", replacement: "Let's try", category: "correctness", explanation: "Use Let's."),
            ProofreadResult.RawIssue(original: "Let also", replacement: "Let's also", category: "correctness", explanation: "Use Let's.")
        ]
        let resolved = GeminiService.resolveIssues(rawIssues, in: emojiBulletText, dictionary: [])
        XCTAssertEqual(resolved.count, 2)

        // Replace 2nd bullet first (after all emojis and 2 bullet markers)
        XCTAssertTrue(axEngine.applyIssueReplacement(resolved[1], in: mockSlack.axValueText))
        XCTAssertEqual(
            mockSlack.axValueText,
            "Hey 👋🏽 team 🚀:\n• 👩‍💻 Let try this\n• Let's also deploy 🚀 tonight"
        )

        // Replace 1st bullet next (immediately following 5-unit ZWJ emoji 👩‍💻)
        XCTAssertTrue(axEngine.applyIssueReplacement(resolved[0], in: mockSlack.axValueText))
        XCTAssertEqual(
            mockSlack.axValueText,
            "Hey 👋🏽 team 🚀:\n• 👩‍💻 Let's try this\n• Let's also deploy 🚀 tonight"
        )
    }

    func testNonBreakingSpaceAndSmartCurlyQuotesInContentEditable() {
        // HTML contenteditable (Slack, Chrome, Notion, Safari) frequently inserts \u{00A0} (&nbsp;)
        // and macOS Smart Quotes converts ' to ’ (\u{2019}).
        // Meanwhile, the LLM returns standard ASCII spaces ' ' and straight apostrophes '''.
        let nbspAndCurlyText = "Update:\n• We\u{00A0}don’t\u{00A0}has time\n• Let\u{00A0}also\u{00A0}check it’s status"
        let mockSlack = SimulatedSlackBulletAXAccessor(axValueText: nbspAndCurlyText)
        axEngine.elementAccessor = mockSlack
        axEngine.setTestingFocusedElement(AXUIElementCreateSystemWide())

        // LLM issues use standard ASCII spaces and straight apostrophes
        let rawIssues = [
            ProofreadResult.RawIssue(original: "don't has", replacement: "don't have", category: "correctness", explanation: "Use have."),
            ProofreadResult.RawIssue(original: "Let also", replacement: "Let's also", category: "correctness", explanation: "Use Let's."),
            ProofreadResult.RawIssue(original: "it's status", replacement: "its status", category: "correctness", explanation: "Possessive its.")
        ]
        let resolved = GeminiService.resolveIssues(rawIssues, in: nbspAndCurlyText, dictionary: [])
        XCTAssertEqual(resolved.count, 3, "Must resolve all 3 issues despite \\u{00A0} and curly apostrophes ’")

        XCTAssertTrue(axEngine.applyIssueReplacement(resolved[2], in: mockSlack.axValueText))
        XCTAssertTrue(axEngine.applyIssueReplacement(resolved[1], in: mockSlack.axValueText))
        XCTAssertTrue(axEngine.applyIssueReplacement(resolved[0], in: mockSlack.axValueText))

        XCTAssertEqual(
            mockSlack.axValueText,
            "Update:\n• We\u{00A0}don't have time\n• Let's also\u{00A0}check its status"
        )
    }

    func testIndentedNestedBulletsAndCRLFLinesReplacement() {
        // 1. Indented multi-level bullets ("  ◦ ", "    ▪ ") where leading indentation + bullet collapses to 1 marker unit in DOM
        let nestedListText = "Roadmap:\n• Let try phase 1\n  ◦ Let also test phase 2\n    ▪ Teh final check"
        let mockNested = SimulatedSlackBulletAXAccessor(axValueText: nestedListText)
        axEngine.elementAccessor = mockNested
        axEngine.setTestingFocusedElement(AXUIElementCreateSystemWide())

        let rawNested = [
            ProofreadResult.RawIssue(original: "Let try", replacement: "Let's try", category: "correctness", explanation: "Fix"),
            ProofreadResult.RawIssue(original: "Let also", replacement: "Let's also", category: "correctness", explanation: "Fix"),
            ProofreadResult.RawIssue(original: "Teh", replacement: "The", category: "correctness", explanation: "Fix")
        ]
        let resolvedNested = GeminiService.resolveIssues(rawNested, in: nestedListText, dictionary: [])
        XCTAssertEqual(resolvedNested.count, 3)

        // Apply bottom-up so earlier offsets don't shift
        XCTAssertTrue(axEngine.applyIssueReplacement(resolvedNested[2], in: mockNested.axValueText))
        XCTAssertTrue(axEngine.applyIssueReplacement(resolvedNested[1], in: mockNested.axValueText))
        XCTAssertTrue(axEngine.applyIssueReplacement(resolvedNested[0], in: mockNested.axValueText))

        XCTAssertEqual(
            mockNested.axValueText,
            "Roadmap:\n• Let's try phase 1\n  ◦ Let's also test phase 2\n    ▪ The final check"
        )

        // 2. CRLF (\r\n) line breaks in AXValue vs LF (\n) in DOM selection
        let crlfText = "Line one:\r\n• Let try this\r\n• Let also try his"
        let mockCRLF = SimulatedSlackBulletAXAccessor(axValueText: crlfText, collapseCRLFInDOM: true)
        axEngine.elementAccessor = mockCRLF

        let resolvedCRLF = GeminiService.resolveIssues(
            [
                ProofreadResult.RawIssue(original: "Let also", replacement: "Let's also", category: "correctness", explanation: "Fix"),
                ProofreadResult.RawIssue(original: "his", replacement: "this", category: "correctness", explanation: "Fix")
            ],
            in: crlfText,
            dictionary: []
        )
        XCTAssertEqual(resolvedCRLF.count, 2)
        XCTAssertTrue(axEngine.applyIssueReplacement(resolvedCRLF[1], in: mockCRLF.axValueText))
        XCTAssertTrue(axEngine.applyIssueReplacement(resolvedCRLF[0], in: mockCRLF.axValueText))
        XCTAssertEqual(
            mockCRLF.axValueText,
            "Line one:\r\n• Let try this\r\n• Let's also try this"
        )
    }

    func testWhileYouTypeLiveUserEditsBeforeClickingAcceptAndSafetyGuardrails() {
        // Initial text when proofread ran:
        let analyzedSnapshot = "Notes:\n• Let try this\n• Let also"
        let resolved = GeminiService.resolveIssues(
            [ProofreadResult.RawIssue(original: "Let also", replacement: "Let's also", category: "correctness", explanation: "Fix")],
            in: analyzedSnapshot,
            dictionary: []
        )
        XCTAssertEqual(resolved.count, 1)
        let staleIssue = resolved[0]

        // Scenario A & B: User typed both BEFORE ("Quick ") and AFTER (" try this now") before clicking Accept!
        let mutatedLiveText = "Quick Notes:\n• Let try this\n• Let also try this now"
        let mockLive = SimulatedSlackBulletAXAccessor(axValueText: mutatedLiveText)
        axEngine.elementAccessor = mockLive
        axEngine.setTestingFocusedElement(AXUIElementCreateSystemWide())

        let replacedAfterLiveTyping = axEngine.applyIssueReplacement(staleIssue, in: analyzedSnapshot)
        XCTAssertTrue(replacedAfterLiveTyping)
        XCTAssertEqual(
            mockLive.axValueText,
            "Quick Notes:\n• Let try this\n• Let's also try this now",
            "Even if the user typed before/after the issue before clicking Accept, live relocation + calibration must replace accurately"
        )

        // Scenario C: User already manually fixed "Let's also" before clicking Accept on the stale suggestion card
        let alreadyFixedByUser = axEngine.applyIssueReplacement(staleIssue, in: mockLive.axValueText)
        XCTAssertFalse(alreadyFixedByUser, "Must return false and never corrupt text if user already fixed/deleted the original word")
        XCTAssertEqual(mockLive.axValueText, "Quick Notes:\n• Let try this\n• Let's also try this now")

        // Scenario D: If DOM selection reports completely unrelated uncalibratable text, must abort rather than overwrite
        mockLive.forceUnrelatedSelectedText = "UNRELATED_SELECTION"
        let issueForTry = WritingIssue(
            original: "Let try",
            replacement: "Let's try",
            category: .correctness,
            explanation: "Fix",
            utf16Location: 15,
            utf16Length: 7
        )
        let aborted = axEngine.applyIssueReplacement(issueForTry, in: mockLive.axValueText)
        XCTAssertFalse(aborted, "Must abort if kAXSelectedTextAttribute cannot be calibrated to match issue.original")
        XCTAssertEqual(mockLive.axValueText, "Quick Notes:\n• Let try this\n• Let's also try this now")
    }

    func testShrinkingAndExpandingReplacementsAndAcceptAllOnBulletedList() async throws {
        // Combines shrinking ("due to the fact that" -> "because", -13 chars),
        // expanding ("Let also" -> "Let's also", +2 chars),
        // and equal-length ("teh" -> "the", 0 chars) across bullets
        let initialText = "Summary:\n• Delayed due to the fact that traffic is heavy\n• Let also fix teh deployment"
        let mockSlack = SimulatedSlackBulletAXAccessor(axValueText: initialText)
        axEngine.elementAccessor = mockSlack
        axEngine.setTestingFocusedElement(AXUIElementCreateSystemWide())

        MockGeminiURLProtocol.requestHandler = { request in
            let response = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"issues\\": [{\\"original\\": \\"due to the fact that\\", \\"replacement\\": \\"because\\", \\"category\\": \\"clarity\\", \\"explanation\\": \\"Concise\\"}, {\\"original\\": \\"Let also\\", \\"replacement\\": \\"Let's also\\", \\"category\\": \\"correctness\\", \\"explanation\\": \\"Contraction\\"}, {\\"original\\": \\"teh\\", \\"replacement\\": \\"the\\", \\"category\\": \\"correctness\\", \\"explanation\\": \\"Spelling\\"}]}"
                  }
                }
              ]
            }
            """
            let httpResponse = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (httpResponse, Data(response.utf8))
        }

        let ctx = FocusedTextContext(
            appName: "Slack",
            bundleID: "com.tinyspeck.slackmacgap",
            pid: 4321,
            fullText: initialText,
            selectedText: nil,
            selectedRange: NSRange(location: 40, length: 0)
        )
        coordinator.axEngineDidUpdateContext(ctx)
        try await Task.sleep(nanoseconds: 220_000_000)

        XCTAssertEqual(coordinator.issues.count, 3)

        // 1. Accept shrinking issue on Bullet 1 (-13 UTF-16 units)
        coordinator.acceptIssue(coordinator.issues[0])
        XCTAssertEqual(
            mockSlack.axValueText,
            "Summary:\n• Delayed because traffic is heavy\n• Let also fix teh deployment"
        )
        // Subsequent issues on Bullet 2 must have shifted by -13 units so accepting them next hits the exact range!
        coordinator.acceptIssue(coordinator.issues[0])
        XCTAssertEqual(
            mockSlack.axValueText,
            "Summary:\n• Delayed because traffic is heavy\n• Let's also fix teh deployment"
        )
        coordinator.acceptIssue(coordinator.issues[0])
        XCTAssertEqual(
            mockSlack.axValueText,
            "Summary:\n• Delayed because traffic is heavy\n• Let's also fix the deployment"
        )
    }

    func testPlainTextChromiumReplacementNeverShiftsOrKeepsStalePartialWords() async throws {
        // 1. User pauses mid-word at "As I think it not deali"
        let partialText = "I don't know what's going on but I think this is too slow to work properly. As I think it not deali"
        let mockElectron = SimulatedSlackBulletAXAccessor(axValueText: partialText)
        axEngine.elementAccessor = mockElectron
        axEngine.setTestingFocusedElement(AXUIElementCreateSystemWide())

        MockGeminiURLProtocol.requestHandler = { request in
            let response = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"issues\\": [{\\"original\\": \\"it not deali\\", \\"replacement\\": \\"it's not dealing\\", \\"category\\": \\"correctness\\", \\"explanation\\": \\"Grammar\\"}]}"
                  }
                }
              ]
            }
            """
            let httpResponse = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (httpResponse, Data(response.utf8))
        }

        coordinator.axEngineDidUpdateContext(
            FocusedTextContext(
                appName: "Antigravity",
                bundleID: "com.google.antigravity",
                pid: 9999,
                fullText: partialText,
                selectedRange: NSRange(location: (partialText as NSString).length, length: 0)
            )
        )
        try await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertEqual(coordinator.issues.count, 1)
        XCTAssertEqual(coordinator.issues.first?.original, "it not deali")

        // 2. User continues typing "ng with punctuation mark." — stale partial issue "it not deali" must be immediately cleared!
        let fullSentence = "I don't know what's going on but I think this is too slow to work properly. As I think it not dealing with punctuation mark."
        mockElectron.axValueText = fullSentence
        // Simulate delayed/empty kAXSelectedTextAttribute in Electron during window activation
        mockElectron.forceUnrelatedSelectedText = ""

        MockGeminiURLProtocol.requestHandler = { request in
            let response = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"issues\\": [{\\"original\\": \\"it not dealing\\", \\"replacement\\": \\"it's not dealing\\", \\"category\\": \\"correctness\\", \\"explanation\\": \\"Grammar\\"}]}"
                  }
                }
              ]
            }
            """
            let httpResponse = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (httpResponse, Data(response.utf8))
        }

        coordinator.axEngineDidUpdateContext(
            FocusedTextContext(
                appName: "Antigravity",
                bundleID: "com.google.antigravity",
                pid: 9999,
                fullText: fullSentence,
                selectedRange: NSRange(location: (fullSentence as NSString).length, length: 0)
            )
        )
        // Immediately on keystroke (before network finishes), stale "it not deali" must be removed from coordinator.issues
        XCTAssertTrue(coordinator.issues.isEmpty, "Stale partial issue 'it not deali' must be cleared immediately when user types 'ng'")

        // 3. Wait for debounced proofread of full sentence and accept "it not dealing" -> "it's not dealing"
        try await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertEqual(coordinator.issues.count, 1)
        XCTAssertEqual(coordinator.issues.first?.original, "it not dealing")
        XCTAssertEqual(coordinator.issues.first?.utf16Location, 87)
        XCTAssertEqual(coordinator.issues.first?.utf16Length, 14)

        mockElectron.setRangeCallCount = 0
        coordinator.acceptIssue(coordinator.issues[0])

        // Plain-text fast path must set range exactly ONCE at (87, 14) without running spiral search or shifting to 85
        XCTAssertEqual(mockElectron.setRangeCallCount, 1)
        XCTAssertEqual(mockElectron.selectedRangeInDOM, NSRange(location: 87, length: 14))
        XCTAssertEqual(
            mockElectron.axValueText,
            "I don't know what's going on but I think this is too slow to work properly. As I think it's not dealing with punctuation mark."
        )
    }

    func testLocalNLPPunctuationAndQuestionDetection() {
        // 1. Direct question missing '?' at the end of a multi-sentence input
        let text1 = "I want to make sure the bug is already fixed but not sure it's fixed or not. Can you make sure about that"
        // Even when user caret is at the end of the input, the completed question is correctly detected
        let activeIssues = MacOSNLPEngine.analyzeLocally(text: text1, caretUTF16Location: (text1 as NSString).length)
        XCTAssertEqual(activeIssues.first?.original, "about that")
        XCTAssertEqual(activeIssues.first?.replacement, "about that?")

        // If typing is in-progress with an incomplete word (e.g. "tha"), punctuation is suppressed until word finishes
        let textUnfinished = "Can you make sure about tha"
        let unfinishedIssues = MacOSNLPEngine.analyzeLocally(text: textUnfinished, caretUTF16Location: (textUnfinished as NSString).length)
        XCTAssertFalse(unfinishedIssues.contains { $0.replacement.hasSuffix("?") })

        // Once typing settles (caretUTF16Location: nil), flag "about that" -> "about that?"
        let settledIssues = MacOSNLPEngine.analyzeLocally(text: text1, caretUTF16Location: nil)
        XCTAssertEqual(settledIssues.count, 1)
        XCTAssertEqual(settledIssues.first?.original, "about that")
        XCTAssertEqual(settledIssues.first?.replacement, "about that?")
        XCTAssertEqual(settledIssues.first?.utf16Location, 95)

        // 2. Direct question ending with '.' instead of '?'
        let text2 = "Can you make sure about that."
        let issues2 = MacOSNLPEngine.analyzeLocally(text: text2, caretUTF16Location: nil)
        XCTAssertEqual(issues2.first?.original, "about that.")
        XCTAssertEqual(issues2.first?.replacement, "about that?")

        // 3. Stray space before '.' and '?'
        let text3 = "This is already fixed . Are you sure ?"
        let issues3 = MacOSNLPEngine.analyzeLocally(text: text3, caretUTF16Location: nil)
        XCTAssertEqual(issues3.count, 2)
        XCTAssertEqual(issues3[0].original, "fixed .")
        XCTAssertEqual(issues3[0].replacement, "fixed.")
        XCTAssertEqual(issues3[1].original, "sure ?")
        XCTAssertEqual(issues3[1].replacement, "sure?")

        // 4. Duplicate or conflicting punctuation ("?.", "..", "? .") and meta-mention immunity ("like . or ?")
        let text4 = "How can we better handle punctuation like . or ? ."
        let issues4 = MacOSNLPEngine.analyzeLocally(text: text4, caretUTF16Location: nil)
        XCTAssertFalse(issues4.contains { $0.original == "like ." }, "Should not flag meta-mention 'like . or'")

        let text5 = "It is fixed.. Can you check that?."
        let issues5 = MacOSNLPEngine.analyzeLocally(text: text5, caretUTF16Location: nil)
        XCTAssertEqual(issues5.count, 2)
        XCTAssertEqual(issues5[0].original, "fixed..")
        XCTAssertEqual(issues5[0].replacement, "fixed.")
        XCTAssertEqual(issues5[1].original, "that?.")
        XCTAssertEqual(issues5[1].replacement, "that?")

        // 5. Missing space after period & lowercase sentence start
        let text6 = "It is fixed.Can you check? Yes. it works."
        let issues6 = MacOSNLPEngine.analyzeLocally(text: text6, caretUTF16Location: nil)
        XCTAssertEqual(issues6.count, 2)
        XCTAssertEqual(issues6[0].original, "fixed.Can")
        XCTAssertEqual(issues6[0].replacement, "fixed. Can")
        XCTAssertEqual(issues6[1].original, "Yes. it")
        XCTAssertEqual(issues6[1].replacement, "Yes. It")

        // 6. Complete declarative sentence missing terminal period (.)
        let text7 = "I want to test what's going on but I am not sure what it's gonna be. Try to think about the way to make some test"
        let issues7 = MacOSNLPEngine.analyzeLocally(text: text7, caretUTF16Location: (text7 as NSString).length)
        XCTAssertEqual(issues7.first?.original, "some test")
        XCTAssertEqual(issues7.first?.replacement, "some test.")
        XCTAssertEqual(issues7.first?.explanation, "Add a period '.' at the end of the sentence.")
    }

    @MainActor
    func testSequentialAltTabFixesOverlappingAndQuestionPunctuationCleanly() async throws {
        settings.enableLocalSpellcheck = true
        let initialText = "I want to make sure the bug is alrady fix but not sure it's fixed or not. Can you make sure about that"
        let mockElectron = SimulatedSlackBulletAXAccessor(axValueText: initialText)
        axEngine.elementAccessor = mockElectron
        axEngine.setTestingFocusedElement(AXUIElementCreateSystemWide())

        // Simulate Gemini returning "alrady fix" -> "already fixed" (overlapping local spellcheck's "alrady" -> "already")
        MockGeminiURLProtocol.requestHandler = { request in
            let responseJSON = """
            {
              "choices": [{
                "message": {
                  "content": "{\\"issues\\": [{\\"original\\": \\"alrady fix\\", \\"replacement\\": \\"already fixed\\", \\"category\\": \\"correctness\\", \\"explanation\\": \\"Fix spelling and verb form.\\"}]}"
                }
              }]
            }
            """
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (http, Data(responseJSON.utf8))
        }

        // User finishes typing the sentence
        coordinator.axEngineDidUpdateContext(
            FocusedTextContext(
                appName: "Antigravity",
                bundleID: "com.google.antigravity",
                pid: 999,
                fullText: initialText,
                selectedText: "",
                selectedRange: NSRange(location: (initialText as NSString).length, length: 0)
            )
        )

        // Wait for debounced proofread + settled local NLP pass
        try await Task.sleep(nanoseconds: 220_000_000)

        // Must have exactly 2 non-overlapping issues:
        // 1. "alrady fix" -> "already fixed" (at 31, length 10) -- local "alrady" (at 31, length 6) must be deduplicated!
        // 2. "about that" -> "about that?" (at 92, length 10) -- detected by settled local NLP Pass 7!
        XCTAssertEqual(coordinator.issues.count, 2)
        XCTAssertEqual(coordinator.issues[0].original, "alrady fix")
        XCTAssertEqual(coordinator.issues[0].replacement, "already fixed")
        XCTAssertEqual(coordinator.issues[0].utf16Location, 31)
        XCTAssertEqual(coordinator.issues[1].original, "about that")
        XCTAssertEqual(coordinator.issues[1].replacement, "about that?")
        XCTAssertEqual(coordinator.issues[1].utf16Location, 92)

        // Alt+Tab #1: Accepts "alrady fix" -> "already fixed"
        coordinator.acceptIssue(coordinator.issues[0])
        XCTAssertEqual(
            mockElectron.axValueText,
            "I want to make sure the bug is already fixed but not sure it's fixed or not. Can you make sure about that"
        )

        // Only 1 issue ("about that" -> "about that?" shifted by +3 to utf16Location 95) should remain
        XCTAssertEqual(coordinator.issues.count, 1)
        XCTAssertEqual(coordinator.issues[0].original, "about that")
        XCTAssertEqual(coordinator.issues[0].utf16Location, 95)

        // Alt+Tab #2: Accepts "about that" -> "about that?"
        coordinator.acceptIssue(coordinator.issues[0])
        XCTAssertEqual(
            mockElectron.axValueText,
            "I want to make sure the bug is already fixed but not sure it's fixed or not. Can you make sure about that?"
        )
        XCTAssertTrue(coordinator.issues.isEmpty)
        XCTAssertEqual(coordinator.pillState, PillVisualState.allClear)
    }

    @MainActor
    func testSequentialAltTabDeclarativePeriodPunctuationAndWordFixes() async throws {
        settings.enableLocalSpellcheck = true
        let initialText = "I want to test what going on but I am not sure what it's gonna be. Try to think about the way to make some test"
        let mockElectron = SimulatedSlackBulletAXAccessor(axValueText: initialText)
        axEngine.elementAccessor = mockElectron
        axEngine.setTestingFocusedElement(AXUIElementCreateSystemWide())

        MockGeminiURLProtocol.requestHandler = { request in
            let responseJSON = """
            {
              "choices": [{
                "message": {
                  "content": "{\\"issues\\": [{\\"original\\": \\"what going\\", \\"replacement\\": \\"what's going\\", \\"category\\": \\"correctness\\", \\"explanation\\": \\"Fix grammar.\\"}]}"
                }
              }]
            }
            """
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (http, Data(responseJSON.utf8))
        }

        coordinator.axEngineDidUpdateContext(
            FocusedTextContext(
                appName: "Antigravity",
                bundleID: "com.google.antigravity",
                pid: 999,
                fullText: initialText,
                selectedText: "",
                selectedRange: NSRange(location: (initialText as NSString).length, length: 0)
            )
        )

        try await Task.sleep(nanoseconds: 220_000_000)

        // Must have:
        // 1. "what going" -> "what's going" (at 15, length 10)
        // 2. "some test" -> "some test." (at 104, length 9) -- missing period on complete declarative sentence!
        XCTAssertEqual(coordinator.issues.count, 2)
        XCTAssertEqual(coordinator.issues[0].original, "what going")
        XCTAssertEqual(coordinator.issues[0].replacement, "what's going")
        XCTAssertEqual(coordinator.issues[1].original, "some test")
        XCTAssertEqual(coordinator.issues[1].replacement, "some test.")

        // Alt+Tab #1: Accepts "what going" -> "what's going"
        coordinator.acceptIssue(coordinator.issues[0])
        XCTAssertEqual(
            mockElectron.axValueText,
            "I want to test what's going on but I am not sure what it's gonna be. Try to think about the way to make some test"
        )

        // Exactly 1 issue remains, shifted by +2 (utf16Location: 104)
        XCTAssertEqual(coordinator.issues.count, 1)
        XCTAssertEqual(coordinator.issues[0].original, "some test")
        XCTAssertEqual(coordinator.issues[0].replacement, "some test.")
        XCTAssertEqual(coordinator.issues[0].utf16Location, 104)

        // Alt+Tab #2: Accepts "some test" -> "some test."
        coordinator.acceptIssue(coordinator.issues[0])
        XCTAssertEqual(
            mockElectron.axValueText,
            "I want to test what's going on but I am not sure what it's gonna be. Try to think about the way to make some test."
        )
        XCTAssertTrue(coordinator.issues.isEmpty)
        XCTAssertEqual(coordinator.pillState, PillVisualState.allClear)
    }

    @MainActor
    func testMovingCursorBeforeAcceptNeverCorruptsWord() async throws {
        settings.enableLocalSpellcheck = true
        let initialText = "Hello this is a tste."
        let mockElectron = SimulatedSlackBulletAXAccessor(axValueText: initialText)
        axEngine.elementAccessor = mockElectron
        axEngine.setTestingFocusedElement(AXUIElementCreateSystemWide())

        MockGeminiURLProtocol.requestHandler = { request in
            let responseJSON = """
            {
              "choices": [{
                "message": {
                  "content": "{\\"issues\\": [{\\"original\\": \\"tste\\", \\"replacement\\": \\"test\\", \\"category\\": \\"correctness\\", \\"explanation\\": \\"Correct spelling of test.\\"}]}"
                }
              }]
            }
            """
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (http, Data(responseJSON.utf8))
        }

        // 1. User types "Hello this is a tste."
        coordinator.axEngineDidUpdateContext(
            FocusedTextContext(
                appName: "Antigravity",
                bundleID: "com.google.antigravity",
                pid: 999,
                fullText: initialText,
                selectedText: "",
                selectedRange: NSRange(location: (initialText as NSString).length, length: 0)
            )
        )

        // 2. User moves cursor elsewhere (e.g. index 5, before "this"). "tste" is now settled!
        mockElectron.selectedRangeInDOM = NSRange(location: 5, length: 0)
        coordinator.axEngineDidUpdateContext(
            FocusedTextContext(
                appName: "Antigravity",
                bundleID: "com.google.antigravity",
                pid: 999,
                fullText: initialText,
                selectedText: "",
                selectedRange: NSRange(location: 5, length: 0)
            )
        )

        try await Task.sleep(nanoseconds: 220_000_000)

        // Gemini proofread surfaces "tste" -> "test" on the card
        XCTAssertEqual(coordinator.issues.count, 1)
        XCTAssertEqual(coordinator.issues[0].original, "tste")
        XCTAssertEqual(coordinator.issues[0].replacement, "test")

        // 3. User clicks Accept on the suggestion card
        coordinator.acceptIssue(coordinator.issues[0])

        // Must cleanly replace "tste" with "test" -> "Hello this is a test." (NEVER "teste" or corrupted offset)
        XCTAssertEqual(mockElectron.axValueText, "Hello this is a test.")
        XCTAssertTrue(coordinator.issues.isEmpty)
        XCTAssertEqual(coordinator.pillState, PillVisualState.allClear)
    }

    @MainActor
    func testSequentialAltTabOnGrammarSentenceNeverCorruptsCompositeWords() async throws {
        settings.enableLocalSpellcheck = true
        let initialText = "It seem to not dealing with \".\" right now according to the screenshot. I type on first pic, and click alt-tab then it just fix word, not puctuation. Can you look into it?"
        let mockElectron = SimulatedSlackBulletAXAccessor(axValueText: initialText)
        axEngine.elementAccessor = mockElectron
        axEngine.setTestingFocusedElement(AXUIElementCreateSystemWide())

        MockGeminiURLProtocol.requestHandler = { request in
            let responseJSON = """
            {
              "choices": [{
                "message": {
                  "content": "{\\"issues\\": [{\\"original\\": \\"seem to not dealing\\", \\"replacement\\": \\"seems not to deal\\", \\"category\\": \\"correctness\\", \\"explanation\\": \\"Grammar.\\"}, {\\"original\\": \\"puctuation\\", \\"replacement\\": \\"punctuation\\", \\"category\\": \\"correctness\\", \\"explanation\\": \\"Spelling.\\"}]}"
                }
              }]
            }
            """
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (http, Data(responseJSON.utf8))
        }

        coordinator.axEngineDidUpdateContext(
            FocusedTextContext(
                appName: "Antigravity",
                bundleID: "com.google.antigravity",
                pid: 999,
                fullText: initialText,
                selectedText: "",
                selectedRange: NSRange(location: (initialText as NSString).length, length: 0)
            )
        )

        try await Task.sleep(nanoseconds: 220_000_000)

        // Must have broad phrase "seem to not dealing" -> "seems not to deal", and "puctuation" -> "punctuation"
        XCTAssertEqual(coordinator.issues.count, 2)
        XCTAssertEqual(coordinator.issues[0].original, "seem to not dealing")
        XCTAssertEqual(coordinator.issues[0].replacement, "seems not to deal")
        XCTAssertEqual(coordinator.issues[1].original, "puctuation")
        XCTAssertEqual(coordinator.issues[1].replacement, "punctuation")

        // Alt+Tab #1: Accepts "seem to not dealing" -> "seems not to deal"
        coordinator.acceptIssue(coordinator.issues[0])
        XCTAssertFalse(mockElectron.axValueText.contains("seemsto"))
        XCTAssertFalse(mockElectron.axValueText.contains("dealg"))
        XCTAssertTrue(mockElectron.axValueText.contains("It seems not to deal with"))

        // Alt+Tab #2: Accepts "puctuation" -> "punctuation"
        XCTAssertEqual(coordinator.issues.count, 1)
        XCTAssertEqual(coordinator.issues[0].original, "puctuation")
        coordinator.acceptIssue(coordinator.issues[0])

        XCTAssertFalse(mockElectron.axValueText.contains("puctuation"))
        XCTAssertTrue(mockElectron.axValueText.contains("not punctuation. Can you look into it?"))
        XCTAssertTrue(coordinator.issues.isEmpty)
        XCTAssertEqual(coordinator.pillState, PillVisualState.allClear)
    }
}

// MARK: - Simulated Slack / Chromium Rich-Text List AXUIElement Accessor

/// Faithfully models Chromium/Electron (`<ul><li>` and `<ol><li>`) Accessibility behavior:
/// - `kAXValueAttribute` serializes each bullet item with `"• "` (2 UTF-16 units), indented sub-bullets (`"  ◦ "`), or `"1. "` (3+ UTF-16 units).
/// - `kAXSelectedTextRangeAttribute` and `kAXSelectedTextAttribute` operate in DOM selection coordinates where
///   each list item marker counts as 1 unit (`"•"`), causing a cumulative offset shift per list item.
final class SimulatedSlackBulletAXAccessor: AXElementAccessing {
    var axValueText: String
    var selectedRangeInDOM: NSRange = NSRange(location: 0, length: 0)
    var collapseCRLFInDOM: Bool
    var forceUnrelatedSelectedText: String?
    var setRangeCallCount: Int = 0

    init(axValueText: String, collapseCRLFInDOM: Bool = false) {
        self.axValueText = axValueText
        self.collapseCRLFInDOM = collapseCRLFInDOM
    }

    private func markerLengthInAXLine(_ line: String) -> Int {
        let nsLine = line as NSString
        if let regex = try? NSRegularExpression(pattern: #"^\s*(?:[•◦▪▫▸‣⁃\-\*\+☐☑✓✔]|(?:\d+|[a-zA-Z])[\.\)])\s+"#),
           let match = regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: nsLine.length)),
           match.range.location == 0 {
            return match.range.length
        }
        return 0
    }

    /// Builds the DOM selection string where each line-leading list marker is represented as a single 1-unit marker `"•"`.
    private var domSelectionText: String {
        let normalizedNewlines = collapseCRLFInDOM ? axValueText.replacingOccurrences(of: "\r\n", with: "\n") : axValueText
        let lines = normalizedNewlines.components(separatedBy: "\n")
        let mapped = lines.map { line -> String in
            let markerLen = markerLengthInAXLine(line)
            if markerLen > 0 {
                let rest = (line as NSString).substring(from: markerLen)
                return "•" + rest
            }
            return line
        }
        return mapped.joined(separator: "\n")
    }

    func selectedTextIfRangeSet(_ range: NSRange) -> String {
        if let forced = forceUnrelatedSelectedText {
            return forced
        }
        let nsDOM = domSelectionText as NSString
        guard range.location >= 0, range.location < nsDOM.length else { return "" }
        let clampedLen = min(range.length, nsDOM.length - range.location)
        return nsDOM.substring(with: NSRange(location: range.location, length: max(0, clampedLen)))
    }

    func textIfReplacedWithoutCalibration(range: NSRange, replacement: String) -> String {
        let savedText = axValueText
        let savedSel = selectedRangeInDOM
        defer {
            axValueText = savedText
            selectedRangeInDOM = savedSel
        }
        selectedRangeInDOM = range
        _ = performPaste(replacement)
        return axValueText
    }

    func copyString(_ element: AXUIElement, attribute: String) -> String? {
        if attribute == (kAXValueAttribute as String) {
            return axValueText
        }
        if attribute == (kAXSelectedTextAttribute as String) {
            return selectedTextIfRangeSet(selectedRangeInDOM)
        }
        if attribute == (kAXRoleAttribute as String) {
            return "AXTextArea"
        }
        return nil
    }

    func copyRange(_ element: AXUIElement, attribute: String) -> NSRange? {
        if attribute == (kAXSelectedTextRangeAttribute as String) {
            return selectedRangeInDOM
        }
        return nil
    }

    func setRange(_ element: AXUIElement, attribute: String, range: NSRange) -> AXError {
        if attribute == (kAXSelectedTextRangeAttribute as String) {
            setRangeCallCount += 1
            let nsDOM = domSelectionText as NSString
            let clampedLoc = max(0, min(range.location, nsDOM.length))
            let clampedLen = max(0, min(range.length, nsDOM.length - clampedLoc))
            selectedRangeInDOM = NSRange(location: clampedLoc, length: clampedLen)
            return .success
        }
        return .failure
    }

    func setString(_ element: AXUIElement, attribute: String, value: String) -> AXError {
        return .attributeUnsupported
    }

    func isChromiumOrElectron(_ element: AXUIElement) -> Bool? {
        return true
    }

    func performPaste(_ text: String) -> Bool {
        // Map `selectedRangeInDOM` back into `axValueText` to mutate the underlying rich-text lines
        let separator = (collapseCRLFInDOM && axValueText.contains("\r\n")) ? "\r\n" : "\n"
        let sepLen = (separator as NSString).length
        let lines = axValueText.components(separatedBy: separator)
        var domOffset = 0
        var axOffset = 0
        var axStart = 0
        var axEnd = 0
        let domStart = selectedRangeInDOM.location
        let domEnd = selectedRangeInDOM.location + selectedRangeInDOM.length

        var foundStart = false
        var foundEnd = false

        for (i, line) in lines.enumerated() {
            let nsLine = line as NSString
            let markerAXLen = markerLengthInAXLine(line)
            let markerDOMLen = markerAXLen > 0 ? 1 : 0
            let contentLen = nsLine.length - markerAXLen
            let lineDOMLen = markerDOMLen + contentLen

            if !foundStart && domStart <= domOffset + lineDOMLen {
                let relDOM = domStart - domOffset
                let relAX = relDOM == 0 ? 0 : markerAXLen + max(0, relDOM - markerDOMLen)
                axStart = axOffset + relAX
                foundStart = true
            }
            if !foundEnd && domEnd <= domOffset + lineDOMLen {
                let relDOM = domEnd - domOffset
                let relAX = relDOM == 0 ? 0 : markerAXLen + max(0, relDOM - markerDOMLen)
                axEnd = axOffset + relAX
                foundEnd = true
            }

            domOffset += lineDOMLen + (i < lines.count - 1 ? 1 : 0)
            axOffset += nsLine.length + (i < lines.count - 1 ? sepLen : 0)
        }

        let nsAX = axValueText as NSString
        if foundStart && foundEnd && axEnd >= axStart && axEnd <= nsAX.length {
            axValueText = nsAX.replacingCharacters(
                in: NSRange(location: axStart, length: axEnd - axStart),
                with: text
            )
            return true
        }
        return false
    }
}
