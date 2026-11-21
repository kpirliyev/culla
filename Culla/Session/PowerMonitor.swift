import CullaCommands
import Foundation
import IOKit.ps
import Observation
import notify

/// What the Mac's power and memory say about how hard analysis may work: whether it runs on
/// battery, and whether the system is short of memory. Follows changes as they happen.
///
/// Uses public interfaces only: IOKit's power source information with its change notification,
/// and Dispatch's memory pressure source.
@MainActor
@Observable
final class PowerMonitor {
    /// True while the Mac draws on its battery.
    private(set) var onBattery = false
    private(set) var memoryPressure = AnalysisConcurrency.MemoryPressure.normal
    /// Set by the automation harness to act as if on battery (true) or on mains power (false).
    var simulatedBattery: Bool? {
        didSet { refreshPowerSource() }
    }

    @ObservationIgnored private var notifyToken: Int32 = NOTIFY_TOKEN_INVALID
    @ObservationIgnored private var pressureSource: (any DispatchSourceMemoryPressure)?

    init() {
        refreshPowerSource()
        notify_register_dispatch("com.apple.system.powersources.source", &notifyToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPowerSource() }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            MainActor.assumeIsolated {
                if event.contains(.critical) {
                    self?.memoryPressure = .critical
                } else if event.contains(.warning) {
                    self?.memoryPressure = .warning
                } else {
                    self?.memoryPressure = .normal
                }
            }
        }
        source.resume()
        pressureSource = source
    }

    isolated deinit {
        if notifyToken != NOTIFY_TOKEN_INVALID { notify_cancel(notifyToken) }
        pressureSource?.cancel()
    }

    private func refreshPowerSource() {
        if let simulatedBattery {
            onBattery = simulatedBattery
            return
        }
        let battery = Self.isOnBattery()
        if battery != onBattery { onBattery = battery }
    }

    /// True when the providing power source is the battery. A desktop Mac has none.
    nonisolated static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}
