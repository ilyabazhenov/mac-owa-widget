import ServiceManagement

@MainActor
protocol LaunchAtLoginManaging: AnyObject {
    var isEnabled: Bool { get }
    var requiresApproval: Bool { get }
    func register() throws
    func unregister() throws
}

@MainActor
final class LaunchAtLoginService: LaunchAtLoginManaging {
    private let service = SMAppService.mainApp

    var isEnabled: Bool {
        service.status == .enabled
    }

    var requiresApproval: Bool {
        service.status == .requiresApproval
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}
