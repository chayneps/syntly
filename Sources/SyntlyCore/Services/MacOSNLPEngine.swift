import Foundation
import AppKit
import NaturalLanguage

/// Native macOS on-device NLP engine powered by Apple's `NaturalLanguage` framework (`NLTokenizer`, `NLTagger`)
/// and `NSSpellChecker` to accelerate Check-While-Typing mode with zero external dependencies.
public enum MacOSNLPEngine {

    // MARK: - 0. Non-English Language Gate

    /// Returns `true` when the text starts with a non-English language (e.g., Thai, CJK, Cyrillic, Arabic,
    /// Hebrew, Devanagari, Greek, or a high-confidence non-English Latin phrase).
    /// Skips leading whitespace, digits, bullets, punctuation, and emojis before inspecting the opening letters.
    public static func startsWithNonEnglish(_ text: String) -> Bool {
        // Scan only the opening words directly without splitting the entire document (strict O(1)).
        var words: [String] = []
        words.reserveCapacity(8)
        var current = String.UnicodeScalarView()
        var inspectedScalars = 0
        let maxInspectScalars = 512

        for scalar in text.unicodeScalars {
            inspectedScalars += 1
            let isWordScalar = scalar.properties.isAlphabetic || scalar.value == 0x27 || scalar.value == 0x2019
            if isWordScalar {
                current.append(scalar)
            } else if !current.isEmpty {
                words.append(String(current))
                current.removeAll(keepingCapacity: true)
                if words.count >= 8 { break }
            }
            if inspectedScalars >= maxInspectScalars { break }
        }
        if !current.isEmpty && words.count < 8 {
            words.append(String(current))
        }

        guard let firstWord = words.first, let firstScalar = firstWord.unicodeScalars.first(where: { CharacterSet.letters.contains($0) }) else {
            return false
        }

        // 1. Instant script check on the first word:
        // Any non-Latin script (Thai 0x0E00..0x0E7F, CJK, Cyrillic, Arabic, Hebrew, Devanagari, Greek, etc.)
        if firstScalar.value > 0x024F || firstWord.unicodeScalars.contains(where: { $0.value > 0x024F }) {
            return true
        }

        // 2. Collect leading Latin-script words (stopping if a later word switches to non-Latin script)
        var leadingLatinWords: [String] = []
        for word in words {
            if word.unicodeScalars.contains(where: { $0.value > 0x024F }) {
                break
            }
            leadingLatinWords.append(word)
        }

        // Extended / accented Latin in the opening words (e.g. "¿Cómo estás", "Bonjour à tous")
        var accentedLatinCount = 0
        for word in leadingLatinWords.prefix(2) {
            for scalar in word.unicodeScalars where scalar.value > 0x007A && scalar.value <= 0x024F {
                accentedLatinCount += 1
            }
        }
        if firstScalar.value > 0x007A || accentedLatinCount >= 2 {
            return true
        }

        // 3. For leading Latin text with at least 3 words (or any accented Latin word), check NLLanguageRecognizer
        if leadingLatinWords.count >= 3 || accentedLatinCount >= 1 {
            let sample = leadingLatinWords.joined(separator: " ")
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(sample)
            let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
            if let top = hypotheses.max(by: { $0.value < $1.value }),
               top.key != .english,
               top.key != .undetermined,
               top.value >= 0.85,
               (hypotheses[.english] ?? 0.0) < 0.10 {
                return true
            }
        }

        return false
    }

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

        // Scan only a small local slice around `caret` so activeTypingWordRange stays O(1) even on 50k-char documents
        var sliceStart = max(0, caret - 96)
        if sliceStart > 0 {
            while sliceStart > 0 {
                let ch = nsText.character(at: sliceStart)
                if ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D || ch == 0x00A0 {
                    break
                }
                sliceStart -= 1
            }
            sliceStart = nsText.rangeOfComposedCharacterSequence(at: sliceStart).location
        }

        var sliceEnd = min(nsText.length, caret + 96)
        if sliceEnd < nsText.length {
            while sliceEnd < nsText.length {
                let ch = nsText.character(at: sliceEnd)
                if ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D || ch == 0x00A0 {
                    break
                }
                sliceEnd += 1
            }
            if sliceEnd < nsText.length {
                let seq = nsText.rangeOfComposedCharacterSequence(at: sliceEnd)
                sliceEnd = min(nsText.length, seq.location + seq.length)
            }
        }

        let localSlice = (sliceStart == 0 && sliceEnd == nsText.length)
            ? text
            : nsText.substring(with: NSRange(location: sliceStart, length: sliceEnd - sliceStart))
        let localCaret = caret - sliceStart

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = localSlice
        var matchingRange: NSRange?

        tokenizer.enumerateTokens(in: localSlice.startIndex..<localSlice.endIndex) { tokenRange, _ in
            let nsRange = NSRange(tokenRange, in: localSlice)
            if localCaret >= nsRange.location && localCaret <= nsRange.location + nsRange.length {
                matchingRange = NSRange(location: sliceStart + nsRange.location, length: nsRange.length)
                return false
            }
            return nsRange.location <= localCaret
        }

        return matchingRange
    }

    // MARK: - 3. Named Entity & Technical Token Immunity (`NLTagger`)

    /// Lazily indexes Named Entity UTF-16 spans once per analyzed chunk instead of rebuilding `NLTagger` for every capitalized word.
    private final class LazyNamedEntityIndex {
        private let text: String
        private var computed = false
        private var entityLocations = IndexSet()

        init(text: String) {
            self.text = text
        }

        func containsNamedEntity(in range: NSRange) -> Bool {
            if !computed {
                computed = true
                let tagger = NLTagger(tagSchemes: [.nameType])
                tagger.string = text
                tagger.enumerateTags(
                    in: text.startIndex..<text.endIndex,
                    unit: .word,
                    scheme: .nameType,
                    options: [.omitWhitespace, .omitPunctuation]
                ) { tag, tokenRange in
                    if tag == .personalName || tag == .organizationName || tag == .placeName {
                        let nsRange = NSRange(tokenRange, in: text)
                        if nsRange.length > 0 {
                            entityLocations.insert(integersIn: nsRange.location..<(nsRange.location + nsRange.length))
                        }
                    }
                    return true
                }
            }
            return entityLocations.intersects(integersIn: range.location..<(range.location + max(1, range.length)))
        }
    }

    /// Structural immunity checks (`@`, `#`, `/`, `` ` ``, `_`, digits, `ALL_CAPS`, `camelCase`) in O(|word|).
    private static func isStructurallyImmuneToken(_ word: String, at range: NSRange, in nsText: NSString) -> (immune: Bool, needsNamedEntityCheck: Bool) {
        guard !word.isEmpty else { return (true, false) }

        if range.location > 0 {
            let prev = nsText.character(at: range.location - 1)
            if prev == 0x40 || prev == 0x23 || prev == 0x2F || prev == 0x60 || prev == 0x5F {
                return (true, false)
            }
        }
        if range.location + range.length < nsText.length {
            let next = nsText.character(at: range.location + range.length)
            if next == 0x60 || next == 0x5F || next == 0x2F {
                return (true, false)
            }
        }

        // Fast scalar scan for digits, underscores, slashes, ALL_CAPS, and camelCase (no Array allocations)
        var letterCount = 0
        var upperCount = 0
        var isFirstUpper = false
        var hasInternalUpper = false
        var index = 0

        for scalar in word.unicodeScalars {
            let v = scalar.value
            if v == 0x5F || v == 0x2F || (v >= 0x30 && v <= 0x39) || CharacterSet.decimalDigits.contains(scalar) {
                return (true, false)
            }
            let isLetter = CharacterSet.letters.contains(scalar)
            let isUpper = CharacterSet.uppercaseLetters.contains(scalar)
            if isLetter {
                letterCount += 1
                if isUpper { upperCount += 1 }
            }
            if index == 0 {
                isFirstUpper = isUpper
            } else if isUpper {
                hasInternalUpper = true
            }
            index += 1
        }

        if letterCount >= 2 && upperCount == letterCount {
            return (true, false)
        }

        if index >= 3 && hasInternalUpper {
            return (true, false)
        }

        return (false, isFirstUpper)
    }

    /// Returns `true` if `word` at `range` in `text` is a code identifier (`camelCase`, `snake_case`, `ALL_CAPS`),
    /// `@mention`, `#channel`, URL/path, inline code, or a Named Entity (`.personalName`, `.organizationName`, `.placeName`).
    public static func isImmuneToken(_ word: String, at range: NSRange, in text: String) -> Bool {
        let nsText = text as NSString
        let (immune, needsNER) = isStructurallyImmuneToken(word, at: range, in: nsText)
        if immune { return true }

        // If capitalized mid-sentence, check Apple's `NLTagger` for Named Entity Recognition
        if needsNER {
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
        "lets": "let's",
        "thats": "that's",
        "whats": "what's",
        "theres": "there's",
        "heres": "here's",
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

    // MARK: - Precompiled Regex Patterns & Incremental Chunk Cache

    private static let dupRegex = try? NSRegularExpression(pattern: #"\b([A-Za-z]{2,})[ \t]+\1\b"#, options: [.caseInsensitive])
    private static let articleRegex = try? NSRegularExpression(pattern: #"\b(a|an|A|An)[ \t]+([A-Za-z]{2,})\b"#, options: [])
    private static let letRegex = try? NSRegularExpression(pattern: #"(?:^|\n)\s*(?:[•◦▪▫▸‣⁃\-\*\+]|\d+[\.\)])?\s*(Let)[ \t]+([a-z]{2,})\b"#, options: [])
    private static let missingSpaceRegex = try? NSRegularExpression(pattern: #"\b([A-Za-z]{2,})([\.\?\!])([A-Z][a-z]+)\b"#, options: [])
    private static let dupPunctRegex = try? NSRegularExpression(pattern: #"\b([A-Za-z0-9']+)([ \t]*(?:(?<!\.)\.\.(?!\.)|\?\?+|!!+|\?[ \t]*\.|\.[ \t]*\?|,[ \t]*\.))"#, options: [])
    private static let spaceBeforePunctRegex = try? NSRegularExpression(pattern: #"\b([A-Za-z0-9']+)[ \t]+([\.\?\!,;])(?![\.\?\!0-9A-Za-z])"#, options: [])
    private static let tailOrAndRegex = try? NSRegularExpression(pattern: #"^[ \t]+(or|and)\b"#, options: [.caseInsensitive])
    private static let lowerStartRegex = try? NSRegularExpression(pattern: #"\b([A-Za-z]{2,})([\.\?\!])[ \t]+([a-z]{2,})\b"#, options: [])
    private static let subjVerbRegex = try? NSRegularExpression(pattern: #"\b(It|He|She|This|That)[ \t]+(seem|appear|look|feel|sound)\b"#, options: [])
    private static let passiveFixRegex = try? NSRegularExpression(pattern: #"\b(is|was|are|were)[ \t]+((?:already[ \t]+)?fix)\b"#, options: [.caseInsensitive])
    private static let whatGoingRegex = try? NSRegularExpression(pattern: #"\b(what|who|where|how)[ \t]+going[ \t]+on\b"#, options: [.caseInsensitive])
    private static let steakRegex = try? NSRegularExpression(pattern: #"\b(eat|ate|eating|eats|cook|cooking|cooked|grilled|order|ordered|buy|bought|having)[ \t]+(stake|stakes)\b"#, options: [.caseInsensitive])

    private struct ChunkCacheKey: Hashable {
        let text: String
        let allowLineStartLetRule: Bool
        let spellLanguage: String
        let dictSignature: String
    }

    private static let chunkCacheLock = NSLock()
    private static var chunkCache: [ChunkCacheKey: [WritingIssue]] = [:]
    private static var chunkCacheOrder: [ChunkCacheKey] = []
    private static let maxChunkCacheEntries = 1000

    public static func clearLocalCache() {
        chunkCacheLock.lock()
        chunkCache.removeAll(keepingCapacity: true)
        chunkCacheOrder.removeAll(keepingCapacity: true)
        chunkCacheLock.unlock()
    }

    /// Splits a document into independent `\n`-delimited lines, and subdivides extraordinarily
    /// long single lines (> 700 UTF-16 units) at safe sentence boundaries (`". Capital"`, `"? Capital"`, `"! Capital"`)
    /// so typing at the end or middle of long documents only re-analyzes the active chunk in O(1).
    private static func partitionIntoIndependentChunks(nsText: NSString) -> [(range: NSRange, allowLineStartLetRule: Bool)] {
        let len = nsText.length
        guard len > 0 else { return [] }

        var chunks: [(range: NSRange, allowLineStartLetRule: Bool)] = []
        var lineStart = 0

        while lineStart < len {
            let lineRange = nsText.lineRange(for: NSRange(location: lineStart, length: 0))
            let lineEnd = lineRange.location + lineRange.length

            if lineRange.length <= 700 {
                chunks.append((lineRange, true))
            } else {
                var subStart = lineRange.location
                var isFirstSub = true
                var idx = lineRange.location

                while idx < lineEnd {
                    if idx - subStart >= 350 && (lineEnd - idx) >= 120 {
                        let ch = nsText.character(at: idx)
                        // Check clean sentence terminator '.', '?', '!' followed by space/tab + ASCII uppercase letter
                        if (ch == 0x2E || ch == 0x3F || ch == 0x21), idx + 2 < lineEnd {
                            let next1 = nsText.character(at: idx + 1)
                            if next1 == 0x20 || next1 == 0x09 {
                                var letterIdx = idx + 2
                                while letterIdx < lineEnd && (nsText.character(at: letterIdx) == 0x20 || nsText.character(at: letterIdx) == 0x09) {
                                    letterIdx += 1
                                }
                                if letterIdx < lineEnd {
                                    let starter = nsText.character(at: letterIdx)
                                    if starter >= 0x41 && starter <= 0x5A {
                                        // Avoid splitting abbreviations like "Mr. Smith" or decimal/version tokens like "v1.0"
                                        var allowSplit = true
                                        if ch == 0x2E && idx > subStart {
                                            var wordStart = idx
                                            var alphaCount = 0
                                            while wordStart > subStart {
                                                let prev = nsText.character(at: wordStart - 1)
                                                if (prev >= 0x41 && prev <= 0x5A) || (prev >= 0x61 && prev <= 0x7A) {
                                                    alphaCount += 1
                                                    wordStart -= 1
                                                } else if prev >= 0x30 && prev <= 0x39 {
                                                    allowSplit = false
                                                    break
                                                } else {
                                                    break
                                                }
                                            }
                                            if alphaCount < 2 {
                                                allowSplit = false
                                            } else if allowSplit {
                                                let prevWord = nsText.substring(with: NSRange(location: wordStart, length: idx - wordStart)).lowercased()
                                                if commonAbbreviationsBeforePeriod.contains(prevWord) {
                                                    allowSplit = false
                                                }
                                            }
                                        }
                                        if allowSplit {
                                            chunks.append((NSRange(location: subStart, length: letterIdx - subStart), isFirstSub))
                                            subStart = letterIdx
                                            isFirstSub = false
                                            idx = letterIdx
                                            continue
                                        }
                                    }
                                }
                            }
                        }
                    }
                    idx += 1
                }

                if subStart < lineEnd {
                    chunks.append((NSRange(location: subStart, length: lineEnd - subStart), isFirstSub))
                }
            }

            if lineEnd <= lineStart { break }
            lineStart = lineEnd
        }

        return chunks
    }

    private static func offsetChunkIssue(_ issue: WritingIssue, by offset: Int) -> WritingIssue {
        guard offset > 0, let loc = issue.utf16Location else { return issue }
        var copy = issue
        copy.utf16Location = loc + offset
        return copy
    }

    /// Runs a fast, 100% on-device pass combining:
    /// 1. Duplicate consecutive word detection (`"the the"` -> `"the"`)
    /// 2. Indefinite article `a` / `an` phonological validation (`"an typo"` -> `"a typo"`, `"a apple"` -> `"an apple"`)
    /// 3. Sentence/bullet-initial `"Let <verb>"` contraction detection (`"Let try"` -> `"Let's try"`, `"Let also"` -> `"Let's also"`)
    /// 4. `NSSpellChecker` contextual spelling & grammar checks with single-pass `NLTagger` entity immunity,
    ///    incremental chunk caching, and active-caret awareness.
    public static func analyzeLocally(
        text: String,
        caretUTF16Location: Int? = nil,
        dictionary: [String] = [],
        enableSpellcheck: Bool = true
    ) -> [WritingIssue] {
        guard enableSpellcheck else { return [] }
        // Fast non-whitespace check without allocating a trimmed String copy
        var nonWhitespaceCount = 0
        for scalar in text.unicodeScalars {
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                nonWhitespaceCount += 1
                if nonWhitespaceCount >= 3 { break }
            }
        }
        guard nonWhitespaceCount >= 3 else { return [] }

        let nsText = text as NSString
        let lowercasedDict = Set(dictionary.map { $0.lowercased() })
        let checker = NSSpellChecker.shared
        let spellLanguage = checker.language()

        // Fast path for short single-line text (avoids partitioning/cache dictionary overhead)
        let hasNewline = text.utf8.contains(0x0A) || text.utf8.contains(0x0D)
        if !hasNewline && nsText.length <= 450 {
            return analyzeChunk(
                text: text,
                nsText: nsText,
                caretUTF16Location: caretUTF16Location,
                allowLineStartLetRule: true,
                lowercasedDict: lowercasedDict,
                checker: checker,
                spellLanguage: spellLanguage
            )
        }

        let chunks = partitionIntoIndependentChunks(nsText: nsText)
        let dictSignature = lowercasedDict.sorted().joined(separator: "\u{1F}")
        var aggregated: [WritingIssue] = []

        for chunk in chunks {
            let chunkEnd = chunk.range.location + chunk.range.length
            let touchesCaret: Bool
            let localCaret: Int?
            if let caret = caretUTF16Location, caret >= chunk.range.location && caret <= chunkEnd {
                touchesCaret = true
                localCaret = caret - chunk.range.location
            } else {
                touchesCaret = false
                localCaret = nil
            }

            let chunkString = nsText.substring(with: chunk.range)
            // Quick skip for blank/tiny non-active lines (e.g. empty lines between paragraphs)
            var chunkNonWS = 0
            for scalar in chunkString.unicodeScalars {
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    chunkNonWS += 1
                    if chunkNonWS >= 2 { break }
                }
            }
            guard chunkNonWS >= 2 else { continue }

            if !touchesCaret {
                let key = ChunkCacheKey(
                    text: chunkString,
                    allowLineStartLetRule: chunk.allowLineStartLetRule,
                    spellLanguage: spellLanguage,
                    dictSignature: dictSignature
                )
                chunkCacheLock.lock()
                let hit = chunkCache[key]
                chunkCacheLock.unlock()

                if let cachedIssues = hit {
                    for issue in cachedIssues {
                        aggregated.append(offsetChunkIssue(issue, by: chunk.range.location))
                    }
                    continue
                }

                let computed = analyzeChunk(
                    text: chunkString,
                    nsText: chunkString as NSString,
                    caretUTF16Location: nil,
                    allowLineStartLetRule: chunk.allowLineStartLetRule,
                    lowercasedDict: lowercasedDict,
                    checker: checker,
                    spellLanguage: spellLanguage
                )

                chunkCacheLock.lock()
                if chunkCache[key] == nil {
                    if chunkCacheOrder.count >= maxChunkCacheEntries {
                        let oldest = chunkCacheOrder.removeFirst()
                        chunkCache.removeValue(forKey: oldest)
                    }
                    chunkCacheOrder.append(key)
                }
                chunkCache[key] = computed
                chunkCacheLock.unlock()

                for issue in computed {
                    aggregated.append(offsetChunkIssue(issue, by: chunk.range.location))
                }
            } else {
                let liveIssues = analyzeChunk(
                    text: chunkString,
                    nsText: chunkString as NSString,
                    caretUTF16Location: localCaret,
                    allowLineStartLetRule: chunk.allowLineStartLetRule,
                    lowercasedDict: lowercasedDict,
                    checker: checker,
                    spellLanguage: spellLanguage
                )
                for issue in liveIssues {
                    aggregated.append(offsetChunkIssue(issue, by: chunk.range.location))
                }
            }
        }

        return aggregated.sorted { ($0.utf16Location ?? 0) < ($1.utf16Location ?? 0) }
    }

    private static func analyzeChunk(
        text: String,
        nsText: NSString,
        caretUTF16Location: Int?,
        allowLineStartLetRule: Bool,
        lowercasedDict: Set<String>,
        checker: NSSpellChecker,
        spellLanguage: String
    ) -> [WritingIssue] {
        let activeWordRange = activeTypingWordRange(in: text, caretUTF16Location: caretUTF16Location)
        let entityIndex = LazyNamedEntityIndex(text: text)
        var issues: [WritingIssue] = []
        var coveredRanges: [NSRange] = []

        @inline(__always)
        func isTokenProtectedOrInDict(_ word: String, at range: NSRange) -> Bool {
            if lowercasedDict.contains(word.lowercased()) {
                return true
            }
            let (immune, needsNER) = isStructurallyImmuneToken(word, at: range, in: nsText)
            if immune { return true }
            if needsNER && entityIndex.containsNamedEntity(in: range) {
                return true
            }
            return false
        }

        func overlapsActiveCaretOrExisting(_ range: NSRange) -> Bool {
            if let active = activeWordRange, NSIntersectionRange(active, range).length > 0 {
                return true
            }
            if let caret = caretUTF16Location, range.location + range.length == caret {
                return true
            }
            return coveredRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }

        let fullRangeNS = NSRange(location: 0, length: nsText.length)

        // Pass 1: Consecutive duplicate words (e.g., "the the", "is is", "to to")
        if let dupRegex = dupRegex {
            let matches = dupRegex.matches(in: text, options: [], range: fullRangeNS)
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
        if let articleRegex = articleRegex {
            let matches = articleRegex.matches(in: text, options: [], range: fullRangeNS)
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
                if isTokenProtectedOrInDict(nextWord, at: nextWordRange) { continue }

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
        if allowLineStartLetRule, let letRegex = letRegex {
            let matches = letRegex.matches(in: text, options: [], range: fullRangeNS)
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

            let hasFused = commonFusedWords[lower] != nil
            let hasContraction = commonContractionTypos[lower] != nil
            guard hasFused || hasContraction else { return true }

            if isTokenProtectedOrInDict(word, at: wordRange) {
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
        // 5a. Missing space after sentence-ending punctuation (e.g., "not.Can" -> "not. Can", "fixed?Can" -> "fixed? Can")
        if let missingSpaceRegex = missingSpaceRegex {
            let matches = missingSpaceRegex.matches(in: text, options: [], range: fullRangeNS)
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
        if let dupPunctRegex = dupPunctRegex {
            let matches = dupPunctRegex.matches(in: text, options: [], range: fullRangeNS)
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
        if let spaceBeforePunctRegex = spaceBeforePunctRegex {
            let matches = spaceBeforePunctRegex.matches(in: text, options: [], range: fullRangeNS)
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
                    if afterIdx < nsText.length, let tailRegex = tailOrAndRegex {
                        let tailRange = NSRange(location: afterIdx, length: min(20, nsText.length - afterIdx))
                        if tailRegex.firstMatch(in: text, options: [], range: tailRange) != nil {
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
        if let lowerStartRegex = lowerStartRegex {
            let matches = lowerStartRegex.matches(in: text, options: [], range: fullRangeNS)
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
                if isTokenProtectedOrInDict(nextWord, at: nextWordRange) {
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

        // 5e. High-frequency spoken and grammar patterns (e.g., "It seem" -> "It seems", "what going on" -> "what's going on", "is already fix" -> "is already fixed")
        if let subjVerbRegex = subjVerbRegex {
            let matches = subjVerbRegex.matches(in: text, options: [], range: fullRangeNS)
            for match in matches {
                let fullRange = match.range
                let subjRange = match.range(at: 1)
                let verbRange = match.range(at: 2)
                guard fullRange.location != NSNotFound, !overlapsActiveCaretOrExisting(fullRange) else { continue }
                let subj = nsText.substring(with: subjRange)
                let verb = nsText.substring(with: verbRange)
                let orig = nsText.substring(with: fullRange)
                let repl = "\(subj) \(verb)s"
                issues.append(
                    WritingIssue(
                        original: orig,
                        replacement: repl,
                        category: .correctness,
                        explanation: "Subject-verb agreement: use '\(subj) \(verb)s'.",
                        utf16Location: fullRange.location,
                        utf16Length: fullRange.length,
                        isLocalSpellcheck: true
                    )
                )
                coveredRanges.append(fullRange)
            }
        }

        if let passiveFixRegex = passiveFixRegex {
            let matches = passiveFixRegex.matches(in: text, options: [], range: fullRangeNS)
            for match in matches {
                let fullRange = match.range
                let beRange = match.range(at: 1)
                let fixPartRange = match.range(at: 2)
                guard fullRange.location != NSNotFound, !overlapsActiveCaretOrExisting(fullRange) else { continue }
                let beWord = nsText.substring(with: beRange)
                let fixPart = nsText.substring(with: fixPartRange)
                let orig = nsText.substring(with: fullRange)
                let repl = fixPart.lowercased().contains("already") ? "\(beWord) already fixed" : "\(beWord) fixed"
                issues.append(
                    WritingIssue(
                        original: orig,
                        replacement: repl,
                        category: .correctness,
                        explanation: "Use past participle 'fixed'.",
                        utf16Location: fullRange.location,
                        utf16Length: fullRange.length,
                        isLocalSpellcheck: true
                    )
                )
                coveredRanges.append(fullRange)
            }
        }

        if let whatGoingRegex = whatGoingRegex {
            let matches = whatGoingRegex.matches(in: text, options: [], range: fullRangeNS)
            for match in matches {
                let fullRange = match.range
                let whRange = match.range(at: 1)
                guard fullRange.location != NSNotFound, !overlapsActiveCaretOrExisting(fullRange) else { continue }
                let wh = nsText.substring(with: whRange)
                let orig = nsText.substring(with: fullRange)
                let isCap = wh.first?.isUppercase == true
                let prefix = isCap ? (wh.prefix(1).uppercased() + wh.dropFirst().lowercased()) : wh.lowercased()
                let repl = "\(prefix)'s going on"
                issues.append(
                    WritingIssue(
                        original: orig,
                        replacement: repl,
                        category: .correctness,
                        explanation: "Add missing contraction: '\(repl)'.",
                        utf16Location: fullRange.location,
                        utf16Length: fullRange.length,
                        isLocalSpellcheck: true
                    )
                )
                coveredRanges.append(fullRange)
            }
        }

        // 5f. Common homophone confusions: "eat stake" -> "eat steak"
        if let steakRegex = steakRegex {
            let matches = steakRegex.matches(in: text, options: [], range: fullRangeNS)
            for match in matches {
                let fullRange = match.range
                let verbRange = match.range(at: 1)
                let stakeRange = match.range(at: 2)
                guard fullRange.location != NSNotFound, !overlapsActiveCaretOrExisting(fullRange) else { continue }
                let verb = nsText.substring(with: verbRange)
                let stakeWord = nsText.substring(with: stakeRange)
                let replStake = stakeWord.lowercased() == "stakes" ? "steaks" : "steak"
                let isStakeCap = stakeWord.first?.isUppercase == true
                let formattedStake = isStakeCap ? replStake.capitalized : replStake
                let orig = nsText.substring(with: fullRange)
                let repl = "\(verb) \(formattedStake)"
                issues.append(
                    WritingIssue(
                        original: orig,
                        replacement: repl,
                        category: .correctness,
                        explanation: "Did you mean '\(formattedStake)' instead of '\(stakeWord)'?",
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

            if isTokenProtectedOrInDict(word, at: misspelledRange) {
                continue
            }

            // Prefer macOS contextual autocorrect suggestion first, then fallback to top dictionary guess
            let contextualCorrection = checker.correction(
                forWordRange: misspelledRange,
                in: text,
                language: spellLanguage,
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

            guard wordRanges.count >= 2 else { continue }
            let firstWord = nsText.substring(with: wordRanges[0])
            let secondWord = nsText.substring(with: wordRanges[1])
            guard firstWord.first?.isUppercase == true else { continue }

            let opener = "\(firstWord.lowercased()) \(secondWord.lowercased())"
            let isDirectQuestion = directQuestionOpeners.contains(opener)
            let minWords = isDirectQuestion ? 3 : 4
            guard wordRanges.count >= minWords else { continue }

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
                    let alreadyCovered = coveredRanges.contains { NSIntersectionRange($0, targetRange).length > 0 }
                    if !alreadyCovered {
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
                let lastWord = nsText.substring(with: lastWordRange)
                let lastWordLower = lastWord.lowercased()
                guard !danglingTrailingWords.contains(lastWordLower) else { continue }

                // If last word is misspelled, let spellchecker flag it first
                if checker.checkSpelling(of: lastWord, startingAt: 0, language: spellLanguage, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location != NSNotFound {
                    continue
                }

                let targetRange = NSRange(location: secondLastWordRange.location, length: afterLastWordLoc - secondLastWordRange.location)
                let alreadyCovered = coveredRanges.contains { NSIntersectionRange($0, targetRange).length > 0 }
                if !alreadyCovered {
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
