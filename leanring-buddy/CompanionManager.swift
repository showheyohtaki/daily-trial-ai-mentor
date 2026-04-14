//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    private let voicevoxTTSClient = VoicevoxTTSClient()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    // MARK: - API Key Management

    private static let anthropicAPIKeyUserDefaultsKey = "anthropicAPIKey"

    @Published var anthropicAPIKey: String = UserDefaults.standard.string(forKey: anthropicAPIKeyUserDefaultsKey) ?? ""

    var hasValidAPIKey: Bool {
        anthropicAPIKey.hasPrefix("sk-ant-")
    }

    func setAnthropicAPIKey(_ key: String) {
        anthropicAPIKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(anthropicAPIKey, forKey: Self.anthropicAPIKeyUserDefaultsKey)
        claudeAPI = ClaudeAPI(apiKey: anthropicAPIKey, model: selectedModel)
    }

    private var claudeAPI: ClaudeAPI = ClaudeAPI(proxyURL: "https://api.anthropic.com/v1/messages")

    /// A single conversation exchange displayed in the conversation log panel.
    struct ConversationEntry: Identifiable {
        let id = UUID()
        let userTranscript: String
        /// The assistant's response with POINT tags removed (display-friendly).
        let assistantResponse: String
    }

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's clean (tag-stripped) response.
    /// `@Published` so the conversation log UI updates automatically.
    @Published private(set) var conversationHistory: [ConversationEntry] = []

    /// Raw conversation history with POINT tags intact, used for the Claude API.
    private var conversationHistoryRaw: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        if hasValidAPIKey {
            claudeAPI = ClaudeAPI(apiKey: anthropicAPIKey, model: model)
        } else {
            claudeAPI.model = model
        }
    }

    /// TTS playback speed (1.0 = normal, 1.1, 1.2). Persisted to UserDefaults.
    @Published var selectedSpeedScale: Double = UserDefaults.standard.object(forKey: "selectedSpeedScale") as? Double ?? 1.0

    func setSpeedScale(_ speed: Double) {
        selectedSpeedScale = speed
        UserDefaults.standard.set(speed, forKey: "selectedSpeedScale")
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding), apiKey: \(hasValidAPIKey)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Initialize Claude API with saved key if available
        if hasValidAPIKey {
            claudeAPI = ClaudeAPI(apiKey: anthropicAPIKey, model: selectedModel)
        }

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and usage prompt
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding prompt is showing
            guard !showOnboardingPrompt else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the overlay isn't visible, bring it up for this interaction.
            // This covers both: cursor intentionally hidden (transient mode)
            // and overlay not yet shown (e.g. fresh install, onboarding not completed).
            if !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            stopSystemTTS()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    あなたはデイトラちゃん。ユーザーのメニューバーに住んでいる、いつも一緒のAIメンターです。ユーザーがプッシュトゥトークで話しかけてきました。画面も見えています。あなたの返答はテキスト読み上げで音声になるので、話し言葉で書いてください。これは継続的な会話で、前に言ったことは全部覚えています。一人称は「ぼく」を使う。

    【最重要】出力フォーマット:
    - 普通の日本語で書く（漢字・ひらがな・カタカナを自然に使う）。英語は使わない。英語の単語や固有名詞はカタカナに変換する（例: Run → ラン、Save → セーブ、Claude → クロード）。
    - すべての応答に [POINT:x,y:ラベル] タグか [POINT:none] を必ず含めること。タグのない応答は不完全とみなされる。

    [POINT] タグのルール:
    画面上の要素に小さなカーソルが飛んでいって指差しできる。ユーザーの質問がUI操作に関係しているときは [POINT:x,y:ラベル] で指差しする。迷ったら指差しする。一般知識の質問や画面と関係ない会話のときだけ [POINT:none] をつける。タグは要素について説明する文の直前に置く。複数の要素に触れるときは、それぞれにタグを置く。スクリーンショット画像のピクセル寸法を座標空間として使う。原点(0,0)は左上。xは右方向、yは下方向に増加。ラベルは日本語で要素名を1〜3語で書く。別のスクリーンの要素は :screenN をつける。

    ルール:
    - 基本は1〜2文。簡潔に、でも密度高く。ただし、ユーザーが「もっと詳しく」「深掘りして」と言ったら、遠慮なく詳しく説明する。
    - 日本語で応答する。カジュアルで温かみのある口調。絵文字は使わない。
    - 耳で聞くための文章を書く。短い文。箇条書き、マークダウン、フォーマットは使わない。自然な話し言葉で。
    - 略語や記号は使わない。声に出して変に聞こえるものは避ける。
    - ユーザーの質問が画面に関係していたら、画面に見える具体的なものに言及する。
    - スクリーンショットが質問に関係なさそうなら、質問にそのまま答える。
    - コーディング、ライティング、一般知識、ブレインストーミング、何でも助けられる。
    - 「簡単に」「ただ」とは言わない。
    - コードをそのまま読み上げない。コードが何をしているか、何を変えるべきかを会話的に説明する。
    - 充実した有用な説明を心がける。「もっと説明しましょうか？」のような単純なyes/no質問で終わらない。
    - 自然な流れで、もっと大きなこと、関連する深い概念、次のレベルのテクニックに触れて終わる。戻ってきたくなるような話題を残す。答えが完結している場合は追加しなくてもよい。
    - 複数の画面画像がある場合、「primary focus」ラベルのものがカーソルのある画面。それを優先しつつ、他の画面も関係あれば言及する。

    例:
    - 画像生成の仕方を聞かれた: 「いいね！ [POINT:350,411:プロンプトボックス] このプロンプトボックスに入れて、 [POINT:560,437:ランボタン] ランボタンを押せばOKだよ。」
    - 設定の場所を聞かれた: 「それね！ [POINT:305,67:レコーディングタブ] レコーディングタブの中の、 [POINT:275,407:ディムスクリーン] ディムスクリーンをオフにすればいいよ。」
    - 一般知識の質問: 「HTMLはウェブページの骨格みたいなものだよ。 [POINT:none]」
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        stopSystemTTS()

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistoryRaw.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { _ in
                        // No streaming text display — spinner stays until TTS plays
                    }
                )

                guard !Task.isCancelled else { return }

                // Parse inline [POINT:...] tags — Claude may place multiple
                // tags throughout the response to point at different elements
                // as the explanation progresses.
                let segments = Self.parseMultiplePointingCoordinates(from: fullResponseText)

                // Debug: log raw Claude output and segment breakdown
                print("📝 Claude raw output: \(fullResponseText)")
                for (i, seg) in segments.enumerated() {
                    print("📦 Segment \(i): coord=\(seg.coordinate?.debugDescription ?? "none") label=\(seg.elementLabel ?? "none") text=\"\(seg.text)\"")
                }

                // Build the full spoken text (all segments, tags stripped) for
                // conversation history.
                let spokenText = segments.map(\.text).joined(separator: " ")

                // Save this exchange to conversation history.
                // Raw history (with POINT tags) is used for the Claude API;
                // clean history (tags stripped) is displayed in the log panel.
                conversationHistoryRaw.append((
                    userTranscript: transcript,
                    assistantResponse: fullResponseText
                ))
                if conversationHistoryRaw.count > 10 {
                    conversationHistoryRaw.removeFirst(conversationHistoryRaw.count - 10)
                }
                conversationHistory.append(ConversationEntry(
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }
                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                // If no pointing needed, show the buddy icon immediately
                // instead of staying in the processing spinner until TTS starts.
                if segments.allSatisfy({ $0.coordinate == nil }) {
                    voiceState = .idle
                }

                // Play each segment with macOS system TTS.
                // No network calls needed — local synthesis is instant.
                for (index, segment) in segments.enumerated() {
                    guard !Task.isCancelled else { return }

                    // Point at the element BEFORE speaking about it
                    if let pointCoordinate = segment.coordinate {
                        // Switch to idle so the triangle becomes visible for flight
                        voiceState = .idle

                        let targetScreenCapture: CompanionScreenCapture? = {
                            if let screenNumber = segment.screenNumber,
                               screenNumber >= 1 && screenNumber <= screenCaptures.count {
                                return screenCaptures[screenNumber - 1]
                            }
                            return screenCaptures.first(where: { $0.isCursorScreen })
                        }()

                        if let targetScreenCapture {
                            let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                            let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                            let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                            let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                            let displayFrame = targetScreenCapture.displayFrame

                            let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                            let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                            let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                            let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                            let appKitY = displayHeight - displayLocalY

                            let globalLocation = CGPoint(
                                x: displayLocalX + displayFrame.origin.x,
                                y: appKitY + displayFrame.origin.y
                            )

                            detectedElementScreenLocation = globalLocation
                            detectedElementDisplayFrame = displayFrame
                            detectedElementBubbleText = segment.elementLabel
                            print("🎯 Element pointing (\(index + 1)/\(segments.count)): (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(segment.elementLabel ?? "element")\"")
                        }

                        // Brief pause so the cursor lands before speaking
                        try? await Task.sleep(nanoseconds: 400_000_000) // 0.4s
                    }

                    // Speak this segment's text with macOS system TTS
                    let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    do {
                        try await speakWithSystemTTSAsync(text, isFirstSegment: index == 0)
                    } catch is CancellationError {
                        return
                    } catch {
                        print("⚠️ System TTS error (segment \(index)): \(error)")
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                print("⚠️ Companion response error: \(error)")
                speakCreditsErrorFallback()
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while isSystemTTSSpeaking {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    // MARK: - Public TTS

    /// Speaks the given text with VOICEVOX (ずんだもん).
    /// Falls back to macOS TTS if VOICEVOX is unavailable.
    /// For use by views that need one-off TTS (e.g. welcome message).
    func speak(_ text: String) {
        Task {
            try? await speakWithSystemTTSAsync(text)
        }
    }

    // MARK: - macOS System TTS

    /// Lazily-initialised singleton synthesizer.
    /// Reusing a single instance avoids repeated Audio Unit setup/teardown,
    /// which suppresses the AUCrashHandler console warning on macOS.
    private lazy var systemSpeechSynthesizer: NSSpeechSynthesizer = NSSpeechSynthesizer()

    /// Whether any TTS is currently speaking.
    var isSystemTTSSpeaking: Bool {
        voicevoxTTSClient.isPlaying || systemSpeechSynthesizer.isSpeaking
    }

    /// Stops any in-progress TTS playback.
    func stopSystemTTS() {
        voicevoxTTSClient.stopPlayback()
        systemSpeechSynthesizer.stopSpeaking()
    }

    /// Speaks the given text using macOS system TTS with a Japanese voice.
    /// Fire-and-forget version (used for error fallbacks).
    private func speakWithSystemTTS(_ text: String) {
        systemSpeechSynthesizer.stopSpeaking()
        systemSpeechSynthesizer.startSpeaking(text)
        voiceState = .responding
    }

    /// Speaks the given text using VOICEVOX (ずんだもん) and waits for completion.
    /// Falls back to macOS system TTS if VOICEVOX is not running or fails.
    /// Cancellation-safe.
    private func speakWithSystemTTSAsync(_ text: String, isFirstSegment: Bool = true) async throws {
        let normalizedText = TTSTextNormalizer.normalize(text)
        voiceState = .responding

        // Try VOICEVOX first
        do {
            try await voicevoxTTSClient.speakText(normalizedText, speedScale: selectedSpeedScale, addLeadingSilence: isFirstSegment)
            return
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print("⚠️ VOICEVOX TTS failed, falling back to macOS TTS: \(error.localizedDescription)")
        }

        // Fallback: macOS NSSpeechSynthesizer (reuse singleton to avoid AUCrashHandler warning)
        systemSpeechSynthesizer.stopSpeaking()
        systemSpeechSynthesizer.startSpeaking(normalizedText)
        print("🔊 System TTS (fallback): speaking \(text.count) chars")

        while systemSpeechSynthesizer.isSpeaking {
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1s polling
            try Task.checkCancellation()
        }
    }

    /// Speaks a hardcoded error message when API credits run out.
    private func speakCreditsErrorFallback() {
        speakWithSystemTTS("APIクレジットがなくなっちゃいました。クレジットを追加してください。")
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Multi-Point Tag Parsing

    /// A single segment of a multi-point response: spoken text followed by
    /// an optional pointing coordinate.
    struct PointingSegment {
        let text: String
        let coordinate: CGPoint?
        let elementLabel: String?
        let screenNumber: Int?
    }

    /// Splits Claude's response into segments delimited by inline [POINT:...]
    /// tags. Each segment contains the text before/after a tag and the
    /// coordinate that should be pointed at after that text is spoken.
    ///
    /// Example input:
    ///   "いいね！ [POINT:350,411:プロンプトボックス] このプロンプトボックスにいれて、 [POINT:560,437:ランボタン] ランボタンをおせばOKだよ。"
    /// Returns three segments:
    ///   1. text="いいね！", coordinate=nil (intro, no pointing)
    ///   2. text="このプロンプトボックスにいれて、", coordinate=(350,411), label="プロンプトボックス"
    ///   3. text="ランボタンをおせばOKだよ。", coordinate=(560,437), label="ランボタン"
    ///
    /// The tag is placed BEFORE the text it explains. The cursor flies to the
    /// element first, then the explanation text (AFTER the tag) is spoken.
    static func parseMultiplePointingCoordinates(from responseText: String) -> [PointingSegment] {
        // Match all [POINT:...] tags (inline, not just at end)
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [PointingSegment(text: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)]
        }

        let fullRange = NSRange(responseText.startIndex..., in: responseText)
        let matches = regex.matches(in: responseText, range: fullRange)

        // No tags at all — return the whole text as a single segment
        if matches.isEmpty {
            return [PointingSegment(text: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)]
        }

        var segments: [PointingSegment] = []

        // Parse all tag positions and their coordinates
        struct TagInfo {
            let range: Range<String.Index>
            let coordinate: CGPoint?
            let elementLabel: String?
            let screenNumber: Int?
        }

        var tags: [TagInfo] = []
        for match in matches {
            let matchRange = Range(match.range, in: responseText)!

            var coordinate: CGPoint? = nil
            var elementLabel: String? = nil
            var screenNumber: Int? = nil

            if match.numberOfRanges >= 3,
               let xRange = Range(match.range(at: 1), in: responseText),
               let yRange = Range(match.range(at: 2), in: responseText),
               let x = Double(responseText[xRange]),
               let y = Double(responseText[yRange]) {
                coordinate = CGPoint(x: x, y: y)

                if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
                    elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
                }
                if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
                    screenNumber = Int(responseText[screenRange])
                }
            }

            tags.append(TagInfo(range: matchRange, coordinate: coordinate, elementLabel: elementLabel, screenNumber: screenNumber))
        }

        // Text before the first tag → intro segment, no pointing
        let introText = String(responseText[responseText.startIndex..<tags[0].range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !introText.isEmpty {
            segments.append(PointingSegment(text: introText, coordinate: nil, elementLabel: nil, screenNumber: nil))
        }

        // Text AFTER each tag → that tag's coordinates
        for (i, tag) in tags.enumerated() {
            let textStart = tag.range.upperBound
            let textEnd = (i + 1 < tags.count) ? tags[i + 1].range.lowerBound : responseText.endIndex
            let text = String(responseText[textStart..<textEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !text.isEmpty {
                segments.append(PointingSegment(
                    text: text,
                    coordinate: tag.coordinate,
                    elementLabel: tag.elementLabel,
                    screenNumber: tag.screenNumber
                ))
            }
        }

        return segments
    }

    /// Simple keyword check to determine if a question is likely about screen UI elements.
    /// Used to append a POINT tag reminder to the user prompt.
    private static func questionAppearsScreenRelated(_ transcript: String) -> Bool {
        let keywords = ["どこ", "ボタン", "クリック", "おして", "押して", "ひらいて", "開いて",
                        "メニュー", "せってい", "設定", "タブ", "アイコン", "みつからない",
                        "見つからない", "どうやって", "ここ", "これ", "どれ", "画面",
                        "ツール", "パネル", "ウィンドウ", "サイドバー", "ナビ"]
        return keywords.contains(where: { transcript.contains($0) })
    }

    // MARK: - Onboarding Video

    /// Called by BlueCursorView when onboarding starts. Shows the usage
    /// prompt and triggers a demo pointing interaction after a short delay.
    func setupOnboardingVideo() {
        // Show the usage prompt immediately
        startOnboardingPromptStream()

        // After 3 seconds, trigger the demo where the buddy flies to
        // something interesting on screen and comments on it
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.performOnboardingDemoInteraction()
        }
    }

    private func startOnboardingPromptStream() {
        let message = "Ctrl + Option をおしながら はなしかけてみてね！"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    あなたはデイトラちゃん。ユーザーの画面に住んでいる小さなカーソルバディ。オンボーディング中のデモとして、画面を見て具体的なものを1つ見つけて指し示す。アプリアイコン（名前を言う）、テキスト、ファイル名、ボタン、タブタイトルなど、はっきりした名前やアイデンティティのあるものを選ぶ。「ウィンドウ」「テキスト」のような曖昧なものは指さない。

    選んだものについて3〜6語の短くてユニークな一言を日本語で書く。楽しく、遊び心があり、ちゃんと見て認識したことが伝わるように。絵文字は使わない。画面のテキストをそのまま引用しない。6語以内、例外なし。

    座標ルール: 画面の中央付近の要素のみ選ぶ。x座標は画像幅の20%〜80%、y座標は画像高さの20%〜80%の範囲内。端の20%にあるものは選ばない。

    フォーマット: コメント [POINT:x,y:label]
    コメントのみ、他には何も書かない。すべて小文字のローマ字ラベル。

    スクリーンショット画像にはピクセル寸法のラベルが付いている。その寸法を座標空間として使う。原点(0,0)は左上。xは右方向、yは下方向に増加。
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
