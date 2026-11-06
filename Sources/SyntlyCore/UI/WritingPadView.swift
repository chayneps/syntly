import SwiftUI
import AppKit

public struct WritingPadView: View {
    @ObservedObject var coordinator: WritingAssistantCoordinator
    @ObservedObject var settings: AppSettings
    public var onOpenSettings: (() -> Void)?

    @State private var padText: String = ""
    @State private var padIssues: [WritingIssue] = []
    @State private var isCheckingPad: Bool = false
    @State private var padError: String?
    @State private var padDebounceTask: Task<Void, Never>?

    @State private var selectedCategory: IssueCategory? = nil
    @State private var showSavePresetSheet: Bool = false
    @State private var showManagePresetsSheet: Bool = false
    @State private var presetNameToSave: String = ""
    @State private var showClearConfirmation: Bool = false
    @State private var copiedNotification: Bool = false

    @State private var isRewritingPad: Bool = false
    @State private var selectedRewriteModifiers: Set<RewriteModifier> = []
    @State private var pendingRewriteText: String? = nil
    @State private var pendingRewriteModifiers: Set<RewriteModifier> = []
    @State private var lastRevertedText: String? = nil
    @State private var copiedRewriteNotification: Bool = false

    private var activePadModel: String {
        settings.rewriteModel.isEmpty ? settings.liveModel : settings.rewriteModel
    }

    private var wordCount: Int {
        padText.split(whereSeparator: \.isWhitespace).count
    }

    private var charCount: Int {
        padText.count
    }

    private var readingTimeMin: Int {
        max(1, Int(ceil(Double(wordCount) / 200.0)))
    }

    private var correctnessCount: Int {
        padIssues.filter { $0.category == .correctness }.count
    }

    private var clarityCount: Int {
        padIssues.filter { $0.category == .clarity }.count
    }

    private var toneCount: Int {
        padIssues.filter { $0.category == .tone }.count
    }

    private var fluencyCount: Int {
        padIssues.filter { $0.category == .fluency }.count
    }

    private var filteredIssues: [WritingIssue] {
        guard let cat = selectedCategory else { return padIssues }
        return padIssues.filter { $0.category == cat }
    }

    private var activePresetName: String {
        let current = settings.customStyleInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty {
            return "Standard (No Rule)"
        }
        if let match = settings.savedStyleRules.first(where: { $0.instruction.trimmingCharacters(in: .whitespacesAndNewlines) == current }) {
            return match.name
        }
        return "Custom Rule"
    }

    public init(
        coordinator: WritingAssistantCoordinator,
        settings: AppSettings = .shared,
        initialText: String = "",
        initialModifiers: Set<RewriteModifier> = [],
        initialIssues: [WritingIssue] = [],
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.settings = settings
        self._padText = State(initialValue: initialText)
        self._selectedRewriteModifiers = State(initialValue: initialModifiers)
        self._padIssues = State(initialValue: initialIssues)
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(spacing: 0) {
            // MARK: - Top Header & Toolbar
            headerBar
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            // MARK: - Style & Persona Rule Box
            styleRuleBar

            Divider()

            // MARK: - Main Workspace (Editor + Suggestions)
            HSplitView {
                // Left Column: Document Canvas & Rewrite Action Bar
                editorColumn
                    .frame(minWidth: 460)

                // Right Column: Live Suggestions & Corrections (narrower by default)
                suggestionsColumn
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            }
        }
        .frame(minWidth: 800, idealWidth: 1080, maxWidth: .infinity, minHeight: 680, idealHeight: 960, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            settings.refreshAuthStatus()
            coordinator.onIssueAccepted = { issue in
                if let range = padText.range(of: issue.original) {
                    padText.replaceSubrange(range, with: issue.replacement)
                    runPadCheck()
                }
            }
            coordinator.onAllIssuesAccepted = { _, updated in
                padText = updated
                runPadCheck()
            }
            if let incoming = coordinator.incomingWritingPadText, !incoming.isEmpty {
                padText = incoming
                coordinator.incomingWritingPadText = nil
                schedulePadCheck(for: incoming)
            } else if !padText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && padIssues.isEmpty {
                DispatchQueue.main.async {
                    runPadCheck()
                }
            }
        }
        .onChange(of: coordinator.incomingWritingPadText) { _, newText in
            if let newText = newText, !newText.isEmpty {
                padText = newText
                coordinator.incomingWritingPadText = nil
                schedulePadCheck(for: newText)
            }
        }
        .sheet(isPresented: $showSavePresetSheet) {
            savePresetSheet
        }
        .sheet(isPresented: $showManagePresetsSheet) {
            managePresetsSheet
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 14) {
            // Brand & Title
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 36, height: 36)
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Synt(ax)ly Writing Pad")
                        .font(.title2.bold())

                    HStack(spacing: 6) {
                        Circle()
                            .fill(settings.isAuthReady ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)

                        Text(activePadModel)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text(settings.dialect.rawValue)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Document Stats Pill
            if !padText.isEmpty {
                HStack(spacing: 12) {
                    Label("\(wordCount) words", systemImage: "doc.text")
                    Label("\(charCount) chars", systemImage: "textformat.size")
                    Label("~\(readingTimeMin) min read", systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.04), in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }

            Spacer()

            // Right Action Tools
            HStack(spacing: 8) {
                if !padText.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(padText, forType: .string)
                        copiedNotification = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copiedNotification = false
                        }
                    } label: {
                        Label(copiedNotification ? "Copied!" : "Copy", systemImage: copiedNotification ? "checkmark" : "doc.on.doc")
                    }
                    .controlSize(.regular)

                    Button(role: .destructive) {
                        if padText.count > 30 {
                            showClearConfirmation = true
                        } else {
                            padText = ""
                            padIssues.removeAll()
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Clear editor text")
                    .controlSize(.regular)
                    .confirmationDialog("Clear Writing Pad?", isPresented: $showClearConfirmation) {
                        Button("Clear All Text", role: .destructive) {
                            padText = ""
                            padIssues.removeAll()
                        }
                    }
                }

                if let onOpenSettings = onOpenSettings {
                    Button {
                        onOpenSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .controlSize(.regular)
                    .help("Open Settings")
                }
            }
        }
    }

    // MARK: - Style & Persona Rule Bar with Left-Side Re-check Button

    private var styleRuleBar: some View {
        HStack(alignment: .center, spacing: 14) {
            // LEFT SIDE: Twin Action Buttons (Re-check & Rewrite) with identical size and height
            HStack(spacing: 8) {
                // Re-check button
                Button {
                    LLMService.shared.clearCache()
                    runPadCheck()
                } label: {
                    VStack(spacing: 5) {
                        if isCheckingPad {
                            ProgressView()
                                .controlSize(.small)
                                .frame(height: 20)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.primary)
                        }

                        Text(isCheckingPad ? "Checking…" : "Re-check")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)

                        Text("⌘R")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 82)
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Re-check document for spelling, grammar, and style suggestions (⌘R)")
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(isCheckingPad)

                // Rewrite button (same size, same height)
                Button {
                    runActiveRewrite()
                } label: {
                    VStack(spacing: 5) {
                        if isRewritingPad {
                            ProgressView()
                                .controlSize(.small)
                                .frame(height: 20)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.primary)
                        }

                        Text(isRewritingPad ? "Rewriting…" : "Rewrite")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)

                        Text("⌘↵")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 82)
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Rewrite document with selected style or custom instructions (⌘Return)")
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(isRewritingPad || padText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // RIGHT SIDE: Custom Persona & Style Rule
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(.pink)
                        .font(.subheadline)

                    Text("Custom Persona & Style Rule:")
                        .font(.subheadline.bold())

                    Menu {
                        Section("Saved Style Presets") {
                            ForEach(settings.savedStyleRules) { preset in
                                Button {
                                    settings.customStyleInstruction = preset.instruction
                                    LLMService.shared.clearCache()
                                    if !padText.isEmpty {
                                        runPadCheck()
                                    }
                                } label: {
                                    if settings.customStyleInstruction.trimmingCharacters(in: .whitespacesAndNewlines) == preset.instruction.trimmingCharacters(in: .whitespacesAndNewlines) {
                                        Label(preset.name, systemImage: "checkmark")
                                    } else {
                                        Text(preset.name)
                                    }
                                }
                            }
                        }

                        Divider()

                        Button {
                            presetNameToSave = ""
                            showSavePresetSheet = true
                        } label: {
                            Label("Save Current Rule as Preset…", systemImage: "plus.circle")
                        }
                        .disabled(settings.customStyleInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button {
                            showManagePresetsSheet = true
                        } label: {
                            Label("Manage Presets…", systemImage: "slider.horizontal.3")
                        }

                        if !settings.customStyleInstruction.isEmpty {
                            Divider()
                            Button(role: .destructive) {
                                settings.customStyleInstruction = ""
                                LLMService.shared.clearCache()
                                if !padText.isEmpty {
                                    runPadCheck()
                                }
                            } label: {
                                Label("Clear Style Rule (Standard)", systemImage: "xmark")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(activePresetName)
                                .font(.caption.bold())
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Spacer()

                    if !settings.customStyleInstruction.isEmpty {
                        Button {
                            presetNameToSave = ""
                            showSavePresetSheet = true
                        } label: {
                            Label("Save Preset", systemImage: "square.and.arrow.down")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Save this rule as a reusable preset")

                        Button {
                            settings.customStyleInstruction = ""
                            LLMService.shared.clearCache()
                            if !padText.isEmpty {
                                runPadCheck()
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear custom style rule")
                    }
                }

                // Multiline Box for Custom Persona / Style Instructions
                ZStack(alignment: .topLeading) {
                    if settings.customStyleInstruction.isEmpty {
                        Text("Type custom instructions or persona (e.g. 'Prefer active voice, keep sentences concise, and use bullet points for lists')…")
                            .font(.callout)
                            .foregroundStyle(Color.secondary.opacity(0.6))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }

                    TextField(
                        "",
                        text: $settings.customStyleInstruction,
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .onChange(of: settings.customStyleInstruction) { _, _ in
                        if !padText.isEmpty {
                            schedulePadCheck(for: padText)
                        }
                    }
                }
                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )

                // Row 3: Multi-Select Rewrite Modifiers (Functional Levers)
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(RewriteModifier.allCases) { modifier in
                                let isSelected = selectedRewriteModifiers.contains(modifier)
                                Button {
                                    if isSelected {
                                        selectedRewriteModifiers.remove(modifier)
                                    } else {
                                        if modifier == .fixOnly {
                                            selectedRewriteModifiers = [.fixOnly]
                                        } else {
                                            selectedRewriteModifiers.remove(.fixOnly)
                                            selectedRewriteModifiers.insert(modifier)
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(isSelected ? Color.pink : Color.secondary)

                                        Text(modifier.title)
                                            .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        isSelected
                                            ? Color.pink.opacity(0.12)
                                            : Color(NSColor.controlBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 6)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(
                                                isSelected
                                                    ? Color.pink.opacity(0.4)
                                                    : Color.primary.opacity(0.12),
                                                lineWidth: 1
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                                .help(modifier.instruction)
                            }
                        }
                    }

                    Spacer()

                    if isRewritingPad {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Rewriting…")
                                .font(.caption2.bold())
                                .foregroundStyle(.pink)
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
    }

    // MARK: - Editor Column (Left)

    private var editorColumn: some View {
        VStack(spacing: 12) {
            // Top Section: Original Document Editor
            VStack(alignment: .leading, spacing: 0) {
                // Header showing "Original Document" if rewrite preview is open
                if pendingRewriteText != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Original Document")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    Divider()
                }

                // Undo banner if text was replaced/inserted
                if let prev = lastRevertedText {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .foregroundStyle(.blue)
                        Text("Text updated with AI rewrite.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Revert to Original") {
                            padText = prev
                            lastRevertedText = nil
                            schedulePadCheck(for: padText)
                        }
                        .font(.caption.bold())
                        .buttonStyle(.link)

                        Button {
                            lastRevertedText = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.08))

                    Divider()
                }

                // Main Text Editor Canvas
                ZStack(alignment: .topLeading) {
                    if padText.isEmpty {
                        Text("Start typing, paste an email, draft an essay, or test sentences here…")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $padText)
                        .disableWritingToolsIfAvailable()
                        .font(.system(size: 15))
                        .lineSpacing(5)
                        .padding(14)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .onChange(of: padText) { _, newValue in
                            schedulePadCheck(for: newValue)
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )

            // Bottom Section: AI Rewrite Result Preview Card (Positioned UNDER Original Text)
            if let rewrite = pendingRewriteText {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.pink)
                                .font(.caption)
                            let modifiersTitle: String = {
                                if pendingRewriteModifiers.isEmpty {
                                    return "Custom Style"
                                } else {
                                    return RewriteModifier.allCases
                                        .filter { pendingRewriteModifiers.contains($0) }
                                        .map(\.title)
                                        .joined(separator: " + ")
                                }
                            }()
                            Text("AI Rewrite (\(modifiersTitle)) Result:")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                        }
                        Spacer()
                        Button {
                            withAnimation {
                                pendingRewriteText = nil
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss rewrite preview")
                    }

                    ScrollView {
                        Text(rewrite)
                            .font(.system(size: 14))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .frame(minHeight: 90, maxHeight: 180)
                    .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.pink.opacity(0.3), lineWidth: 1)
                    )

                    HStack(spacing: 8) {
                        Button {
                            lastRevertedText = padText
                            padText = rewrite
                            withAnimation {
                                pendingRewriteText = nil
                            }
                            schedulePadCheck(for: rewrite)
                        } label: {
                            Label("Take Rewrite (Replace Original)", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)

                        Button {
                            lastRevertedText = padText
                            padText = padText.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + rewrite
                            withAnimation {
                                pendingRewriteText = nil
                            }
                            schedulePadCheck(for: padText)
                        } label: {
                            Label("Insert Below Original", systemImage: "text.append")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(rewrite, forType: .string)
                            copiedRewriteNotification = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copiedRewriteNotification = false
                            }
                        } label: {
                            Label(copiedRewriteNotification ? "Copied!" : "Copy", systemImage: copiedRewriteNotification ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)

                        Spacer()

                        Button("Discard") {
                            withAnimation {
                                pendingRewriteText = nil
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(Color.pink.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.pink.opacity(0.25), lineWidth: 1)
                )
            }
        }
        .padding(16)
    }

    // MARK: - Suggestions Column (Right)

    private var suggestionsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Suggestions Header & Action
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("Suggestions")
                            .font(.headline)

                        Text("(\(padIssues.count))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Text("Accept will change the original text")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if padIssues.count > 1 {
                    Button("Accept All") {
                        var workingText = padText
                        let resolvedPairs: [(issue: WritingIssue, range: NSRange)] = padIssues.compactMap { issue in
                            let range = AXEngine.findBestOccurrenceRange(
                                of: issue.original,
                                preferredUTF16Location: issue.utf16Location,
                                in: workingText
                            )
                            guard range.location != NSNotFound else { return nil }
                            return (issue, range)
                        }.sorted { $0.range.location > $1.range.location }

                        var nsWorking = workingText as NSString
                        for pair in resolvedPairs {
                            if pair.range.location + pair.range.length <= nsWorking.length {
                                workingText = nsWorking.replacingCharacters(in: pair.range, with: pair.issue.replacement)
                                nsWorking = workingText as NSString
                            }
                        }
                        padText = workingText
                        padIssues.removeAll()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Accept all suggestions and update the original text on the left")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Guidance Notice Banner
            if !padIssues.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.pink)
                    Text("Accepting will change the original text on the left.")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.pink.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.pink.opacity(0.2), lineWidth: 1)
                )
                .padding(.horizontal, 16)
            }

            // Category Filter Pills
            if !padIssues.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        categoryFilterPill(title: "All (\(padIssues.count))", category: nil)

                        if correctnessCount > 0 {
                            categoryFilterPill(title: "Correctness (\(correctnessCount))", category: .correctness)
                        }
                        if clarityCount > 0 {
                            categoryFilterPill(title: "Clarity (\(clarityCount))", category: .clarity)
                        }
                        if toneCount > 0 {
                            categoryFilterPill(title: "Tone (\(toneCount))", category: .tone)
                        }
                        if fluencyCount > 0 {
                            categoryFilterPill(title: "Fluency (\(fluencyCount))", category: .fluency)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            // Error Notice
            if let err = padError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16)
            }

            // Suggestions List or Empty State
            if padText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary.opacity(0.35))
                    Text("Ready for Writing")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                    Text("Start typing or paste text on the left. Synt(ax)ly will check grammar, spelling, clarity, and your custom style rules in real time.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if padIssues.isEmpty && !isCheckingPad {
                VStack(spacing: 12) {
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.12))
                            .frame(width: 56, height: 56)
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.green)
                    }
                    Text("All Clear!")
                        .font(.headline)
                    Text("No errors or style issues detected. Your writing matches your style rules and dialect preferences.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(filteredIssues) { issue in
                            IssueCardRow(
                                issue: issue,
                                onAccept: {
                                    let nsPad = padText as NSString
                                    let targetRange = AXEngine.findBestOccurrenceRange(
                                        of: issue.original,
                                        preferredUTF16Location: issue.utf16Location,
                                        in: padText
                                    )
                                    let delta = (issue.replacement as NSString).length - (issue.original as NSString).length
                                    if targetRange.location != NSNotFound && targetRange.location + targetRange.length <= nsPad.length {
                                        padText = nsPad.replacingCharacters(in: targetRange, with: issue.replacement)
                                    }
                                    let replacedLoc = targetRange.location != NSNotFound ? targetRange.location : (issue.utf16Location ?? 0)
                                    var updatedIssues: [WritingIssue] = []
                                    for var remaining in padIssues where remaining.id != issue.id {
                                        if let loc = remaining.utf16Location, loc > replacedLoc {
                                            remaining.utf16Location = max(0, loc + delta)
                                        }
                                        updatedIssues.append(remaining)
                                    }
                                    padIssues = updatedIssues
                                },
                                onDismiss: {
                                    padIssues.removeAll { $0.id == issue.id }
                                },
                                onAddToDictionary: {
                                    settings.addWordToDictionary(issue.original)
                                    padIssues.removeAll { $0.id == issue.id }
                                },
                                acceptHelpText: "Accept will replace '\(issue.original)' with '\(issue.replacement)' in the original text",
                                showsTargetHint: true
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
    }

    private func categoryFilterPill(title: String, category: IssueCategory?) -> some View {
        let isSelected = selectedCategory == category
        return Button {
            selectedCategory = category
        } label: {
            Text(title)
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isSelected ? Color.pink : Color.primary.opacity(0.08), in: Capsule())
                .foregroundColor(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Save Preset Sheet

    private var savePresetSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.title2)
                    .foregroundStyle(.pink)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Save Style Rule Preset")
                        .font(.headline)
                    Text("Save this writing rule to easily reuse it in Writing Pad.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Preset Name:")
                    .font(.caption.bold())
                TextField("e.g. Client Emails, Technical Blog, Formal Report", text: $presetNameToSave)
                    .textFieldStyle(.roundedBorder)

                Text("Rule Instruction:")
                    .font(.caption.bold())
                    .padding(.top, 4)
                Text(settings.customStyleInstruction)
                    .font(.caption)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showSavePresetSheet = false
                }
                Button("Save Preset") {
                    settings.saveStyleRule(name: presetNameToSave, instruction: settings.customStyleInstruction)
                    showSavePresetSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(presetNameToSave.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: - Manage Presets Sheet

    private var managePresetsSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Manage Saved Style Presets")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    showManagePresetsSheet = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Text("Click a preset to apply it, or delete presets you no longer need.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(settings.savedStyleRules) { preset in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preset.name)
                                .font(.subheadline.bold())
                            Text(preset.instruction)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Apply") {
                            settings.customStyleInstruction = preset.instruction
                            LLMService.shared.clearCache()
                            if !padText.isEmpty {
                                runPadCheck()
                            }
                            showManagePresetsSheet = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            settings.removeStyleRule(id: preset.id)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Delete preset")
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(height: 260)
        }
        .padding(20)
        .frame(width: 500)
    }

    // MARK: - AI Checking & Rewriting Logic

    private func schedulePadCheck(for text: String) {
        let local = LLMService.shared.runLocalSpellcheck(on: text)
        if !local.isEmpty && padIssues.isEmpty {
            padIssues = local
        }

        padDebounceTask?.cancel()
        padDebounceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(settings.debounceMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            runPadCheck()
        }
    }

    private func runPadCheck() {
        let text = padText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            padIssues = []
            return
        }

        let local = LLMService.shared.runLocalSpellcheck(on: text)

        guard settings.isAuthReady else {
            padIssues = local
            padError = "Please configure your API endpoint in Settings."
            isCheckingPad = false
            return
        }

        isCheckingPad = true
        padError = nil

        Task {
            do {
                let ai = try await LLMService.shared.proofread(text: text, model: activePadModel)
                var merged = ai
                for item in local where !merged.contains(where: { $0.original.localizedCaseInsensitiveContains(item.original) }) {
                    merged.append(item)
                }
                await MainActor.run {
                    self.padIssues = merged
                    self.isCheckingPad = false
                }
            } catch {
                await MainActor.run {
                    self.padIssues = local
                    self.padError = error.localizedDescription
                    self.isCheckingPad = false
                }
            }
        }
    }

    private func runActiveRewrite() {
        runPadRewrite(modifiers: selectedRewriteModifiers)
    }

    private func runPadRewrite(modifiers: Set<RewriteModifier>) {
        let text = padText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        guard settings.isAuthReady else {
            padError = "Please configure your API endpoint in Settings."
            isRewritingPad = false
            return
        }

        isRewritingPad = true
        padError = nil

        let customPrompt: String?
        if modifiers.isEmpty {
            let userStyle = settings.customStyleInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
            if !userStyle.isEmpty {
                customPrompt = "Rewrite and polish the text adhering strictly to the user's custom style / persona instructions, preserving all original facts and intent."
            } else {
                customPrompt = "Improve clarity, flow, and phrasing while preserving all original facts, meaning, and intent."
            }
        } else {
            customPrompt = nil
        }

        Task {
            do {
                let rewritten = try await LLMService.shared.rewrite(
                    text: text,
                    modifiers: modifiers,
                    customPrompt: customPrompt,
                    model: activePadModel
                )
                await MainActor.run {
                    self.pendingRewriteText = rewritten
                    self.pendingRewriteModifiers = modifiers
                    self.isRewritingPad = false
                }
            } catch {
                await MainActor.run {
                    self.padError = error.localizedDescription
                    self.isRewritingPad = false
                }
            }
        }
    }
}
