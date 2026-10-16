import SwiftUI

struct StatusMenu: View {
    @Bindable var host: HostModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Accept CI jobs", isOn: $host.isAccepting)
                .toggleStyle(.switch)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("CPU")
                    Text("\(host.resources.cpuCount) cores")
                }
                GridRow {
                    Text("Memory")
                    Text("\(host.resources.memoryGB, format: .number.precision(.fractionLength(0))) GB")
                }
                GridRow {
                    Text("Free disk")
                    Text("\(host.resources.freeDiskGB, format: .number.precision(.fractionLength(0))) GB")
                }
                GridRow {
                    Text("Free slots")
                    Text("\(host.leaseRequest.freeSlots) of \(HostModel.maxSlots)")
                }
            }
            .font(.callout.monospacedDigit())

            if !host.blockers.isEmpty {
                ForEach(host.blockers, id: \.self) { blocker in
                    Label(blocker, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            Text(host.labels.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Button("Refresh", action: host.refresh)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding()
        .frame(width: 280)
        .onAppear(perform: host.refresh)
    }
}
