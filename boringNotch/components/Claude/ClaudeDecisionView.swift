import NotchExtrasCore
import SwiftUI

/// Hosts the pop-up for the current Claude decision: permission or question, plus the "Sent" confirmation.
/// `holdSent` stays true for 0.8 s after an answer so the parent keeps this view on screen.
struct ClaudeDecisionHost: View {
    @ObservedObject private var manager = ClaudeDecisionManager.shared
    @Binding var holdSent: Bool
    /// Called after "Sent" when no further decision is queued.
    var onFinished: () -> Void

    /// Snapshot so the view survives the manager moving on to the next decision.
    @State private var shown: PendingDecision?

    var body: some View {
        Group {
            if holdSent {
                sentView
            } else if let decision = shown ?? manager.current {
                if decision.request.kind == .question, let questions = decision.request.questions, !questions.isEmpty {
                    ClaudeQuestionView(decision: decision, questions: questions, queuedCount: manager.queuedCount,
                                       onAnswer: { answers in send { manager.answer(id: decision.id, answers) } },
                                       onHandBack: { manager.handBack(id: decision.id) })
                        .id(decision.id)
                } else {
                    ClaudePermissionView(decision: decision, queuedCount: manager.queuedCount,
                                         onAllow: { send { manager.allow(id: decision.id) } },
                                         onDeny: { send { manager.deny(id: decision.id) } },
                                         onHandBack: { manager.handBack(id: decision.id) })
                        .id(decision.id)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { shown = manager.current }
        .onChange(of: manager.current) { _, new in if !holdSent { shown = new } }
    }

    private var sentView: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.effectiveAccent)
            Text("Sent").font(.headline).foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func send(_ action: () -> Void) {
        action()
        holdSent = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            holdSent = false
            shown = manager.current
            if manager.current == nil { onFinished() }
        }
    }
}

struct ClaudeDecisionHeader: View {
    let project: String?
    let queuedCount: Int
    var trailing: String?

    var body: some View {
        HStack {
            Text(project.map { "Claude · \($0)" } ?? "Claude").font(.headline).foregroundStyle(.white)
            if queuedCount > 0 {
                Text("(+\(queuedCount) more)").font(.caption).foregroundStyle(.gray)
            }
            Spacer()
            if let trailing { Text(trailing).font(.caption).foregroundStyle(.gray) }
        }
    }
}

/// The notch auto-expands under the cursor, so a click meant for something else could land on Allow.
/// Every action stays disabled (and dimmed) for `delay` after a decision is first shown.
enum ClaudeDecisionClickGuard {
    static let delay: Duration = .milliseconds(800)
    static let disabledOpacity = 0.5

    /// Run as `.task(id: decision.id)`: re-arms the guard whenever the displayed decision changes.
    @MainActor
    static func arm(_ armed: Binding<Bool>) async {
        armed.wrappedValue = false
        try? await Task.sleep(for: delay)
        if !Task.isCancelled { armed.wrappedValue = true }
    }
}

struct ClaudePermissionView: View {
    let decision: PendingDecision
    let queuedCount: Int
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onHandBack: () -> Void

    @State private var armed = false

    var body: some View {
        let r = decision.request
        VStack(alignment: .leading, spacing: 8) {
            ClaudeDecisionHeader(project: r.project, queuedCount: queuedCount)
            ViewThatFits(in: .vertical) {
                permissionText(r)
                ScrollView(.vertical, showsIndicators: false) { permissionText(r) }
            }
            buttonRow
                .disabled(!armed)
                .opacity(armed ? 1 : ClaudeDecisionClickGuard.disabledOpacity)
        }
        .task(id: decision.id) { await ClaudeDecisionClickGuard.arm($armed) }
    }

    private func permissionText(_ r: DecisionRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(r.command == nil ? r.question : "Allow running:")
                .font(.subheadline).foregroundStyle(.white)
            if let command = r.command {
                // The full command, never truncated: it is what gets allowed. Long ones scroll above the buttons.
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            if let explain = r.explain, !explain.isEmpty {
                Text("\u{201C}\(explain)\u{201D}").font(.caption).foregroundStyle(.gray).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var buttonRow: some View {
        HStack(spacing: 8) {
            Button("Deny", action: onDeny)
            Spacer()
            Button("Answer in Claude", action: onHandBack)
            Button(action: onAllow) { Text("Allow").bold() }
                .buttonStyle(.borderedProminent)
                .tint(Color.effectiveAccent)
        }
        .controlSize(.small)
    }
}
