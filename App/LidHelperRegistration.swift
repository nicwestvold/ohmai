import Foundation
import Observation
import OhmaiLidXPC
import ServiceManagement

/// Registers and unregisters the lid helper daemon with launchd via `SMAppService`.
@MainActor
@Observable
final class LidHelperRegistration {
    enum Status: Equatable {
        case notRegistered
        case requiresApproval
        case enabled
        case notFound
        case unknown

        var summary: String {
            switch self {
            case .notRegistered: "Not installed"
            case .requiresApproval: "Waiting for your approval in System Settings → Login Items"
            case .enabled: "Installed and approved"
            case .notFound: "Helper missing from this build"
            case .unknown: "Status unknown"
            }
        }
    }

    private(set) var status: Status = .unknown
    private(set) var lastError: String?
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let service = SMAppService.daemon(plistName: LidHelperXPC.launchdPlistName)

    init() { refresh() }

    /// `SMAppService` doesn't notify on approval, so the app calls this when it matters:
    /// at launch, when Settings or the dropdown opens, and after register/unregister.
    func refresh() {
        let next: Status = switch service.status {
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .enabled: .enabled
        case .notFound: .notFound
        @unknown default: .unknown
        }
        if next != status {
            status = next
            onChange?()
        }
    }

    func register() {
        do {
            try service.register()
            lastError = nil
        } catch {
            // `register` reports "needs approval" as an error too; status tells the real story.
            lastError = service.status == .requiresApproval ? nil : error.localizedDescription
        }
        refresh()
    }

    func unregister() async {
        do {
            try await service.unregister()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
