//
//  ConversationLogWindowManager.swift
//  leanring-buddy
//
//  Manages the floating NSPanel that hosts the conversation log view.
//  The panel slides in from the right edge of the screen and can be
//  toggled via the menu bar panel's "会話ログ" button.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let clickyDismissConversationLog = Notification.Name("clickyDismissConversationLog")
    static let clickyToggleConversationLog = Notification.Name("clickyToggleConversationLog")
}

@MainActor
final class ConversationLogWindowManager {
    private var panel: NSPanel?
    private var dismissObserver: NSObjectProtocol?
    private let companionManager: CompanionManager

    private let panelWidth: CGFloat = 300
    /// Panel height as a fraction of the screen height.
    private let panelHeightRatio: CGFloat = 0.6

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager

        dismissObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissConversationLog,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }
    }

    deinit {
        if let observer = dismissObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Toggles the conversation log panel visibility with a slide animation.
    func togglePanel() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        guard let panel, let screen = NSScreen.main else { return }

        // Position at the right edge of the screen
        let screenFrame = screen.visibleFrame
        let panelHeight = screenFrame.height * panelHeightRatio
        let panelOriginX = screenFrame.maxX  // Start offscreen for slide-in
        let panelOriginY = screenFrame.midY - (panelHeight / 2)

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: panelHeight),
            display: true
        )

        panel.orderFrontRegardless()

        // Slide in from right edge
        let targetX = screenFrame.maxX - panelWidth - 12
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(
                NSRect(x: targetX, y: panelOriginY, width: panelWidth, height: panelHeight),
                display: true
            )
        }
    }

    private func hidePanel() {
        guard let panel, let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let targetX = screenFrame.maxX  // Slide offscreen to the right

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(
                NSRect(x: targetX, y: panel.frame.origin.y, width: panelWidth, height: panel.frame.height),
                display: true
            )
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func createPanel() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelHeight = screenFrame.height * panelHeightRatio

        let logView = ConversationLogView(companionManager: companionManager)

        let hostingView = NSHostingView(rootView: logView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let logPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel,
                        .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        logPanel.isFloatingPanel = true
        logPanel.level = .floating
        logPanel.isOpaque = false
        logPanel.backgroundColor = .clear
        logPanel.hasShadow = true
        logPanel.hidesOnDeactivate = false
        logPanel.isExcludedFromWindowsMenu = true
        logPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        logPanel.titleVisibility = .hidden
        logPanel.titlebarAppearsTransparent = true
        logPanel.isMovableByWindowBackground = true
        logPanel.minSize = NSSize(width: 240, height: 300)

        logPanel.contentView = hostingView
        panel = logPanel
    }
}
