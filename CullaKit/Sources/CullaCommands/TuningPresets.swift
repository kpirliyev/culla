import CullaAnalysis
import Foundation

/// Lenient, Balanced and Strict: one choice that sets every detection slider at once.
///
/// **Balanced** is exactly today's defaults, `Tuning()`.
///
/// **Lenient and Strict are derived from Balanced by one rule**, and are provisional until the
/// detection tuning of milestone M7: every slider that trades fewer flags for more (its
/// `TuningControl.direction` is not `none`) moves `fraction` (a quarter) of the way from its
/// Balanced value to the end of its range that flags fewer photos (Lenient) or more photos
/// (Strict), then snaps to the slider's step. "More" also means more frames joined into stacks
/// and more files joined into duplicate sets. Switches, choices and the best-pick margins are
/// not sliders of that kind and keep whatever they are set to, so a preset never turns a kind
/// of flag on or off.
///
/// A tuning matches a preset when every such slider has the preset's value; otherwise it is
/// Custom (`TuningPreset.matching(_:)` returns nil).
public enum TuningPreset: String, CaseIterable, Sendable, Hashable, Codable {
    case lenient
    case balanced
    case strict

    /// How far Lenient and Strict move each slider from Balanced towards the end of its range.
    public static let fraction = 0.25

    public var title: String {
        switch self {
        case .lenient: localized("Lenient")
        case .balanced: localized("Balanced")
        case .strict: localized("Strict")
        }
    }

    /// One line on what the preset does.
    public var summary: String {
        switch self {
        case .lenient: localized("Flags fewer photos: only clear problems.")
        case .balanced: localized("The defaults, chosen by eye on a real shoot.")
        case .strict: localized("Flags more photos: anything doubtful.")
        }
    }

    /// The sliders a preset sets.
    public static let controls: [TuningControl] = TuningKey.allCases
        .map(TuningControl.control(for:))
        .filter { $0.isSlider && $0.direction != .none }

    /// The preset's value for a slider.
    public func value(for control: TuningControl) -> Double {
        let balanced = control.balancedValue
        let towardsMore: Bool
        switch self {
        case .balanced: return balanced
        case .lenient: towardsMore = false
        case .strict: towardsMore = true
        }
        let higher = (control.direction == .higherFlagsMore) == towardsMore
        let end = higher ? control.range.upperBound : control.range.lowerBound
        return control.snapped(balanced + Self.fraction * (end - balanced))
    }

    /// A tuning with every preset slider set to this preset's value; everything else as given.
    public func applied(to tuning: Tuning) -> Tuning {
        var result = tuning
        for control in Self.controls { control.key.set(value(for: control), in: &result) }
        return result
    }

    /// The preset whose values the tuning's sliders have, or nil for Custom.
    public static func matching(_ tuning: Tuning) -> TuningPreset? {
        allCases.first { preset in
            controls.allSatisfy { abs($0.key.value(in: tuning) - preset.value(for: $0)) < 1e-9 }
        }
    }
}
