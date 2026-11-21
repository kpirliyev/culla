import CoreML
import Foundation
import Vision

/// Lists which processors Vision says each request can run on, which processors this Mac has,
/// and so which requests the analyzer performs here (see `VisionAvailability`).
///
/// This is what the public API reports. Vision picks among the listed devices itself;
/// it does not report which one a given run used, or how busy that device was.
/// Synchronous and possibly slow: call it off the cooperative pool when that matters.
public enum ComputeDeviceReport {
    public static func lines() -> [String] {
        let machine = VisionAvailability.machineDeviceKinds()
        var lines = VisionRequestKind.allCases.map(describe)
        lines.append("This Mac: \(names(machine))")
        let availability = VisionAvailability.measure()
        let skipped = VisionRequestKind.allCases.filter { !availability.isUsable($0) }
        lines.append(
            "Performed here: "
                + VisionRequestKind.allCases.filter(availability.isUsable).map(\.diagnosticName).joined(separator: ", ")
        )
        lines.append(
            "Skipped here: "
                + (skipped.isEmpty ? "none" : skipped.map(\.diagnosticName).joined(separator: ", "))
        )
        return lines
    }

    private static func describe(_ kind: VisionRequestKind) -> String {
        let stages = VisionAvailability.stageDeviceKinds(of: kind)
        guard !stages.isEmpty else {
            return kind.reportsDevices
                ? "\(kind.diagnosticName): reports no devices: skipped"
                : "\(kind.diagnosticName): never reports devices: performed"
        }
        let parts = stages
            .map { stage, devices in
                "\(stageName(stage)): \(devices.isEmpty ? "none" : devices.map(\.diagnosticName).joined(separator: ", "))"
            }
            .sorted()
        return "\(kind.diagnosticName): \(parts.joined(separator: "; "))"
    }

    private static func names(_ kinds: Set<ComputeDeviceKind>) -> String {
        kinds.isEmpty ? "none" : kinds.map(\.diagnosticName).sorted().joined(separator: ", ")
    }

    private static func stageName(_ stage: ComputeStage) -> String {
        switch stage {
        case .main: "main"
        case .postProcessing: "post-processing"
        @unknown default: "other"
        }
    }
}
