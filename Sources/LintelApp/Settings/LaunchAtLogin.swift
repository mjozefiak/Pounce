import Foundation
import ServiceManagement

/// Launch at login through `SMAppService.mainApp`. QA mode and tests use the in-memory one, so a QA
/// run never registers a login item.
protocol LaunchAtLoginClient: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

final class SystemLaunchAtLogin: LaunchAtLoginClient {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

final class InMemoryLaunchAtLogin: LaunchAtLoginClient {
    private(set) var isEnabled = false

    func setEnabled(_ enabled: Bool) throws {
        isEnabled = enabled
    }
}
