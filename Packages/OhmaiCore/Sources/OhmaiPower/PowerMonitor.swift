import Foundation
import IOKit.ps
import Observation
import notify
import OhmaiCore

/// Watches the power source, Low Power Mode and thermal state, and reports changes.
@MainActor
@Observable
public final class PowerMonitor {
    public private(set) var source: PowerSource = .unknown
    public private(set) var lowPowerMode = false
    public private(set) var thermal: ThermalState = .nominal

    /// Called on the main actor after any input changes.
    @ObservationIgnored public var onChange: (() -> Void)?

    @ObservationIgnored private var notifyToken: Int32?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    public init() {
        refresh()
        start()
    }

    isolated deinit {
        if let notifyToken { notify_cancel(notifyToken) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    public func refresh() {
        source = PowerSourceReader.current()
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        thermal = ThermalState(ProcessInfo.processInfo.thermalState)
        onChange?()
    }

    private func start() {
        // Fires on any power source change, including charge percentage.
        var token: Int32 = 0
        let status = notify_register_dispatch(kIOPSNotifyAnyPowerSource, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if status == NOTIFY_STATUS_OK { notifyToken = token }
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }
}

extension ThermalState {
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        // Unknown future values: assume the worst, so we release.
        @unknown default: self = .critical
        }
    }
}
