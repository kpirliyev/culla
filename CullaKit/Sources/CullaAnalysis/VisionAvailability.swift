import CoreML
import CullaCore
import Foundation
import Synchronization
import Vision

/// The Vision requests the analyzer performs.
public enum VisionRequestKind: String, CaseIterable, Sendable {
    case faceLandmarks
    case faceCaptureQuality
    case featurePrint
    case aesthetics
    case saliency
    case horizon
    case lensSmudge

    /// A name for diagnostic output. Not shown in the interface.
    public var diagnosticName: String {
        switch self {
        case .faceLandmarks: "Face landmarks"
        case .faceCaptureQuality: "Face capture quality"
        case .featurePrint: "Feature print"
        case .aesthetics: "Aesthetics"
        case .saliency: "Attention saliency"
        case .horizon: "Horizon"
        case .lensSmudge: "Lens smudge"
        }
    }

    /// Whether Vision lists this request's devices wherever the request can run.
    ///
    /// Observed on an M2 and on GitHub's macOS 27 virtual machine, which has no Neural Engine:
    /// face landmarks reports no stages on both and runs on both, so for it an empty report
    /// says nothing. Every other request here reports its devices on the M2. Lens smudge
    /// reports `main: Neural Engine` on the M2 and no stages at all on the virtual machine,
    /// where performing it traps inside Vision; so for these requests an empty report means
    /// this Mac has nothing to run them on.
    public var reportsDevices: Bool {
        self != .faceLandmarks
    }

    /// The devices Vision says this request can run on, per stage of the request.
    var supportedStageDevices: [ComputeStage: [MLComputeDevice]] {
        switch self {
        case .faceLandmarks: Self.devices(of: DetectFaceLandmarksRequest())
        case .faceCaptureQuality: Self.devices(of: DetectFaceCaptureQualityRequest())
        case .featurePrint: Self.devices(of: GenerateImageFeaturePrintRequest())
        case .aesthetics: Self.devices(of: CalculateImageAestheticsScoresRequest())
        case .saliency: Self.devices(of: GenerateAttentionBasedSaliencyImageRequest())
        case .horizon: Self.devices(of: DetectHorizonRequest())
        case .lensSmudge: Self.devices(of: DetectLensSmudgeRequest())
        }
    }

    private static func devices(of request: some VisionRequest) -> [ComputeStage: [MLComputeDevice]] {
        request.supportedComputeStageDevices
    }
}

/// A kind of processor, without the particular device behind it.
public enum ComputeDeviceKind: String, Hashable, Sendable {
    case cpu
    case gpu
    case neuralEngine
    case other

    init(_ device: MLComputeDevice) {
        switch device {
        case .cpu: self = .cpu
        case .gpu: self = .gpu
        case .neuralEngine: self = .neuralEngine
        @unknown default: self = .other
        }
    }

    public var diagnosticName: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .neuralEngine: "Neural Engine"
        case .other: "other"
        }
    }
}

/// Which of the analyzer's Vision requests this Mac can run.
///
/// Vision does not throw for a request this Mac has no device for, it traps, which ends the
/// process: lens smudge on GitHub's macOS 27 virtual machine, which has no Neural Engine. So a
/// request is performed only when Vision's report allows it:
///
/// - A request that reports its devices (`VisionRequestKind.reportsDevices`) needs at least one
///   stage, and every stage needs a kind of device this Mac has. On that virtual machine
///   Vision already leaves the Neural Engine out of every list and reports no stages at all for
///   lens smudge, which is how it is caught.
/// - Face landmarks never reports devices (seen on an M2 and on that virtual machine, and it
///   runs on both), so an empty report does not stop it.
///
/// The lists are also checked against `MLComputeDevice.allComputeDevices`, Core ML's list of the
/// devices present, in case a list names a device the machine lacks. Devices are compared by
/// kind rather than as values, since two values for the same processor need not be equal.
public struct VisionAvailability: Sendable {
    /// The requests this Mac can run.
    public let usable: Set<VisionRequestKind>

    public init(usable: Set<VisionRequestKind>) {
        self.usable = usable
    }

    public func isUsable(_ kind: VisionRequestKind) -> Bool {
        usable.contains(kind)
    }

    /// The decision for one request, as a pure function of what the request and the machine report.
    ///
    /// - Parameters:
    ///   - stageDevices: the device kinds the request lists for each of its stages. A stage with
    ///     an empty list is never usable.
    ///   - reportsDevices: whether the request lists its devices wherever it can run. When it
    ///     does, no stages at all means nothing here can run it; when it does not, no stages
    ///     says nothing and the request is usable.
    ///   - machineDevices: the device kinds this machine has.
    public static func isUsable(
        stageDevices: [[ComputeDeviceKind]],
        reportsDevices: Bool,
        machineDevices: Set<ComputeDeviceKind>
    ) -> Bool {
        if stageDevices.isEmpty { return !reportsDevices }
        return stageDevices.allSatisfy { devices in devices.contains { machineDevices.contains($0) } }
    }

    /// The decision for one request on this machine, from what Vision reports for it.
    static func isUsable(_ kind: VisionRequestKind, machineDevices: Set<ComputeDeviceKind>) -> Bool {
        isUsable(
            stageDevices: Array(stageDeviceKinds(of: kind).values),
            reportsDevices: kind.reportsDevices,
            machineDevices: machineDevices
        )
    }

    /// The device kinds this machine has, according to Core ML.
    public static func machineDeviceKinds() -> Set<ComputeDeviceKind> {
        Set(MLComputeDevice.allComputeDevices.map(ComputeDeviceKind.init))
    }

    /// The device kinds each stage of a request lists.
    /// Public for diagnostics and tests.
    public static func stageDeviceKinds(of kind: VisionRequestKind) -> [ComputeStage: [ComputeDeviceKind]] {
        kind.supportedStageDevices.mapValues { $0.map(ComputeDeviceKind.init) }
    }

    /// Asks Vision and Core ML. May load model descriptions, so it is called off the cooperative pool.
    static func measure() -> VisionAvailability {
        let machine = machineDeviceKinds()
        let usable = VisionRequestKind.allCases.filter { isUsable($0, machineDevices: machine) }
        return VisionAvailability(usable: Set(usable))
    }

    private static let cached = Mutex<VisionAvailability?>(nil)

    /// This Mac's answer, worked out once per process on `BlockingQueue` and kept.
    public static func current() async -> VisionAvailability {
        if let known = cached.withLock({ $0 }) { return known }
        let measured = await BlockingQueue.shared.run { measure() }
        // Two first callers may both measure; they get the same answer, and the first one is kept.
        return cached.withLock { stored in
            if let stored { return stored }
            stored = measured
            return measured
        }
    }
}
