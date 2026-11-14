import Defaults
import NotchExtrasCore
import SwiftUI

struct FansView: View {
    @ObservedObject private var manager = FanManager.shared
    @Default(.fanSensorsExpanded) private var expanded
    @State private var text = ""
    @State private var syncedText = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ViewThatFits(in: .vertical) {
            fansContent
            ScrollView(.vertical, showsIndicators: false) { fansContent }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { manager.startPolling() }
        .onDisappear { manager.stopPolling() }
    }

    private var fansContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if manager.daemonInstalled, let fans = manager.status?.fans, !fans.isEmpty {
                controls(fans)
            } else if !manager.daemonInstalled {
                enableRow
            } else {
                Text("Loading…").font(.subheadline).foregroundStyle(.gray)
            }
            temperatures
            if let message = manager.errorMessage {
                Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Sections

    private var isManual: Bool {
        manager.manualTarget != nil || (manager.status?.fans.contains(where: \.manual) ?? false)
    }

    private var header: some View {
        HStack {
            Text("Fans").font(.headline).foregroundStyle(.white)
            Spacer()
            if manager.daemonInstalled, manager.status != nil {
                if isManual {
                    Text("Manual").font(.caption).foregroundStyle(.orange)
                }
                Button { manager.setAuto() } label: {
                    Text("Auto")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Capsule().fill(isManual ? Color.white.opacity(0.15) : Color.accentColor))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func controls(_ fans: [FanInfo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(fans.enumerated().map { "\(label($0.offset, of: fans.count)) \(FanMath.display($0.element.actual))" }
                .joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.white).monospacedDigit()
            if let range = manager.range {
                HStack(spacing: 8) {
                    Text("\(Int(range.lowerBound))").font(.caption2).foregroundStyle(.gray).monospacedDigit()
                    Slider(value: sliderBinding(range), in: range)
                    TextField("", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                        .focused($fieldFocused)
                        .onSubmit { commit(range) }
                        .onChange(of: fieldFocused) { _, focused in if !focused { commit(range) } }
                    Text("rpm").font(.caption).foregroundStyle(.gray)
                }
                .onAppear { syncText() }
                .onChange(of: manager.displayTarget) { _, _ in if !fieldFocused { syncText() } }
            }
        }
    }

    private var enableRow: some View {
        HStack {
            Text("Fan control needs a small helper.").font(.caption).foregroundStyle(.gray)
            Spacer()
            Button("Enable fan control") { Task { await manager.installDaemon() } }
                .controlSize(.small)
        }
    }

    private var temperatures: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                if let cpu = manager.sensors?.cpu { temp("CPU", cpu) }
                if let gpu = manager.sensors?.gpu { temp("GPU", gpu) }
                if manager.sensors == nil { Text("Reading sensors…").font(.caption).foregroundStyle(.gray) }
                Spacer()
                if let extras = manager.sensors?.extras, !extras.isEmpty {
                    Button { withAnimation(.smooth) { expanded.toggle() } } label: {
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .foregroundStyle(.gray)
                    }
                    .buttonStyle(.plain)
                }
            }
            if expanded, let extras = manager.sensors?.extras, !extras.isEmpty {
                Text(extras.map { "\($0.name) \(Int($0.celsius.rounded()))°C" }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.gray)
            }
        }
    }

    // MARK: - Helpers

    private func temp(_ name: String, _ celsius: Double) -> some View {
        Text("\(name) \(Int(celsius.rounded()))°C").font(.subheadline).foregroundStyle(.white).monospacedDigit()
    }

    private func label(_ index: Int, of count: Int) -> String {
        count == 2 ? (index == 0 ? "Left" : "Right") : "Fan \(index + 1)"
    }

    private func sliderBinding(_ range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { min(max(manager.displayTarget ?? range.lowerBound, range.lowerBound), range.upperBound) },
            set: { manager.setSpeed(FanMath.snap($0, min: range.lowerBound, max: range.upperBound)) }
        )
    }

    /// Acts only when the user changed the text; a bare focus/blur must not engage Manual.
    private func commit(_ range: ClosedRange<Double>) {
        guard text != syncedText else { return }
        let parsed = FanMath.parseTyped(text, min: range.lowerBound, max: range.upperBound)
        if let parsed { manager.setSpeed(parsed) }
        syncText(forceFrom: parsed)
    }

    /// Shows the current target, or `forceFrom` right after a commit. Invalid input with no
    /// known target reverts to an empty field.
    private func syncText(forceFrom value: Double? = nil) {
        let shown = (value ?? manager.displayTarget).map { "\(Int($0.rounded()))" } ?? ""
        text = shown
        syncedText = shown
    }
}
