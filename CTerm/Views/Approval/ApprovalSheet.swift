// ApprovalSheet.swift
// CTerm
//
// Modal sheet that surfaces an ApprovalContext to the user. Shows the full
// action descriptor (what / why / impact / rollback), a risk badge, and a
// scope picker. Hard-stop actions render red and force `.once` scope.
//
// When the context carries a `secureInputRequest`, the sheet switches into
// secure-input mode: the descriptor rows are replaced by a matched-line
// preview + SecureField. The entered text is passed inline through the
// resolve callback; the sheet never stores or logs it beyond the @State
// binding on its SecureField (released when the sheet closes).

import SwiftUI

struct ApprovalSheet: View {
    let context: ApprovalContext
    let hardStop: HardStopReason?
    var onResolve: (ApprovalAnswer, ApprovalScope, String?) -> Void
    var onDismiss: () -> Void

    @State private var scope: ApprovalScope
    @State private var secureText: String = ""
    @State private var autoApproveRemaining: Int = 0
    @State private var autoApproveTimer: Timer? = nil

    init(
        context: ApprovalContext,
        hardStop: HardStopReason? = nil,
        onResolve: @escaping (ApprovalAnswer, ApprovalScope, String?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.context = context
        self.hardStop = hardStop
        self.onResolve = onResolve
        self.onDismiss = onDismiss
        let forcedOnce = hardStop != nil || context.secureInputRequest != nil
        self._scope = State(initialValue: forcedOnce ? .once : context.suggestedScope)
    }

    // True when the Approve button should be enabled in secure-input mode.
    // Exposed via static helper for unit testing (see ApprovalSheet.canSubmit).
    private var canSubmit: Bool {
        Self.canSubmit(secureInputRequest: context.secureInputRequest, enteredText: secureText)
    }

    /// Pure helper: Approve is enabled iff there is no secure input required
    /// OR the user has typed at least one non-empty character.
    static func canSubmit(secureInputRequest: ApprovalSecureInputRequest?, enteredText: String) -> Bool {
        guard secureInputRequest != nil else { return true }
        return !enteredText.isEmpty
    }

    var body: some View {
        if context.secureInputRequest != nil {
            secureBody
        } else {
            standardBody
        }
    }

    // MARK: - Standard layout (unchanged)

    private var standardBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            descriptorRows
            Divider()
            riskRow
            Divider()
            ApprovalScopePicker(selection: $scope, isHardStop: hardStop != nil)
            Divider()
            buttons
        }
        .padding(18)
        .frame(width: 440)
        .onAppear { startAutoApproveIfEligible() }
        .onDisappear { cancelAutoApprove() }
    }

    // MARK: - Auto-approve

    /// Low-risk, non-hard-stop approvals tick down a 5s countdown and
    /// auto-approve. Any user interaction (touching the scope picker,
    /// moving the mouse over the sheet) cancels the timer.
    private var isAutoApproveEligible: Bool {
        hardStop == nil
            && context.secureInputRequest == nil
            && context.riskTier == .low
    }

    private func startAutoApproveIfEligible() {
        guard isAutoApproveEligible else { return }
        autoApproveRemaining = 5
        autoApproveTimer?.invalidate()
        autoApproveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                autoApproveRemaining -= 1
                if autoApproveRemaining <= 0 {
                    autoApproveTimer?.invalidate()
                    autoApproveTimer = nil
                    onResolve(.approved, scope, nil)
                }
            }
        }
    }

    private func cancelAutoApprove() {
        autoApproveTimer?.invalidate()
        autoApproveTimer = nil
        autoApproveRemaining = 0
    }

    // MARK: - Secure-input layout

    private var secureBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            secureHeader
            Divider()
            if let req = context.secureInputRequest {
                secureInputSection(req)
            }
            Divider()
            // Scope is locked to .once for secure input; render read-only.
            ApprovalScopePicker(selection: $scope, isHardStop: true)
            Divider()
            secureButtons
        }
        .padding(18)
        .frame(width: 440)
        .tint(.orange)
    }

    private var secureHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .font(.title3)
                .foregroundStyle(Color.orange)
            Text("Secure Input Requested")
                .font(.headline)
            Spacer()
        }
    }

    private func secureInputSection(_ req: ApprovalSecureInputRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(req.matchedLine)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            SecureField(req.placeholder, text: $secureText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if canSubmit {
                        onResolve(.approved, .once, secureText)
                    }
                }

            Text("CTerm does not store or log this value.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var secureButtons: some View {
        HStack(spacing: 10) {
            Button("Deny") { onResolve(.denied, .once, nil) }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Dismiss") { onDismiss() }
            Button("Send") {
                onResolve(.approved, .once, secureText)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: hardStop != nil ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(hardStop != nil ? Color.red : accentForTier(context.riskTier))
            Text(hardStop != nil ? "Hard Stop — Confirm Once" : "Approval Needed")
                .font(.headline)
            Spacer()
        }
    }

    private var descriptorRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(label: "WHAT", value: context.action.what, mono: true)
            row(label: "WHY", value: context.action.why)
            row(label: "IMPACT", value: context.action.impact)
            if let rollback = context.action.rollback {
                row(label: "ROLLBACK", value: rollback, mono: true)
            }
            if let hardStop {
                row(label: "REASON", value: hardStop.detail)
            }
        }
    }

    private var riskRow: some View {
        HStack(spacing: 8) {
            Image(systemName: context.riskTier.icon)
                .foregroundStyle(accentForTier(context.riskTier))
            Text("\(context.riskTier.label) (\(context.riskScore))")
                .font(.callout.weight(.medium))
            Spacer()
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button("Deny") {
                cancelAutoApprove()
                onResolve(.denied, .once, nil)
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            if autoApproveRemaining > 0 {
                Button("Pause (\(autoApproveRemaining)s)") {
                    cancelAutoApprove()
                }
                .buttonStyle(.bordered)
            }
            Button("Dismiss") {
                cancelAutoApprove()
                onDismiss()
            }
            Button(hardStop != nil ? "Approve once" : "Approve") {
                cancelAutoApprove()
                onResolve(.approved, scope, nil)
            }
            .buttonStyle(.borderedProminent)
            .tint(hardStop != nil ? .red : accentForTier(context.riskTier))
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Helpers

    private func row(label: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .trailing)
            Text(value)
                .font(mono ? .system(.callout, design: .monospaced) : .callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func accentForTier(_ tier: RiskTier) -> Color {
        switch tier {
        case .low:      return .green
        case .medium:   return .yellow
        case .high:     return .orange
        case .critical: return .red
        }
    }
}
