//
//  ConversationLogView.swift
//  leanring-buddy
//
//  Floating conversation log panel that displays the chat history between
//  the user and the AI mentor. Shows user messages right-aligned and
//  assistant responses left-aligned in a scrollable chat-bubble layout.
//  Positioned on the right edge of the screen and toggled via the menu bar panel.
//

import SwiftUI

struct ConversationLogView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()
                .background(DS.Colors.borderSubtle)

            // Conversation list or placeholder
            if companionManager.conversationHistory.isEmpty {
                emptyStateView
            } else {
                conversationListView
            }
        }
        .background(DS.Colors.background)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("会話ログ")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer()

            Button(action: {
                NotificationCenter.default.post(name: .clickyDismissConversationLog, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Spacer()

            Image(systemName: "text.bubble")
                .font(.system(size: 28))
                .foregroundColor(DS.Colors.textTertiary.opacity(0.5))

            Text("まだ会話がありません")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Text("Control+Optionを長押しして\n話しかけてみてください")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary.opacity(0.7))
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    // MARK: - Conversation List

    private var conversationListView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 16) {
                    ForEach(companionManager.conversationHistory) { entry in
                        conversationEntryView(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .onChange(of: companionManager.conversationHistory.count) { _ in
                // Auto-scroll to latest message
                if let lastEntry = companionManager.conversationHistory.last {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(lastEntry.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Conversation Entry

    private func conversationEntryView(entry: CompanionManager.ConversationEntry) -> some View {
        VStack(spacing: 8) {
            // User message (right-aligned)
            HStack {
                Spacer(minLength: 40)

                Text(entry.userTranscript)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(DS.Colors.helpChatUserBubble)
                    )
                    .textSelection(.enabled)
            }

            // Assistant message (left-aligned)
            HStack {
                Text(entry.assistantResponse)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(DS.Colors.surface2)
                    )
                    .textSelection(.enabled)

                Spacer(minLength: 40)
            }
        }
    }
}
