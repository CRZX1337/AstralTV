//
//  SettingsChoicePicker.swift
//  Astral
//
//  Settings redesign Phase 3, item 3: ONE "pick one of these" control.
//
//  Before Phase 3 the same question was asked five different ways:
//  a ForEach of check-marked Buttons inlined into the page (nine of
//  them), a `.segmented` Picker (Appearance Mode, Tile Corners), a
//  `Menu` picker (the DVR buffers), a native menu Picker (DVR
//  destination), and on tvOS a wall of `TVSettingsSelectionRow`s. A
//  page with three of those inline lists on it was mostly other
//  people's options.
//
//  The Phase 3 shape, matching Android:
//
//    iPhone / iPad - the picker is ONE row: title on the left, the
//      current value trailing, chevron. It pushes a single-choice page
//      (a radio list with a check on the selected row) carrying the
//      same title and the caller's footer.
//    tvOS - revised 2026-09-19 (Logan: "a lot of submenus seem very
//      long and could be condensed"). MORE than three options collapse
//      to the same single row and push a tvOS choice page; two or three
//      options still read as a compact group and stay INLINE with a
//      check, where a push would only cost an extra Back press.
//
//  Selection rows never ring or fill in white: the check is the
//  selection, the accent ring is the focus (Logan's standing rule).
//

import SwiftUI

// MARK: - Option model

/// One choice offered by `SettingsChoicePicker`.
struct SettingsChoice<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    /// Second line, on the choice page and on tvOS. Usually an example
    /// ("7:30 PM") or a one-line consequence.
    var subtitle: String? = nil
    /// Leading SF Symbol. Optional; a list where only some rows have an
    /// icon looks broken, so pass it for all or for none.
    var icon: String? = nil
    /// Leading color dot instead of an icon: the Color Theme list shows
    /// each theme's accent this way.
    var swatch: Color? = nil

    var id: Value { value }

    init(_ value: Value, _ title: String, subtitle: String? = nil,
         icon: String? = nil, swatch: Color? = nil) {
        self.value = value
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.swatch = swatch
    }
}

// MARK: - Picker

struct SettingsChoicePicker<Value: Hashable>: View {
    let title: String
    let options: [SettingsChoice<Value>]
    @Binding var selection: Value
    /// Explanatory copy. On iOS it becomes the pushed page's footer; on
    /// tvOS it renders under the inline rows.
    var footer: String? = nil
    /// Leading SF Symbol for the ROW (iOS) - not for the options.
    var icon: String? = nil
    var iconColor: Color = .accentPrimary
    /// Runs after `selection` is written. Pages that have to push
    /// preferences or save a model pass it here rather than using
    /// `.onChange`, so the write and its side effect stay together.
    var onChange: ((Value) -> Void)? = nil
    /// iOS: an extra card shown first on the pushed page (e.g. toggles
    /// that scope where the choice applies). Ignored on tvOS.
    var leadingSection: AnyView? = nil

    @ObservedObject private var theme = ThemeManager.shared

    init(_ title: String,
         options: [SettingsChoice<Value>],
         selection: Binding<Value>,
         footer: String? = nil,
         icon: String? = nil,
         iconColor: Color = .accentPrimary,
         leadingSection: AnyView? = nil,
         onChange: ((Value) -> Void)? = nil) {
        self.leadingSection = leadingSection
        self.title = title
        self.options = options
        self._selection = selection
        self.footer = footer
        self.icon = icon
        self.iconColor = iconColor
        self.onChange = onChange
    }

    /// The label shown trailing on the collapsed row. Falls back to an
    /// em-dash-free placeholder when the stored value is not one of the
    /// offered options (a stale preference, or a group that went away).
    private var currentTitle: String {
        options.first(where: { $0.value == selection })?.title ?? "Not set"
    }

    private func select(_ value: Value) {
        selection = value
        onChange?(value)
    }

    var body: some View {
        iosRow
    }

    // MARK: iOS / iPadOS - collapsed row that pushes a choice page

    private var iosRow: some View {
        NavigationLink {
            SettingsChoicePage(title: title,
                               options: options,
                               selection: $selection,
                               footer: footer,
                               onChange: onChange,
                               leadingSection: leadingSection)
        } label: {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .scaledFont(.system(size: 15, weight: .semibold))
                        .foregroundColor(iconColor)
                        .frame(width: 22)
                }
                Text(title)
                    .scaledFont(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Spacer(minLength: 12)
                Text(currentTitle)
                    .scaledFont(.bodyMedium)
                    .foregroundColor(Color.contrastText(.textSecondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    // MARK: tvOS - collapsed row that opens a pop-up option sheet

}


// MARK: - Pushed choice page (iOS / iPadOS)

/// The single-choice page a `SettingsChoicePicker` row pushes. A radio
/// list: one row per option, a check on the selected one, and the
/// caller's footer underneath. Choosing a row writes the value and pops,
/// which is the iOS convention and matches Android's single-choice
/// dialog closing on selection.
struct SettingsChoicePage<Value: Hashable>: View {
    let title: String
    let options: [SettingsChoice<Value>]
    @Binding var selection: Value
    var footer: String? = nil
    var onChange: ((Value) -> Void)? = nil
    var leadingSection: AnyView? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        List {
            if let leadingSection {
                Section { leadingSection }
            }
            Section {
                ForEach(options) { option in
                    Button {
                        selection = option.value
                        onChange?(option.value)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            if let icon = option.icon {
                                Image(systemName: icon)
                                    .scaledFont(.system(size: 15, weight: .semibold))
                                    .foregroundColor(theme.accent)
                                    .frame(width: 22)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .scaledFont(.bodyMedium)
                                    .foregroundColor(.textPrimary)
                                if let subtitle = option.subtitle {
                                    Text(subtitle)
                                        .scaledFont(.labelSmall.subtext())
                                        .foregroundColor(Color.contrastText(.textTertiary))
                                }
                            }
                            Spacer(minLength: 12)
                            if option.value == selection {
                                Image(systemName: "checkmark")
                                    .scaledFont(.system(size: 14, weight: .semibold))
                                    .foregroundColor(theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .listRowBackground(Color.cardBackground)
                }
            } footer: {
                if let footer, !footer.isEmpty {
                    Text(footer)
                        .scaledFont(.labelSmall.subtext())
                        .foregroundColor(Color.contrastText(.textTertiary))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        // Phase 3 (Logan 2026-09-18): floating tab bar parity -
        // content runs under the bar, the bar tucks away on scroll,
        // and the last row clears it.
        .settingsPhoneTabBarChrome()
        .background(Color.appBackground)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
