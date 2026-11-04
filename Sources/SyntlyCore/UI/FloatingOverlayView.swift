import SwiftUI

public enum OverlayTab: String, CaseIterable {
    case suggestions = "Suggestions"
    case openWritingPad = "Open writing pad to rewrite"
}

// MARK: - App Icon Loader

func loadAppIconImage() -> NSImage? {
    if let img = NSApp.applicationIconImage, img.isValid {
        return img
    }
    if let url = Bundle.main.url(forResource: "app_icon_1024", withExtension: "png"),
       let img = NSImage(contentsOf: url) {
        return img
    }
    let devPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("assets/app_icon_1024.png")
    if let img = NSImage(contentsOf: devPath) {
        return img
    }
    return nil
}

// MARK: - Floating Pill View (48x48 Companion)

public struct FloatingPillView: View {
    @ObservedObject var coordinator: WritingAssistantCoordinator
    @State private var isHovered: Bool = false
    @State private var hasPushedCursor: Bool = false

    public init(coordinator: WritingAssistantCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            // 1. Authentic Manga Thought Bubble App Icon (36x36)
            Image(nsImage: StatusBarController.renderMangaBubble(size: 36))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)
                .scaleEffect(isHovered ? 1.08 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)

            // 2. Status Badge / Spinner
            statusBadgeOverlay
        }
        .frame(width: 48, height: 48)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            coordinator.handlePillHover(hovering)
            if hovering && !hasPushedCursor {
                hasPushedCursor = true
                NSCursor.openHand.push()
            } else if !hovering && hasPushedCursor {
                hasPushedCursor = false
                NSCursor.pop()
            }
        }
        .onDisappear {
            if hasPushedCursor {
                hasPushedCursor = false
                NSCursor.pop()
            }
        }
        .help(tooltipText)
    }

    private var tooltipText: String {
        switch coordinator.pillState {
        case .allClear:
            return "Synt(ax)ly — All Clear • Drag to move • Click to open (⌘⇧G) • Right-click for options • Double-click to reset"
        case .checking:
            return "Synt(ax)ly — Checking your writing… • Drag to move • Right-click for options"
        case .issuesFound(let count, _):
            return "Synt(ax)ly — \(count) fix\(count == 1 ? "" : "es") found • Quick-accept: ⌥Tab • Drag to move • Hover badge to peek • Click to view • Right-click for options"
        case .paused:
            return "Synt(ax)ly — Paused • Click to resume • Right-click for options"
        case .error:
            return "Synt(ax)ly — Connection issue • Click to inspect • Right-click for options"
        }
    }

    @ViewBuilder
    private var statusBadgeOverlay: some View {
        switch coordinator.pillState {
        case .allClear:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .background(Circle().fill(.white).padding(1.5))
                .font(.system(size: 13, weight: .bold))
                .offset(x: 4, y: -4)

        case .checking:
            MangaThinkingDotsBadge()
                .offset(x: 6, y: -5)

        case .issuesFound(let count, let topCategory):
            ZStack(alignment: .topTrailing) {
                Text("\(count)")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 16, minHeight: 16)
                    .padding(.horizontal, 3)
                    .background(topCategory.badgeColor, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .scaleEffect(coordinator.isBadgeHovered ? 1.15 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.7), value: coordinator.isBadgeHovered)
                    .offset(x: 5, y: -5)
            }
            .frame(width: 26, height: 26, alignment: .topTrailing)
            .contentShape(Rectangle())
            .onHover { hovering in
                coordinator.handleBadgeHover(hovering)
            }
            .help("Hover 1s to peek • Click to view")

        case .paused:
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.secondary)
                .background(Circle().fill(.white).padding(1.5))
                .font(.system(size: 13))
                .offset(x: 4, y: -4)

        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .background(Circle().fill(.white).padding(1.5))
                .font(.system(size: 13))
                .offset(x: 4, y: -4)
        }
    }
}

// MARK: - Floating Dialog View (380x348 Expanded Card)

public struct FloatingDialogView: View {
    @ObservedObject var coordinator: WritingAssistantCoordinator
    @State private var selectedTab: OverlayTab = .suggestions

    public init(coordinator: WritingAssistantCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerBar

            Picker("", selection: $selectedTab) {
                ForEach(OverlayTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: selectedTab) { _, newTab in
                if newTab == .openWritingPad {
                    coordinator.openWritingPadToRewrite()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        selectedTab = .suggestions
                    }
                }
            }

            if selectedTab == .suggestions {
                suggestionsListContent
            } else {
                openWritingPadTabContent
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
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering in
            coordinator.handleDialogHover(hovering)
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                coordinator.openedByHover = false
            }
        )
    }

    private var headerBar: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(nsImage: StatusBarController.renderMangaBubble(size: 20))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Synt(ax)ly Writing Assistant")
                        .font(.system(size: 13, weight: .bold))

                    if let appName = coordinator.currentContext?.appName {
                        Text("• \(appName)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                // Show model name for when you type
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.blue)
                    Text("Type Model: \(coordinator.settings.liveModel)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
                .help("Drag header to move dialog • Double-click to reset position")

            Spacer()

            if coordinator.issues.count > 1 && selectedTab == .suggestions {
                Button("Accept All (\(coordinator.issues.count))") {
                    coordinator.acceptAllIssues()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button {
                coordinator.cancelHoverTimers()
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
            VStack(spacing: 12) {
                Spacer()
                MangaThinkingDotsBadge()
                    .scaleEffect(1.25)
                Text("Analyzing your writing…")
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
                Text("Keep typing—Synt(ax)ly checks your sentences automatically.")
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

                Button {
                    coordinator.openWritingPadToRewrite()
                } label: {
                    Label("Open writing pad to rewrite", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 6)

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

                    Button {
                        coordinator.openWritingPadToRewrite()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.forward.app")
                            Text("Open writing pad to rewrite")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.purple)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Open Writing Pad to Rewrite Tab

    private var openWritingPadTabContent: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "wand.and.stars")
                .font(.system(size: 32))
                .foregroundStyle(.purple)

            Text("Rewrite in Writing Pad")
                .font(.system(size: 14, weight: .semibold))

            Text("The check-while-you-type popup is designed for quick spelling & grammar fixes. Use Writing Pad to rewrite paragraphs with custom presets, tones, and formatting.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Button {
                coordinator.openWritingPadToRewrite()
            } label: {
                Label("Open writing pad to rewrite", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .controlSize(.regular)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer Bar

    private var footerBar: some View {
        HStack {
            Text("Quick accept: ⌥Tab • Toggle: ⌘⇧G")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Spacer()

            if let bundleID = coordinator.currentContext?.bundleID ?? coordinator.currentContext?.appName {
                let appName = coordinator.currentContext?.appName ?? "Current App"
                Menu {
                    Button("Open Writing Pad to Rewrite") {
                        coordinator.openWritingPadToRewrite()
                    }
                    Button("Check Paragraph Now") {
                        if let para = coordinator.currentContext?.activeParagraph {
                            coordinator.triggerImmediateCheck(for: para)
                        }
                    }
                    Button("Pause Synt(ax)ly for 1 Hour") {
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

// MARK: - Unified Wrapper for Previews & Tests

public struct FloatingOverlayView: View {
    @ObservedObject var coordinator: WritingAssistantCoordinator

    public init(coordinator: WritingAssistantCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        Group {
            if coordinator.isPopoverExpanded {
                FloatingDialogView(coordinator: coordinator)
            } else {
                FloatingPillView(coordinator: coordinator)
            }
        }
        .frame(
            width: coordinator.isPopoverExpanded ? 380 : 48,
            height: coordinator.isPopoverExpanded ? 348 : 48
        )
    }
}

// MARK: - Single Issue Diff Row

struct IssueCardRow: View {
    let issue: WritingIssue
    let onAccept: () -> Void
    let onDismiss: () -> Void
    let onAddToDictionary: () -> Void
    var acceptHelpText: String = "Accept will replace in original text"
    var showsTargetHint: Bool = false

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
                .help(acceptHelpText)

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

            if showsTargetHint {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.left")
                        .font(.system(size: 9))
                    Text("Accept will change on original")
                        .font(.system(size: 9.5, weight: .medium))
                }
                .foregroundStyle(.secondary.opacity(0.85))
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Animated Manga Thinking Dots Badge (•••)

public struct MangaThinkingDotsBadge: View {
    public init() {}

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.2) {
                ForEach(0..<3) { i in
                    let offset = sin((time * 6.8) - Double(i) * 1.1) * 2.0
                    Circle()
                        .fill(Color.white)
                        .frame(width: 3.2, height: 3.2)
                        .offset(y: -offset)
                }
            }
            .padding(.horizontal, 4.5)
            .padding(.vertical, 3.2)
            .background(
                Capsule()
                    .fill(Color(red: 0.14, green: 0.10, blue: 0.22))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.2)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 2, x: 0, y: 1)
        }
    }
}
