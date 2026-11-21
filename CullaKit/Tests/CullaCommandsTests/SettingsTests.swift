import CullaAnalysis
import CullaCommands
import CullaCore
import CullaSession
import Foundation
import Testing

@Suite("Settings: controls, presets and keys")
struct SettingsTests {
    // MARK: Controls

    @Test func everyKeyHasOneControlAndEveryPaneHasItsRows() {
        let inPanes = TuningPane.allCases.flatMap(\.controls).map(\.key)
        // Every value is in exactly one pane of Settings.
        #expect(Set(inPanes) == Set(TuningKey.allCases))
        #expect(inPanes.count == TuningKey.allCases.count)
        // The panel's controls are the very same descriptions.
        for group in GroupID.allCases {
            for control in TuningControl.controls(for: group) {
                #expect(control == TuningControl.control(for: control.key))
            }
        }
        // The Design doc's ranges.
        #expect(TuningControl.control(for: .minFaceFraction).range == 0.01...0.20)
        #expect(TuningControl.control(for: .backgroundFaceRatio).range == 0.20...0.80)
        #expect(TuningControl.control(for: .stackGapSeconds).range == 1...60)
        #expect(TuningControl.control(for: .minStackSize).range == 2...5)
        #expect(TuningControl.control(for: .clippedHighlightsAbove).range == 0.05...0.90)
        #expect(TuningControl.control(for: .lowAestheticsBelow).range == -1...1)
        #expect(TuningControl.control(for: .groupPhotoRule).choices == ["Any main face", "Most faces", "All faces"])
        #expect(TuningControl.control(for: .eyesClosedCertainBelow).isProvisional)
        #expect(TuningControl.control(for: .bestPickSharpnessMargin).isProvisional)
    }

    @Test func balancedValuesAreOnTheirSteps() {
        for key in TuningKey.allCases {
            let control = TuningControl.control(for: key)
            #expect(control.snapped(control.balancedValue) == control.balancedValue, "\(key)")
            #expect(control.range.contains(control.balancedValue) || !control.isSlider, "\(key)")
        }
    }

    @Test func sensitivityIsFiftyAtBalancedAndSpansTheRange() {
        let eyes = TuningControl.control(for: .eyesClosedBelow)
        #expect(eyes.sensitivity(of: 0.26) == 50)
        #expect(eyes.value(atSensitivity: 50) == 0.26)
        #expect(eyes.value(atSensitivity: 0) == 0.05)
        #expect(eyes.value(atSensitivity: 100) == 0.50)
        #expect(eyes.shownValue(0.26) == "50")
        #expect(eyes.valueNote(0.26) == "Flags eye openness below 0.26")
        let blur = TuningControl.control(for: .blurryBelow)
        #expect(blur.valueNote(25) == "Flags sharpness below 25")
        #expect(blur.value(atSensitivity: 75) == 53)
        let similarity = TuningControl.control(for: .stackDistance)
        #expect(similarity.valueNote(0.6) == "Joins frames up to a distance of 0.60")
        #expect(similarity.value(atSensitivity: 100) == 1.0)
        // Every value a slider can reach reads back as the sensitivity it came from, give or take
        // the value's step.
        for s in stride(from: 0.0, through: 100, by: 1) {
            let value = eyes.value(atSensitivity: s)
            #expect(abs(eyes.value(atSensitivity: eyes.sensitivity(of: value)) - value) < 1e-9)
        }
        #expect(TuningControl.control(for: .groupPhotoRule).format(1) == "Most faces")
        #expect(TuningControl.control(for: .minStackSize).format(3) == "3")
    }

    @Test func switchesAndDependentValuesReadAsOff() {
        var tuning = Tuning()
        let smudge = TuningControl.control(for: .lensSmudgeAbove)
        #expect(!smudge.isOff(in: tuning))
        tuning.flagLensSmudge = false
        #expect(smudge.isOff(in: tuning))
        #expect(TuningControl.control(for: .flagLensSmudge).isOff(in: tuning))
    }

    @Test func aPaneResetsOnlyItsOwnValues() {
        var tuning = Tuning()
        tuning.blurryBelow = 40
        tuning.minFaceFraction = 0.1
        tuning.groupPhotoRule = .allFaces
        let reset = TuningPane.eyes.resetting(tuning)
        #expect(reset.minFaceFraction == 0.04 && reset.groupPhotoRule == .anyMainFace)
        #expect(reset.blurryBelow == 40)
        // A group's reset can take another tuning's values, such as the user's default.
        var defaults = Tuning()
        defaults.blurryBelow = 30
        #expect(TuningControl.resetting(.blurry, in: tuning, to: defaults).blurryBelow == 30)
    }

    // MARK: Presets

    @Test func balancedIsExactlyTodaysDefaults() {
        #expect(TuningPreset.balanced.applied(to: Tuning()) == Tuning())
        #expect(TuningPreset.matching(Tuning()) == .balanced)
        var changed = Tuning()
        changed.flagTiltedHorizon = true
        changed.groupPhotoRule = .allFaces
        // Switches and choices are not part of a preset.
        #expect(TuningPreset.matching(changed) == .balanced)
    }

    @Test func lenientAndStrictFollowTheRule() {
        let lenient = TuningPreset.lenient.applied(to: Tuning())
        let strict = TuningPreset.strict.applied(to: Tuning())
        // A quarter of the way from Balanced to the end that flags fewer, or more, then snapped.
        #expect(lenient.blurryBelow == 19 && strict.blurryBelow == 39)
        #expect(lenient.eyesClosedBelow == 0.21 && strict.eyesClosedBelow == 0.32)
        #expect(lenient.clippedHighlightsAbove == 0.45 && strict.clippedHighlightsAbove == 0.24)
        #expect(lenient.stackGapSeconds == 8 && strict.stackGapSeconds == 23)
        #expect(lenient.minStackSize == 3 && strict.minStackSize == 2)
        // Margins and switches are left alone.
        #expect(lenient.bestPickSharpnessMargin == Tuning().bestPickSharpnessMargin)
        #expect(strict.flagTiltedHorizon == Tuning().flagTiltedHorizon)
        for control in TuningPreset.controls {
            let l = control.key.value(in: lenient), b = control.balancedValue, s = control.key.value(in: strict)
            #expect(control.range.contains(l) && control.range.contains(s), "\(control.key)")
            // Lenient never flags more than Balanced, Strict never fewer.
            switch control.direction {
            case .higherFlagsMore: #expect(l <= b && b <= s, "\(control.key)")
            case .lowerFlagsMore: #expect(l >= b && b >= s, "\(control.key)")
            case .none: Issue.record("\(control.key) has no direction")
            }
        }
        #expect(TuningPreset.matching(lenient) == .lenient)
        #expect(TuningPreset.matching(strict) == .strict)
        var custom = strict
        custom.blurryBelow = 38
        #expect(TuningPreset.matching(custom) == nil)
    }

    @Test func presetsChangeWhatIsFlagged() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let items = [8.0, 17, 22, 30, 45].enumerated().map { index, blur in
            var scores = PhotoScores(analysedWidth: 100, analysedHeight: 100)
            scores.subjectSharpness = blur
            return PhotoItem(
                file: PhotoFile(id: "p\(index)", url: URL(fileURLWithPath: "/s/p\(index)"), fileSize: 10, modificationDate: start, isRAW: false),
                metadata: PhotoMetadata(captureDate: start.addingTimeInterval(Double(index) * 100)), scores: scores
            )
        }
        var state = SessionState(photos: items)
        #expect(TuningCounts(state).count(.flag(.blurry)) == 3)
        state.tuning = TuningPreset.lenient.applied(to: state.tuning)
        #expect(TuningCounts(state).count(.flag(.blurry)) == 2)
        state.tuning = TuningPreset.strict.applied(to: state.tuning)
        #expect(TuningCounts(state).count(.flag(.blurry)) == 4)
    }

    // MARK: Keys

    @Test func remappingMovesAChordAndKeepsTheOrder() {
        var keys = KeyBindings.defaults
        #expect(keys.conflict(assigning: KeyChord("u"), to: .keep) == .command(KeyChord("u"), .clearDecision))
        #expect(keys.conflict(assigning: KeyChord("k"), to: .keep) == nil)
        #expect(keys.conflict(assigning: KeyChord("p"), to: .keep) == nil)
        keys.setChords([KeyChord("k")], for: .keep)
        #expect(keys.command(for: KeyChord("k")) == .keep)
        #expect(keys.command(for: KeyChord("p")) == nil)
        #expect(keys.bindings.first?.command == .keep)
        // Taking a chord from another command leaves that one without it.
        keys.setChords([KeyChord("u")], for: .reject)
        #expect(keys.command(for: KeyChord("u")) == .reject)
        #expect(keys.chords(for: .clearDecision).isEmpty)
        #expect(keys.conflicts.isEmpty)
        keys.reset(.clearDecision)
        #expect(keys.command(for: KeyChord("u")) == .clearDecision)
        #expect(keys.chords(for: .reject).isEmpty)
        keys.reset(.keep)
        keys.reset(.reject)
        #expect(keys == KeyBindings.defaults)
    }

    @Test func replacingOneChordKeepsTheOthers() {
        var keys = KeyBindings.defaults
        #expect(keys.chords(for: .largerThumbnails) == [KeyChord("=", .command), KeyChord("+", .command)])
        // Changing ⌘+ keeps ⌘=, in its place.
        keys.replace(KeyChord("+", .command), with: KeyChord("l", .command), for: .largerThumbnails)
        #expect(keys.chords(for: .largerThumbnails) == [KeyChord("=", .command), KeyChord("l", .command)])
        #expect(keys.command(for: KeyChord("+", .command)) == nil)
        // Changing the first of C and ⌘3 keeps ⌘3 and makes the new key the one menus show.
        keys.replace(KeyChord("c"), with: KeyChord("v"), for: .showCompare)
        #expect(keys.chords(for: .showCompare) == [KeyChord("v"), KeyChord("3", .command)])
        #expect(keys.primaryChord(for: .showCompare) == KeyChord("v"))
        // Adding a key: nil, or a chord the command does not have.
        keys.replace(nil, with: KeyChord("k"), for: .keep)
        #expect(keys.chords(for: .keep) == [KeyChord("p"), KeyChord("k")])
        // Taking a chord from another command removes only that chord there.
        keys.replace(nil, with: KeyChord("3", .command), for: .showGrid)
        #expect(keys.chords(for: .showGrid) == [KeyChord("1", .command), KeyChord("3", .command)])
        #expect(keys.chords(for: .showCompare) == [KeyChord("v")])
        // Replacing with a chord the command already has does not list it twice.
        keys.replace(KeyChord("k"), with: KeyChord("p"), for: .keep)
        #expect(keys.chords(for: .keep) == [KeyChord("p")])
        keys.remove(KeyChord("=", .command), from: .largerThumbnails)
        #expect(keys.chords(for: .largerThumbnails) == [KeyChord("l", .command)])
        #expect(keys.conflicts.isEmpty)
    }

    @Test func reservedChordsAndSavedClashesAreReported() {
        let keys = KeyBindings.defaults
        let quit = KeyChord("q", .command)
        #expect(keys.conflict(assigning: quit, to: .keep) == .reserved(quit, "Quit Culla"))
        #expect(KeyConflict.reserved(quit, "Quit Culla").message == "⌘Q is kept for Quit Culla and cannot be changed.")
        #expect(KeyConflict.command(KeyChord("u"), .clearDecision).message == "U is used by Clear Decision.")
        #expect(keys.conflicts.isEmpty)
        // A saved map from an older version that lists a chord twice.
        let clashing = KeyBindings([KeyBinding(KeyChord("p"), .keep), KeyBinding(KeyChord("p"), .reject), KeyBinding(quit, .undo)])
        #expect(clashing.conflicts == [.command(KeyChord("p"), .keep), .reserved(quit, "Quit Culla")])
        #expect(KeyBindings.isRecorderControl(KeyChord(.escape)))
        #expect(!KeyBindings.isRecorderControl(KeyChord(.escape, .shift)))
    }

    @Test func everyCommandHasASettingsNameAndSection() {
        for command in Command.allCases {
            #expect(!command.settingsTitle.isEmpty && !command.settingsTitle.contains("…"))
            #expect(Command.settingsSections.contains(command.settingsSection))
        }
    }
}
