import CoreML
import Foundation
import Vision

/// Lists which processors Vision says each request can run on.
///
/// This is what the public API reports. Vision picks among the listed devices itself;
/// it does not report which one a given run used, or how busy that device was.
public enum ComputeDeviceReport {
    public static func lines() -> [String] {
        [
            describe("Face landmarks", DetectFaceLandmarksRequest()),
            describe("Face capture quality", DetectFaceCaptureQualityRequest()),
            describe("Feature print", GenerateImageFeaturePrintRequest()),
            describe("Aesthetics", CalculateImageAestheticsScoresRequest()),
            describe("Attention saliency", GenerateAttentionBasedSaliencyImageRequest()),
            describe("Horizon", DetectHorizonRequest()),
            describe("Lens smudge", DetectLensSmudgeRequest()),
        ]
    }

    private static func describe<Request: VisionRequest>(_ name: String, _ request: Request) -> String {
        let stages = request.supportedComputeStageDevices
        guard !stages.isEmpty else { return "\(name): no selectable device reported" }
        let parts = stages
            .map { stage, devices in
                "\(stageName(stage)): \(devices.map(deviceName).joined(separator: ", "))"
            }
            .sorted()
        return "\(name): \(parts.joined(separator: "; "))"
    }

    private static func stageName(_ stage: ComputeStage) -> String {
        switch stage {
        case .main: "main"
        case .postProcessing: "post-processing"
        @unknown default: "other"
        }
    }

    private static func deviceName(_ device: MLComputeDevice) -> String {
        switch device {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .neuralEngine: "Neural Engine"
        @unknown default: "other"
        }
    }
}
