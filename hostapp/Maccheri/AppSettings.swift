import AgentCore
import Foundation

/// The owner's settings, in user defaults. The token lives in the keychain (`AgentCredentials`).
struct AppSettings: Codable, Equatable {
    var controlPlane = ""
    var imagesPath = "/Volumes/Dev/vm/images"
    var workPath = "/Volumes/Dev/vm/work"
    var maxVMs = PoolSettings.licenseLimit
    var warmVMs = 1
    /// nil: what the image's `config.json` says.
    var cpuCount: Int?
    var memoryGB: Int?
    /// RAM all VMs together may use.
    var memoryBudgetGB = Int(PoolSettings.defaultMemoryBudget >> 30)
    var paused = false

    private static let key = "settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    var store: ImageStore {
        ImageStore(imagesDirectory: URL(filePath: imagesPath, directoryHint: .isDirectory), workDirectory: URL(filePath: workPath, directoryHint: .isDirectory))
    }

    var pool: PoolSettings {
        PoolSettings(
            maxVMs: maxVMs,
            warmVMs: warmVMs,
            memoryBudget: UInt64(memoryBudgetGB) << 30,
            resources: VMResources(cpuCount: cpuCount, memorySize: memoryGB.map { UInt64($0) << 30 })
        )
    }
}
