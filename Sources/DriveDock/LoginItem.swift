import Foundation
import ServiceManagement

enum LoginItem {
    /// Demo mode: shown and switched without touching the real login item.
    static var demoValue: Bool?

    static var isEnabled: Bool { demoValue ?? (SMAppService.mainApp.status == .enabled) }

    static func set(_ enabled: Bool) throws {
        if demoValue != nil {
            demoValue = enabled
        } else if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Registers the app as login item once, on the very first launch.
    static func enableOnFirstLaunch() {
        let key = "didOfferLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? set(true)
    }
}
