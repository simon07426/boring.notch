import NotchExtrasCore
import SwiftUI

/// Multiple-choice question(s) from Claude: one question at a time ("1 of N").
struct ClaudeQuestionView: View {
    let decision: PendingDecision
    let questions: [DecisionQuestion]
    let queuedCount: Int
    let onAnswer: ([String: String]) -> Void
    let onHandBack: () -> Void

    @State private var index = 0
    @State private var answers: [String: String] = [:]
    @State private var picked: Set<String> = []
    @State private var armed = false

    private var question: DecisionQuestion { questions[min(index, questions.count - 1)] }
    private var isLast: Bool { index >= questions.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ClaudeDecisionHeader(project: decision.request.project, queuedCount: queuedCount,
                                 trailing: questions.count > 1 ? "\(index + 1) of \(questions.count)" : nil)
            Text(question.question).font(.subheadline).foregroundStyle(.white).lineLimit(2)
            ViewThatFits(in: .vertical) {
                optionList
                ScrollView(showsIndicators: false) { optionList }
            }
            HStack {
                Button("Answer in Claude", action: onHandBack)
                Spacer()
                if question.multiSelect {
                    Button(isLast ? "Submit" : "Next") { commit(ordered(picked)) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.effectiveAccent)
                        .disabled(picked.isEmpty)
                }
            }
            .controlSize(.small)
            .disabled(!armed)
            .opacity(armed ? 1 : ClaudeDecisionClickGuard.disabledOpacity)
        }
        .task(id: decision.id) { await ClaudeDecisionClickGuard.arm($armed) }
    }

    private var optionList: some View {
        VStack(spacing: 4) {
            ForEach(question.options, id: \.label) { option in
                optionRow(option)
            }
        }
        .disabled(!armed)
        .opacity(armed ? 1 : ClaudeDecisionClickGuard.disabledOpacity)
    }

    private func optionRow(_ option: DecisionQuestion.Option) -> some View {
        let selected = picked.contains(option.label)
        return Button {
            if question.multiSelect {
                if selected { picked.remove(option.label) } else { picked.insert(option.label) }
            } else {
                commit(option.label)
            }
        } label: {
            HStack(spacing: 8) {
                if question.multiSelect {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(selected ? Color.effectiveAccent : .gray)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(.caption).bold().foregroundStyle(.white)
                    if let d = option.description, !d.isEmpty {
                        Text(d).font(.caption2).foregroundStyle(.gray).lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(selected ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func ordered(_ labels: Set<String>) -> String {
        question.options.map(\.label).filter(labels.contains).joined(separator: ", ")
    }

    private func commit(_ value: String) {
        answers[question.question] = value
        if isLast {
            onAnswer(answers)
        } else {
            index += 1
            picked = []
        }
    }
}
