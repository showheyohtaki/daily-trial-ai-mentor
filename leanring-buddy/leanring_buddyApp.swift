//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI
@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private var conversationLogWindowManager: ConversationLogWindowManager?
    private var toggleConversationLogObserver: NSObjectProtocol?
    private let companionManager = CompanionManager()
    private let voicevoxEngineManager = VoicevoxEngineManager()
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Clicky: Starting...")
        print("🎯 Clicky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        conversationLogWindowManager = ConversationLogWindowManager(companionManager: companionManager)

        // Listen for conversation log toggle from the menu bar panel button
        toggleConversationLogObserver = NotificationCenter.default.addObserver(
            forName: .clickyToggleConversationLog,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.conversationLogWindowManager?.togglePanel()
        }

        companionManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted || !companionManager.hasValidAPIKey {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()

        // Start bundled VOICEVOX engine in the background.
        // The engine takes a few seconds to initialize; meanwhile,
        // VoicevoxTTSClient will fall back to macOS system TTS if needed.
        Task {
            await voicevoxEngineManager.startEngine()
            let ready = await voicevoxEngineManager.waitForReady(timeout: 30)
            if ready {
                print("🎯 Clicky: VOICEVOX engine ready — ずんだもん TTS active")
            } else {
                print("⚠️ Clicky: VOICEVOX engine not ready — using fallback TTS")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
        voicevoxEngineManager.stopEngine()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Clicky: Registered as login item")
            } catch {
                print("⚠️ Clicky: Failed to register as login item: \(error)")
            }
        }
    }

}
