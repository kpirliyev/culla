import CullaAnalysis
import Testing

@Suite("Vision availability")
struct VisionAvailabilityTests {
    private let appleSilicon: Set<ComputeDeviceKind> = [.cpu, .gpu, .neuralEngine]
    /// A virtual machine, such as GitHub's macOS runners: no Neural Engine.
    private let virtualMachine: Set<ComputeDeviceKind> = [.cpu, .gpu]

    private func usable(_ stages: [[ComputeDeviceKind]], reports: Bool = true, on machine: Set<ComputeDeviceKind>) -> Bool {
        VisionAvailability.isUsable(stageDevices: stages, reportsDevices: reports, machineDevices: machine)
    }

    /// What GitHub's macOS 27 virtual machine reported: lens smudge with no stages at all, face
    /// landmarks with none either, on a machine with a CPU and a GPU. Smudge traps there; landmarks run.
    @Test func theVirtualMachineCase() {
        #expect(!usable([], reports: VisionRequestKind.lensSmudge.reportsDevices, on: virtualMachine))
        #expect(usable([], reports: VisionRequestKind.faceLandmarks.reportsDevices, on: virtualMachine))
        // And what the M2 reports for lens smudge.
        #expect(usable([[.neuralEngine]], reports: VisionRequestKind.lensSmudge.reportsDevices, on: appleSilicon))
    }

    @Test func onlyFaceLandmarksNeverReportsDevices() {
        #expect(VisionRequestKind.allCases.filter { !$0.reportsDevices } == [.faceLandmarks])
    }

    @Test func aRequestOnlyForTheNeuralEngineIsUnusableWithoutOne() {
        let smudgeLike: [[ComputeDeviceKind]] = [[.neuralEngine]]
        #expect(usable(smudgeLike, on: appleSilicon))
        #expect(!usable(smudgeLike, on: virtualMachine))
    }

    @Test func oneDeviceInCommonIsEnough() {
        let devices: [[ComputeDeviceKind]] = [[.neuralEngine, .gpu, .cpu]]
        #expect(usable(devices, on: virtualMachine))
        #expect(usable(devices, on: [.cpu]))
    }

    @Test func everyStageNeedsADevice() {
        let twoStages: [[ComputeDeviceKind]] = [[.cpu, .gpu], [.neuralEngine]]
        #expect(usable(twoStages, on: appleSilicon))
        #expect(!usable(twoStages, on: virtualMachine))
    }

    @Test func aStageWithNoDevicesIsUnusable() {
        for reports in [true, false] {
            #expect(!usable([[]], reports: reports, on: appleSilicon))
            #expect(!usable([[.cpu], []], reports: reports, on: appleSilicon))
        }
    }

    @Test func noStagesIsUnusableOnlyForARequestThatReportsDevices() {
        #expect(!usable([], reports: true, on: appleSilicon))
        #expect(usable([], reports: false, on: appleSilicon))
        #expect(usable([], reports: false, on: []))
    }

    @Test func aMachineReportingNoDevicesCanRunNothingThatNeedsOne() {
        #expect(!usable([[.cpu, .gpu, .neuralEngine]], on: []))
    }

    /// Prints what Vision and Core ML report on the machine running the tests, and the decision
    /// taken from it. The CI log shows this for the runner, which cannot be checked here.
    @Test func reportsTheDevicesOnThisMachine() async {
        let lines = ComputeDeviceReport.lines()
        print("Vision devices on this machine:\n  " + lines.joined(separator: "\n  "))
        let available = await VisionAvailability.current()
        #expect(lines.count == VisionRequestKind.allCases.count + 3)
        // The cached answer and a fresh one agree.
        let machine = VisionAvailability.machineDeviceKinds()
        for kind in VisionRequestKind.allCases {
            let fresh = usable(
                Array(VisionAvailability.stageDeviceKinds(of: kind).values), reports: kind.reportsDevices, on: machine
            )
            #expect(available.isUsable(kind) == fresh, "\(kind.diagnosticName)")
        }
    }
}
