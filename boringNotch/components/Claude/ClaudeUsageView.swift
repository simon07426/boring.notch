import NotchExtrasCore
import SwiftUI

struct ClaudeUsageView: View {
    @ObservedObject private var manager = ClaudeUsageManager.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task { await manager.refresh() }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(now: now)
            if let snapshot = manager.snapshot {
                let stale = manager.error == .network || manager.error == .badResponse
                VStack(alignment: .leading, spacing: 8) {
                    if let b = snapshot.fiveHour { row("5-hour", b, now: now, small: false) }
                    if let b = snapshot.weekly { row("Weekly", b, now: now, small: false) }
                    if let b = snapshot.weeklyModelBucket {
                        row("\(snapshot.weeklyModelName ?? "Model") weekly", b, now: now, small: true)
                    }
                }
                .opacity(stale ? 0.4 : 1)
            } else if manager.error == nil {
                Text("Loading…").font(.subheadline).foregroundStyle(.gray)
            }
            if let error = manager.error { errorView(error) }
        }
    }

    private func header(now: Date) -> some View {
        HStack {
            Text("Claude usage").font(.headline).foregroundStyle(.white)
            Spacer()
            if let updated = manager.lastUpdated {
                Text("updated \(ago(updated, now: now))").font(.caption).foregroundStyle(.gray)
            }
            Button {
                Task { await manager.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise").foregroundStyle(.gray)
            }
            .buttonStyle(.plain)
        }
    }

    private func row(_ title: String, _ bucket: UsageBucket, now: Date, small: Bool) -> some View {
        let color = color(for: UsageLevel.of(bucket.percent))
        return HStack(spacing: 8) {
            Text(title)
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(.white)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule().fill(color)
                        .frame(width: geo.size.width * min(max(bucket.percent, 0), 100) / 100)
                }
            }
            .frame(height: small ? 5 : 8)
            Text("\(Int(bucket.percent.rounded()))%")
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(color)
            Text(resetText(bucket.resetsAt, now: now))
                .foregroundStyle(.gray)
                .frame(width: 110, alignment: .leading)
        }
        .font(small ? .caption : .subheadline)
    }

    @ViewBuilder
    private func errorView(_ error: UsageFetchError) -> some View {
        switch error {
        case .noCredentials:
            Text("Sign in to Claude Code").font(.caption).foregroundStyle(.orange)
        case .keychainDenied:
            Button {
                Task { await manager.refresh() }
            } label: {
                Text("Keychain access denied — click to retry").font(.caption).foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
        case .expired:
            Text("Open Claude Code to refresh login").font(.caption).foregroundStyle(.orange)
        case .network, .badResponse:
            Text("Couldn't reach Anthropic").font(.caption).foregroundStyle(.orange)
        }
    }

    private func color(for level: UsageLevel) -> Color {
        switch level {
        case .normal: return .white
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private func ago(_ date: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        return minutes < 1 ? "just now" : "\(minutes)m ago"
    }
}
