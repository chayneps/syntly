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
        XCTAssertEqual(coordinator.totalFixesApplied, 1)
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
        XCTAssertEqual(coordinator.totalFixesApplied, 2)
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
}
