import AgentCore
import SwiftUI

struct SettingsView: View {
    @Bindable var host: HostModel

    var body: some View {
        TabView {
            ConnectionSettings(host: host)
                .tabItem { Label("Pool", systemImage: "network") }
            MachineSettings(host: host)
                .tabItem { Label("Virtual machines", systemImage: "cpu") }
        }
        .frame(width: 480)
        .padding()
    }
}

private struct ConnectionSettings: View {
    @Bindable var host: HostModel

    var body: some View {
        Form {
            if let credentials = host.credentials {
                LabeledContent("Server", value: credentials.controlPlane.absoluteString)
                LabeledContent("This Mac", value: HostInventory.computerName)
                LabeledContent("Host ID", value: credentials.hostID.uuidString)
                    .textSelection(.enabled)
                Button("Disconnect This Mac", role: .destructive) {
                    Task { await host.signOut() }
                }
            } else {
                ConnectForm(host: host)
            }
            if let problem = host.problem {
                Text(problem)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            Toggle("Launch at login", isOn: Binding(get: { host.launchAtLogin }, set: { host.launchAtLogin = $0 }))
        }
        .formStyle(.grouped)
    }
}

/// Server address and token → enrolled. Shown in the menu bar window and in Settings.
struct ConnectForm: View {
    @Bindable var host: HostModel
    @State private var address = ""
    @State private var token = ""
    @State private var connecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Server", text: $address, prompt: Text("maccheri.example.com"))
                .textContentType(.URL)
            SecureField("Token", text: $token, prompt: Text("from the team's admin"))
                .onSubmit(connect)
            if let error = host.enrollmentError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if connecting { ProgressView().controlSize(.small) }
                Spacer()
                Button(connecting ? "Connecting…" : "Connect This Mac", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(connecting || address.trimmingCharacters(in: .whitespaces).isEmpty || token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .onAppear { if address.isEmpty { address = host.settings.controlPlane } }
    }

    private func connect() {
        guard !connecting else { return }
        connecting = true
        Task {
            await host.enroll(controlPlane: address, token: token)
            connecting = false
            if host.credentials != nil { token = "" }
        }
    }
}

private struct MachineSettings: View {
    @Bindable var host: HostModel
    private let resources = HostResources.current()

    var body: some View {
        Form {
            Section {
                DirectoryField(title: "Images", path: $host.settings.imagesPath)
                DirectoryField(title: "Clones", path: $host.settings.workPath)
                HStack {
                    Spacer()
                    Button("Rescan Images", action: host.rescanImages)
                    Button("Apply Paths") { Task { await host.restart() } }
                }
            } footer: {
                Text("Clones are APFS copies of an image, so both folders must be on the same volume.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Stepper("At most \(host.settings.maxVMs) VMs at once", value: $host.settings.maxVMs, in: 1...PoolSettings.licenseLimit)
                Stepper("Keep \(host.settings.warmVMs) warm", value: $host.settings.warmVMs, in: 0...PoolSettings.licenseLimit)
                Stepper("VMs may use \(host.settings.memoryBudgetGB) GB of \(resources.memoryGB) GB RAM", value: $host.settings.memoryBudgetGB, in: 4...max(4, resources.memoryGB))
            } footer: {
                Text("Apple's license allows two macOS VMs per Mac. A warm VM is booted ahead of time so a simulator session starts in seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Each VM") {
                OptionalStepper(title: "CPU cores", value: $host.settings.cpuCount, range: 2...resources.cpuCount)
                OptionalStepper(title: "Memory, GB", value: $host.settings.memoryGB, range: 4...max(4, resources.memoryGB))
            }
        }
        .formStyle(.grouped)
    }
}

private struct DirectoryField: View {
    let title: LocalizedStringKey
    @Binding var path: String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = URL(filePath: path)
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }
            }
        }
    }
}

/// "From image" or a fixed number.
private struct OptionalStepper: View {
    let title: LocalizedStringKey
    @Binding var value: Int?
    let range: ClosedRange<Int>

    var body: some View {
        LabeledContent(title) {
            HStack {
                Toggle("From image", isOn: Binding(get: { value == nil }, set: { value = $0 ? nil : range.lowerBound }))
                    .toggleStyle(.checkbox)
                if let current = value {
                    Stepper("\(current)", value: Binding(get: { current }, set: { value = $0 }), in: range)
                }
            }
        }
    }
}

struct HostResources: Equatable {
    var cpuCount: Int
    var memoryGB: Int

    static func current() -> HostResources {
        let info = ProcessInfo.processInfo
        return HostResources(cpuCount: info.activeProcessorCount, memoryGB: Int(info.physicalMemory >> 30))
    }
}
