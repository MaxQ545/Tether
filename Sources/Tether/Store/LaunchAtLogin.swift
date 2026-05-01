import Foundation
import Observation
import ServiceManagement
import os

@MainActor
@Observable
final class LaunchAtLogin {
    static let shared = LaunchAtLogin()

    private static let log = Logger(subsystem: "app.tether", category: "LaunchAtLogin")

    private(set) var isEnabled: Bool = false
    private(set) var lastError: String?

    private init() {
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enable: Bool) {
        do {
            if enable, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enable, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            Self.log.error("Failed to \(enable ? "register" : "unregister") login item: \(String(describing: error))")
            lastError = error.localizedDescription
        }
        refresh()
    }
}
