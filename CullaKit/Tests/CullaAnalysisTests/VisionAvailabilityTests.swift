import CullaAnalysis
import Testing

@Suite("Vision availability")
struct VisionAvailabilityTests {
    private let appleSilicon: Set<ComputeDeviceKind> = [.cpu, .gpu, .neuralEngine]
    /// A virtual machine, such as GitHub's macOS runners: no Neural Engine.
    private let virtualMachine: Set<ComputeDeviceKind> = [.cpu, .gpu]

    @Test func aRequestOnlyForTheNeuralEngineIsUnusableWithoutOne() {
        let smudgeLike: [[ComputeDeviceKind]] = [[.neuralEngine]]
        #expect(VisionAvailability.isUsable(stageDevices: smudgeLike, machineDevices: appleSilicon))
        #expect(!VisionAvailability.isUsable(stageDevices: smudgeLike, machineDevices: virtualMachine))
    }

    @Test func oneDeviceInCommonIsEnough() {
        let devices: [[ComputeDeviceKind]] = [[.neuralEngine, .gpu, .cpu]]
        #expect(VisionAvailability.isUsable(stageDevices: devices, machineDevices: virtualMachine))
        #expect(VisionAvailability.isUsable(stageDevices: devices, machineDevices: [.cpu]))
    }

    @Test func everyStageNeedsADevice() {
        let twoStages: [[ComputeDeviceKind]] = [[.cpu, .gpu], [.neuralEngine]]
        #expect(VisionAvailability.isUsable(stageDevices: twoStages, machineDevices: appleSilicon))
        #expect(!VisionAvailability.isUsable(stageDevices: twoStages, machineDevices: virtualMachine))
    }

    @Test func aStageWithNoDevicesIsUnusable() {
        #expect(!VisionAvailability.isUsable(stageDevices: [[]], machineDevices: appleSilicon))
        #expect(!VisionAvailability.isUsable(stageDevices: [[.cpu], []], machineDevices: appleSilicon))
    }

    @Test func aRequestWithNoStagesHasNothingToChooseAndIsUsable() {
        #expect(VisionAvailability.isUsable(stageDevices: [], machineDevices: virtualMachine))
    }

    @Test func aMachineReportingNoDevicesCanRunNothingThatNeedsOne() {
        #expect(!VisionAvailability.isUsable(stageDevices: [[.cpu, .gpu, .neuralEngine]], machineDevices: []))
    }

    /// Prints what Vision and Core ML report on the machine running the tests, and the decision
    /// taken from it. The CI log shows this line for the runner, which cannot be checked here.
    @Test func reportsTheDevicesOnThisMachine() async {
        let lines = ComputeDeviceReport.lines()
        print("Vision devices on this machine:\n  " + lines.joined(separator: "\n  "))
        let available = await VisionAvailability.current()
        #expect(lines.count == VisionRequestKind.allCases.count + 3)
        // The cached answer and a fresh one agree.
        let machine = VisionAvailability.machineDeviceKinds()
        for kind in VisionRequestKind.allCases {
            let fresh = VisionAvailability.isUsable(
                stageDevices: Array(VisionAvailability.stageDeviceKinds(of: kind).values), machineDevices: machine
            )
            #expect(available.isUsable(kind) == fresh, "\(kind.diagnosticName)")
        }
    }
}
