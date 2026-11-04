import Foundation
import AppKit
import NaturalLanguage

/// Native macOS on-device NLP engine powered by Apple's `NaturalLanguage` framework (`NLTokenizer`, `NLTagger`)
/// and `NSSpellChecker` to accelerate Check-While-Typing mode with zero external dependencies.
public enum MacOSNLPEngine {

    // MARK: - 1. Sentence & Bullet Clause Segmentation (`NLTokenizer`)

    public struct SentenceSegment: Equatable {
        public let text: String
        public let utf16Range: NSRange

        public init(text: String, utf16Range: NSRange) {
            self.text = text
            self.utf16Range = utf16Range
        }
    }

    /// Segments text into discrete lines and sentences using `NLTokenizer(unit: .sentence)`
    /// while preserving exact UTF-16 `NSRange` offsets.
    public static func segmentSentences(in text: String) -> [SentenceSegment] {
        let nsText = text as NSString
        guard nsText.length > 0 else { return [] }

        var segments: [SentenceSegment] = []
        var lineStart = 0

        while lineStart < nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: lineStart, length: 0))
            let lineString = nsText.substring(with: lineRange)

            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = lineString

            var foundInLine = false
            tokenizer.enumerateTokens(in: lineString.startIndex..<lineString.endIndex) { tokenRange, _ in
                let localNSRange = NSRange(tokenRange, in: lineString)
                let globalRange = NSRange(location: lineRange.location + localNSRange.location, length: localNSRange.length)
                let substr = nsText.substring(with: globalRange)
                if !substr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(SentenceSegment(text: substr, utf16Range: globalRange))
                    foundInLine = true
                }
                return true
            }

            if !foundInLine && !lineString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(SentenceSegment(text: lineString, utf16Range: lineRange))
            }

            let nextStart = lineRange.location + lineRange.length
            if nextStart <= lineStart { break }
            lineStart = nextStart
        }

        return segments
    }

    // MARK: - 2. Active-Word Caret Awareness (`NLTokenizer(unit: .word)`)

    /// Returns the UTF-16 `NSRange` of the word currently being typed at `caretUTF16Location`, if the caret
    /// is inside the word or directly touching its trailing character (before the user presses space or punctuation).
    public static func activeTypingWordRange(in text: String, caretUTF16Location: Int?) -> NSRange? {
        guard let caret = caretUTF16Location else { return nil }
        let nsText = text as NSString
        guard caret > 0, caret <= nsText.length else { return nil }

        // A word is actively being typed if the character immediately before the caret is a word character
        // and the character at the caret (if any) is either EOF, whitespace, newline, or another word character.
        let prevChar = nsText.character(at: caret - 1)
        guard let prevScalar = UnicodeScalar(prevChar),
              CharacterSet.alphanumerics.contains(prevScalar) || prevChar == 0x27 || prevChar == 0x2019 else {
            return nil
        }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var matchingRange: NSRange?

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { tokenRange, _ in
            let nsRange = NSRange(tokenRange, in: text)
            if caret >= nsRange.location && caret <= nsRange.location + nsRange.length {
                matchingRange = nsRange
                return false
            }
            return nsRange.location <= caret
        }

        return matchingRange
    }

    // MARK: - 3. Named Entity & Technical Token Immunity (`NLTagger`)

    /// Returns `true` if `word` at `range` in `text` is a code identifier (`camelCase`, `snake_case`, `ALL_CAPS`),
    /// `@mention`, `#channel`, URL/path, inline code, or a Named Entity (`.personalName`, `.organizationName`, `.placeName`).
    public static func isImmuneToken(_ word: String, at range: NSRange, in text: String) -> Bool {
        guard !word.isEmpty else { return true }
        let nsText = text as NSString

        // 1. Check characters immediately preceding `range` for '@', '#', '/', '`', or '_'
        if range.location > 0 {
            let prev = nsText.character(at: range.location - 1)
            if prev == 0x40 || prev == 0x23 || prev == 0x2F || prev == 0x60 || prev == 0x5F {
                return true
            }
        }
        if range.location + range.length < nsText.length {
            let next = nsText.character(at: range.location + range.length)
            if next == 0x60 || next == 0x5F || next == 0x2F {
                return true
            }
        }

        // 2. Skip words containing digits, underscores, slashes, or URLs
        if word.contains("_") || word.contains("/") || word.rangeOfCharacter(from: .decimalDigits) != nil {
            return true
        }

        // 3. Skip ALL_CAPS acronyms (e.g. "API", "DMG", "JSON", "CLI")
        let lettersOnly = word.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if lettersOnly.count >= 2 && lettersOnly.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) }) {
            return true
        }

        // 4. Skip camelCase / internal uppercase identifiers (e.g. "cliProxy", "SyntlyCore", "macOS", "iOS")
        let scalars = Array(word.unicodeScalars)
        if scalars.count >= 3 {
            let hasInternalUpper = scalars.dropFirst().contains { CharacterSet.uppercaseLetters.contains($0) }
            if hasInternalUpper {
                return true
            }
        }

        // 5. If capitalized mid-sentence, check Apple's `NLTagger` for Named Entity Recognition
        if let first = scalars.first, CharacterSet.uppercaseLetters.contains(first) {
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = text
            if let swiftRange = Range(range, in: text) {
                let (tag, _) = tagger.tag(at: swiftRange.lowerBound, unit: .word, scheme: .nameType)
                if tag == .personalName || tag == .organizationName || tag == .placeName {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - 4. Instant On-Device Linguistic, Grammar & Spell Analysis (<3ms)

    private static let silentHWords: Set<String> = [
        "hour", "hours", "hourly", "honest", "honestly", "honesty",
        "honor", "honors", "honour", "honours", "honorable", "honourable",
        "heir", "heirs", "heirloom"
    ]

    private static let consonantSoundVowelPrefixes: [String] = [
        "uni", "use", "usu", "uti", "ura", "uro", "eup", "eur", "one", "once"
    ]

    private static let commonBareVerbsAfterLet: Set<String> = [
        "also", "try", "go", "check", "see", "make", "do", "start", "test",
        "get", "take", "look", "review", "discuss", "fix", "build", "run",
        "talk", "meet", "find", "keep", "move", "work", "wait", "think"
    ]

    private static let commonFusedWords: [String: String] = [
        "alot": "a lot",
        "incase": "in case",
        "atleast": "at least",
        "infront": "in front",
        "aswell": "as well",
        "eachother": "each other",
        "everytime": "every time"
    ]

    private static let commonContractionTypos: [String: String] = [
        "dont": "don't",
        "cant": "can't",
        "wont": "won't",
        "didnt": "didn't",
        "couldnt": "couldn't",
        "wouldnt": "wouldn't",
        "shouldnt": "shouldn't",
        "doesnt": "doesn't",
        "isnt": "isn't",
        "arent": "aren't",
        "hasnt": "hasn't",
        "havent": "haven't",
        "wasnt": "wasn't",
        "werent": "weren't"
    ]

    private static let commonAbbreviationsBeforePeriod: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "no", "fig",
        "inc", "ltd", "co", "corp", "vs", "etc", "approx", "dept", "est",
        "min", "max", "misc", "ref", "vol", "jan", "feb", "mar", "apr",
        "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"
    ]

    private static let commonSentenceStarterWords: Set<String> = [
        "I", "It", "He", "She", "We", "They", "You", "The", "This", "That",
        "These", "Those", "Can", "Could", "Would", "Should", "Will", "Do",
        "Does", "Did", "Is", "Are", "Was", "Were", "Have", "Has", "Had",
        "What", "Why", "How", "When", "Where", "Who", "Which", "Please",
        "Let", "But", "And", "So", "If", "As", "In", "On", "At", "For",
        "To", "No", "Yes", "However", "Also", "Then", "There", "Here"
    ]

    private static let directQuestionOpeners: Set<String> = [
        "can you", "can i", "can we", "can he", "can she", "can they", "can it", "can this", "can that", "can someone", "can anyone",
        "could you", "could i", "could we", "could he", "could she", "could they", "could it", "could someone", "could anyone",
        "would you", "would i", "would we", "would he", "would she", "would they", "would it",
        "will you", "will i", "will we", "will he", "will she", "will they", "will it", "will this",
        "should i", "should we", "should you", "should he", "should she", "should they", "should it",
        "do you", "do i", "do we", "do they",
        "does it", "does this", "does that", "does he", "does she", "does anyone", "does someone",
        "did you", "did i", "did we", "did he", "did she", "did they", "did it",
        "are you", "are we", "are they", "are there", "are these", "are those",
        "is it", "is this", "is that", "is there", "is he", "is she", "is anyone",
        "have you", "have we", "have they", "has it", "has he", "has she", "has anyone", "had you",
        "may i", "may we", "might it",
        "won't you", "don't you", "didn't you", "doesn't it", "isn't it", "aren't you", "can't you", "can't we", "couldn't you", "wouldn't you", "shouldn't we",
        "what is", "what's", "what are", "what was", "what were", "what do", "what does", "what did", "what can", "what could", "what would", "what should", "what will", "what have", "what has", "what happened", "what about", "what if",
        "why is", "why's", "why are", "why was", "why were", "why do", "why does", "why did", "why can", "why can't", "why don't", "why didn't", "why would", "why should",
        "how is", "how's", "how are", "how was", "how were", "how do", "how does", "how did", "how can", "how could", "how would", "how should", "how will", "how have", "how has", "how many", "how much", "how long", "how often", "how far", "how about", "how come",
        "where is", "where's", "where are", "where was", "where were", "where do", "where does", "where did", "where can", "where could", "where should", "where will",
        "when is", "when's", "when are", "when was", "when were", "when do", "when does", "when did", "when can", "when could", "when should", "when will",
        "who is", "who's", "who are", "who was", "who were", "who did", "who can", "who will", "who has",
        "which is", "which are", "which one", "which ones"
    ]

    private static let danglingTrailingWords: Set<String> = [
        "to", "the", "a", "an", "and", "or", "but", "if", "of", "in", "on", "at",
        "by", "for", "with", "from", "into", "about", "as", "is", "are", "was",
        "were", "be", "been", "can", "could", "would", "should", "will", "do",
        "does", "did", "have", "has", "had", "not", "very", "so", "too", "my",
        "your", "his", "her", "our", "their", "its", "than", "what", "where",
        "when", "who", "why", "how", "which", "because", "while", "although"
    ]

    /// Runs a fast, 100% on-device pass combining:
    /// 1. Duplicate consecutive word detection (`"the the"` -> `"the"`)
    /// 2. Indefinite article `a` / `an` phonological validation (`"an typo"` -> `"a typo"`, `"a apple"` -> `"an apple"`)
    /// 3. Sentence/bullet-initial `"Let <verb>"` contraction detection (`"Let try"` -> `"Let's try"`, `"Let also"` -> `"Let's also"`)
    /// 4. `NSSpellChecker` contextual spelling & grammar checks with `NLTagger` entity immunity and active-caret awareness
    public static func analyzeLocally(
        text: String,
        caretUTF16Location: Int? = nil,
        dictionary: [String] = [],
        enableSpellcheck: Bool = true
    ) -> [WritingIssue] {
        guard enableSpellcheck else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return [] }

        let nsText = text as NSString
        let activeWordRange = activeTypingWordRange(in: text, caretUTF16Location: caretUTF16Location)
        var issues: [WritingIssue] = []
        var coveredRanges: [NSRange] = []

        func overlapsActiveCaretOrExisting(_ range: NSRange) -> Bool {
            if let active = activeWordRange, NSIntersectionRange(active, range).length > 0 {
                return true
            }
            if let caret = caretUTF16Location, range.location + range.length == caret {
                return true
            }
            return coveredRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }

        // Pass 1: Consecutive duplicate words (e.g., "the the", "is is", "to to")
        if let dupRegex = try? NSRegularExpression(pattern: #"\b([A-Za-z]{2,})[ \t]+\1\b"#, options: [.caseInsensitive]) {
            let matches = dupRegex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
            for match in matches {
                let fullRange = match.range
                let firstWordRange = match.range(at: 1)
                guard fullRange.location != NSNotFound,
                      firstWordRange.location != NSNotFound,
                      !overlapsActiveCaretOrExisting(fullRange) else {
                    continue
                }
                let fullSubstring = nsText.substring(with: fullRange)
                let firstWord = nsText.substring(with: firstWordRange)
                // Only flag common lowercase duplicate words (avoid intentional "had had" if needed, though "the the" / "is is" are clear)
                if firstWord.lowercased() != "had" && firstWord.lowercased() != "that" {
                    issues.append(
                        WritingIssue(
                            original: fullSubstring,
                            replacement: firstWord,
                            category: .correctness,
                            explanation: "Remove repeated word '\(firstWord)'.",
                            utf16Location: fullRange.location,
                            utf16Length: fullRange.length,
                            isLocalSpellcheck: true
                        )
                    )
                    coveredRanges.append(fullRange)
                }
            }
        }

        // Pass 2: Indefinite article "a" vs "an" phonological check
        if let articleRegex = try? NSRegularExpression(pattern: #"\b(a|an|A|An)[ \t]+([A-Za-z]{2,})\b"#, options: []) {
            let matches = articleRegex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
            for match in matches {
                let fullRange = match.range
                let articleRange = match.range(at: 1)
                let nextWordRange = match.range(at: 2)
                guard fullRange.location != NSNotFound,
                      !overlapsActiveCaretOrExisting(fullRange) else {
                    continue
                }

                let article = nsText.substring(with: articleRange)
                let nextWord = nsText.substring(with: nextWordRange)
                // Skip if nextWord is an ALL_CAPS acronym or in personal dictionary
                if isImmuneToken(nextWord, at: nextWordRange, in: text) { continue }

                let shouldUseAn = startsWithVowelSound(nextWord)
                let isCurrentlyAn = article.lowercased() == "an"

                if shouldUseAn != isCurrentlyAn {
                    let isCapitalized = article.first?.isUppercase == true
                    let correctArticle = shouldUseAn ? (isCapitalized ? "An" : "an") : (isCapitalized ? "A" : "a")
                    let originalPhrase = nsText.substring(with: fullRange)
                    let replacementPhrase = "\(correctArticle) \(nextWord)"
                    issues.append(
                        WritingIssue(
                            original: originalPhrase,
                            replacement: replacementPhrase,
                            category: .correctness,
                            explanation: "Use '\(correctArticle)' before '\(nextWord)'.",
                            utf16Location: fullRange.location,
                            utf16Length: fullRange.length,
                            isLocalSpellcheck: true
                        )
                    )
                    coveredRanges.append(fullRange)
                }
            }
        }

        // Pass 3: Sentence or bullet-initial "Let <bare-verb/also>" -> "Let's <bare-verb/also>"
        if let letRegex = try? NSRegularExpression(pattern: #"(?:^|\n)\s*(?:[•◦▪▫▸‣⁃\-\*\+]|\d+[\.\)])?\s*(Let)[ \t]+([a-z]{2,})\b"#, options: []) {
            let matches = letRegex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
            for match in matches {
                let letRange = match.range(at: 1)
                let secondRange = match.range(at: 2)
                guard letRange.location != NSNotFound, secondRange.location != NSNotFound else { continue }
                let combinedRange = NSRange(
                    location: letRange.location,
                    length: (secondRange.location + secondRange.length) - letRange.location
                )
                guard !overlapsActiveCaretOrExisting(combinedRange) else { continue }

                let secondWord = nsText.substring(with: secondRange).lowercased()
                if commonBareVerbsAfterLet.contains(secondWord) {
                    let origPhrase = nsText.substring(with: combinedRange)
                    let replPhrase = "Let's " + nsText.substring(with: secondRange)
                    issues.append(
                        WritingIssue(
                            original: origPhrase,
                            replacement: replPhrase,
                            category: .correctness,
                            explanation: "Use contraction 'Let's' instead of 'Let'.",
                            utf16Location: combinedRange.location,
                            utf16Length: combinedRange.length,
                            isLocalSpellcheck: true
                        )
                    )
                    coveredRanges.append(combinedRange)
                }
            }
        }

        // Pass 4: High-frequency fused-word and contraction typos (e.g., "alot" -> "a lot", "dont" -> "don't")
        let wordTokenizer = NLTokenizer(unit: .word)
        wordTokenizer.string = text
        wordTokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { tokenRange, _ in
            let wordRange = NSRange(tokenRange, in: text)
            guard !overlapsActiveCaretOrExisting(wordRange) else { return true }
            let word = nsText.substring(with: wordRange)
            let lower = word.lowercased()

            if isImmuneToken(word, at: wordRange, in: text) || dictionary.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
                return true
            }

            if let repl = commonFusedWords[lower] {
                let isCap = word.first?.isUppercase == true
                let formattedRepl = isCap ? (repl.prefix(1).uppercased() + repl.dropFirst()) : repl
                issues.append(
                    WritingIssue(
                        original: word,
                        replacement: formattedRepl,
                        category: .correctness,
                        explanation: "Split into two words: '\(formattedRepl)'.",
                        utf16Location: wordRange.location,
                        utf16Length: wordRange.length,
                        isLocalSpellcheck: true
                    )
                )
                coveredRanges.append(wordRange)
            } else if let repl = commonContractionTypos[lower] {
                let isCap = word.first?.isUppercase == true
                let formattedRepl = isCap ? (repl.prefix(1).uppercased() + repl.dropFirst()) : repl
                issues.append(
                    WritingIssue(
                        original: word,
                        replacement: formattedRepl,
                        category: .correctness,
                        explanation: "Add missing apostrophe: '\(formattedRepl)'.",
                        utf16Location: wordRange.location,
                        utf16Length: wordRange.length,
                        isLocalSpellcheck: true
                    )
                )
                coveredRanges.append(wordRange)
            }
            return true
        }

        // Pass 5: Inline punctuation spacing, duplicate/mixed punctuation, and sentence-start capitalization
        let checker = NSSpellChecker.shared

        // 5a. Missing space after sentence-ending punctuation (e.g., "not.Can" -> "not. Can", "fixed?Can" -> "fixed? Can")
        if let missingSpaceRegex = try? NSRegularExpression(pattern: #"\b([A-Za-z]{2,})([\.\?\!])([A-Z][a-z]+)\b"#, options: []) {
            let matches = missingSpaceRegex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
            for match in matches {
                let fullRange = match.range
                let firstWordRange = match.range(at: 1)
                let punctRange = match.range(at: 2)
                let secondWordRange = match.range(at: 3)
                guard fullRange.location != NSNotFound, !overlapsActiveCaretOrExisting(fullRange) else { continue }

                let firstWord = nsText.substring(with: firstWordRange)
                let punct = nsText.substring(with: punctRange)
                let secondWord = nsText.substring(with: secondWordRange)

                // Avoid code identifiers like "object.Property" unless secondWord is a clear English sentence starter
                if punct == "." && !commonSentenceStarterWords.contains(secondWord) {
                    continue
                }

                let orig = nsText.substring(with: fullRange)
                let repl = "\(firstWord)\(punct) \(secondWord)"
                issues.append(
                    WritingIssue(
                        original: orig,
                        replacement: repl,
                        category: .correctness,
                        explanation: "Add a space after '\(punct)'.",
                        utf16Location: fullRange.location,
                        utf16Length: fullRange.length,
                        isLocalSpellcheck: true
                    )
                )
                coveredRanges.append(fullRange)
            }
        }

        // 5b. Duplicate or conflicting terminal punctuation (e.g., "that?." -> "that?", "fixed.." -> "fixed.", "that ? ." -> "that?")
        if let dupPunctRegex = try? NSRegularExpression(pattern: #"\b([A-Za-z0-9']+)([ \t]*(?:(?<!\.)\.\.(?!\.)|\?\?+|!!+|\?[ \t]*\.|\.[ \t]*\?|,[ \t]*\.))"#, options: []) {
            let matches = dupPunctRegex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
            for match in matches {
                let fullRange = match.range
                let wordRange = match.range(at: 1)
                let punctPartRange = match.range(at: 2)
                guard fullRange.location != NSNotFound, !overlapsActiveCaretOrExisting(fullRange) else { continue }

                let word = nsText.substring(with: wordRange)
                let punctPart = nsText.substring(with: punctPartRange)
                let targetPunct: String
                if punctPart.contains("?") {
                    targetPunct = "?"
                } else if punctPart.contains("!") {
                    targetPunct = "!"
                } else {
                    targetPunct = "."
                }
                let orig = nsText.substring(with: fullRange)
                let repl = "\(word)\(targetPunct)"
                guard orig != repl else { continue }

                issues.append(
                    WritingIssue(
                        original: orig,
                        replacement: repl,
                        category: .correctness,
                        explanation: "Use single punctuation mark '\(targetPunct)'.",
                        utf16Location: fullRange.location,
                        utf16Length: fullRange.length,
                        isLocalSpellcheck: true
                    )
                )
                coveredRanges.append(fullRange)
            }
        }

        // 5c. Stray space before sentence/clause punctuation (e.g., "that ?" -> "that?", "fixed ." -> "fixed.", "wait ," -> "wait,")
        if let spaceBeforePunctRegex = try? NSRegularExpression(pattern: #"\b([A-Za-z0-9']+)[ \t]+([\.\?\!,;])(?![\.\?\!0-9A-Za-z])"#, options: []) {
            let matches = spaceBeforePunctRegex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
            for match in matches {
                let fullRange = match.range
                let wordRange = match.range(at: 1)
                let punctRange = match.range(at: 2)
                guard fullRange.location != NSNotFound, !overlapsActiveCaretOrExisting(fullRange) else { continue }

                let word = nsText.substring(with: wordRange)
                let punct = nsText.substring(with: punctRange)

                // Skip meta-mentions like "punctuation like . or ?"
                if word.lowercased() == "like" {
                    let afterIdx = fullRange.location + fullRange.length
                    if afterIdx < nsText.length {
                        let tail = nsText.substring(from: afterIdx)
                        if tail.range(of: #"^[ \t]+(or|and)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                            continue
                        }
                    }
                }

                // Skip if the word itself is misspelled so Pass 6 fixes the spelling first
                if checker.checkSpelling(of: word, startingAt: 0).location != NSNotFound {
                    continue
                }

                let orig = nsText.substring(with: fullRange)
                let repl = "\(word)\(punct)"
                issues.append(
                    WritingIssue(
                        original: orig,
                        replacement: repl,
                        category: .correctness,
                        explanation: "Remove extra space before '\(punct)'.",
                        utf16Location: fullRange.location,
                        utf16Length: fullRange.length,
                        isLocalSpellcheck: true
                    )
                )
                coveredRanges.append(fullRange)
            }
        }

        // 5d. Lowercase start of a sentence after ". ", "? ", or "! " (e.g., "or not. can you" -> "or not. Can you")
        if let lowerStartRegex = try? NSRegularExpression(pattern: #"\b([A-Za-z]{2,})([\.\?\!])[ \t]+([a-z]{2,})\b"#, options: []) {
            let matches = lowerStartRegex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
            for match in matches {
                let fullRange = match.range
                let prevWordRange = match.range(at: 1)
                let punctRange = match.range(at: 2)
                let nextWordRange = match.range(at: 3)
                guard fullRange.location != NSNotFound, !overlapsActiveCaretOrExisting(fullRange) else { continue }

                let prevWord = nsText.substring(with: prevWordRange)
                let punct = nsText.substring(with: punctRange)
                let nextWord = nsText.substring(with: nextWordRange)

                if punct == "." && commonAbbreviationsBeforePeriod.contains(prevWord.lowercased()) {
                    continue
                }
                if isImmuneToken(nextWord, at: nextWordRange, in: text) || dictionary.contains(where: { $0.caseInsensitiveCompare(nextWord) == .orderedSame }) {
                    continue
                }
                if checker.checkSpelling(of: nextWord, startingAt: 0).location != NSNotFound {
                    continue
                }

                let capitalizedNext = nextWord.prefix(1).uppercased() + nextWord.dropFirst()
                let orig = nsText.substring(with: fullRange)
                let repl = "\(prevWord)\(punct) \(capitalizedNext)"
                issues.append(
                    WritingIssue(
                        original: orig,
                        replacement: repl,
                        category: .correctness,
                        explanation: "Capitalize '\(capitalizedNext)' at the start of the sentence.",
                        utf16Location: fullRange.location,
                        utf16Length: fullRange.length,
                        isLocalSpellcheck: true
                    )
                )
                coveredRanges.append(fullRange)
            }
        }

        // Pass 6: NSSpellChecker with contextual correction, entity immunity, and active-caret protection
        var searchOffset = 0

        while searchOffset < nsText.length {
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

            searchOffset = misspelledRange.location + misspelledRange.length

            if overlapsActiveCaretOrExisting(misspelledRange) {
                continue
            }

            let word = nsText.substring(with: misspelledRange)

            if dictionary.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
                continue
            }

            if isImmuneToken(word, at: misspelledRange, in: text) {
                continue
            }

            // Prefer macOS contextual autocorrect suggestion first, then fallback to top dictionary guess
            let contextualCorrection = checker.correction(
                forWordRange: misspelledRange,
                in: text,
                language: checker.language(),
                inSpellDocumentWithTag: 0
            )
            let topGuess = contextualCorrection ?? checker.guesses(
                forWordRange: misspelledRange,
                in: text,
                language: nil,
                inSpellDocumentWithTag: 0
            )?.first

            if let replacement = topGuess, replacement != word {
                issues.append(
                    WritingIssue(
                        original: word,
                        replacement: replacement,
                        category: .correctness,
                        explanation: "Possible spelling mistake.",
                        utf16Location: misspelledRange.location,
                        utf16Length: misspelledRange.length,
                        isLocalSpellcheck: true
                    )
                )
                coveredRanges.append(misspelledRange)
            }
        }

        // Pass 7: Terminal sentence punctuation ("Can you check that" -> "check that?", "Try to think about the way to make some test" -> "some test.")
        let segments = segmentSentences(in: text)
        for segment in segments {
            let segTokenizer = NLTokenizer(unit: .word)
            segTokenizer.string = segment.text
            var wordRanges: [NSRange] = []
            segTokenizer.enumerateTokens(in: segment.text.startIndex..<segment.text.endIndex) { tokenRange, _ in
                let localRange = NSRange(tokenRange, in: segment.text)
                wordRanges.append(NSRange(location: segment.utf16Range.location + localRange.location, length: localRange.length))
                return true
            }

            guard wordRanges.count >= 4 else { continue }
            let firstWord = nsText.substring(with: wordRanges[0])
            let secondWord = nsText.substring(with: wordRanges[1])
            guard firstWord.first?.isUppercase == true else { continue }

            let opener = "\(firstWord.lowercased()) \(secondWord.lowercased())"
            let isDirectQuestion = directQuestionOpeners.contains(opener)

            let lastWordRange = wordRanges[wordRanges.count - 1]
            let secondLastWordRange = wordRanges[wordRanges.count - 2]
            let afterLastWordLoc = lastWordRange.location + lastWordRange.length
            let segmentEndLoc = segment.utf16Range.location + segment.utf16Range.length

            let trailingSlice = afterLastWordLoc < segmentEndLoc
                ? nsText.substring(with: NSRange(location: afterLastWordLoc, length: segmentEndLoc - afterLastWordLoc))
                : ""
            let trimmedTrailing = trailingSlice.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedTrailing == "." && isDirectQuestion {
                let nsTrailing = trailingSlice as NSString
                let dotOffset = nsTrailing.range(of: ".").location
                if dotOffset != NSNotFound {
                    let fullEndLoc = afterLastWordLoc + dotOffset + 1
                    let targetRange = NSRange(location: secondLastWordRange.location, length: fullEndLoc - secondLastWordRange.location)
                    if !overlapsActiveCaretOrExisting(targetRange) {
                        let origWithDot = nsText.substring(with: targetRange)
                        let origWordsOnly = nsText.substring(with: NSRange(location: secondLastWordRange.location, length: afterLastWordLoc - secondLastWordRange.location))
                        issues.append(
                            WritingIssue(
                                original: origWithDot,
                                replacement: "\(origWordsOnly)?",
                                category: .correctness,
                                explanation: "Use a question mark '?' at the end of a question.",
                                utf16Location: targetRange.location,
                                utf16Length: targetRange.length,
                                isLocalSpellcheck: true
                            )
                        )
                        coveredRanges.append(targetRange)
                    }
                }
            } else if trimmedTrailing.isEmpty {
                let lastWordLower = nsText.substring(with: lastWordRange).lowercased()
                guard !danglingTrailingWords.contains(lastWordLower) else { continue }

                let targetRange = NSRange(location: secondLastWordRange.location, length: afterLastWordLoc - secondLastWordRange.location)
                if !overlapsActiveCaretOrExisting(targetRange) {
                    let origPhrase = nsText.substring(with: targetRange)
                    let (replacementPunct, explanation): (String, String) = isDirectQuestion
                        ? ("?", "Add a question mark '?' at the end of the question.")
                        : (".", "Add a period '.' at the end of the sentence.")
                    issues.append(
                        WritingIssue(
                            original: origPhrase,
                            replacement: "\(origPhrase)\(replacementPunct)",
                            category: .correctness,
                            explanation: explanation,
                            utf16Location: targetRange.location,
                            utf16Length: targetRange.length,
                            isLocalSpellcheck: true
                        )
                    )
                    coveredRanges.append(targetRange)
                }
            }
        }

        return issues.sorted { ($0.utf16Location ?? 0) < ($1.utf16Location ?? 0) }
    }

    private static func startsWithVowelSound(_ word: String) -> Bool {
        let lower = word.lowercased()
        guard let first = lower.unicodeScalars.first else { return false }

        if silentHWords.contains(lower) {
            return true
        }

        for prefix in consonantSoundVowelPrefixes where lower.hasPrefix(prefix) {
            return false
        }

        let vowels = CharacterSet(charactersIn: "aeiou")
        return vowels.contains(first)
    }
}
