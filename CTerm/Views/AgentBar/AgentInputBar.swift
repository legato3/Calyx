// AgentInputBar.swift
// CTerm
//
// Warp-style minimal input bar at the bottom of the terminal area.
// Clean text field with a placeholder, send button, and suggestion chips above.

import SwiftUI

struct AgentInputBar: View {
    @Binding var text: String
    let suggestions: [ActiveAISuggestion]
    let isAgentRunning: Bool
    let planStore: AgentPlanStore?
    var onSubmit: (String) -> Void
    var onSuggestionTapped: (ActiveAISuggestion) -> Void
    var onExpandCompose: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !suggestions.isEmpty && !isAgentRunning {
                suggestionChips
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            inputRow
        }
        .background(
            Color(nsColor: NSColor(calibratedWhite: 0.08, alpha: 1.0))
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    // MARK: - Input row

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(fieldFocused ? Color.accentColor : .secondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($fieldFocused)
                .foregroundStyle(.primary)
                .onSubmit(submit)

            if isAgentRunning {
                ProgressView()
                    .controlSize(.mini)
                    .transition(.opacity)
            } else if !text.isEmpty {
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .animation(.easeInOut(duration: 0.15), value: isAgentRunning)
        .animation(.easeInOut(duration: 0.12), value: text.isEmpty)
        .animation(.easeInOut(duration: 0.12), value: fieldFocused)
    }

    private var placeholder: String {
        isAgentRunning ? "Agent is running…" : "Ask CTerm anything…"
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        text = ""
    }

    // MARK: - Suggestion chips

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestions) { suggestion in
                    Button {
                        onSuggestionTapped(suggestion)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: suggestion.icon)
                                .font(.system(size: 9, weight: .semibold))
                            Text(suggestion.prompt)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(chipTint(for: suggestion.kind))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(chipBackground(for: suggestion.kind))
                        .overlay(
                            Capsule().stroke(chipTint(for: suggestion.kind).opacity(0.3), lineWidth: 0.5)
                        )
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
        }
    }

    private func chipBackground(for kind: ActiveAISuggestion.Kind) -> some ShapeStyle {
        AnyShapeStyle(chipTint(for: kind).opacity(0.14))
    }

    private func chipTint(for kind: ActiveAISuggestion.Kind) -> Color {
        switch kind {
        case .fix:           return .red
        case .explain:       return .blue
        case .nextStep:      return .green
        case .continueAgent: return .purple
        case .custom:        return .secondary
        }
    }
}
