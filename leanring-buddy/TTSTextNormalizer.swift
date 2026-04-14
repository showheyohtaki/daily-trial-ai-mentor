//
//  TTSTextNormalizer.swift
//  leanring-buddy
//
//  Normalizes text before sending to TTS to prevent mispronunciations.
//  Replaces English abbreviations and terms that macOS TTS reads incorrectly
//  with their katakana phonetic equivalents.
//

import Foundation

enum TTSTextNormalizer {
    /// English terms that macOS TTS mispronounces, mapped to katakana readings.
    /// Claude's prompt says "convert English to katakana" but common abbreviations
    /// still slip through — this catches them before TTS.
    private static let replacements: [(pattern: String, replacement: String)] = [
        ("AI", "エーアイ"),
        ("API", "エーピーアイ"),
        ("URL", "ユーアールエル"),
        ("HTML", "エイチティーエムエル"),
        ("CSS", "シーエスエス"),
        ("UI", "ユーアイ"),
        ("UX", "ユーエックス"),
        ("OS", "オーエス"),
        ("SDK", "エスディーケー"),
        ("MCP", "エムシーピー"),
        ("VS Code", "ブイエスコード"),
        ("VSCode", "ブイエスコード"),
    ]

    /// Replaces English abbreviations with katakana readings for accurate TTS.
    static func normalize(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in replacements {
            // Word-boundary aware replacement to avoid partial matches
            // e.g. "MAIN" should not replace "AI" inside it
            let regex = try? NSRegularExpression(
                pattern: "(?<![A-Za-z])\(NSRegularExpression.escapedPattern(for: pattern))(?![A-Za-z])",
                options: []
            )
            if let regex {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: replacement
                )
            }
        }
        return result
    }
}
