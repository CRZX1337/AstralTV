import SwiftUI
#if canImport(UIKit)
import UIKit
#endif


// MARK: - Shared tvOS Button Style

// =====================================================================
// tvOS FOCUS VISUAL CHECKLIST - read before adding any focusable control
// (Logan's standing rule, restated 2026-09-19 after a third round of
// device screenshots showed white platters in Settings.)
//
//  1. NEVER `.buttonStyle(.plain)` or the default style on tvOS. Both
//     let the system paint its white lozenge platter (lift + shadow)
//     behind the label. Every focusable control owns its focus visual.
//  2. Own it with `@FocusState` + `.focused($isFocused)` on the control
//     itself, NOT with `@Environment(\.isFocused)` inside a ButtonStyle:
//     the environment value does not reach a style hosted inside a
//     hand-built (non-List) card, which is why the Appearance stepper
//     rows showed no focus at all.
//  3. Suppress the platter with `TVNoHighlightButtonStyle`. Pass
//     `drawsFocusRing: false` when the control draws its own ring.
//  4. In SETTINGS the ring is ALWAYS the theme accent at
//     `SettingsMetrics.tvFocusRingWidth` (2pt), traced on the control's
//     OWN shape (`.tvFocusRingShape(_:)` or `settingsStyle: true`).
//     Never white, never 3pt or 4pt, never a glow or shadow.
//  5. No scale-up beyond the 1.02 the standard Settings rows use.
//  6. Selection is the FILL or the checkmark, focus is the RING. A
//     focused+selected control must stay readable without turning white.
//  7. Text fields: accent 2pt outline on the box, never a white field
//     highlight (`DarkFocusTextFieldRepresentable` keeps the interior
//     dark).
// =====================================================================

/// Suppresses the default tvOS system focus highlight (white glow) and
/// provides themed focus feedback. The visible focus indicator is the
/// accent stroke ring drawn on the focused element. v1.6.21 dropped
/// the scale, brightness, and shadow effects per user feedback that the
/// pop-out was distracting and pushed text too close to row borders. The
/// stroke alone is sufficient to identify focus at TV viewing distance.
/// Press feedback is a brief opacity dip.

// MARK: - iOS Pressable Button Style

/// Provides subtle scale + opacity feedback on press for iOS cards/rows.
/// Use on NavigationLinks and Buttons that otherwise appear static.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.15 : 0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

// tvOS / macOS shim, UIKeyboardType isn't available outside iOS,
// so we mirror the values the app references to keep call sites clean.

// MARK: - App Card
struct AppCard<Content: View>: View {
    let content: Content
    var padding: CGFloat = 16

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.borderSubtle, lineWidth: 1)
            )
    }
}


// MARK: - TMDB attribution

/// TMDB's logo plus the wording its terms require wherever TMDB data or
/// images are shown (https://www.themoviedb.org/about/logos-attribution).
struct TMDBAttributionView: View {
    enum Style { case short, long }
    var style: Style = .long

    var body: some View {
        let logoHeight: CGFloat = style == .long ? 12 : 28
        let font = AstralFont.footnote
        VStack(alignment: .leading, spacing: 8) {
            Image(style == .long ? "TMDBLogoLong" : "TMDBLogoShort")
                .resizable()
                .scaledToFit()
                .frame(height: logoHeight)
                .accessibilityLabel("The Movie Database")
            // Their required line first, ours second.
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                .scaledFont(font.subtext())
                .foregroundColor(Color.contrastText(.textTertiary))
                .fixedSize(horizontal: false, vertical: true)
            Text("TMDB data is used only after configuring a TMDB API key in Settings > Movies & TV Shows.")
                .scaledFont(font.subtext())
                .foregroundColor(Color.contrastText(.textTertiary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Primary Button
struct PrimaryButton: View {
    let title: String
    let icon: String?
    let action: () -> Void
    var isLoading: Bool = false
    var isDisabled: Bool = false

    init(_ title: String, icon: String? = nil, isLoading: Bool = false, isDisabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isLoading = isLoading
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.85)
                } else {
                    if let icon {
                        Image(systemName: icon)
                            .scaledFont(.system(size: 16, weight: .semibold))
                    }
                    Text(title)
                        .scaledFont(.headlineMedium)
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .background(
                isDisabled
                    ? AnyShapeStyle(Color.textTertiary)
                    : AnyShapeStyle(LinearGradient.accentGradient)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(isDisabled || isLoading)
        .buttonStyle(.plain)
    }
}

// MARK: - Secondary Button
struct SecondaryButton: View {
    let title: String
    let icon: String?
    let action: () -> Void

    init(_ title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .scaledFont(.system(size: 15, weight: .medium))
                }
                Text(title)
                    .scaledFont(.headlineMedium)
            }
            .foregroundColor(.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .background(Color.elevatedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.borderMedium, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Styled Text Field
struct AppTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var icon: String? = nil
    var keyboardType: UIKeyboardType = .default
    var isSecure: Bool = false
    var autocapitalization: TextInputAutocapitalization = .never
    var autocorrection: Bool = false
    // SECURITY, removed 2026-09-19 (Logan's Apple TV review): there used
    // to be a `revealWhenFocused` flag here that unmasked a secure field
    // while the field itself was focused, on the theory that the Siri
    // Remote could not reach the in-box eye button. The eye IS reachable
    // (verified on device), and the flag printed the TMDB API key in
    // plain text on the TV the moment the field took focus. A secure
    // field now stays masked whenever reveal is off, focused or not, on
    // every platform; the eye toggle is the ONLY thing that reveals it.
    // Do not reintroduce a focus-driven reveal.

    @FocusState private var isFocused: Bool

    /// v1.7.x: when `isSecure` is true, this drives a trailing
    /// eye-toggle button that flips between `SecureField` and
    /// `TextField`. Lets users verify they typed the password
    /// correctly, especially valuable on Apple TV where the Siri
    /// Remote keyboard makes typos easy. Defaults to hidden so
    /// dots are still the at-rest state; security posture is
    /// unchanged unless the user explicitly taps reveal.
    @State private var passwordVisible: Bool = false

    /// v1.7.5: tvOS focus state, driven by the UIKit DarkFocusTextField's
    /// focus callback (the tvOS body hosts that instead of a SwiftUI
    /// TextField, so @FocusState can't track it). Drives the box border +
    /// icon tint on tvOS the way `isFocused` does on iOS.
    @State private var isFocusedTV: Bool = false


    init(_ title: String,
         placeholder: String,
         text: Binding<String>,
         icon: String? = nil,
         keyboardType: UIKeyboardType = .default,
         isSecure: Bool = false,
         autocapitalization: TextInputAutocapitalization = .never,
         autocorrection: Bool = false) {
        self.title = title
        self.placeholder = placeholder
        self._text = text
        self.icon = icon
        self.keyboardType = keyboardType
        self.isSecure = isSecure
        self.autocapitalization = autocapitalization
        self.autocorrection = autocorrection
    }

    var body: some View {
        iosBody
    }


    private var iosBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .scaledFont(.labelLarge)
                .foregroundColor(Color.contrastText(.textSecondary))

            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .scaledFont(.system(size: 16))
                        .foregroundColor(isFocused ? .accentPrimary : Color.contrastText(.textTertiary))
                        .frame(width: 20)
                        .animation(.easeInOut(duration: 0.15), value: isFocused)
                }

                Group {
                    if isSecure && !passwordVisible {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                            .keyboardType(keyboardType)
                    }
                }
                .scaledFont(.bodyMedium)
                // v1.6.21 fix for the "white-on-white" tvOS bug.
                // tvOS fills the focused TextField with white and
                // expects dark text. Forcing `.textPrimary` (light)
                // there made typed text invisible against the
                // white fill. On tvOS, switch to a dark colour
                // when focused so the entered text contrasts; on
                // iOS the original light colour is correct.
                .foregroundColor(.textPrimary)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled(!autocorrection)
                .focused($isFocused)

                // v1.7.x: trailing reveal/hide button for secure
                // fields. Only renders when `isSecure` is true so
                // non-password fields stay flush. Tap toggles
                // `passwordVisible`, which swaps the inner field
                // between SecureField and TextField. Stays empty
                // on tvOS focus engine because tvOS users tap the
                // field directly, adding a sibling button would
                // confuse the focus engine without corresponding
                // value (Siri Remote keyboard reveal is server-side).
                if isSecure {
                    Button {
                        passwordVisible.toggle()
                    } label: {
                        Image(systemName: passwordVisible ? "eye.slash" : "eye")
                            .font(.system(size: 16))  // glyph in a fixed box: not text, stays fixed
                            .foregroundColor(Color.contrastText(.textTertiary))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(passwordVisible ? "Hide password" : "Show password")
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(Color.elevatedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isFocused ? Color.accentPrimary.opacity(0.6) : (text.isEmpty ? Color.borderSubtle : Color.accentPrimary.opacity(0.4)), lineWidth: isFocused ? 1.5 : 1)
                    .animation(.easeInOut(duration: 0.15), value: isFocused)
            )
            // Tapping anywhere in the field, including the icon area, focuses the input
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
        }
        // tvOS notes: the system applies a white fill to the focused
        // TextField. v1.6.21 attempted to suppress this with a
        // Button-wrapped mock label and a hidden TextField behind it
        // for the keyboard sheet, but on tvOS the system keyboard
        // sheet only presents when the user explicitly presses
        // Select on a directly-focused TextField. Programmatically
        // setting `@FocusState` on a hidden field doesn't trigger
        // the keyboard, so users couldn't type. Reverted to the
        // direct-TextField path; the white fill on focus stays as
        // an accepted system UX for now. A proper themed-focus tvOS
        // text field requires UIViewRepresentable wrapping
        // UITextField with custom focused-appearance overrides,
        // which is bigger than v1.6.21 scope.
    }
}

// MARK: - Server Type Badge
struct ServerTypeBadge: View {
    let type: ServerType

    private let iconSize: CGFloat = 10
    private let hPad: CGFloat = 8
    private let vPad: CGFloat = 4

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: type.systemIcon)
                .scaledFont(.system(size: iconSize, weight: .semibold))
            Text(type.displayName)
                .scaledFont(.labelSmall)
                // The badge is an identity chip, not prose: it stays on
                // one line at every width. Without this it wrapped to
                // three lines beside a truncated URL in a 50% Split View.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundColor(type.color)
        .padding(.horizontal, hPad)
        .padding(.vertical, vPad)
        .background(type.color.opacity(0.15))
        .clipShape(Capsule())
    }
}

// MARK: - Live Badge
struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.statusLive)
                .frame(width: 5, height: 5)
            Text("LIVE")
                .scaledFont(.labelSmall)
                .foregroundColor(Color.statusLive)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.statusLive.opacity(0.15))
        .clipShape(Capsule())
    }
}

// MARK: - Section Header
struct SectionHeader: View {
    let title: String
    var action: (() -> Void)? = nil
    var actionTitle: String = "See All"

    var body: some View {
        HStack {
            Text(title)
                .sectionHeaderStyle()
            Spacer()
            if let action {
                Button(action: action) {
                    Text(actionTitle)
                        .scaledFont(.labelMedium)
                        .foregroundColor(Color.contrastText(.accentPrimary))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Loading View
struct LoadingView: View {
    var message: String = "Loading..."

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.accentPrimary)
                .scaleEffect(1.2)
            Text(message)
                .scaledFont(.bodyMedium.subtext())
                .foregroundColor(Color.contrastText(.textSecondary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }
}

// MARK: - Empty State View
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var action: (() -> Void)? = nil
    var actionTitle: String = "Get Started"

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .scaledFont(.system(size: 48))
                .foregroundStyle(LinearGradient.accentGradient)

            VStack(spacing: 8) {
                Text(title)
                    .scaledFont(.headlineLarge)
                    .foregroundColor(.textPrimary)
                Text(message)
                    .scaledFont(.bodyMedium.subtext())
                    .foregroundColor(Color.contrastText(.textSecondary))
                    .multilineTextAlignment(.center)
            }

            if let action {
                Button(action: action) {
                    Text(actionTitle)
                        .scaledFont(.headlineSmall)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(LinearGradient.accentGradient)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - No-Poster Placeholder
/// Shown when no artwork is available for a movie, series, or channel.
struct NoPosterPlaceholder: View {
    /// When true, shows only the logo without text (for small contexts like channel logos).
    var compact: Bool = false

    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            Image("AstralLogo")
                .resizable()
                .scaledToFit()
                .frame(width: compact ? 20 : 40, height: compact ? 20 : 40)
                .opacity(0.6)
            if !compact {
                Text("No artwork provided")
                    .scaledFont(.labelSmall.subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
    }
}

// MARK: - tvOS Category Pill (shared)

// MARK: - EPG Program Flag Badges
//
// Shared LIVE / NEW / PREMIERE / FINALE / REPEAT badges and the
// season/episode label, rendered in the guide grid cell, the channel
// list rows, and the Program Info sheet. Ported from Android
// `core/ui/EpgBadges.kt` (the semantic source of truth).
//
// These are driven by FEED metadata, not the wall clock: `LIVE` here is
// the XMLTV `<live/>` / Dispatcharr `is_live` broadcast flag, distinct
// from the guide's clock-derived "airing now" tint. Per the per-source
// matrix, Dispatcharr cannot supply REPEAT (no previously-shown field).

extension Color {
    // LIVE reuses the existing `statusLive` (#FF4757). These three are
    // the badge-specific additions, matching the Android palette
    // (EpgNewGreen / EpgPremierePurple / EpgRepeatGray).
    static let epgFlagNew      = Color(hex: "27AE60")
    static let epgFlagPremiere = Color(hex: "9B59B6")
    static let epgFlagRepeat   = Color(hex: "8A8F98")
}

/// One feed-flag badge: a label + its solid pill colour.
struct EPGFlag {
    let label: String
    let color: Color
}

/// Ordered badge list for a program, most-salient first. REPEAT is
/// suppressed when NEW is set (a program is one or the other). Empty
/// when nothing applies. FINALE shares the PREMIERE purple (Android
/// parity). A simple free function so `GuideProgram`, `EPGProgram`,
/// `EPGEntry`, and `ProgramInfoTarget` can all feed it their 5 Bools.
/// @AppStorage key for the "Show program badges" preference on THIS device type.
/// Per-device-type: tvOS and iOS store separately and both sync, so a TV's
/// choice follows the user's Apple TVs and a phone/tablet's follows their
/// iPhones/iPads, independently. Default true (badges shown).
let epgBadgesVisibleKey = "showEpgBadges.mobile"

func epgFlagBadges(isLiveBroadcast: Bool,
                   isNew: Bool,
                   isPremiere: Bool,
                   isFinale: Bool,
                   isRepeat: Bool) -> [EPGFlag] {
    var out: [EPGFlag] = []
    if isLiveBroadcast { out.append(EPGFlag(label: "LIVE", color: .statusLive)) }
    if isNew           { out.append(EPGFlag(label: "NEW", color: .epgFlagNew)) }
    if isPremiere      { out.append(EPGFlag(label: "PREMIERE", color: .epgFlagPremiere)) }
    if isFinale        { out.append(EPGFlag(label: "FINALE", color: .epgFlagPremiere)) }
    if isRepeat && !isNew { out.append(EPGFlag(label: "REPEAT", color: .epgFlagRepeat)) }
    return out
}

/// "S3 E5" / "S3" / "E5", or nil when neither number is known.
func seasonEpisodeLabel(season: Int?, episode: Int?) -> String? {
    switch (season, episode) {
    case let (s?, e?): return "S\(s) E\(e)"
    case let (s?, nil): return "S\(s)"
    case let (nil, e?): return "E\(e)"
    default: return nil
    }
}

/// Small value type carrying the feed's per-program flag markers so a
/// caller (e.g. `ChannelRow.liveProgram`) can pass them around in one
/// bag. All default false so the no-metadata path is a plain `EPGFlags()`.
struct EPGFlags: Equatable {
    var isNew: Bool = false
    var isLiveBroadcast: Bool = false
    var isPremiere: Bool = false
    var isFinale: Bool = false
    var isRepeat: Bool = false

    var badges: [EPGFlag] {
        epgFlagBadges(isLiveBroadcast: isLiveBroadcast, isNew: isNew,
                      isPremiere: isPremiere, isFinale: isFinale, isRepeat: isRepeat)
    }
    var isEmpty: Bool { badges.isEmpty }
}

/// A compact solid-colour badge pill. `compact` keeps guide-cell badges
/// tight; the roomier list/info-sheet uses the larger (tvOS-bumped) size,
/// matching the `LiveBadge` / `ServerTypeBadge` sizing idiom.
struct EPGFlagBadge: View {
    let flag: EPGFlag
    var compact: Bool = false

    private var fontSize: CGFloat { compact ? 7 : 10 }
    private var hPad: CGFloat { compact ? 3 : 6 }
    private var vPad: CGFloat { compact ? 0.5 : 2 }
    private var cornerRadius: CGFloat { compact ? 3 : 4 }

    var body: some View {
        Text(flag.label)
            .scaledFont(.system(size: fontSize, weight: .bold))
            .foregroundColor(.white)
            .lineLimit(1)
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background(flag.color)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A horizontal run of badges; renders nothing when there are no flags.
struct EPGFlagsRow: View {
    let flags: [EPGFlag]
    var compact: Bool = false
    var spacing: CGFloat = 4

    init(flags: [EPGFlag], compact: Bool = false, spacing: CGFloat = 4) {
        self.flags = flags
        self.compact = compact
        self.spacing = spacing
    }

    /// Convenience: build straight from the 5 feed Bools.
    init(isLiveBroadcast: Bool, isNew: Bool, isPremiere: Bool,
         isFinale: Bool, isRepeat: Bool, compact: Bool = false, spacing: CGFloat = 4) {
        self.init(flags: epgFlagBadges(isLiveBroadcast: isLiveBroadcast, isNew: isNew,
                                       isPremiere: isPremiere, isFinale: isFinale,
                                       isRepeat: isRepeat),
                  compact: compact, spacing: spacing)
    }

    /// Labels the user hid under Settings > App Behaviors > Show Program
    /// Badges (Logan, 2026-08-19). Newline-joined set; empty = show all, so
    /// future badge kinds stay visible until explicitly hidden. Same storage
    /// shape as Android's ui_hidden_epg_badges.
    @AppStorage("ui.hiddenEpgBadges") private var hiddenEpgBadgesRaw = ""

    var body: some View {
        let hidden = Set(hiddenEpgBadgesRaw.split(separator: "\n").map(String.init))
        let shown = hidden.isEmpty ? flags : flags.filter { !hidden.contains($0.label) }
        if !shown.isEmpty {
            HStack(spacing: spacing) {
                ForEach(shown.indices, id: \.self) { i in
                    EPGFlagBadge(flag: shown[i], compact: compact)
                }
            }
        }
    }
}

/// A small neutral outlined "S3 E5" pill. Renders nothing when `label`
/// (or the season/episode pair) is nil.
struct SeasonEpisodePill: View {
    let label: String?
    var compact: Bool = false

    init(label: String?, compact: Bool = false) {
        self.label = label
        self.compact = compact
    }

    init(season: Int?, episode: Int?, compact: Bool = false) {
        self.label = seasonEpisodeLabel(season: season, episode: episode)
        self.compact = compact
    }

    private var fontSize: CGFloat { compact ? 7 : 10 }
    private var hPad: CGFloat { compact ? 3 : 6 }
    private var vPad: CGFloat { compact ? 0.5 : 2 }
    private var cornerRadius: CGFloat { compact ? 3 : 4 }

    var body: some View {
        if let label {
            Text(label)
                .scaledFont(.system(size: fontSize, weight: .medium).subtext())
                .foregroundColor(Color.contrastText(.textSecondary))
                .lineLimit(1)
                .padding(.horizontal, hPad)
                .padding(.vertical, vPad)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.borderMedium, lineWidth: 1)
                )
        }
    }
}

// MARK: - tvOS QR link sheet



// MARK: - Phone card deck

/// Horizontal card deck for the iPhone hero rows (Logan 2026-09-05): the
/// current card in front at the left margin, the following ones peeking
/// out to its right, the previous one parked at the left edge with a
/// sliver showing. A drag slides the deck and snaps to the nearest card;
/// the deck is endless. Dots under it follow the current card.
/// Deck drag bookkeeping shared across generic instantiations.
@MainActor
enum PhoneCardDeckStats {
    static var lastDragEnded: TimeInterval = 0
}

struct PhoneCardDeck<Item: Identifiable, Card: View>: View {
    let items: [Item]
    let cardHeight: CGFloat
    var onCurrentChange: ((Item) -> Void)? = nil
    @ViewBuilder let card: (Item) -> Card

    @State private var index: Int = 0
    @State private var dragX: CGFloat = 0
    /// Drag instrumentation (Logan 2026-09-06, "very laggy"): frame gaps
    /// between drag samples and the tap-after-drag window.
    @State private var lastDragSample: TimeInterval = 0
    @State private var dragFrames = 0
    @State private var dragDropped = 0
    @State private var dragWorstMs: Double = 0
    private let peek: CGFloat = 9
    private let margin: CGFloat = 10
    /// Extra lead so the front card's left edge lines up with the library
    /// grid's 18 pt margin (Logan 2026-09-09); the right side keeps its
    /// peeks toward the screen edge.
    private let leadInset: CGFloat = 8
    private let dot: CGFloat = 6
    private let dotInset: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - leadInset - margin * 2 - peek * 2
            let front0 = leadInset + margin
            let count = max(items.count, 1)
            let p = CGFloat(index) - dragX / w
            ZStack(alignment: .leading) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    let raw = (CGFloat(i) - p).truncatingRemainder(dividingBy: CGFloat(count))
                    let wrapped = raw < 0 ? raw + CGFloat(count) : raw
                    // Single card: no wrap or stack; it follows the finger with
                    // a dampened drag and springs back (Logan 2026-09-09: the
                    // wrapped position moved and faded it, which read as the
                    // image reloading).
                    let single = count == 1
                    // Android rule (Logan 2026-09-09): nothing parks to the
                    // side. Only a card mid-exit (wrapped strictly past the
                    // last slot) is negative; at rest the previous card sits
                    // at the back of the stack.
                    let relRaw: CGFloat = single ? 0
                        : ((wrapped > CGFloat(count) - 1 + 0.0001) ? wrapped - CGFloat(count) : wrapped)
                    // Decks of any size behave like a four-card deck (Logan
                    // 2026-09-09: the swiped card must arrive at the back of
                    // the stack on a 12-card deck too, not vanish): the last
                    // card at rest takes the rear slot.
                    let rel: CGFloat = (count > 4 && abs(relRaw - (CGFloat(count) - 1)) < 0.0001) ? 3 : relRaw
                    // Only the cards that can be seen are built: the current
                    // one, three behind it and the parked previous one. A
                    // ten-item deck was laying out ten hero views per drag
                    // frame (Logan 2026-09-06, "very laggy").
                    // One extra card is built behind the visible three (drawn
                    // under the rear slot) so its art loads before it is seen;
                    // on a big deck the rear card used to load its image the
                    // moment it appeared (log 2026-09-09).
                    if rel > -1.5 && rel < 4.5 {
                    let slot = min(rel, 3)
                    let x: CGFloat = single ? front0 + dragX * 0.35
                        : rel >= 0
                        ? front0 + slot * peek
                        : front0 - (w + front0) * min(-rel, 1)
                    let scale: CGFloat = rel >= 0 ? 1 - slot * 0.03 : 1
                    // The leaving card stays solid (Logan 2026-09-09: the
                    // exit fade read as the DVR card "fading out too quickly"
                    // against its darker hero gradient).
                    let alpha: Double = rel >= 0 ? Double(1 - min(rel, 3) * 0.2) : 1
                    card(item)
                        .frame(width: w, height: cardHeight)
                        // The drop shadow lives on a plain shape under the
                        // card, not on the card: shadowing a hero with
                        // gradients and masks re-renders it offscreen on
                        // every frame of the drag.
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.black.opacity(0.001))
                                .shadow(color: .black.opacity(abs(rel) < 0.5 ? 0.45 : 0), radius: 14, x: 6, y: 0)
                        )
                        .scaleEffect(scale, anchor: .trailing)
                        .offset(x: x)
                        .opacity(max(0, min(1, alpha)))
                        .allowsHitTesting(abs(rel) < 0.02)
                        .zIndex(rel >= 0 ? Double(10 - rel) : Double(10.99 + rel))
                    }
                }
            }
            .frame(width: geo.size.width, height: cardHeight, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            // A UIKit pan that FAILS on a vertical start (Logan 2026-09-09:
            // "can't scroll if I begin on a stacked card"): vertical swipes
            // fall through to the scroll view, horizontal ones page the deck,
            // and a recognised pan still cancels the card's own taps.
            .gesture(HorizontalPanGesture(
                onChanged: { dx in
                    let now = CACurrentMediaTime()
                    if lastDragSample > 0 {
                        let gap = (now - lastDragSample) * 1000
                        dragFrames += 1
                        if gap > 34 { dragDropped += 1 }
                        dragWorstMs = max(dragWorstMs, gap)
                    } else {
                        dragFrames = 0; dragDropped = 0; dragWorstMs = 0
                    }
                    lastDragSample = now
                    dragX = dx
                },
                onEnded: { dx, vx in
                    debugLog("[DECK] drag end: \(dragFrames) samples, \(dragDropped) gaps > 34 ms, worst \(Int(dragWorstMs)) ms, cards=\(items.count)")
                    lastDragSample = 0
                    PhoneCardDeckStats.lastDragEnded = CACurrentMediaTime()
                    // Predicted end: where a flick would settle (~0.15 s of velocity).
                    let predicted = dx + vx * 0.15
                    var target = index
                    if dx < -60 || predicted < -w / 2 { target += 1 }
                    else if dx > 60 || predicted > w / 2 { target -= 1 }
                    let wrappedTarget = ((target % count) + count) % count
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
                        index = wrappedTarget
                        dragX = 0
                    }
                    if wrappedTarget < items.count { onCurrentChange?(items[wrappedTarget]) }
                }
            ))
        }
        .frame(height: cardHeight)
        .overlay(alignment: .bottom) {
            if items.count > 1 {
                HStack(spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, _ in
                        Circle()
                            .fill(i == index ? Color.accentPrimary : Color.textTertiary.opacity(0.5))
                            .frame(width: dot, height: dot)
                    }
                }
                .offset(y: dotInset)
            }
        }
        .padding(.bottom, 24)
        .onChange(of: items.map { $0.id }) { _, ids in
            index = min(index, max(ids.count - 1, 0))
        }
    }
}

/// Horizontal-only pan for the phone card deck. Fails as soon as the first
/// movement is more vertical than horizontal, so the enclosing scroll view
/// keeps vertical drags that start on a card.
struct HorizontalPanGesture: UIGestureRecognizerRepresentable {
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> HorizontalPanRecognizer {
        let r = HorizontalPanRecognizer()
        r.maximumNumberOfTouches = 1
        return r
    }

    func handleUIGestureRecognizerAction(_ r: HorizontalPanRecognizer, context: Context) {
        let t = r.translation(in: r.view)
        switch r.state {
        case .changed: onChanged(t.x)
        case .ended, .cancelled: onEnded(t.x, r.velocity(in: r.view).x)
        default: break
        }
    }
}

final class HorizontalPanRecognizer: UIPanGestureRecognizer {
    private var start: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        start = touches.first?.location(in: view)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible, let s = start, let p = touches.first?.location(in: view) {
            let dx = abs(p.x - s.x), dy = abs(p.y - s.y)
            if dy > 8, dy > dx { state = .failed; return }
            if dx < 10 { return }   // same 10 pt lead-in as before
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() { start = nil; super.reset() }
}

// MARK: - iCloud Sync Failure

/// Inline failure reason for a manual iCloud Push or Pull, in the same
/// red-status treatment neighboring settings rows use for a failed Test
/// Connection. Deliberately NOT a blocking overlay.
///
/// Logan 2026-09-15 (device feedback): the in-flight half of this row
/// flashed so briefly it read as a glitch, so progress moved INTO the
/// Push / Pull rows themselves (a native spinner in the row that is
/// running, see `SettingsRow.isBusy` / `TVSettingsActionRow.isBusy`) and
/// this row was reduced to the failure case.
///
/// Renders nothing when there is nothing to report, so it can sit
/// unconditionally inside any Sync section on any platform.
struct SyncActivityRow: View {
    @ObservedObject private var sync = SyncManager.shared

    private let titleSize: CGFloat = 14
    private let horizontalPadding: CGFloat = 0
    private let verticalPadding: CGFloat = 2

    var body: some View {
        Group {
            if let failure = sync.lastSyncFailure {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.statusLive)
                    Text(failure)
                        .scaledFont(.system(size: titleSize).subtext())
                        .foregroundColor(.statusLive)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: sync.lastSyncFailure)
    }
}
