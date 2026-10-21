import AgentCore
import MaccheriProtocol
import SwiftUI

struct StatusMenu: View {
    @Bindable var host: HostModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            connection

            if host.credentials != nil {
                Toggle("Accept work", isOn: Binding(get: { !host.isPaused }, set: { host.setPaused(!$0) }))
                    .toggleStyle(.switch)

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("VM slots")
                        Text("\(host.status.pool.busy) busy, \(host.status.pool.freeSlots) free of \(host.status.pool.slots)")
                    }
                    GridRow {
                        Text("Warm VMs")
                        Text(warmDescription)
                    }
                    GridRow {
                        Text("Images")
                        Text(host.status.images.isEmpty ? String(localized: "none") : host.status.images.joined(separator: ", "))
                            .lineLimit(2)
                    }
                }
                .font(.callout.monospacedDigit())

                if !host.status.activities.isEmpty {
                    Divider()
                    ForEach(host.status.activities) { activity in
                        ActivityRow(activity: activity)
                    }
                }
            }

            if host.credentials != nil, host.servableImages.isEmpty {
                Label("No Maccheri images in \(host.settings.imagesPath). Choose the images folder in Settings.", systemImage: "externaldrive.badge.questionmark")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            if let problem = host.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            Divider()

            HStack {
                Button("Settings…") {
                    openSettings()
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding()
        .frame(width: 300)
    }

    @ViewBuilder
    private var connection: some View {
        if host.credentials == nil {
            Label("Not connected to a pool", systemImage: "circle.dashed")
            Text("Enter your team's Maccheri server and the code from your team's admin.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ConnectForm(host: host)
        } else {
            if let team = host.credentials?.teamName {
                Label(team, systemImage: "person.3")
                    .font(.headline)
            }
            switch host.status.connection {
            case .online:
                Label(host.isPaused ? "Online, paused" : "Online", systemImage: "circle.fill")
                    .foregroundStyle(host.isPaused ? .orange : .green)
            case .connecting:
                Label("Connecting…", systemImage: "circle.dotted")
            case let .offline(reason):
                Label("Offline", systemImage: "circle.slash")
                    .foregroundStyle(.red)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    private var warmDescription: String {
        let pool = host.status.pool
        if pool.warm == 0 { return String(localized: "none") }
        let booting = pool.warm - pool.warmBooted
        return booting > 0 ? String(localized: "\(pool.warmBooted) ready, \(booting) booting") : String(localized: "\(pool.warmBooted) ready")
    }
}

private struct ActivityRow: View {
    let activity: AgentStatus.Activity

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: symbol)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text("\(phase) · \(activity.startedAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private var symbol: String {
        switch activity.kind {
        case .ci: "hammer"
        case .simulator: "iphone"
        }
    }

    private var title: String {
        switch activity.kind {
        case let .ci(repository): String(localized: "CI: \(repository)")
        case let .simulator(device): String(localized: "Simulator: \(device.shortName)")
        }
    }

    private var phase: String {
        switch activity.phase {
        case .starting: activity.usedWarmVM ? String(localized: "starting (warm VM)") : String(localized: "booting VM")
        case .running: String(localized: "running")
        case .finishing: String(localized: "cleaning up")
        }
    }
}

extension DeviceSpec {
    /// `iPhone 17 Pro, iOS 27.2` from the CoreSimulator identifiers.
    var shortName: String {
        let type = deviceType.split(separator: ".").last.map { $0.replacingOccurrences(of: "-", with: " ") } ?? deviceType
        let os = runtime.split(separator: ".").last.map { part -> String in
            let pieces = part.split(separator: "-")
            return pieces.count > 1 ? "\(pieces[0]) \(pieces.dropFirst().joined(separator: "."))" : String(part)
        } ?? runtime
        return "\(type), \(os)"
    }
}
