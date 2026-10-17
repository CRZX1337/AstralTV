import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Developer Icon Tile

/// The rounded-rect tinted icon tile every Settings row uses. Phase 3:
/// this page had it on the engine toggles only, so the log-file rows and
/// the What's Captured rows carried a bare glyph and read as a different
/// page. Sized to match the toggles already here (36 pt box on iOS,
/// 48 pt on tvOS) and kept at a low tint opacity, never a bright fill.
struct DevIconTile: View {
    let icon: String
    var tint: Color = .accentPrimary
    /// Off-state rows sit on the neutral elevated fill instead of the
    /// tinted one, exactly as the engine toggles already do.
    var isActive: Bool = true

    private let boxSize: CGFloat = 36
    private let glyphSize: CGFloat = 16
    private let corner: CGFloat = 8

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(isActive ? tint.opacity(0.18) : Color.elevatedBackground)
                .frame(width: boxSize, height: boxSize)
            Image(systemName: icon)
                .scaledFont(.system(size: glyphSize, weight: .medium))
                .foregroundColor(isActive ? tint : Color.contrastText(.textSecondary))
        }
    }
}

/// Which playback engine the Developer page's one picker reports and
/// writes. `custom` is display-only: it appears when the individual flags
/// are a mix that matches neither preset.
enum PlaybackEnginePreset: String, Hashable {
    case avPlayer
    case mpv
    case custom
}

// MARK: - Developer Settings View

struct DeveloperSettingsView: View {
    /// See SettingsView. Re-renders this page on every theme change
    /// so accent-tinted toggles and section headers don't freeze at
    /// the theme that was active when the page was first pushed.
    @ObservedObject private var theme = ThemeManager.shared
    @AppStorage("debugLoggingEnabled") private var debugLoggingEnabled = false

    /// Mirrors `PlaybackFeatureFlags.useUnifiedPlayback`. The toggle
    /// routes every playback entry point (guide tap, favorites,
    /// CarPlay, deep-link, add-sheet) through `PlayerSession.begin(...)`
    /// which mounts `MultiviewContainerView` from the first tile
    /// instead of the legacy `PlayerView`. **Default `true`** as of
    /// Phase D, the unified view is now the canonical path. Users
    /// who hit a unified-path regression can flip this off for the
    /// legacy `PlayerView` fallback while we chase the bug.
    @AppStorage("playback.unified") private var unifiedPlayback = true
    /// Engine auto-detection, HLS arm. **Default ON** (matches
    /// PlaybackFeatureFlags.avPlayerForHLS absent-key-means-on): genuine
    /// HLS + natively-HLS-capable Dispatcharr servers ride AVPlayer; mpv
    /// stays the automatic fallback. The off switch remains for chasing
    /// AVPlayer-path regressions.
    @AppStorage("playback.avplayerHLS") private var avPlayerHLS = true
    /// Engine auto-detection, remux arm: raw MPEG-TS through the on-device
    /// TS-to-HLS remuxer into AVPlayer (H.264 + AC-3/AAC only; auto
    /// fallback to mpv otherwise). Still opt-in: background-audio +
    /// transition-restart caveats keep it below the default-on bar.
    @AppStorage("playback.avplayerRemuxTS") private var avPlayerRemuxTS = true
    /// TEST BRANCH: mpv engine kill-switch, default OFF (mpv disabled)
    /// so AVPlayer gaps fail visibly instead of being silently rescued.
    /// See PlaybackFeatureFlags.mpvEngineEnabled - must default back ON
    /// before this branch ships beyond Logan's devices.
    @AppStorage("dev.mpvEngineEnabled") private var mpvEngineEnabled = false
    /// Force HLS (developer test, 2026-10-04): every Dispatcharr Direct
    /// Connect live channel requests the server's native HLS output and
    /// plays direct on AVPlayer. Read at tune time by
    /// PlaybackFeatureFlags.forceHLS, so a flip applies on the next tune.
    @AppStorage("developer.forceHLS") private var forceHLS = false
    /// Dump Audio-Only Segments (developer diagnostic, 2026-10-15): the TS
    /// remuxer also writes every audio-only segment and playlist it serves
    /// on the loopback to Documents/AudioOnlyDump. Per device, read at tune
    /// time by AudioOnlySegmentDumper.enabled.
    @AppStorage(AudioOnlySegmentDumper.defaultsKey) private var dumpAudioOnlySegments = false

    /// **Experimental**, iPhone-only. When on, the Live TV chrome is
    /// compacted: Manage Groups moves into the nav bar toolbar, and the
    /// filter-pills + search strip can be hidden entirely via two new
    /// toggles inside the Manage Groups sheet. Default **off** so the
    /// main user base is unaffected; we ship the flag first to let
    /// opted-in testers validate the layout before considering a flip.
    /// Reads:
    /// - `ChannelListView` for the chrome layout branch
    /// - `ManageGroupsSheet` for the hide-filter / hide-search toggles
    @AppStorage("ui.iphone.compactChrome") private var compactChromeiPhone = false
    @AppStorage("castForceHEVCTranscode") private var castForceHEVCTranscode = false
    @AppStorage("castTranscodeDownProfile") private var castTranscodeDownProfile = "720p60"

    /// Companion toggles, previously only exposed inside the Manage
    /// Groups sheet, which made the parent "Compact Chrome" toggle
    /// seem to do nothing (#22 feedback: "I can't tell what iPhone
    /// Compact Chrome even does"). Exposed inline here so turning
    /// Compact Chrome ON reveals its actual controls directly beneath.
    @AppStorage("ui.iphone.hideFilterBar") private var hideFilterBarCompact = false
    @AppStorage("ui.iphone.hideSearchBar") private var hideSearchBarCompact = false

    @Query private var servers: [ServerConnection]

    @State private var showEnableConfirmation = false
    @State private var showDisableConfirmation = false
    @State private var copiedConfirmation = false
    @State private var showClearConfirmation = false
    @State private var showLogViewer = false
    @State private var logSize = "Empty"
    private let logger = DebugLogger.shared

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            iOSBody
        }
        .navigationTitle("Developer")
        // Every other Settings sub-page uses an inline title; Developer
        // was the only large one (Logan screenshots 2026-09-18).
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appBackground, for: .navigationBar)

        // MARK: - Enable Confirmation
        .alert("Enable Debug Logging?", isPresented: $showEnableConfirmation) {
            Button("Enable Logging", role: .none) {
                debugLoggingEnabled = true
                logger.enable()
                refreshLogSize()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("AstralTV will write detailed diagnostic logs to a file on your device.\n\nThis includes network requests, playback events, and error details. The file is only accessible from this device via the Files app or the share button below.\n\nLogging has a minor impact on performance and storage. You can disable it at any time.")
        }

        // MARK: - Disable Confirmation
        .alert("Disable Debug Logging?", isPresented: $showDisableConfirmation) {
            Button("Disable", role: .destructive) {
                logger.disable()
                debugLoggingEnabled = false
                refreshLogSize()
            }
            Button("Keep Logging", role: .cancel) {}
        } message: {
            Text("The existing log file will be kept. You can share or clear it at any time.")
        }

        // MARK: - Clear Confirmation
        .confirmationDialog("Delete All Logs?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Delete All Logs", role: .destructive) {
                logger.clearLogs()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refreshLogSize() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the current log file and any rotated archives. This cannot be undone.")
        }
        // MARK: - tvOS Share Sheet (LAN HTTP server + QR code)
        // Presented when the user taps Share Log File on tvOS. The server
        // is started in `shareFile` just before this flips true; it stops
        // automatically when the sheet disappears (TvOSLogShareSheet.onDisappear).
    }

    // MARK: - iOS Body

    private var iOSBody: some View {
        List {

                // MARK: - Debug Logging Toggle
                // Phase 3 (Logan 2026-09-18): the page opens with the
                // toggle, so the toggle's effect is self-documenting:
                // you see the toggle, immediately below it "What's
                // Captured" says what enabling it will log, and the
                // log file actions follow. Matches the tvOS order.
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(debugLoggingEnabled
                                      ? Color.accentPrimary.opacity(0.18)
                                      : Color.elevatedBackground)
                                .frame(width: 36, height: 36)
                            Image(systemName: debugLoggingEnabled
                                  ? "ladybug.fill"
                                  : "ladybug")
                                .scaledFont(.system(size: 16, weight: .medium))
                                .foregroundColor(debugLoggingEnabled ? .accentPrimary : Color.contrastText(.textSecondary))
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Debug Logging")
                                .scaledFont(.bodyMedium)
                                .foregroundColor(.textPrimary)
                            Text(debugLoggingEnabled
                                 ? "Active: writing to astral_debug_logs.txt"
                                 : "Off: no data is collected")
                                .scaledFont(.labelSmall)
                                .foregroundColor(debugLoggingEnabled ? Color.contrastText(.accentPrimary) : Color.contrastText(.textTertiary))
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { debugLoggingEnabled },
                            set: { newValue in
                                if newValue {
                                    showEnableConfirmation = true
                                } else {
                                    showDisableConfirmation = true
                                }
                            }
                        ))
                        .labelsHidden()
                        .tint(.accentPrimary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.cardBackground)

                } header: {
                    Text("Logging")
                        .sectionHeaderStyle()
                } footer: {
                    Text("When enabled, detailed logs are written to a file in On My iPhone › AstralTV. Logs include network requests, playback events, EPG activity, errors, and app lifecycle events. No personally identifiable information is collected.")
                        .scaledFont(.labelSmall.subtext())
                        .foregroundColor(Color.contrastText(.textTertiary))
                        .padding(.top, 4)
                }
                .listSectionSeparator(.hidden)

                // MARK: - What's Logged
                Section {
                    logCategoryRow(icon: "network",                title: "Network",     detail: "All API requests: URL, method, status code, duration, payload size")
                    logCategoryRow(icon: "play.rectangle.fill",    title: "Playback",    detail: "Stream URLs loaded, player state transitions, DVR mode, failover attempts")
                    logCategoryRow(icon: "calendar",               title: "EPG",         detail: "Current program fetches, upcoming program loads, decode errors")
                    logCategoryRow(icon: "antenna.radiowaves.left.and.right", title: "Channels", detail: "Channel list loads, server type, item counts, timing")
                    logCategoryRow(icon: "app.badge",              title: "Lifecycle",   detail: "App foreground/background, launch, scene transitions")
                    logCategoryRow(icon: "exclamationmark.triangle.fill", title: "Errors", detail: "Caught exceptions with full context, source file and line number")
                    logCategoryRow(icon: "gauge.with.dots.needle.67percent", title: "Performance", detail: "Timed operations: parse time, load time, memory at session start")
                } header: {
                    Text("What's Captured")
                        .sectionHeaderStyle()
                } footer: {
                    Text("Logs rotate automatically when the file exceeds 4 MB. The previous log is preserved as astral_debug_logs.1.txt.")
                        .scaledFont(.labelSmall.subtext())
                        .foregroundColor(Color.contrastText(.textTertiary))
                }
                // Was the only Settings card left on the system row
                // background, so it read darker than every other card
                // in Settings (Logan screenshots 2026-09-18).
                .listRowBackground(Color.cardBackground)
                .listSectionSeparator(.hidden)

                // MARK: - Playback Engine
                // Logan 2026-09-19: six flag toggles became ONE picker
                // plus a troubleshooting page. No storage key, default or
                // player code changed; the picker just writes the flag
                // COMBINATION that means "AVPlayer" or "mpv", and reads
                // the current combination back to decide what to display.
                Section {
                    SettingsChoicePicker("Playback Engine",
                                         options: engineOptions,
                                         selection: engineSelection,
                                         icon: "play.rectangle.on.rectangle")
                    engineAdvancedGroup
                    forceHLSToggle
                    dumpAudioOnlyToggle
                } header: {
                    Text("Playback Engine")
                        .sectionHeaderStyle()
                } footer: {
                    Text(Self.playbackEngineFooter)
                        .scaledFont(.labelSmall.subtext())
                        .foregroundColor(Color.contrastText(.textTertiary))
                        .padding(.top, 4)
                }
                // The picker and Advanced Engine Flags rows set no row
                // background, so they sat on the system cell color while
                // the Force HLS toggle set cardBackground and read as a
                // separate, lighter card (Logan screenshot 2026-10-07).
                // One background for the whole section, like every other
                // Settings card.
                .listRowBackground(Color.cardBackground)
                .listSectionSeparator(.hidden)


                // MARK: - Experimental UI (iPhone only)
                // Veldmuus-proposal flag. Only show on actual iPhones, the
                // feature doesn't apply to iPad (its layout isn't cramped) or
                // to Mac Catalyst (no UIDevice.phone idiom in the iOS-family
                // sense). When toggled, the compact-chrome layout moves the
                // Manage Groups icon to the nav-bar trailing edge and lets
                // users hide the filter pills + search from inside the sheet.
                if UIDevice.current.userInterfaceIdiom == .phone {
                    Section {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(compactChromeiPhone
                                          ? Color.accentPrimary.opacity(0.18)
                                          : Color.elevatedBackground)
                                    .frame(width: 36, height: 36)
                                Image(systemName: compactChromeiPhone
                                      ? "iphone.gen3.landscape"
                                      : "iphone.gen3")
                                    .scaledFont(.system(size: 16, weight: .medium))
                                    .foregroundColor(compactChromeiPhone ? .accentPrimary : Color.contrastText(.textSecondary))
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("iPhone Compact Chrome")
                                    .scaledFont(.bodyMedium)
                                    .foregroundColor(.textPrimary)
                                Text(compactChromeiPhone
                                     ? "On: Manage Groups lives in the Live TV nav bar"
                                     : "Off: classic layout")
                                    .scaledFont(.labelSmall)
                                    .foregroundColor(compactChromeiPhone ? Color.contrastText(.accentPrimary) : Color.contrastText(.textTertiary))
                            }

                            Spacer()

                            Toggle("", isOn: $compactChromeiPhone)
                                .labelsHidden()
                                .tint(.accentPrimary)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color.cardBackground)

                        // Cast video transcode test switch (2026-09-26):
                        // re-encode any H.264 source on the phone, HEVC when
                        // the receiver presents it, else the H.264 profile
                        // picked below.
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cast: Transcode Video to HEVC (Test)")
                                    .scaledFont(.bodyMedium)
                                    .foregroundColor(.textPrimary)
                                Text("Re-encode every H.264 channel; H.264 profile below when the receiver has no HEVC")
                                    .scaledFont(.labelSmall)
                                    .foregroundColor(Color.contrastText(.textTertiary))
                            }
                            Spacer()
                            Toggle("", isOn: $castForceHEVCTranscode)
                                .labelsHidden()
                                .tint(.accentPrimary)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color.cardBackground)

                        // H.264 output when the receiver cannot present the
                        // source or HEVC: 720p at the source rate, or the
                        // source size at half rate.
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cast: H.264 Transcode Profile")
                                    .scaledFont(.bodyMedium)
                                    .foregroundColor(.textPrimary)
                                Text("720p60 keeps motion; 1080p30 keeps resolution")
                                    .scaledFont(.labelSmall)
                                    .foregroundColor(Color.contrastText(.textTertiary))
                            }
                            Spacer()
                            Picker("", selection: $castTranscodeDownProfile) {
                                Text("720p60").tag("720p60")
                                Text("1080p30").tag("1080p30")
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .tint(.accentPrimary)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color.cardBackground)

                        // Companion toggles, only meaningful when
                        // Compact Chrome is ON. Previously these were
                        // buried inside the Manage Groups sheet, which
                        // made the parent toggle seem inert ("I can't
                        // tell what iPhone Compact Chrome even does").
                        // Surfacing them here means turning Compact
                        // Chrome on immediately reveals its actual
                        // controls, users can see at a glance what
                        // the feature does before toggling sub-options.
                        if compactChromeiPhone {
                            Toggle(isOn: $hideFilterBarCompact) {
                                HStack(spacing: 14) {
                                    DevIconTile(icon: "line.3.horizontal.decrease.circle",
                                                isActive: hideFilterBarCompact)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Hide Filter Bar")
                                            .scaledFont(.bodyMedium)
                                            .foregroundColor(.textPrimary)
                                        Text("Removes the group pills strip above the channel list.")
                                            .scaledFont(.labelSmall.subtext())
                                            .foregroundColor(Color.contrastText(.textTertiary))
                                    }
                                }
                            }
                            .tint(.accentPrimary)
                            .listRowBackground(Color.cardBackground)

                            Toggle(isOn: $hideSearchBarCompact) {
                                HStack(spacing: 14) {
                                    DevIconTile(icon: "magnifyingglass",
                                                isActive: hideSearchBarCompact)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Hide Search Bar")
                                            .scaledFont(.bodyMedium)
                                            .foregroundColor(.textPrimary)
                                        Text("Replaces the always-visible search row with the nav-bar search icon.")
                                            .scaledFont(.labelSmall.subtext())
                                            .foregroundColor(Color.contrastText(.textTertiary))
                                    }
                                }
                            }
                            .tint(.accentPrimary)
                            .listRowBackground(Color.cardBackground)
                        }
                    } header: {
                        Text("Experimental UI")
                            .sectionHeaderStyle()
                    } footer: {
                        Text(compactChromeiPhone
                             ? "Compact Chrome moves Manage Groups into the Live TV nav bar. The two toggles above let you further reclaim vertical space by hiding the filter pills and/or the search row. All three options revert instantly: no restart required."
                             : "Designed for iPhone landscape. When enabled, Manage Groups moves to the nav bar and two further toggles appear for hiding the filter pills and search row. Reverting restores the classic layout instantly."
                        )
                        .scaledFont(.labelSmall.subtext())
                        .foregroundColor(Color.contrastText(.textTertiary))
                        .padding(.top, 4)
                    }
                    .listSectionSeparator(.hidden)
                }

                // MARK: - Log File Actions (only when logging is active or file exists)
                if debugLoggingEnabled || (logger.logFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false) {
                    Section {

                        // File size row
                        HStack(spacing: 14) {
                            DevIconTile(icon: "doc.text", isActive: false)
                            Text("Log File Size")
                                .scaledFont(.bodyMedium)
                                .foregroundColor(.textPrimary)
                            Spacer()
                            // v1.7.x: poll the file size every 2s while the
                            // screen is up. Pre-fix this only refreshed inside
                            // .task(once-on-appear), so a user enabling
                            // logging and watching the row would see "Empty"
                            // until they backed out and re-entered Developer
                            // Settings. Now Empty -> 1 KB -> 5 KB updates
                            // live as the firehose lands in the file, which
                            // is the simplest possible signal that the write
                            // path is actually working.
                            TimelineView(.periodic(from: Date(), by: 2)) { _ in
                                Text(logSize)
                                    .scaledFont(.monoSmall.subtext())
                                    .foregroundColor(Color.contrastText(.textTertiary))
                                    .onAppear { refreshLogSize() }
                                    .onChange(of: Date().timeIntervalSinceReferenceDate) { _, _ in
                                        refreshLogSize()
                                    }
                            }
                        }
                        .listRowBackground(Color.cardBackground)
                        .task { refreshLogSize() }

                        // View
                        // v1.7.x: show this whenever Debug Logging is enabled
                        // OR the file already has bytes on disk. Pre-fix the
                        // guard was file-existence only, but the file is
                        // created lazily on the first write - so users who
                        // just toggled logging on, then opened this screen,
                        // saw no View / Share buttons until they triggered
                        // something log-worthy (a channel play). LogViewerView
                        // and the share path both handle empty content
                        // gracefully, so it is safe to surface the buttons
                        // immediately on enable.
                        if let url = logger.logFileURL,
                           (debugLoggingEnabled || FileManager.default.fileExists(atPath: url.path)) {
                            Button {
                                showLogViewer = true
                            } label: {
                                HStack(spacing: 14) {
                                    DevIconTile(icon: "doc.text.magnifyingglass")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("View Log File")
                                            .scaledFont(.bodyMedium)
                                            .foregroundColor(.textPrimary)
                                        Text("Scroll through entries in the app")
                                            .scaledFont(.labelSmall.subtext())
                                            .foregroundColor(Color.contrastText(.textTertiary))
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                            .listRowBackground(Color.cardBackground)
                            .sheet(isPresented: $showLogViewer) {
                                LogViewerView(url: url)
                            }
                        }

                        // Share, uses a UIKit sheet with proper iPad popover anchoring
                        // (iOS) or a LAN HTTP server + QR sheet (tvOS). Same
                        // relaxed guard as View above so the button appears
                        // the moment Debug Logging is on, not after the
                        // first log flush.
                        if let url = logger.logFileURL,
                           (debugLoggingEnabled || FileManager.default.fileExists(atPath: url.path)) {
                            Button {
                                shareFile(url)
                            } label: {
                                HStack(spacing: 14) {
                                    DevIconTile(icon: "square.and.arrow.up")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Share Log File")
                                            .scaledFont(.bodyMedium)
                                            .foregroundColor(.textPrimary)
                                        Text("Email, Messages, Discord, Signal…")
                                            .scaledFont(.labelSmall.subtext())
                                            .foregroundColor(Color.contrastText(.textTertiary))
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                            // v1.7.x: removed the platform-split buttonStyle.
                            // On tvOS the previous TVNoHighlightButtonStyle()
                            // returned only the label content with a focus-
                            // ring overlay - no card chrome, no padding - and
                            // in a List/Form row it rendered effectively
                            // invisible against the dark background until
                            // focused. The sibling View Log File button right
                            // above this one uses no buttonStyle at all and
                            // gets the default tvOS form-row chrome the user
                            // expects, so match that pattern exactly. iOS
                            // List handles the .plain treatment naturally too.
                            .listRowBackground(Color.cardBackground)
                        }

                        // Clear
                        Button(role: .destructive) {
                            showClearConfirmation = true
                        } label: {
                            HStack(spacing: 14) {
                                DevIconTile(icon: "trash", tint: .red)
                                Text("Delete All Logs")
                                    .scaledFont(.bodyMedium)
                                Spacer(minLength: 0)
                            }
                        }
                        .listRowBackground(Color.cardBackground)

                    } header: {
                        Text("Log File")
                            .sectionHeaderStyle()
                    }
                    .listSectionSeparator(.hidden)
                }



            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            // Phase 3 (Logan 2026-09-18): floating tab bar parity -
            // content runs under the bar, the bar tucks away on scroll,
            // and the last row clears it.
            .settingsPhoneTabBarChrome()
    }

    // MARK: - tvOS Body
    // Uses the shared TVSettings* components so focus highlights match the
    // rest of the tvOS UI. iOS-only rows (Share Log File via
    // UIActivityViewController) are omitted, the log file can still be
    // retrieved via the companion iOS/iPad app or Files app sharing.

    // MARK: - Playback Engine preset
    //
    // The four flags are the real state the player reads (see
    // PlaybackFeatureFlags); this picker is a friendly face over the two
    // combinations that matter. Mapping:
    //
    //   AVPlayer     unified ON,  HLS ON,  remux ON,  mpv OFF  (defaults)
    //   mpv (Legacy) unified ON,  HLS OFF, remux OFF, mpv ON
    //
    // Anything else reads as Custom. `mpvEngineEnabled` is the hinge:
    // with it off, PlaybackFeatureFlags force the AVPlayer arms on
    // regardless of their keys, so "AVPlayer" writes them on explicitly
    // and the displayed value never disagrees with what plays.
    private static let playbackEngineFooter = "AVPlayer is Apple's native player: fast first frame, HDR (PQ) output, surround passthrough and AirPlay. Anything it cannot render falls back automatically when mpv is the selected engine. Live only (VOD always uses the container path). Restart playback for changes to take effect."

    private var enginePreset: PlaybackEnginePreset {
        if unifiedPlayback && avPlayerHLS && avPlayerRemuxTS && !mpvEngineEnabled {
            return .avPlayer
        }
        if unifiedPlayback && !avPlayerHLS && !avPlayerRemuxTS && mpvEngineEnabled {
            return .mpv
        }
        return .custom
    }

    private var engineOptions: [SettingsChoice<PlaybackEnginePreset>] {
        var out: [SettingsChoice<PlaybackEnginePreset>] = [
            SettingsChoice(.avPlayer, "AVPlayer",
                           subtitle: "Default. Apple's player for live, HLS and remuxed TS streams."),
            SettingsChoice(.mpv, "mpv (Legacy)",
                           subtitle: "Fallback engine. Use only if a stream will not play with AVPlayer.")
        ]
        // Only offered while the flags actually are a custom mix, so the
        // collapsed row can display it. Choosing it changes nothing.
        if enginePreset == .custom {
            out.append(SettingsChoice(.custom, "Custom",
                                      subtitle: "Set by hand in Advanced Engine Flags."))
        }
        return out
    }

    private var engineSelection: Binding<PlaybackEnginePreset> {
        Binding(
            get: { enginePreset },
            set: { preset in
                switch preset {
                case .avPlayer:
                    unifiedPlayback = true
                    avPlayerHLS = true
                    avPlayerRemuxTS = true
                    mpvEngineEnabled = false
                case .mpv:
                    unifiedPlayback = true
                    avPlayerHLS = false
                    avPlayerRemuxTS = false
                    mpvEngineEnabled = true
                case .custom:
                    break
                }
            }
        )
    }

    /// The original four flag switches, kept verbatim in wording, behind
    /// one row. Mixed controls, so it is a PAGE on every platform, never
    /// the option sheet.
    private var engineAdvancedGroup: some View {
        SettingsSubgroup("Advanced Engine Flags",
                         summary: "Individual switches for troubleshooting",
                         icon: "slider.horizontal.3",
                         iconColor: theme.accent,
                         footer: "These are set for you by Playback Engine. Change them only when asked to while troubleshooting.") {
            engineFlagToggle(
                title: "Unified Playback",
                subtitle: unifiedPlayback
                    ? "On: required for the AVPlayer engines; also enables multiview"
                    : "Off: legacy single-stream player (mpv only)",
                icon: unifiedPlayback ? "rectangle.stack.fill" : "rectangle.stack",
                isOn: $unifiedPlayback)
            engineFlagToggle(
                title: "AVPlayer for HLS Streams",
                subtitle: avPlayerHLS
                    ? "On: HLS channels play on Apple's AVPlayer (HEVC auto-falls back to mpv)"
                    : "Off: every channel uses the mpv engine",
                icon: avPlayerHLS ? "play.tv.fill" : "play.tv",
                isOn: $avPlayerHLS)
            engineFlagToggle(
                title: "AVPlayer Remux for TS Streams",
                subtitle: avPlayerRemuxTS
                    ? "On: raw MPEG-TS remuxed to HLS for AVPlayer (HEVC/MPEG-2 fall back to mpv)"
                    : "Off: raw TS channels use the mpv engine",
                icon: avPlayerRemuxTS ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle",
                isOn: $avPlayerRemuxTS)
            engineFlagToggle(
                title: "mpv Engine",
                subtitle: mpvEngineEnabled
                    ? "On: mpv is the fallback when AVPlayer can't play something"
                    : "Off: AVPlayer only; unplayable content shows an error",
                icon: mpvEngineEnabled ? "shield.lefthalf.filled" : "shield.slash",
                isOn: $mpvEngineEnabled)
        }
    }

    /// Developer test toggle for Dispatcharr's native HLS output.
    private var forceHLSToggle: some View {
        engineFlagToggle(
            title: "Force HLS",
            subtitle: "Request HLS output from Dispatcharr for every live channel instead of the TS stream. For testing.",
            icon: forceHLS ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right",
            isOn: $forceHLS)
    }

    /// Developer diagnostic: dump the audio-only segments the remuxer serves.
    private var dumpAudioOnlyToggle: some View {
        engineFlagToggle(
            title: "Dump Audio-Only Segments",
            subtitle: "Save every audio-only segment and playlist served to the player in Documents/AudioOnlyDump, starting with the next tune. For testing.",
            icon: dumpAudioOnlySegments ? "square.and.arrow.down.fill" : "square.and.arrow.down",
            isOn: $dumpAudioOnlySegments)
    }

    @ViewBuilder
    private func engineFlagToggle(title: String, subtitle: String,
                                  icon: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Text(subtitle)
                    .scaledFont(.labelSmall.subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
            }
        }
        .tint(theme.accent)
        .listRowBackground(Color.cardBackground)
    }

    // MARK: - Helpers

    private func refreshLogSize() {
        logSize = logger.logFileSizeString
    }

    /// Present a UIActivityViewController with proper iPad popover anchoring
    /// (iOS) or a LAN HTTP server + QR sheet (tvOS).
    private func shareFile(_ url: URL) {
        // v1.7.x: ensure the file exists before we hand it to the share
        // path. Debug Logging is async-buffered, so the user can toggle
        // it on and immediately tap Share with the file not yet flushed
        // to disk. Create an empty placeholder so both iOS's
        // UIActivityViewController and the tvOS LAN server have a real
        // file URL to operate on. The next real log line appends as
        // usual.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
        }
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)

        guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let rootVC = windowScene.windows.first(where: \.isKeyWindow)?.rootViewController else {
            return
        }

        // Walk to the topmost presented controller.
        var presenter = rootVC
        while let next = presenter.presentedViewController { presenter = next }

        // iPad requires a popover anchor, center it in the presenting view.
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 0, height: 0
            )
            popover.permittedArrowDirections = [.up, .down]
        }

        presenter.present(activityVC, animated: true)

    }
}

// MARK: - Log Viewer View

struct LogViewerView: View {
    let url: URL

    @State private var content: String = ""
    @State private var isLoading = true
    @State private var isTruncated = false
    @Environment(\.dismiss) private var dismiss

    private let maxLines = 2_000

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                if isLoading {
                    ProgressView("Loading…")
                        .foregroundColor(.textSecondary)
                } else if content.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .scaledFont(.system(size: 40))
                            .foregroundColor(Color.contrastText(.textTertiary))
                        Text("Log file is empty.")
                            .scaledFont(.bodyMedium.subtext())
                            .foregroundColor(Color.contrastText(.textTertiary))
                    }
                } else {
                    VStack(spacing: 0) {
                        if isTruncated {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                    .scaledFont(.system(size: 12, weight: .semibold))
                                Text("Showing last \(maxLines) lines: share the file for the full log")
                                    .scaledFont(.labelSmall)
                            }
                            .foregroundColor(.statusWarning)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.statusWarning.opacity(0.12))
                        }

                        LogTextView(text: content)
                    }
                }
            }
            .navigationTitle("Log File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.accentPrimary)
                }
            }
            .task { await loadContent() }
        }
    }

    private func loadContent() async {
        let result: (String, Bool) = await Task.detached(priority: .userInitiated) {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
                return ("", false)
            }
            let lines = raw.components(separatedBy: "\n")
            if lines.count > maxLines {
                return (lines.suffix(maxLines).joined(separator: "\n"), true)
            }
            return (raw, false)
        }.value

        content = result.0
        isTruncated = result.1
        isLoading = false
    }
}

// MARK: - Log Text View

#if canImport(UIKit)
private struct LogTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 24, right: 8)
        tv.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textColor = UIColor.label
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        guard uiView.text != text else { return }
        uiView.text = text
        // Scroll to bottom so the newest entries are visible immediately
        DispatchQueue.main.async {
            let bottom = max(0, uiView.contentSize.height - uiView.bounds.height + uiView.contentInset.bottom)
            uiView.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        }
    }
}
#endif

// MARK: - Log Category Row

@MainActor
private func logCategoryRow(icon: String, title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
        // Phase 3: tiled like every other Settings row.
        DevIconTile(icon: icon, tint: .accentSecondary)

        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .scaledFont(.headlineSmall)
                .foregroundColor(.textPrimary)
            Text(detail)
                .scaledFont(.labelSmall.subtext())
                .foregroundColor(Color.contrastText(.textSecondary))
        }
    }
    .padding(.vertical, 4)
}

// MARK: - tvOS Log Share (LAN HTTP server + QR code)



// MARK: - Metal HDR Prototype (Phase 0, feature/hdr-metal, tvOS only)
//
// Answers ONE question: does tvOS pass mpv's HDR (PQ/BT.2020) output through
// a CAMetalLayer + MoltenVK swapchain correctly, with hwdec=videotoolbox in
// DIRECT (zero-copy) mode? Everything here is diagnostic scaffolding around
// that question; none of it is production plumbing. Recipe mirrors MPVKit's
// Demo-tvOS MPVMetalViewController (MPVKit 1.0.0 = mpv 0.41 + libplacebo
// 7.360.1 + MoltenVK 1.4).
//
// Verdict evidence, logged as [METAL-HDR] every 5s:
//   hwdec=videotoolbox (NOT -copy) -> zero-copy confirmed
//   gamma=pq primaries=bt.2020 sig-peak>1 -> HDR passthrough negotiated
//   frame-drop counters -> smoothness vs tonight's 44-71 drops/15s baseline
// Color CORRECTNESS still needs eyes on the TV (Logan's morning review).

// MARK: - Metal HDR autorun (headless driving via devicectl)
//
// Push an empty marker file to Library/Caches/metal_hdr_autorun in the app
// container (devicectl device copy to --domain-type appDataContainer), then
// launch with --terminate-existing. On launch this waits for the channel
// list, presents MetalHDRTestScreen full-screen for `runSeconds`, then
// dismisses itself. Single-shot: the marker is deleted on pickup, so the
// next normal launch is unaffected. Debug builds only (call site is
// #if DEBUG gated in AstralApp).
