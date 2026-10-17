import SwiftUI

// MARK: - Appearance Settings View (full replacement for the inline one in SettingsView)
struct AppearanceSettingsView: View {
    @ObservedObject private var theme = ThemeManager.shared
    // Phase 1 regroup (2026-09-17): Appearance is now theme, text and
    // clock only. Channel List / Guide Presentation, Category Colors, the
    // palette editor and the Guide + Live TV List scale sliders moved to
    // Live TV; the Movies & Series slider moved to Movies & TV Shows.
    /// App-wide text multiplier (Settings > Appearance > Text Size).
    /// Read by every `.scaledFont` call site via the root environment;
    /// synced across devices. See `TextScale` in Typography.swift.
    @AppStorage(TextScale.key) private var textScale: Double = TextScale.defaultValue
    /// Secondary-text multiplier (Settings > Appearance > Subtext Size),
    /// stacked on Text Size for fonts marked `.subtext()`. Synced.
    @AppStorage(SubtextScale.key) private var subtextScale: Double = SubtextScale.defaultValue

    @AppStorage(ClockFormat.defaultsKey) private var timeFormat = "system"

    /// Measured width of this page, used to pick the Color Theme layout.
    /// The two-column tile grid needs real room: in a narrow Slide Over
    /// (about 400 pt) the tiles are so narrow that theme names break
    /// mid-word ("AstralT/V", "Monochro/me"), so the page falls back to
    /// the stacked single-column rows. Measured, not inferred from the
    /// size class, because an iPad Slide Over and an iPad Split View pane
    /// report the same compact class at very different widths.
    ///
    /// Written only from onAppear/onChange (never during body
    /// evaluation), and it feeds a layout CHOICE rather than a sibling's
    /// padding, so there is no measure-then-resize loop.
    @State private var pageWidth: CGFloat = 0
    /// Below this the theme tiles cannot hold their longest name.
    private static let themeGridMinWidth: CGFloat = 500
    private var useThemeTileGrid: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && pageWidth >= Self.themeGridMinWidth
    }

    private static let timeFormatOptions: [(value: String, label: String, subtitle: String)] = [
        ("system", "System", "Follow the device's clock setting."),
        ("12", "12-hour", "7:30 PM"),
        ("24", "24-hour", "19:30"),
    ]

    // MARK: - Phase 3 shared option lists
    // One list per question, used by both platforms, so iOS and tvOS
    // cannot drift apart on titles, subtitles or order again.

    private static var timeFormatChoices: [SettingsChoice<String>] {
        timeFormatOptions.map { SettingsChoice($0.value, $0.label, subtitle: $0.subtitle, icon: "clock") }
    }

    private static let timeFormatFootnote = "System follows your device's clock setting. Applies to the Guide, program info, search, and recordings."

    private var appearanceModeChoices: [SettingsChoice<AppearanceMode>] {
        AppearanceMode.allCases.map { mode in
            SettingsChoice(mode, mode.displayName,
                           subtitle: appearanceModeSubtitle(mode),
                           icon: mode == .dark ? "moon.fill"
                                 : mode == .light ? "sun.max.fill"
                                 : "circle.lefthalf.filled")
        }
    }

    /// Writes through `ThemeManager` (never a raw property assignment)
    /// and keeps the immediate preference push the segmented control
    /// used to do from `.onChange`.
    private var appearanceModeSelection: Binding<AppearanceMode> {
        Binding(
            get: { theme.appearanceMode },
            set: { theme.setAppearanceMode($0) }
        )
    }

    private var liquidGlassChoices: [SettingsChoice<LiquidGlassStyle>] {
        LiquidGlassStyle.allCases.map {
            SettingsChoice($0, $0.displayName, subtitle: liquidGlassDescription($0))
        }
    }

    private var liquidGlassSelection: Binding<LiquidGlassStyle> {
        Binding(
            get: { theme.liquidGlassStyle },
            set: { theme.setLiquidGlassStyle($0) }
        )
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            iOSBody
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
    }

    // MARK: - tvOS Body
    // Every row uses one of the shared TVSettings* components so focus
    // highlight (accent-tinted card + stroke + scale bump) matches the
    // rest of the tvOS UI uniformly. Previously rows used only
    // TVNoHighlightButtonStyle without the card background, so focus
    // was almost invisible inside a section.

    /// One-line palette description per theme, matching the Android
    /// theme picker so the copy reads identically across platforms.
    private func themeSubtitle(_ t: AppTheme) -> String {
        switch t {
        case .astral:      return "Cyan on deep navy (default)"
        case .midnight:   return "Cool blue on near-black"
        case .sunset:     return "Warm orange on near-black"
        case .forest:     return "Green on near-black"
        case .lavender:   return "Purple on near-black"
        case .monochrome: return "Grayscale on near-black"
        case .light:      return "Neutral teal-gray that reads on white"
        }
    }

    /// One-line description per appearance mode, shown under the
    /// Dark / Light / System selection rows on tvOS.
    private func appearanceModeSubtitle(_ mode: AppearanceMode) -> String {
        switch mode {
        case .dark:   return "Dark surfaces (default)"
        case .light:  return "Light surfaces"
        case .system: return "Follow the system setting"
        }
    }

    // MARK: - iOS Body
    private var iOSBody: some View {
        List {
                // MARK: Color Theme
                Section {
                    // Phase 5 (plan A2 density): a wide iPad page shows the
                    // themes as a two-column tile grid; iPhone and any
                    // narrow page (Slide Over) keep the stacked rows.
                    if useThemeTileGrid {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                            GridItem(.flexible(), spacing: 10)],
                                  spacing: 10) {
                            ForEach(AppTheme.allCases, id: \.self) { t in
                                Button {
                                    theme.setTheme(t)
                                } label: {
                                    themeRowLabel(t)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 12)
                                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color.cardBackground))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        // Keep outer tiles clear of the List's section
                        // corner mask, which otherwise re-rounds the last
                        // row's corner tiles (Logan's report: Light tile
                        // corners uneven).
                        .padding(6)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    } else {
                        ForEach(AppTheme.allCases, id: \.self) { t in
                            Button {
                                theme.setTheme(t)
                            } label: {
                                themeRowLabel(t)
                            }
                            .listRowBackground(Color.cardBackground)
                            // Dividers start at the row's title text, past
                            // the swatch (22 pt swatch + 14 pt spacing).
                            .alignmentGuide(.listRowSeparatorLeading) { _ in
                                Self.themeRowSeparatorInset
                            }
                        }
                    }

                } header: {
                    Text("Color Theme").sectionHeaderStyle()
                } footer: {
                    Text("Colors used throughout the app.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                }
                .listSectionSeparator(.hidden)

                // MARK: Appearance (surface luminance)
                // Phase 3 (Logan 2026-09-18): the mode picker and the
                // accent rows used to ride inside the Color Theme card
                // (iPhone) or share one unheaded card (iPad). Each card
                // now states what it is, on both idioms.
                Section {
                    appearanceModeRow
                    trueBlackRow
                } header: {
                    Text("Light and Dark Mode").sectionHeaderStyle()
                } footer: {
                    Text("Light or dark surfaces, independent of the color theme.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                }
                .listSectionSeparator(.hidden)

                // MARK: Accent
                Section {
                    accentRows
                } header: {
                    Text("Accent").sectionHeaderStyle()
                } footer: {
                    Text("Override the theme's accent color with one of your own.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                }
                .listSectionSeparator(.hidden)

                // MARK: Effects
                Section {
                    // Phase 3: four inline check rows collapse to one row
                    // that pushes the choice page, carrying the footnote.
                    SettingsChoicePicker("Glass Effect",
                                         options: liquidGlassChoices,
                                         selection: liquidGlassSelection,
                                         footer: liquidGlassFootnote)
                        .listRowBackground(Color.cardBackground)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                } header: {
                    Text("Effects").sectionHeaderStyle()
                }
                .listSectionSeparator(.hidden)

                // MARK: Preview Swatch
                Section {
                    swatchPreview
                        .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Preview").sectionHeaderStyle()
                }
                .listSectionSeparator(.hidden)

                // MARK: Text Size (app-wide text multiplier)
                Section {
                    textSizeRow_iOS
                } header: {
                    Text("Text Size").sectionHeaderStyle()
                } footer: {
                    Text("Scales all text in the app, from 85% to 150%. Applies live and syncs to your other devices.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                }

                // MARK: Subtext Size (secondary text multiplier)
                Section {
                    percentSliderRow_iOS(
                        title: "Subtext Size",
                        value: SubtextScale.clamp(subtextScale),
                        range: SubtextScale.range,
                        step: SubtextScale.step,
                        smallerGlyph: "textformat.size.smaller",
                        largerGlyph: "textformat.size.larger",
                        set: setSubtextScale
                    )
                } header: {
                    Text("Subtext Size").sectionHeaderStyle()
                } footer: {
                    Text("Scales descriptions, subtitles, metadata and timestamps on top of Text Size, from 85% to 150%. Titles and buttons stay the same.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                }

                // MARK: Text Contrast (dimmed + accent text toward white/black)
                Section {
                    percentSliderRow_iOS(
                        title: "Text Contrast",
                        value: TextContrast.clamp(theme.textContrast),
                        range: TextContrast.range,
                        step: TextContrast.step,
                        smallerGlyph: "circle.lefthalf.filled",
                        largerGlyph: "circle.fill",
                        set: { theme.setTextContrast($0); SyncManager.shared.pushPreferences() }
                    )
                } header: {
                    Text("Text Contrast").sectionHeaderStyle()
                } footer: {
                    Text("Makes dimmed and accent-colored text brighter in dark mode and darker in light mode. 0% keeps the theme colors, 100% uses plain white or black.")
                        .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                }
                .listSectionSeparator(.hidden)

                // MARK: Time Format
                Section {
                    // Phase 3: one row that pushes the choice page; the
                    // Section footer moved onto the picker.
                    SettingsChoicePicker("Time Format",
                                         options: Self.timeFormatChoices,
                                         selection: $timeFormat,
                                         footer: Self.timeFormatFootnote,
                                         icon: "clock",
                                         onChange: { _ in
                                             SyncManager.shared.pushPreferencesImmediate()
                                         })
                        .listRowBackground(Color.cardBackground)
                }
                // Phase 3: no Section header, for the same reason as
                // Glass Effect above.
                .listSectionSeparator(.hidden)

            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            // Phase 3 (Logan 2026-09-18): floating tab bar parity -
            // content runs under the bar, the bar tucks away on scroll,
            // and the last row clears it.
            .settingsPhoneTabBarChrome()
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { pageWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, width in pageWidth = width }
                }
            }
            // See SettingsView for rationale, SwiftUI List cells
            // cache their rendered content even when the parent
            // re-renders, leaving accent-derived text colors
            // (.textSecondary, .textTertiary) and section header
            // tints stuck on the previous theme. Keying the List
            // identity to the active theme forces a clean rebuild.
            .id("appearance-list-\(theme.selectedTheme.rawValue)-\(theme.appearanceMode.rawValue)-\(theme.useCustomAccent ? theme.customAccentHex : "preset")")
    }

    /// Leading inset for the dividers in the Color Theme and Accent
    /// cards: the swatch width plus its trailing spacing, so every
    /// divider starts under the row's title text.
    private static let themeRowSeparatorInset: CGFloat = 36

    /// Appearance mode (Dark / Light / System). Its own headed card
    /// since Phase 3.
    private var appearanceModeRow: some View {
        // Appearance mode, a surface luminance axis orthogonal to the
        // hue/identity themes. Defaults to Dark; selecting a theme never
        // changes the mode, and vice versa.
        // Phase 3: the segmented control becomes the shared picker row,
        // so Appearance asks its question the same way as every other
        // one-of-N setting (and the same way as tvOS and Android).
        SettingsChoicePicker("Mode",
                             options: appearanceModeChoices,
                             selection: appearanceModeSelection,
                             onChange: { _ in
                                 SyncManager.shared.pushPreferencesImmediate()
                             })
            .listRowBackground(Color.cardBackground)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }

    /// True Black Background (OLED): pure black page backgrounds and
    /// #0A0A0A cards / sheets, resolved in ThemeManager. Synced bool
    /// `appearance.trueBlack`.
    private var trueBlackRow: some View {
        Toggle(isOn: Binding(
            get: { theme.trueBlack },
            set: { theme.trueBlack = $0; SyncManager.shared.pushPreferencesImmediate() }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("True Black Background")
                    .scaledFont(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Text("Use pure black for backgrounds, for OLED screens.")
                    .scaledFont(.labelSmall.subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
            }
        }
        .tint(theme.accent)
        .listRowBackground(Color.cardBackground)
    }

    /// Custom accent toggle, system color picker and hex field. Its own
    /// headed card since Phase 3.
    @ViewBuilder
    private var accentRows: some View {
        // Custom accent color toggle
        Toggle(isOn: $theme.useCustomAccent) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(hex: theme.customAccentHex))
                    .frame(width: 22, height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.borderMedium, lineWidth: 1)
                    )
                Text("Custom Accent Color")
                    .scaledFont(.bodyMedium).foregroundColor(.textPrimary)
            }
        }
        .tint(theme.accent)
        .listRowBackground(Color.cardBackground)
        .alignmentGuide(.listRowSeparatorLeading) { _ in
            Self.themeRowSeparatorInset
        }

        if theme.useCustomAccent {
            // Native system color picker, tap the swatch to open the full picker
            ColorPicker(
                selection: Binding(
                    get: { Color(hex: theme.customAccentHex) },
                    set: { theme.customAccentHex = $0.toHex() }
                ),
                supportsOpacity: false
            ) {
                Text("Accent Color")
                    .scaledFont(.bodyMedium).foregroundColor(.textPrimary)
            }
            .listRowBackground(Color.cardBackground)
            .alignmentGuide(.listRowSeparatorLeading) { _ in
                Self.themeRowSeparatorInset
            }

            // Hex field for power users who want to paste a specific
            // value. Phase 3: the shared Settings field; the filtering
            // and uppercasing binding is unchanged.
            SettingsTextField("Hex Color",
                              placeholder: "2DD4BF",
                              text: Binding(
                                get: { theme.customAccentHex },
                                set: { newValue in
                                    let allowed: Set<Character> = Set("0123456789ABCDEFabcdef")
                                    let cleaned = newValue.filter { allowed.contains($0) }.uppercased()
                                    theme.customAccentHex = String(cleaned.prefix(6))
                                }
                              ),
                              helper: "Six hex digits, for example 2DD4BF.",
                              autocapitalization: .characters)
                .listRowBackground(Color.cardBackground)
                .alignmentGuide(.listRowSeparatorLeading) { _ in
                    Self.themeRowSeparatorInset
                }
        }
    }

    /// The theme row content shared by the iPhone stacked rows and the
    /// iPad tile grid (Phase 5).
    private func themeRowLabel(_ t: AppTheme) -> some View {
        HStack(spacing: 14) {
            Circle()
                .fill(t.accentPrimary)
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(Color.borderMedium, lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(t.displayName)
                    .scaledFont(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Text(themeSubtitle(t))
                    .scaledFont(.labelSmall.subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
            }

            Spacer()

            if theme.selectedTheme == t {
                Image(systemName: "checkmark")
                    .scaledFont(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.accent)
            }
        }
    }

    /// iOS Text Size row: 85% to 150% in 5% steps, live percent readout.
    private var textSizeRow_iOS: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Text Size")
                    .scaledFont(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Spacer()
                Text("\(Int((TextScale.clamp(textScale) * 100).rounded()))%")
                    .scaledFont(.labelSmall.monospacedDigit().subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
            }
            HStack(spacing: 12) {
                // Glyphs stay fixed so the slider's ends do not shift
                // while the user drags.
                Image(systemName: "textformat.size.smaller")
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .font(.system(size: 12))
                Slider(
                    value: Binding(
                        get: { TextScale.clamp(textScale) },
                        set: { setTextScale($0) }
                    ),
                    in: TextScale.range,
                    step: TextScale.step
                )
                .tint(theme.accent)
                Image(systemName: "textformat.size.larger")
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .font(.system(size: 14))
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.cardBackground)
    }

    /// iOS percent slider row shared by Subtext Size and Text Contrast.
    private func percentSliderRow_iOS(
        title: String,
        value: Double,
        range: ClosedRange<Double>,
        step: Double,
        smallerGlyph: String,
        largerGlyph: String,
        set: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .scaledFont(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .scaledFont(.labelSmall.monospacedDigit())
                    .foregroundColor(Color.contrastText(.textTertiary))
            }
            HStack(spacing: 12) {
                Image(systemName: smallerGlyph)
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .font(.system(size: 12))
                Slider(
                    value: Binding(get: { value }, set: { set($0) }),
                    in: range,
                    step: step
                )
                .tint(theme.accent)
                Image(systemName: largerGlyph)
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .font(.system(size: 14))
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.cardBackground)
    }


    private func setSubtextScale(_ value: Double) {
        let snapped = SubtextScale.clamp(value)
        guard abs(snapped - subtextScale) > 0.0001 else { return }
        subtextScale = snapped
        SyncManager.shared.pushPreferences()
    }

    private func setTextScale(_ value: Double) {
        let snapped = TextScale.clamp(value)
        guard abs(snapped - textScale) > 0.0001 else { return }
        textScale = snapped
        SyncManager.shared.pushPreferences()
    }

    private var swatchPreview: some View {
        HStack(spacing: 14) {
            // Live accent swatch
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.accent)
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.accent.opacity(0.4), lineWidth: 1)
                )
                .shadow(color: theme.accent.opacity(0.4), radius: 6, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 4) {
                let themeLabel = theme.useCustomAccent
                    ? "Custom #\(theme.customAccentHex.uppercased())"
                    : theme.selectedTheme.displayName
                Text(themeLabel + " · " + theme.liquidGlassStyle.displayName)
                    .scaledFont(.bodyMedium).foregroundColor(.textPrimary)
                Text("Applied across the entire app")
                    .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textSecondary))
            }

            Spacer()

            // Phase 3 item 9 (Logan 2026-09-19): the trailing accent
            // gradient dash said nothing - on the TV it read as a stray
            // mark at the edge of the row. Replaced by a real preview of
            // what the page's other controls actually change: a line of
            // primary text and a line of subtext, drawn through
            // `.scaledFont` / `Color.contrastText` so it reflects the
            // current Text Size, Subtext Size and Text Contrast live.
            VStack(alignment: .trailing, spacing: 2) {
                Text("Sample")
                    .scaledFont(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Text("Secondary text")
                    .scaledFont(.labelSmall.subtext())
                    .foregroundColor(Color.contrastText(.textSecondary))
            }
            .lineLimit(1)
        }
        .padding(.vertical, 6)
    }

    private func liquidGlassDescription(_ style: LiquidGlassStyle) -> String {
        switch style {
        case .full:     return "Native Apple Liquid Glass (iOS 26+)"
        case .tinted:   return "Frosted glass with accent color tint"
        case .minimal:  return "Subtle ultra-thin material"
        case .disabled: return "Solid card backgrounds, no glass"
        }
    }

    private var liquidGlassFootnote: String {
        if #available(iOS 26.0, *) {
            return "Full Liquid Glass requires iOS 26 or later and is available on this device."
        } else {
            return "Full Liquid Glass requires iOS 26. Tinted glass is used as a fallback."
        }
    }
}
