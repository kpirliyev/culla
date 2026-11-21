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
/// Some requests run only on the Neural Engine: `DetectLensSmudgeRequest` lists no other device.
/// On a Mac without one (a virtual machine, such as GitHub's macOS runners) Vision does not throw
/// for such a request, it traps, which ends the process. So a request is performed only when
/// every one of its stages lists at least one kind of device this Mac really has.
///
/// The request's own list is not trusted on its own: nothing in Vision's documentation promises
/// that it leaves out devices the machine lacks, so it is checked against
/// `MLComputeDevice.allComputeDevices`, Core ML's list of the devices present. Devices are compared
/// by kind rather than as values, since two values for the same processor need not be equal.
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
    ///   - stageDevices: the device kinds the request lists for each of its stages. A request
    ///     that reports no stages at all has nothing to choose between and is usable; a stage
    ///     with an empty list is not.
    ///   - machineDevices: the device kinds this machine has.
    public static func isUsable(stageDevices: [[ComputeDeviceKind]], machineDevices: Set<ComputeDeviceKind>) -> Bool {
        stageDevices.allSatisfy { devices in devices.contains { machineDevices.contains($0) } }
    }

    /// The device kinds this machine has, according to Core ML.
    public static func machineDeviceKinds() -> Set<ComputeDeviceKind> {
        Set(MLComputeDevice.allComputeDevices.map(ComputeDeviceKind.init))
    }

    /// The device kinds each stage of a request lists.
    public static func stageDeviceKinds(of kind: VisionRequestKind) -> [ComputeStage: [ComputeDeviceKind]] {
        kind.supportedStageDevices.mapValues { $0.map(ComputeDeviceKind.init) }
    }

    /// Asks Vision and Core ML. May load model descriptions, so it is called off the cooperative pool.
    static func measure() -> VisionAvailability {
        let machine = machineDeviceKinds()
        let usable = VisionRequestKind.allCases.filter { kind in
            isUsable(stageDevices: Array(stageDeviceKinds(of: kind).values), machineDevices: machine)
        }
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
