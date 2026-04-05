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
        .background(.ultraThinMaterial)
    }

    // MARK: - Input row

    private var inputRow: some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($fieldFocused)
                .foregroundStyle(.primary)
                .onSubmit(submit)

            if isAgentRunning {
                ProgressView()
                    .controlSize(.mini)
                    .transition(.opacity)
            } else if !text.isEmpty {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.borderless)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.15), value: isAgentRunning)
        .animation(.easeInOut(duration: 0.1), value: text.isEmpty)
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
                        HStack(spacing: 4) {
                            Image(systemName: suggestion.icon)
                                .font(.system(size: 9))
                            Text(suggestion.prompt)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(chipBackground(for: suggestion.kind))
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
        switch kind {
        case .fix:           return AnyShapeStyle(Color.red.opacity(0.1))
        case .explain:       return AnyShapeStyle(Color.blue.opacity(0.1))
        case .nextStep:      return AnyShapeStyle(Color.green.opacity(0.1))
        case .continueAgent: return AnyShapeStyle(Color.purple.opacity(0.1))
        case .custom:        return AnyShapeStyle(Color.secondary.opacity(0.1))
        }
    }
}
