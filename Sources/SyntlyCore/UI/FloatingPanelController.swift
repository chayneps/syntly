import Foundation
import AppKit
import SwiftUI

/// Non-activating floating NSPanel so clicking suggestion cards never steals keyboard focus from the target app.
public final class NonActivatingPanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}

@MainActor
public final class FloatingPanelController {
    private var panel: NonActivatingPanel?
    private let coordinator: WritingAssistantCoordinator

    public init(coordinator: WritingAssistantCoordinator) {
        self.coordinator = coordinator
        setupPanel()

        coordinator.onOverlayStateChanged = { [weak self] in
            self?.syncPanelVisibilityAndFrame()
        }
    }

    private func setupPanel() {
        let initialRect = NSRect(x: 200, y: 200, width: 380, height: 48)
        let newPanel = NonActivatingPanel(
            contentRect: initialRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        newPanel.level = .floating
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.isMovableByWindowBackground = true
        newPanel.hidesOnDeactivate = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let rootView = FloatingOverlayView(coordinator: coordinator)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = initialRect
        newPanel.contentView = hostingView

        self.panel = newPanel
    }

    public func syncPanelVisibilityAndFrame() {
        guard let panel = panel else { return }

        guard let context = coordinator.currentContext else {
            if !coordinator.isPopoverExpanded {
                panel.orderOut(nil)
            }
            return
        }

        // Hide if app is blocked and user hasn't manually opened the popover
        if coordinator.settings.isAppBlocked(bundleID: context.bundleID) && !coordinator.isPopoverExpanded {
            panel.orderOut(nil)
            return
        }

        // Hide if text field is completely empty and popover is collapsed
        if context.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !coordinator.isPopoverExpanded {
            panel.orderOut(nil)
            return
        }

        let targetSize: NSSize = coordinator.isPopoverExpanded
            ? NSSize(width: 390, height: 360)
            : NSSize(width: 150, height: 44)

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var originX = context.anchorAppKitPoint.x - targetSize.width
        var originY = context.anchorAppKitPoint.y - (coordinator.isPopoverExpanded ? targetSize.height : 18)

        // Keep panel inside visible screen bounds
        originX = max(screenFrame.minX + 12, min(originX, screenFrame.maxX - targetSize.width - 12))
        originY = max(screenFrame.minY + 12, min(originY, screenFrame.maxY - targetSize.height - 12))

        let newFrame = NSRect(origin: CGPoint(x: originX, y: originY), size: targetSize)
        panel.setFrame(newFrame, display: true, animate: false)
        panel.orderFrontRegardless()
    }
}
