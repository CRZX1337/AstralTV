//
//  SettingsControls.swift
//  Astral
//
//  Settings redesign Phase 1 (regroup): the shared Settings controls that
//  used to live at the bottom of AppBehaviorsSettingsView.swift. That file
//  became PlayerSettingsView.swift, but TVSteppedSegmentStyle is used by
//  Appearance too, so the controls move to Components/ where every page
//  can reach them. Bodies are unchanged.
//

import SwiftUI



// MARK: - Stream Buffer Slider (reusable, platform-split)

/// Reusable "Stream Buffer" control for Settings → App Behaviors.
///
/// Encapsulates the per-platform slider so both `iOSBody` and
/// `tvOSBody` can drop in `StreamBufferSlider(value:)`:
///   - iOS / iPadOS: a native `Slider` (0...5, step 0.5) with a
///     right-aligned "Off" / "X.Xs" value label, modeled on the
///     networkTimeout row in `SettingsView`.
///   - tvOS: a custom focusable track adjusted with the Siri Remote.
///     Left/right decrement/increment by 0.5 (clamped 0...5);
///     up/down are passed through so the focus engine still navigates
///     to adjacent rows.
struct StreamBufferSlider: View {
    @Environment(\.astralTextScale) private var textScale
    @Binding var value: Double
    @ObservedObject private var theme = ThemeManager.shared

    private static let range: ClosedRange<Double> = 0...5
    private static let step: Double = 0.5

    /// "Off" at 0, otherwise "X.Xs".
    private var valueLabel: String {
        value <= 0 ? "Off" : String(format: "%.1fs", value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stream Buffer")
                    .scaledFont(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Spacer()
                Text(valueLabel)
                    .scaledFont(.labelSmall.subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
            }
            Slider(value: $value, in: Self.range, step: Self.step)
                .tint(theme.accent)
        }
    }
}

