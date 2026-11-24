import CullaCore
import CullaUpdates
import Foundation
import Testing

@Suite("Versions")
struct ReleaseVersionTests {
    private func version(_ text: String) -> ReleaseVersion {
        guard let version = ReleaseVersion(text) else {
            Issue.record("“\(text)” did not parse")
            return ReleaseVersion("0")!
        }
        return version
    }

    @Test func dottedNumbersParse() {
        #expect(ReleaseVersion("1")?.components == [1])
        #expect(ReleaseVersion("1.0")?.components == [1, 0])
        #expect(ReleaseVersion("1.0.1")?.components == [1, 0, 1])
        #expect(ReleaseVersion("26.0")?.components == [26, 0])
        #expect(ReleaseVersion("10.200.3000")?.components == [10, 200, 3000])
    }

    @Test(arguments: ["", ".", "1.", ".1", "1..1", "v1.1", "1.1 beta", "1.1b", " 1.1", "1.1 ", "-1", "+1", "1,1",
                      "١.٢", "1.0.0.0.0.0.0.0.0", "99999999999999999999", "1.x", "1_1"])
    func anythingElseIsRejected(_ text: String) {
        #expect(ReleaseVersion(text) == nil)
    }

    @Test func missingComponentsCountAsZero() {
        #expect(version("1.0") == version("1.0.0"))
        #expect(version("1") == version("1.0"))
        #expect(version("1.0").hashValue == version("1.0.0").hashValue)
        #expect(!(version("1.0") < version("1.0.0")))
        #expect(!(version("1.0.0") < version("1.0")))
        #expect(version("1.0") < version("1.0.1"))
        #expect(Set([version("2.0"), version("2"), version("2.0.0")]).count == 1)
    }

    @Test func componentsCompareAsNumbers() {
        #expect(version("1.9") < version("1.10"))
        #expect(version("1.10") > version("1.9"))
        #expect(version("2") > version("1.99.99"))
        #expect(version("1.1") > version("1.0"))
        #expect(version("26.1") > version("26.0.9"))
    }

    @Test func text() {
        #expect(version("1.1").description == "1.1")
        #expect(version("1.0.1").description == "1.0.1")
        #expect(version("26.0").systemDescription == "26")
        #expect(version("26.1.0").systemDescription == "26.1")
        #expect(ReleaseVersion(OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0)).systemDescription == "26.2")
    }
}

@Suite("Update decision")
struct UpdateDecisionTests {
    private let current = ReleaseVersion("1.0")!
    private let system = ReleaseVersion("26.1")!

    private func decide(_ version: String, minimum: String = "26.0", date: String = "2026-12-01",
                        current: ReleaseVersion? = nil, system: ReleaseVersion? = nil) throws -> UpdateDecision {
        try UpdateDecision.make(current: current ?? self.current, system: system ?? self.system,
                                document: UpdateDocument(version: version, minimumSystem: minimum, date: date))
    }

    @Test func aNewerVersionIsAvailable() throws {
        #expect(try decide("1.1") == .available(ReleaseVersion("1.1")!))
        #expect(try decide("1.0.1") == .available(ReleaseVersion("1.0.1")!))
        #expect(try decide("2") == .available(ReleaseVersion("2")!))
    }

    @Test func theSameOrAnOlderVersionIsUpToDate() throws {
        #expect(try decide("1.0") == .upToDate)
        #expect(try decide("1.0.0") == .upToDate)
        #expect(try decide("1") == .upToDate)
        #expect(try decide("0.9") == .upToDate)
        #expect(try decide("1.1", current: ReleaseVersion("1.2")!) == .upToDate)
    }

    @Test func nothingPublishedIsUpToDate() throws {
        #expect(try decide("1.1", date: "") == .upToDate)
        #expect(try decide("", date: "2026-12-01") == .upToDate)
        #expect(try decide("", minimum: "", date: "") == .upToDate)
        // Not even an invalid version matters while nothing is published.
        #expect(try decide("soon", date: "") == .upToDate)
    }

    @Test func aNewerMacOSIsNamed() throws {
        #expect(try decide("1.1", minimum: "27.0") == .needsNewerSystem(version: ReleaseVersion("1.1")!, minimumSystem: ReleaseVersion("27.0")!))
        #expect(try decide("1.1", minimum: "26.2") == .needsNewerSystem(version: ReleaseVersion("1.1")!, minimumSystem: ReleaseVersion("26.2")!))
        // Exactly the minimum, or the minimum with a missing zero, is enough.
        #expect(try decide("1.1", minimum: "26.1") == .available(ReleaseVersion("1.1")!))
        #expect(try decide("1.1", minimum: "26.1.0") == .available(ReleaseVersion("1.1")!))
        #expect(try decide("1.1", minimum: "26.1", system: ReleaseVersion("26.1.0")!) == .available(ReleaseVersion("1.1")!))
        // An older version needing a newer macOS is still up to date.
        #expect(try decide("1.0", minimum: "27.0") == .upToDate)
    }

    @Test func anEmptyMinimumStatesNoRequirement() throws {
        #expect(try decide("1.1", minimum: "") == .available(ReleaseVersion("1.1")!))
    }

    @Test(arguments: [("1.1 beta", "26.0"), ("v1.1", "26.0"), ("1.1", "Tahoe"), ("1.1", "26.x"), ("one", "26.0")])
    func versionsThatAreNotNumbersAreRefused(_ version: String, _ minimum: String) {
        #expect(throws: UpdateCheckError.invalidDocument) { try decide(version, minimum: minimum) }
    }

    @Test func whitespaceAroundAVersionIsTrimmed() throws {
        #expect(try decide(" 1.1 ", minimum: " 26.0") == .available(ReleaseVersion("1.1")!))
    }

    @Test func newerVersion() throws {
        #expect(try decide("1.1").newerVersion == ReleaseVersion("1.1"))
        #expect(try decide("1.1", minimum: "27").newerVersion == ReleaseVersion("1.1"))
        #expect(try decide("1.0").newerVersion == nil)
    }
}

@Suite("Update document")
struct UpdateDocumentTests {
    @Test func decodesTheSitesFile() throws {
        let data = Data(#"{ "version": "1.1", "minimumSystem": "26.0", "date": "2026-12-01" }"#.utf8)
        #expect(try UpdateDocument.decode(data) == UpdateDocument(version: "1.1", minimumSystem: "26.0", date: "2026-12-01"))
    }

    @Test func unknownKeysAreIgnoredAndMissingOnesAreEmpty() throws {
        let data = Data(#"{ "version": "1.1", "date": "2026-12-01", "notes": {"en": "x"}, "size": 12 }"#.utf8)
        let document = try UpdateDocument.decode(data)
        #expect(document == UpdateDocument(version: "1.1", minimumSystem: "", date: "2026-12-01"))
        #expect(document.isPublished)
    }

    @Test func emptyDateIsNotPublished() throws {
        let data = Data(#"{ "version": "1.0", "minimumSystem": "26.0", "date": "" }"#.utf8)
        #expect(try !UpdateDocument.decode(data).isPublished)
    }

    @Test(arguments: ["", "[]", "null", "1.1", #"{"version": 1.1}"#, "<html></html>", #"{"version": "1.1""#])
    func otherContentIsInvalid(_ text: String) {
        #expect(throws: UpdateCheckError.invalidDocument) { try UpdateDocument.decode(Data(text.utf8)) }
    }
}

@Suite("Update schedule")
struct UpdateScheduleTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func dueOnceADayFromTheLastAttempt() {
        #expect(UpdateSchedule.isAutomaticCheckDue(enabled: true, lastAttempt: nil, now: now))
        #expect(!UpdateSchedule.isAutomaticCheckDue(enabled: true, lastAttempt: now, now: now))
        #expect(!UpdateSchedule.isAutomaticCheckDue(enabled: true, lastAttempt: now.addingTimeInterval(-23 * 3600), now: now))
        #expect(!UpdateSchedule.isAutomaticCheckDue(enabled: true, lastAttempt: now.addingTimeInterval(-86_399), now: now))
        #expect(UpdateSchedule.isAutomaticCheckDue(enabled: true, lastAttempt: now.addingTimeInterval(-86_400), now: now))
        #expect(UpdateSchedule.isAutomaticCheckDue(enabled: true, lastAttempt: now.addingTimeInterval(-30 * 86_400), now: now))
    }

    @Test func neverWhenSwitchedOff() {
        #expect(!UpdateSchedule.isAutomaticCheckDue(enabled: false, lastAttempt: nil, now: now))
        #expect(!UpdateSchedule.isAutomaticCheckDue(enabled: false, lastAttempt: now.addingTimeInterval(-10 * 86_400), now: now))
    }

    @Test func aClockSetBackDoesNotHoldChecksOff() {
        #expect(UpdateSchedule.isAutomaticCheckDue(enabled: true, lastAttempt: now.addingTimeInterval(3600), now: now))
    }

    @Test func automaticNoticesLeaveOutSkippedVersionsAndOtherOutcomes() {
        let v11 = ReleaseVersion("1.1")!
        #expect(UpdateSchedule.automaticNotice(for: .available(v11), skipped: nil) == v11)
        #expect(UpdateSchedule.automaticNotice(for: .available(v11), skipped: v11) == nil)
        #expect(UpdateSchedule.automaticNotice(for: .available(v11), skipped: ReleaseVersion("1.1.0")) == nil)
        // A version newer than the skipped one is shown again.
        #expect(UpdateSchedule.automaticNotice(for: .available(ReleaseVersion("1.2")!), skipped: v11) == ReleaseVersion("1.2"))
        #expect(UpdateSchedule.automaticNotice(for: .upToDate, skipped: nil) == nil)
        #expect(UpdateSchedule.automaticNotice(for: .needsNewerSystem(version: v11, minimumSystem: ReleaseVersion("27")!), skipped: nil) == nil)
    }
}

@Suite("Update links")
struct UpdateLinksTests {
    @Test func linksAreBuiltIn() {
        #expect(UpdateLinks.download.absoluteString == "https://cullaapp.com/download")
        #expect(UpdateLinks.releaseNotes(.english).absoluteString == "https://cullaapp.com/en/release-notes/")
        #expect(UpdateLinks.releaseNotes(.russian).absoluteString == "https://cullaapp.com/ru/release-notes/")
        #expect(UpdateLinks.releaseNotes(.turkmen).absoluteString == "https://cullaapp.com/tk/release-notes/")
    }
}
