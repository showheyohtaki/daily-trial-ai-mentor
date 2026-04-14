//
//  VoicevoxTTSClient.swift
//  leanring-buddy
//
//  Connects to a locally-running VOICEVOX engine (default: ずんだもん)
//  to synthesize speech. Falls through gracefully when the engine is
//  not running so callers can fall back to macOS system TTS.
//
//  VOICEVOX Engine: https://voicevox.hiroshiba.jp/
//  License: 商用利用OK・クレジット表記必須（VOICEVOX:ずんだもん）
//

import AVFoundation
import Foundation

@MainActor
final class VoicevoxTTSClient {
    private let baseURL: URL
    private let speakerId: Int
    private let session: URLSession
    private var audioPlayer: AVAudioPlayer?

    /// Whether the initial connection has been logged already.
    private var hasLoggedConnection = false

    init(host: String = "127.0.0.1", port: Int = 50021, speakerId: Int = 3) {
        self.baseURL = URL(string: "http://\(host):\(port)")!
        self.speakerId = speakerId

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Public API

    /// Fetches synthesized audio data from VOICEVOX (audio_query → synthesis).
    /// When `addLeadingSilence` is true, extra silence is prepended to prevent
    /// AVAudioPlayer from clipping the first phoneme. Only needed for the first segment.
    func fetchAudioData(for text: String, speedScale: Double = 1.0, addLeadingSilence: Bool = true) async throws -> Data {
        // Step 1: Generate audio query (prosody / accent data)
        let queryURL = baseURL
            .appendingPathComponent("audio_query")
        var queryComponents = URLComponents(url: queryURL, resolvingAgainstBaseURL: false)!
        queryComponents.queryItems = [
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "speaker", value: String(speakerId)),
        ]

        var queryRequest = URLRequest(url: queryComponents.url!)
        queryRequest.httpMethod = "POST"
        queryRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (queryData, queryResponse) = try await session.data(for: queryRequest)

        guard let queryHTTP = queryResponse as? HTTPURLResponse,
              (200...299).contains(queryHTTP.statusCode) else {
            let code = (queryResponse as? HTTPURLResponse)?.statusCode ?? -1
            throw VoicevoxError.audioQueryFailed(statusCode: code)
        }

        try Task.checkCancellation()

        // Modify audio query: apply speed and optionally add leading silence.
        // Leading silence prevents AVAudioPlayer from clipping the first phoneme,
        // but is only needed for the first segment (subsequent segments play seamlessly).
        var modifiedQueryData = queryData
        if var queryJSON = try? JSONSerialization.jsonObject(with: queryData) as? [String: Any] {
            if addLeadingSilence {
                queryJSON["prePhonemeLength"] = 0.25 * speedScale
            }
            queryJSON["speedScale"] = speedScale
            if let updated = try? JSONSerialization.data(withJSONObject: queryJSON) {
                modifiedQueryData = updated
            }
        }

        // Step 2: Synthesize WAV audio from the query JSON
        let synthesisURL = baseURL
            .appendingPathComponent("synthesis")
        var synthComponents = URLComponents(url: synthesisURL, resolvingAgainstBaseURL: false)!
        synthComponents.queryItems = [
            URLQueryItem(name: "speaker", value: String(speakerId)),
        ]

        var synthRequest = URLRequest(url: synthComponents.url!)
        synthRequest.httpMethod = "POST"
        synthRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        synthRequest.setValue("audio/wav", forHTTPHeaderField: "Accept")
        synthRequest.httpBody = modifiedQueryData

        let (wavData, synthResponse) = try await session.data(for: synthRequest)

        guard let synthHTTP = synthResponse as? HTTPURLResponse,
              (200...299).contains(synthHTTP.statusCode) else {
            let code = (synthResponse as? HTTPURLResponse)?.statusCode ?? -1
            throw VoicevoxError.synthesisFailed(statusCode: code)
        }

        try Task.checkCancellation()

        // Log first successful connection
        if !hasLoggedConnection {
            hasLoggedConnection = true
            print("🟢 VOICEVOX connected (zundamon, speaker=\(speakerId))")
        }

        return wavData
    }

    /// Plays previously fetched WAV data. Blocks (async) until playback completes.
    func playAudioData(_ data: Data) async throws {
        let player = try AVAudioPlayer(data: data)
        self.audioPlayer = player
        player.prepareToPlay()
        player.play()
        print("🔊 VOICEVOX TTS: playing \(data.count / 1024)KB audio")

        while player.isPlaying {
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1s polling
            try Task.checkCancellation()
        }
    }

    /// Convenience: fetch audio from VOICEVOX and play it immediately.
    func speakText(_ text: String, speedScale: Double = 1.0, addLeadingSilence: Bool = true) async throws {
        let data = try await fetchAudioData(for: text, speedScale: speedScale, addLeadingSilence: addLeadingSilence)
        try await playAudioData(data)
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    // MARK: - Engine Health Check

    /// Returns `true` if the VOICEVOX engine is reachable.
    func isEngineRunning() async -> Bool {
        let versionURL = baseURL.appendingPathComponent("version")
        var request = URLRequest(url: versionURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 3

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Errors

    enum VoicevoxError: LocalizedError {
        case audioQueryFailed(statusCode: Int)
        case synthesisFailed(statusCode: Int)

        var errorDescription: String? {
            switch self {
            case .audioQueryFailed(let code):
                return "VOICEVOX audio_query failed (HTTP \(code))"
            case .synthesisFailed(let code):
                return "VOICEVOX synthesis failed (HTTP \(code))"
            }
        }
    }
}
