import SwiftUI

public struct FloatingOverlayView: View {
    @ObservedObject var coordinator: WritingAssistantCoordinator
    @State private var selectedTab: OverlayTab = .suggestions

    public enum OverlayTab: String, CaseIterable {
        case suggestions = "Suggestions"
        case rewrite = "Rewrite"
    }

    public init(coordinator: WritingAssistantCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        Group {
            if coordinator.isPopoverExpanded {
                expandedCardView
            } else {
                compactPillView
            }
        }
        .frame(
            width: coordinator.isPopoverExpanded ? 380 : 150,
            height: coordinator.isPopoverExpanded ? 348 : 44
        )
    }

    // MARK: - Compact Corner Status Pill

    private var compactPillView: some View {
        HStack(spacing: 6) {
            Button {
                coordinator.isPopoverExpanded = true
                coordinator.onOverlayStateChanged?()
            } label: {
                HStack(spacing: 6) {
                    pillStatusIcon
                    Text(pillStatusLabel)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(pillBorderColor.opacity(0.65), lineWidth: 1.2)
                )
            }
            .buttonStyle(.plain)
            .help("Click to open Syntly suggestions (⌘⇧G) • Quick-accept top fix (⌥Tab)")
        }
        .frame(width: 150, height: 44)
    }

    @ViewBuilder
    private var pillStatusIcon: some View {
        switch coordinator.pillState {
        case .allClear:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 13, weight: .bold))
        case .checking:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        case .issuesFound(let count, let topCategory):
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(topCategory.badgeColor, in: Capsule())
        case .paused:
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 13))
        }
    }

    private var pillStatusLabel: String {
        switch coordinator.pillState {
        case .allClear:
            return "Syntly"
        case .checking:
            return "Checking…"
        case .issuesFound(let count, _):
            return count == 1 ? "1 fix" : "\(count) fixes"
        case .paused:
            return "Paused"
        case .error:
            return "Retry"
        }
    }

    private var pillBorderColor: Color {
        switch coordinator.pillState {
        case .allClear: return .green
        case .checking: return .blue
        case .issuesFound(_, let topCategory): return topCategory.badgeColor
        case .paused: return .gray
        case .error: return .orange
        }
    }

    // MARK: - Expanded Suggestion & Rewrite Card

    private var expandedCardView: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerBar

            Picker("", selection: $selectedTab) {
                ForEach(OverlayTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if selectedTab == .suggestions {
                suggestionsListContent
            } else {
                rewriteTabContent
            }

            footerBar
        }
        .padding(12)
        .frame(width: 380, height: 348)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
    }

    private var headerBar: some View {
        HStack {
            Image(systemName: "sparkles")
                .foregroundStyle(.blue)
            Text("Syntly Writing Assistant")
                .font(.system(size: 13, weight: .bold))

            if let appName = coordinator.currentContext?.appName {
                Text("• \(appName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if coordinator.issues.count > 1 && selectedTab == .suggestions {
                Button("Accept All (\(coordinator.issues.count))") {
                    coordinator.acceptAllIssues()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button {
                coordinator.isPopoverExpanded = false
                coordinator.onOverlayStateChanged?()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Suggestions Tab

    @ViewBuilder
    private var suggestionsListContent: some View {
        if coordinator.pillState == .checking && coordinator.issues.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                ProgressView()
                Text("Analyzing your writing with Gemini…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if coordinator.issues.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.green)
                Text("Looks clear and polished!")
                    .font(.system(size: 13, weight: .semibold))
                Text("Keep typing—Syntly checks your sentences automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let err = coordinator.lastErrorMessage {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(coordinator.issues) { issue in
                        IssueCardRow(
                            issue: issue,
                            onAccept: { coordinator.acceptIssue(issue) },
                            onDismiss: { coordinator.dismissIssue(issue) },
                            onAddToDictionary: { coordinator.addIssueWordToDictionary(issue) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Rewrite Tab

    private var rewriteTabContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(RewritePreset.allCases) { preset in
                        Button {
                            coordinator.runRewritePreset(preset)
                        } label: {
                            Label(preset.title, systemImage: preset.iconName)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("Custom instruction (e.g. 'make bullet points')", text: $coordinator.customRewritePrompt)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button("Run") {
                    coordinator.runRewritePreset(.fixGrammar, customPrompt: coordinator.customRewritePrompt)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(coordinator.customRewritePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if coordinator.isRewriting {
                VStack {
                    Spacer()
                    ProgressView("Rewriting with Gemini…")
                        .font(.caption)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if let preview = coordinator.rewrittenPreview {
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView {
                        Text(preview)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                    HStack {
                        Button("Replace in App") {
                            coordinator.applyRewrittenPreview()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(preview, forType: .string)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()
                    }
                }
            } else {
                Spacer()
                Text("Select a tone preset above or enter a custom instruction to rewrite the current selection or paragraph.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
    }

    private var footerBar: some View {
        HStack {
            Text("Quick accept: ⌥Tab • Toggle: ⌘⇧G")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            if let bundleID = coordinator.currentContext?.bundleID,
               let appName = coordinator.currentContext?.appName {
                Menu {
                    Button("Recheck Now") {
                        if let para = coordinator.currentContext?.activeParagraph {
                            coordinator.triggerImmediateCheck(for: para)
                        }
                    }
                    Button("Pause Syntly for 1 Hour") {
                        coordinator.settings.pauseForOneHour()
                        coordinator.isPopoverExpanded = false
                        coordinator.onOverlayStateChanged?()
                    }
                    Button("Disable in \(appName)") {
                        coordinator.settings.toggleAppBlocked(bundleID: bundleID)
                        coordinator.isPopoverExpanded = false
                        coordinator.onOverlayStateChanged?()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 22)
            }
        }
    }
}

// MARK: - Single Issue Diff Row

struct IssueCardRow: View {
    let issue: WritingIssue
    let onAccept: () -> Void
    let onDismiss: () -> Void
    let onAddToDictionary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(issue.category.badgeColor)
                    .frame(width: 7, height: 7)
                Text(issue.category.shortLabel.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(issue.category.badgeColor)

                if issue.isLocalSpellcheck {
                    Text("• Instant")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Accept") {
                    onAccept()
                }
                .buttonStyle(.borderedProminent)
                .tint(issue.category.badgeColor)
                .controlSize(.mini)

                Button {
                    onAddToDictionary()
                } label: {
                    Image(systemName: "text.book.closed")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Add '\(issue.original)' to Personal Dictionary")

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Ignore this suggestion")
            }

            HStack(spacing: 6) {
                Text(issue.original)
                    .strikethrough(true, color: .red)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(issue.replacement)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(issue.category.badgeColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
            }

            Text(issue.explanation)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
