import Foundation
import AppKit
import SwiftUI

/// Non-activating floating NSPanel so clicking suggestion cards never steals keyboard focus from the target app.
/// Also handles smooth dragging and per-app repositioning for both compact pill and expanded dialog.
public final class NonActivatingPanel: NSPanel {
    public var allowsKeyWindow: Bool = false
    public override var canBecomeKey: Bool { allowsKeyWindow }
    public override var canBecomeMain: Bool { false }

    public var isDraggingPill: Bool = false
    public var isPopoverExpanded: () -> Bool = { false }
    public var onPillDragged: ((CGPoint) -> Void)?
    public var onPillDragEnded: ((CGPoint) -> Void)?
    public var onDialogDragEnded: ((CGPoint) -> Void)?
    public var onPillSingleClick: (() -> Void)?
    public var onPanelDoubleClick: (() -> Void)?

    private var initialMouseScreenLocation: CGPoint = .zero
    private var initialPanelOrigin: CGPoint = .zero
    private var dragThresholdPassed: Bool = false
    private var isDragCandidate: Bool = false

    public override func orderOut(_ sender: Any?) {
        if dragThresholdPassed {
            dragThresholdPassed = false
            isDraggingPill = false
            NSCursor.pop()
        }
        super.orderOut(sender)
    }

    public override func sendEvent(_ event: NSEvent) {
        let isExpanded = isPopoverExpanded()

        switch event.type {
        case .leftMouseDown:
            if event.clickCount == 2 {
                onPanelDoubleClick?()
                return
            }

            initialMouseScreenLocation = NSEvent.mouseLocation
            initialPanelOrigin = self.frame.origin
            dragThresholdPassed = false
            isDraggingPill = false

            if isExpanded {
                // When expanded: Allow dragging if click began in header bar (top 48pt) or footer bar (bottom 38pt)
                let localPoint = self.contentView?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
                let inHeader = localPoint.y >= self.frame.height - 48
                let inFooter = localPoint.y <= 38
                isDragCandidate = inHeader || inFooter
                super.sendEvent(event)
            } else {
                // When compact: Anywhere on the 48x48 icon is draggable or clickable
                isDragCandidate = true
            }

        case .leftMouseDragged:
            guard isDragCandidate else {
                super.sendEvent(event)
                return
            }

            let currentMouse = NSEvent.mouseLocation
            let dx = currentMouse.x - initialMouseScreenLocation.x
            let dy = currentMouse.y - initialMouseScreenLocation.y

            if !dragThresholdPassed && hypot(dx, dy) >= 4.0 {
                dragThresholdPassed = true
                isDraggingPill = true
                NSCursor.closedHand.push()
            }

            if dragThresholdPassed {
                let screen = self.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                let rawX = initialPanelOrigin.x + dx
                let rawY = initialPanelOrigin.y + dy
                let clampedX = max(screen.minX + 4, min(rawX, screen.maxX - self.frame.width - 4))
                let clampedY = max(screen.minY + 4, min(rawY, screen.maxY - self.frame.height - 4))
                let newOrigin = CGPoint(x: clampedX, y: clampedY)
                self.setFrameOrigin(newOrigin)
                onPillDragged?(newOrigin)
                return
            }

            super.sendEvent(event)

        case .leftMouseUp:
            let wasDragging = dragThresholdPassed
            isDragCandidate = false

            if wasDragging {
                dragThresholdPassed = false
                isDraggingPill = false
                NSCursor.pop()
                if isExpanded {
                    onDialogDragEnded?(self.frame.origin)
                } else {
                    onPillDragEnded?(self.frame.origin)
                }
                return
            } else {
                if !isExpanded {
                    // Short tap on collapsed pill expands it
                    onPillSingleClick?()
                    return
                } else {
                    super.sendEvent(event)
                }
            }

        default:
            super.sendEvent(event)
        }
    }
}

@MainActor
public final class FloatingPanelController {
    private var panel: NonActivatingPanel?
    private let coordinator: WritingAssistantCoordinator

    public init(coordinator: WritingAssistantCoordinator) {
        self.coordinator = coordinator

        coordinator.onOverlayStateChanged = { [weak self] in
            self?.syncPanelVisibilityAndFrame()
        }
    }

    private func getOrCreatePanel() -> NonActivatingPanel {
        if let existing = self.panel {
            return existing
        }

        let initialRect = NSRect(x: 200, y: 200, width: 48, height: 48)
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
        newPanel.isMovableByWindowBackground = false
        newPanel.hidesOnDeactivate = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        newPanel.isPopoverExpanded = { [weak self] in
            self?.coordinator.isPopoverExpanded ?? false
        }

        newPanel.onPillDragEnded = { [weak self] finalPanelOrigin in
            guard let self = self, let context = self.coordinator.currentContext else { return }
            let appKey = context.bundleID ?? context.appName
            guard !appKey.isEmpty else { return }
            let dx = finalPanelOrigin.x - context.anchorAppKitPoint.x
            let dy = finalPanelOrigin.y - context.anchorAppKitPoint.y
            let offset = AppPillOffset(dx: dx, dy: dy)
            self.coordinator.settings.setPillOffset(offset, for: appKey)
        }

        newPanel.onDialogDragEnded = { [weak self] finalPanelOrigin in
            guard let self = self, let context = self.coordinator.currentContext else { return }
            let appKey = context.bundleID ?? context.appName
            guard !appKey.isEmpty else { return }
            let dx = finalPanelOrigin.x - context.anchorAppKitPoint.x
            let dy = finalPanelOrigin.y - context.anchorAppKitPoint.y
            let offset = AppPillOffset(dx: dx, dy: dy)
            self.coordinator.settings.setDialogOffset(offset, for: appKey)
        }

        newPanel.onPillSingleClick = { [weak self] in
            guard let self = self else { return }
            self.coordinator.isPopoverExpanded = true
            self.coordinator.onOverlayStateChanged?()
        }

        newPanel.onPanelDoubleClick = { [weak self] in
            guard let self = self, let context = self.coordinator.currentContext else { return }
            let appKey = context.bundleID ?? context.appName
            if self.coordinator.isPopoverExpanded {
                self.coordinator.settings.resetDialogOffset(for: appKey)
            } else {
                self.coordinator.settings.resetPillOffset(for: appKey)
            }
            self.syncPanelVisibilityAndFrame()
        }

        let rootView = FloatingOverlayView(coordinator: coordinator)
        let hostingController = NSHostingController(rootView: rootView)
        newPanel.contentViewController = hostingController

        self.panel = newPanel
        return newPanel
    }

    public func syncPanelVisibilityAndFrame() {
        let panel = getOrCreatePanel()

        // If the user is actively dragging the pill with the mouse, never interrupt with an automatic reposition
        if panel.isDraggingPill {
            return
        }

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

        panel.allowsKeyWindow = (coordinator.isPopoverExpanded && coordinator.isRewriteTabActive)

        let targetSize: NSSize = coordinator.isPopoverExpanded
            ? NSSize(width: 380, height: 348)
            : NSSize(width: 48, height: 48)

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // Default top-left positioning relative to the start of text:
        let bubbleSize: CGFloat = 48.0
        let hasRoomOnLeft = (context.anchorAppKitPoint.x - bubbleSize - 6) >= (screenFrame.minX + 8)

        let defaultOriginX: CGFloat
        let defaultOriginY: CGFloat

        if hasRoomOnLeft {
            // Sit cleanly to the left of the text input, aligned with its top edge
            defaultOriginX = context.anchorAppKitPoint.x - bubbleSize - 6
            defaultOriginY = context.anchorAppKitPoint.y - bubbleSize
        } else {
            // If flush against the left screen edge, sit just above the top edge
            defaultOriginX = max(screenFrame.minX + 8, context.anchorAppKitPoint.x)
            defaultOriginY = context.anchorAppKitPoint.y + 4
        }

        // Check if the user has dragged and saved a custom relative offset for this app:
        let appKey = context.bundleID ?? context.appName
        let customOffset = coordinator.settings.pillOffset(for: appKey)

        let pillOriginX: CGFloat
        let pillOriginY: CGFloat

        if let offset = customOffset {
            pillOriginX = context.anchorAppKitPoint.x + offset.dx
            pillOriginY = context.anchorAppKitPoint.y + offset.dy
        } else {
            pillOriginX = defaultOriginX
            pillOriginY = defaultOriginY
        }

        var originX: CGFloat
        var originY: CGFloat

        if coordinator.isPopoverExpanded {
            if let dialogOffset = coordinator.settings.dialogOffset(for: appKey) {
                // User has dragged and set a custom position for the expanded dialog
                originX = context.anchorAppKitPoint.x + dialogOffset.dx
                originY = context.anchorAppKitPoint.y + dialogOffset.dy
            } else {
                // Default behavior: The dialog opens with its lower-left corner anchored right at the badge,
                // opening upwards or downwards depending on screen room.
                let badgeX = pillOriginX + 36.0
                let badgeY = pillOriginY + 38.0

                let roomAbove = screenFrame.maxY - 8 - badgeY
                let roomBelow = badgeY - (screenFrame.minY + 8)

                if roomAbove >= targetSize.height || roomAbove >= roomBelow {
                    // Primary behavior: Dialog lower-left corner sits right at the badge, opening upwards
                    originX = badgeX
                    originY = badgeY
                } else {
                    // Secondary fallback (e.g. text input at top of screen): Dialog upper-left corner at badge, opening downwards
                    originX = badgeX
                    originY = badgeY - targetSize.height
                }
            }
        } else {
            // Collapsed 48x48 icon
            originX = pillOriginX
            originY = pillOriginY
        }

        // Keep panel safely inside visible screen bounds
        originX = max(screenFrame.minX + 8, min(originX, screenFrame.maxX - targetSize.width - 8))
        originY = max(screenFrame.minY + 8, min(originY, screenFrame.maxY - targetSize.height - 8))

        let newFrame = NSRect(origin: CGPoint(x: originX, y: originY), size: targetSize)
        panel.setFrame(newFrame, display: true, animate: false)
        panel.orderFrontRegardless()
    }
}
