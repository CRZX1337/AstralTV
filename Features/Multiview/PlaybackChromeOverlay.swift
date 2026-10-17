import SwiftUI

/// Playback chrome for the unified `MultiviewContainerView`, the
/// parts of the UI that sit *on top* of the tile grid (top bar on
/// iOS, bottom pills on tvOS). Branches on `tiles.count == 1` so
/// the N=1 case gets PlayerView-style top chrome while N>1 relies
/// on the existing `MultiviewTransportBar` docked below.
///
/// Phase C.4 scope, minimum-viable overlay:
/// - iOS N=1: top bar with Close (×) on the right and `+` next to
///   it. Title shown between them. No AirPlay / overflow / scrubber
///   yet, those are a Phase C.6 port of `PlayerView`'s rich chrome.
/// - tvOS N=1: a single `+` pill at bottom-center. Options pill +
///   full per-tile controls come in Phase C.6.
/// - N>1 on either platform: the overlay renders nothing; the
///   existing `MultiviewTransportBar` handles tile count + `+` + `×`.
///
/// Chrome auto-fade is honoured via the injected `MultiviewChromeState`
/// same environment object the transport bar reads, so the top
/// bar fades in/out together with the bottom bar when the user goes
/// idle.
///
/// Focus-halo discipline: every tvOS button uses
/// `TVNoHighlightButtonStyle` (`Components.swift:10`) which
/// suppresses the default white system halo, the ButtonStyle reads
/// `@Environment(\.isFocused)` inside its label to paint its own
/// focus ring. That was the pattern already used for PlayerView's
/// Options pill; adopting it verbatim here avoids the regression
/// we hit in an earlier iteration where the tvOS focus halo fought
/// with our custom chrome.
/// Re-renders only its own subtree when the given progress store
/// publishes, so a transport control can follow the audio tile's
/// position / length / paused state without going through
/// MultiviewStore (which does not republish the nested store).
/// GH #93 follow-up 2026-10-12: the first attempt subscribed with
/// .onReceive to a publisher built inside body; every render made a new
/// publisher, SwiftUI resubscribed, @Published replayed its current value
/// on subscribe, the handler bumped a @State counter, which re-rendered,
/// which resubscribed: a main-thread render loop (9 s lag, playback never
/// started). Observation here is plain @ObservedObject, no writes back.
struct ProgressStoreReader<Content: View>: View {
    @ObservedObject var progress: PlayerProgressStore
    let content: (PlayerProgressStore) -> Content
    var body: some View { content(progress) }
}

struct PlaybackChromeOverlay: View {
    /// Live Rewind engine state (iOS unified chrome): drives the band
    /// swap; its 0.5s window publisher paces position re-render.
    @ObservedObject private var liveRewindIOS = LiveRewindEngine.shared
    @ObservedObject var store: MultiviewStore

    /// Bound from the container. Tapping `+` flips this to `true` so
    /// the container's `.sheet` / `.fullScreenCover` presents the
    /// channel picker. Keeping the sheet state on the container
    /// (instead of here) means the add-sheet survives even if the
    /// chrome overlay itself unmounts for any reason.
    @Binding var showAddSheet: Bool

    /// Bound from the container. `true` while the tvOS Options panel
    /// is showing. Kept on the container (not here) so the panel's
    /// dismiss path in the container's `.onExitCommand` can reach
    /// it, and so the panel's sleep-timer / stream-info bindings
    /// (which are also container-owned @State) live next to the
    /// presentation flag.
    @Binding var showTVOptions: Bool

    /// Sleep-timer + stream-info state bound from the container.
    /// The iOS overflow menu (added in this phase) needs to read and
    /// write both. Declared here as bindings so the container remains
    /// the single source of truth, same rationale as `showTVOptions`.
    @Binding var sleepTimerEnd: Date?
    @Binding var showStreamInfo: Bool

    /// Bound from the container. Tapping the iOS Record button flips
    /// this true; container presents `RecordProgramSheet` via
    /// `.sheet`, matches the pattern used for `showAddSheet`.
    @Binding var showRecordSheet: Bool

    /// Bound from the container. The iOS overflow menu's "Switch Stream"
    /// row flips this true; the container presents `SwitchStreamView`.
    /// Only wired on the iOS (overflow-menu) path; on tvOS the Options
    /// panel drives its own copy in the container.
    @Binding var showSwitchStream: Bool

    /// Drives the 5-second auto-fade of chrome. Container owns it;
    /// we read `isVisible` to gate opacity + hit-testing, and call
    /// `reportInteraction()` on every button action to bump the
    /// timer.
    @EnvironmentObject private var chromeState: MultiviewChromeState

    /// Issue #38: reflects whether the player is currently forcing
    /// landscape, so the fullscreen button shows the correct icon. Synced
    /// from `AppOrientationLock` on appear so it stays right when the
    /// chrome is re-created for a new player session.
    @State private var forcedLandscape = false

    /// GH #33: gates the cast button on device availability. The session
    /// lifecycle itself (local teardown + remote cover) is HomeView's job.
    @ObservedObject private var castController = AstralCastController.shared
    /// GH #33 companion remote: gates the "Control a TV" button on mDNS
    /// discovery of an open AstralTV Android TV app.
    @ObservedObject private var companionClient = CompanionClient.shared
    @State private var showOutputPicker = false

    /// Task #225 section gates for the unified output picker; the same
    /// conditions the three separate buttons used (see the button site).
    private var castPickerCastGate: Bool {
        // P2: the local cast HLS proxy serves ANY raw stream URL; the
        // codec gate happens at load time inside the proxy, so the only
        // structural requirement left is having a stream URL at all.
        castController.state != .unavailable
            && store.tiles.first?.streamURL != nil
    }
    private var castPickerAirPlayGate: Bool {
        store.sessionEngine.isAVPlayer
    }
    private var castPickerCompanionGate: Bool {
        guard !companionClient.devices.isEmpty,
              let tile = store.tiles.first else { return false }
        return CompanionClient.androidChannelID(for: tile.item) != nil
    }

    // v1.6.15: removed `verticalSizeClass` + `isiPhonePortrait`,
    // they only existed to switch between the inline title layout
    // (iPad / iPhone landscape) and the three-line title row
    // (iPhone portrait), both of which are now gone. Channel info
    // lives in `ChannelInfoBanner` (HomeView) instead.

    var body: some View {
        // This overlay ONLY renders the iOS top bar at N=1. tvOS
        // chrome (Options pill + Add pill + live progress band) is
        // mounted inline inside `MultiviewContainerView`'s VStack
        // so the focus engine can route D-pad-down from the tile to
        // the pills, a ZStack overlay doesn't give tvOS the
        // spatial separation it needs. See `PlaybackBottomChrome_tvOS`
        // in this file.
        if store.tiles.count == 1 {
            ZStack {
                // Audio-Only foreground cover. Drawn BEHIND the top
                // chrome so Close / Overflow / + remain tappable, the
                // user needs access to the overflow menu to exit
                // Audio-Only mode. Nothing renders unless the audio
                // tile has its `isAudioOnly` flag set, so the default
                // video-playing case pays zero overhead.
                if let audio = store.audioProgressStore {
                    AudioOnlyForegroundOverlay(
                        progressStore: audio,
                        title: soleTileTitle
                    )
                }
                soleTileChrome_iOS
                    .opacity(chromeState.isVisible ? 1 : 0)
                    .allowsHitTesting(chromeState.isVisible)
                    .animation(.easeInOut(duration: 0.25), value: chromeState.isVisible)
                    .accessibilityHidden(!chromeState.isVisible)
            }
            // v1.6.18: explicitly bypass the parent's safe-area
            // handling. v1.6.17's iPhone-only multiview safe-area
            // carve-out (HomeView's `iOSMultiviewWrapper` dropped
            // the outer `.ignoresSafeArea()` for iPhone) caused this
            // overlay to start at safe-area-top, after which the
            // `dynamicTopInset` formula's own `windowInset + 12`
            // double-counted the Dynamic Island clearance and
            // pushed the Close / Overflow / + buttons too far down
            // in iPhone portrait. Anchoring this overlay at the
            // literal screen top restores the absolute positioning
            // the formula was designed around, chrome y =
            // dynamicTopInset (~71pt on Pro Max portrait), which
            // hugs the Dynamic Island instead of floating ~130pt
            // below it. Landscape was already fine because
            // dynamicTopInset bottoms out at 20pt there.
            .ignoresSafeArea(edges: .top)
        }
        // N > 1 on either platform: transport bar handles chrome,
        // nothing rendered here.
    }

    /// Title of the sole tile (or empty). v1.6.15: no longer used by
    /// the chrome bar (the new `ChannelInfoBanner` in HomeView
    /// covers that), but still consumed by the Audio-Only
    /// foreground overlay, Audio-Only is a fullscreen "no video"
    /// curtain that needs its own readout of which channel is
    /// muted-to-audio.
    private var soleTileTitle: String {
        store.tiles.first?.item.name ?? ""
    }

    /// Dynamic top inset for the N=1 chrome. Adapts to the device in
    /// real time, no hardcoded "iPhone Pro Max needs X pt" branching,
    /// no guessing based on user-agent. Every iPhone, iPad, and Mac
    /// Catalyst layout falls out of the public safe-area / status-bar
    /// APIs. See the comment at the `.padding(.top, dynamicTopInset)`
    /// call site for the full reasoning.
    private var dynamicTopInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first

        // Window safe area inset. `.first { $0.isKeyWindow }` can return
        // nil mid-transition, so we fall back to any window of the scene.
        let windowInset: CGFloat = {
            guard let scene else { return 0 }
            if let key = scene.windows.first(where: { $0.isKeyWindow }) {
                return key.safeAreaInsets.top
            }
            return scene.windows.first?.safeAreaInsets.top ?? 0
        }()

        // Status-bar frame height, an independent measurement that iOS
        // updates alongside layout changes (orientation, status-bar
        // hiding, etc.). Identical to `windowInset` in most cases, but
        // picks up scenarios where the latter was zeroed by an ancestor
        // `.ignoresSafeArea()`.
        let statusBarHeight = scene?.statusBarManager?.statusBarFrame.height ?? 0

        // Per-orientation floor. In landscape on iPhone the reported
        // inset is usually 0 (no status bar; side notch doesn't affect
        // the top edge), so the 48pt floor we used to apply universally
        // pushed the Close / Overflow / Add buttons noticeably lower
        // than they should sit (#22 feedback). Landscape gets a 20pt
        // floor instead, which hugs the top edge while still clearing
        // rounded-corner insets and the hardware camera cutout.
        // Portrait keeps the 48pt floor so the chrome clears a compact
        // Live Activity pill or a short status bar on non-notch phones.
        let idiomIsPhone = UIDevice.current.userInterfaceIdiom == .phone
        let isLandscapePhone: Bool = {
            guard idiomIsPhone else { return false }
            return scene?.interfaceOrientation.isLandscape ?? false
        }()
        let floor: CGFloat = isLandscapePhone ? 20 : 48

        // Take the max so we always pick up the larger of the two
        // reported values, then add a 12pt breathing constant.
        return max(max(windowInset, statusBarHeight) + 12, floor)
    }

    // MARK: - iOS N=1 top bar

    /// iOS top bar for the N=1 case. Layout mirrors today's
    /// PlayerView top bar (Close on the left, Title centred, then
    /// overflow `⋯` and `+` on the right). AirPlay + Stream-Info
    /// overlay join in a later Phase C.6 pass.
    ///
    /// The overflow menu only mounts when we can find the audio
    /// tile's `PlayerProgressStore` via `MultiviewStore.audioProgressStore`
    /// without it we can't bind tracks / speed / PiP toggle to
    /// real state. It's typically non-nil within one frame of
    /// `MultiviewTileView.onAppear` firing, so in practice the user
    /// just sees the menu appear as the tile becomes playable.
    @ViewBuilder
    private var soleTileChrome_iOS: some View {
        VStack(spacing: 0) {
            // Button row. In iPhone portrait we deliberately drop the
            // inline title from this row and mount it on its own full-width
            // row below, otherwise the channel name + program name get
            // squeezed between Close and the Overflow/+ cluster and
            // truncate inside a ~160pt gap that can't hold them.
            HStack(alignment: .center, spacing: 12) {
                closeButton_iOS
                // v1.6.15: title removed from the chrome bar, the
                // new top-left `ChannelInfoBanner` (HomeView) shows
                // channel logo, number, name, program title, and
                // airing window in one place across iPhone, iPad,
                // and Apple TV. The chrome's centered title /
                // iPhone-portrait three-line title stack was
                // duplicating that information.
                Spacer(minLength: 0)
                // Issue #38: rotate-to-fullscreen, iPhone only (iPad already
                // rotates with the device).
                if UIDevice.current.userInterfaceIdiom == .phone {
                    landscapeButton_iOS
                }
                // Task #225: ONE sectioned output picker replaces the three
                // separate Cast / AirPlay / Control-a-TV buttons. The old
                // per-transport gates become section gates inside the sheet:
                // - Google Cast: devices exist AND the channel is basic-
                //   castable (Dispatcharr /proxy/ts/ source; loading a
                //   non-castable channel black-screens the receiver).
                // - AirPlay: VIDEO routes exist only on the AVPlayer engine
                //   (mpv frames never leave the GPU); mpv sessions keep the
                //   audio-only AirPlay entry in the overflow menu.
                // - AstralTV Remote: an AstralTV TV is discovered AND the
                //   playing channel's identity translates.
                // Session start/teardown stays at HomeView scope.
                if castPickerCastGate || castPickerAirPlayGate || castPickerCompanionGate {
                    Button {
                        chromeState.reportInteraction()
                        showOutputPicker = true
                    } label: {
                        ZStack {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                            Image(systemName: "airplay.video")
                                .font(.system(size: 18, weight: .semibold))  // glyph in a fixed box: not text, stays fixed
                                .foregroundStyle(.white)
                        }
                        .frame(width: 52, height: 52)
                    }
                    .accessibilityLabel("Cast or AirPlay")
                    .sheet(isPresented: $showOutputPicker) {
                        CastPickerSheet(
                            showGoogleCast: castPickerCastGate,
                            showAirPlay: castPickerAirPlayGate
                        )
                    }
                }
                if let audio = store.audioProgressStore {
                    iPadOverflowAdapter(
                        progressStore: audio,
                        sleepTimerEnd: $sleepTimerEnd,
                        showStreamInfo: $showStreamInfo,
                        canRecord: canRecordCurrentProgram_iOS,
                        onRecord: {
                            chromeState.reportInteraction()
                            showRecordSheet = true
                        },
                        onSwitchStream: canSwitchStreamForAudioTile ? {
                            chromeState.reportInteraction()
                            showSwitchStream = true
                        } : nil,
                        versionOptions: store.vodSoloTile != nil ? store.vodVersionOptions : [],
                        currentVersionOptionID: store.vodCurrentVersionID,
                        onSelectVersion: store.vodSoloTile == nil ? nil : { store.switchVODVersion($0) },
                        isVODSession: store.vodSoloTile != nil,
                        // Pin the chrome up while the overflow menu (and
                        // its sub-menus) is open; release + restart the
                        // fade clock on dismiss. Without this the 5s
                        // timer could hide the chrome (and the menu's
                        // anchor) out from under the open menu.
                        // NO pin here: SwiftUI Menu's onDisappear is
                        // unreliable (a swallowed close leaked the pin
                        // for two minutes, field-caught 2026-08-26).
                        // A 30s fade grace self-heals instead; a close
                        // that DOES fire restores the normal 5s.
                        onMenuOpen: { chromeState.reportInteractionWithGrace(30) },
                        onMenuClose: { chromeState.reportInteraction() },
                        onRadioMode: RadioModeSession.canEnterFromPlayer
                            ? { RadioModeSession.shared.enterFromPlayer() } : nil
                    )
                }
                // The "+" stays while one channel plays (Logan 2026-10-11);
                // only the in-Multiview chrome dropped its add and layout
                // buttons, which the tile menu covers.
                addButton_iOS
            }
            .padding(.horizontal, 16)
            // Dynamic top inset, not a hardcoded constant, and not a
            // device-specific bump. We read the two public signals iOS
            // exposes for "how far down the chrome should start":
            //
            //   • window.safeAreaInsets.top  → reflects notch / Dynamic
            //     Island cutout on iPhone Pro devices (~59pt) and the
            //     status-bar height on iPad (~24pt) / old iPhones (~20pt)
            //   • statusBarManager.statusBarFrame.height → usually matches
            //     the above but picks up some layouts where safeAreaInsets
            //     is zeroed (e.g., inside an ancestor using
            //     `.ignoresSafeArea()`, which is exactly our situation,
            //     the container zeroes the safe area for its children)
            //
            // The max of the two is "what iOS thinks the top is right
            // now." We add a small constant (12pt) for breathing room
            // and floor at 48pt so the chrome never looks cramped on
            // devices that report abnormally small insets (iPad
            // landscape, older home-button iPhones). No device model
            // probing, no manual bumps per form factor.
            .padding(.top, dynamicTopInset)

            // v1.6.15: removed the iPhone-portrait three-line title
            // stack (channel name / program / time range). The new
            // `ChannelInfoBanner` (HomeView) renders this as a
            // single top-left HUD on every form factor.

            Spacer(minLength: 0)
            // Engine badge moved into the trailing stream readout of the
            // top bar (Logan 2026-10-04), next to resolution and frame rate.
            // Catch-up rides the VOD transport (Logan 2026-09-05: no seek
            // controls in catch-up): the pipeline pins durationMs to the
            // programme length and routes seekAction through the window
            // re-tune, so the drag-to-seek bar and skips work as they are.
            // Stream readout on the transport row like the tvOS band
            // (Logan 2026-10-04): pipeline bottom left, format bottom
            // right, level with the 44 pt transport buttons.
            if store.vodSoloTile != nil || store.catchupTile != nil {
                VODTransportBar_iOS(store: store)
                    .overlay(alignment: .bottom) { streamReadout_iOS }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            } else if liveRewindIOS.buffering {
                RewindTransportBar_iOS(store: store)
                    .overlay(alignment: .bottom) { streamReadout_iOS }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            } else {
                VStack(spacing: 8) {
                    liveProgressBand
                    streamReadout_iOS
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(
            // Top gradient matches the rest of the app's in-player
            // chrome: solid black at the top fading to transparent
            // below, so controls stay legible over video content.
            LinearGradient(
                colors: [Color.black.opacity(0.65), Color.clear],
                startPoint: .top, endPoint: .bottom
            )
            .frame(maxHeight: 140)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false),
            alignment: .top
        )
        // Bottom gradient for the live-progress band readability.
        // Independent from the top gradient so the middle of the
        // video stays untinted.
        .background(
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.55)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(maxHeight: 110)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false),
            alignment: .bottom
        )
        // Keep the fullscreen-toggle icon correct when the chrome is
        // (re)created for a new player session.
        .onAppear { forcedLandscape = AppOrientationLock.isForcingLandscape }
    }

    /// Phone landscape reports a compact vertical size class; iPad and
    /// phone portrait report regular.
    @Environment(\.verticalSizeClass) private var verticalSizeClass_iOS

    /// Same sources and strings as the tvOS band: the engine label from
    /// `store.tileEngines` (only while an AVPlayer engine toggle is on)
    /// and `TVVideoFormatBadge` on the audio tile's progress store.
    /// Hidden on iPhone portrait; scaled per device (iPad 16, phone 12).
    @ViewBuilder
    private var streamReadout_iOS: some View {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        if isPad || verticalSizeClass_iOS == .compact {
            let size: CGFloat = isPad ? 16 : 12
            HStack(spacing: 12) {
                if (PlaybackFeatureFlags.avPlayerForHLS || PlaybackFeatureFlags.avPlayerRemuxTS),
                   let audioID = store.audioTileID,
                   let engine = store.tileEngines[audioID] {
                    Text(engine)
                        .scaledFont(.system(size: size, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, size * 16 / 18)
                        .padding(.vertical, size * 10 / 18)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityLabel("Playback pipeline \(engine)")
                }
                Spacer(minLength: 0)
                if let audioStore = store.audioProgressStore {
                    TVVideoFormatBadge(progress: audioStore, fontSize: size)
                }
            }
            .frame(height: 44)
            .allowsHitTesting(false)
        }
    }

    private var closeButton_iOS: some View {
        Button {
            chromeState.reportInteraction()
            // Issue #38: closing the player must return to the natural
            // orientation. The container's `.onDisappear` is unreliable
            // here (HomeView keeps the container mounted for the mini-
            // player, so it never fires on Close), and `exit()` also runs
            // on channel changes where landscape should persist, so release
            // explicitly at the close action.
            AppOrientationLock.release(reason: "X")
            PlayerSession.shared.stop()
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .semibold))  // glyph in a fixed box: not text, stays fixed
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close player")
        .accessibilityHint("Stop playback and return to the guide")
    }

    // v1.6.15: title helpers removed (`titleLabel_iOS`,
    // `titleInlineLabel_iOS`, `titleStack_iPhonePortrait`,
    // `soleTileTitle`). The new top-left `ChannelInfoBanner`
    // (HomeView) is the single source of truth for "what am I
    // watching" across iPhone, iPad, and Apple TV.

    private var addButton_iOS: some View {
        Button {
            chromeState.reportInteraction()
            showAddSheet = true
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))  // glyph in a fixed box: not text, stays fixed
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add stream")
        .accessibilityHint("Pick another channel to watch alongside this one")
    }

    /// Issue #38: rotate the player into landscape fullscreen on demand,
    /// even when the device is rotation-locked to portrait. iPhone-only
    /// (iPad already rotates freely). Same 52x52 round pill as Close / +.
    private var landscapeButton_iOS: some View {
        Button {
            chromeState.reportInteraction()
            // GH #99: toggle from the lock itself, not this view's copy.
            // The @State survived a release made elsewhere (exit paths),
            // so the next tap "re-released" instead of rotating.
            let next = !AppOrientationLock.isForcingLandscape
            AppOrientationLock.apply(landscape: next, reason: "rotate button")
            forcedLandscape = AppOrientationLock.isForcingLandscape
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
                Image(systemName: forcedLandscape
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 19, weight: .semibold))  // glyph in a fixed box: not text, stays fixed
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(forcedLandscape ? "Exit fullscreen" : "Rotate to fullscreen")
        .accessibilityHint(forcedLandscape ? "Return to portrait" : "Rotate the video into landscape fullscreen")
    }

    /// Record button in the iOS top chrome, same 52×52 round pill
    /// as Close / `+` / AirPlay, with a red record-dot icon to
    /// match the system recording vocabulary. Tapping presents
    /// `RecordProgramSheet` for the audio tile's current program,
    /// saving the user a trip back to the guide + long-press.
    /// True when the audio tile has live EPG data so recording the
    /// currently-playing program is meaningful. Gates the iOS
    /// Record pill availability. v1.6.8 (B1 Phase 1): no longer
    /// gates on EPG, Dispatcharr playlists don't populate
    /// `currentProgram` at load time, so the prior gate hid the
    /// pill permanently. We only need a stream URL to record;
    /// `RecordProgramSheet` handles the missing-EPG case by
    /// falling back to a generic title + default 60-minute
    /// duration the user can override.
    private var canRecordCurrentProgram_iOS: Bool {
        guard let audioID = store.audioTileID,
              let audio = store.tiles.first(where: { $0.id == audioID })
        else { return false }
        return audio.item.streamURL != nil
    }

    /// Whether the audio tile's channel can Switch Stream: a Dispatcharr
    /// channel (has both the integer pk and the proxy uuid) on a Direct
    /// Connect admin server. Gates the iOS overflow-menu "Switch Stream"
    /// row; nil-or-closure is decided from this at the call site.
    private var canSwitchStreamForAudioTile: Bool {
        guard let audioID = store.audioTileID,
              let audio = store.tiles.first(where: { $0.id == audioID }),
              audio.item.dispatcharrChannelID != nil,
              let uuid = audio.item.uuid, !uuid.isEmpty
        else { return false }
        return ChannelStore.shared.activeServer?.dispatcharrCanSwitchStream ?? false
    }


    // MARK: - Live program progress band

    /// Program-name + progress-bar + time-remaining strip, ported
    /// from `PlayerView.liveProgressSection` (`PlayerView.swift:953-1007`).
    /// Reads program metadata off the sole tile's
    /// `ChannelDisplayItem`. Renders nothing when the current
    /// program isn't known (no `currentProgramStart` / `End`),
    /// which keeps the chrome clean at boot and for channels
    /// without EPG data.
    ///
    /// Non-focusable, it's informational. Hardware Play/Pause on
    /// tvOS, on-screen toggle on iOS still drives the Coordinator's
    /// `togglePauseAction`; the band is purely display.
    @ViewBuilder
    private var liveProgressBand: some View {
        if let tile = store.tiles.first,
           let start = tile.item.currentProgramStart,
           let end = tile.item.currentProgramEnd {
            let now = Date()
            let total = end.timeIntervalSince(start)
            let elapsed = now.timeIntervalSince(start)
            let fraction = total > 0 ? min(1, max(0, elapsed / total)) : 0
            let remaining = max(0, end.timeIntervalSince(now))
            let mins = Int(remaining / 60)
            let remainingText = mins > 0 ? "\(mins) min remaining" : "Ending soon"
            let programName = tile.item.currentProgram ?? ""

            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.2))
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 6)

                HStack {
                    if !programName.isEmpty {
                        Text(programName)
                            .scaledFont(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(remainingText)
                        .scaledFont(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                programName.isEmpty
                    ? "\(remainingText)"
                    : "\(programName), \(remainingText)"
            )
        }
    }
}

// MARK: - Live Rewind transport (iOS unified chrome)

/// Live Rewind transport for the iOS unified chrome (locked layout):
/// draggable timeline over [buffer tail .. live edge]; under it the
/// remaining time LEFT and LIVE / behind-live countdown RIGHT;
/// centered skip/pause controls with the Go Live pill on the right
/// while rewound. Actions dispatch through the sole tile's
/// PlayerProgressStore closures into the coordinator's re-tune branch.
/// VOD transport for the iOS unified chrome: the rewind bar's layout
/// over the title's full duration (drag-to-seek timeline, elapsed /
/// total clock, 30s skips, play-pause). Solo-VOD sessions only.
struct VODTransportBar_iOS: View {
    @ObservedObject var store: MultiviewStore
    // Skip Intervals setting; held here so a change re-renders the glyphs.
    @AppStorage(SkipIntervals.backKey) private var skipBackSeconds = SkipIntervals.defaultBack
    @AppStorage(SkipIntervals.forwardKey) private var skipForwardSeconds = SkipIntervals.defaultForward
    @State private var dragFraction: CGFloat? = nil
    @State private var settleTask: Task<Void, Never>? = nil

    var body: some View {
        if let ps = store.audioProgressStore {
            ProgressStoreReader(progress: ps) { bar($0) }
        }
    }

    private func bar(_ ps: PlayerProgressStore) -> some View {
        let duration = Int64(max(Int32(1), ps.durationMs))
        let posMs = Int64(ps.currentMs)
        let current = min(posMs, duration)
        let fraction = dragFraction ?? CGFloat(Double(current) / Double(duration))
        let isPaused = ps.isPaused

        return VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule().fill(Color.accentColor)
                        .frame(width: geo.size.width * max(0, min(1, fraction)))
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .offset(x: geo.size.width * max(0, min(1, fraction)) - 7)
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            settleTask?.cancel()
                            dragFraction = max(0, min(1, v.location.x / geo.size.width))
                        }
                        .onEnded { v in
                            let f = max(0, min(1, v.location.x / geo.size.width))
                            let target = Int32(Double(duration) * Double(f))
                            store.audioProgressStore?.seekAction?(target)
                            // Hold the bar at the released spot until playback
                            // actually lands near it. Dropping dragFraction
                            // immediately rubber-banded the thumb back to the
                            // stale pre-seek position for the seconds the MKV
                            // remuxer spends reopening at the new offset, then
                            // jumped it forward (tester 2026-08-31, iPad).
                            settleTask?.cancel()
                            settleTask = Task { @MainActor in
                                for _ in 0..<188 {  // ~15s backstop at 80ms
                                    if Task.isCancelled { return }
                                    let cur = store.audioProgressStore?.currentMs ?? 0
                                    if abs(Int64(cur) - Int64(target)) < 4_000 { break }
                                    try? await Task.sleep(nanoseconds: 80_000_000)
                                }
                                guard !Task.isCancelled else { return }
                                dragFraction = nil
                            }
                        }
                )
                .padding(.vertical, -12)
            }
            .frame(height: 14)

            HStack {
                Text(Self.clock(Int32(clamping: dragFraction.map { Int64(Double(duration) * Double($0)) } ?? current)))
                    .scaledFont(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .monospacedDigit()
                Spacer()
                Text(Self.clock(Int32(clamping: duration)))
                    .scaledFont(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .monospacedDigit()
            }

            HStack(spacing: 26) {
                vodButton(SkipIntervals.backSymbol(skipBackSeconds)) {
                    if let ps = store.audioProgressStore {
                        ps.seekAction?(max(0, ps.currentMs - SkipIntervals.backMs))
                    }
                }
                .accessibilityLabel(SkipIntervals.backLabel(skipBackSeconds))
                vodButton(isPaused ? "play.fill" : "pause.fill") {
                    store.audioProgressStore?.userTogglePause()
                }
                vodButton(SkipIntervals.forwardSymbol(skipForwardSeconds)) {
                    if let ps = store.audioProgressStore {
                        ps.seekAction?(min(Int32(clamping: duration), ps.currentMs + SkipIntervals.forwardMs))
                    }
                }
                .accessibilityLabel(SkipIntervals.forwardLabel(skipForwardSeconds))
            }
            .padding(.top, 2)
        }
    }

    private func vodButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))  // glyph in a fixed box: not text, stays fixed
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.55), in: Circle())
        }
    }

    private static func clock(_ ms: Int32) -> String {
        let total = Int(ms) / 1000
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct RewindTransportBar_iOS: View {
    @ObservedObject var store: MultiviewStore
    @ObservedObject private var liveRewind = LiveRewindEngine.shared
    // Skip Intervals setting; held here so a change re-renders the glyphs.
    @AppStorage(SkipIntervals.backKey) private var skipBackSeconds = SkipIntervals.defaultBack
    @AppStorage(SkipIntervals.forwardKey) private var skipForwardSeconds = SkipIntervals.defaultForward
    @State private var dragFraction: CGFloat? = nil

    var body: some View {
        let window = max(Int64(1), liveRewind.headWallMs - liveRewind.tailWallMs)
        let posMs = Int64(store.audioProgressStore?.currentMs ?? 0)
        let current = liveRewind.timeshifting ? min(posMs, window) : window
        let fraction = dragFraction ?? CGFloat(Double(current) / Double(window))
        let behindMs = window - current
        let isPaused = store.audioProgressStore?.isPaused ?? false

        VStack(spacing: 6) {
            // Timeline: tap/drag to scrub anywhere in the window.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule().fill(Color.accentColor)
                        .frame(width: geo.size.width * max(0, min(1, fraction)))
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .offset(x: geo.size.width * max(0, min(1, fraction)) - 7)
                }
                // The player surface owns competing drag gestures (the
                // swipe-up/down channel flip most notably), which were
                // swallowing the scrub drag. High priority makes the
                // timeline win while a finger is ON it, and the padded
                // contentShape gives the thumb a real touch target.
                .padding(.vertical, 12)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            dragFraction = max(0, min(1, v.location.x / geo.size.width))
                        }
                        .onEnded { v in
                            let f = max(0, min(1, v.location.x / geo.size.width))
                            dragFraction = nil
                            store.audioProgressStore?.seekAction?(Int32(Double(window) * Double(f)))
                        }
                )
                .padding(.vertical, -12)
            }
            .frame(height: 14)

            // Status line: remaining LEFT, LIVE / behind RIGHT.
            HStack {
                if let end = store.tiles.first?.item.currentProgramEnd {
                    let wall = liveRewind.tailWallMs + current
                    let rem = max(0, Int64(end.timeIntervalSince1970 * 1000) - wall)
                    let mins = Int(rem / 60_000)
                    Text(mins >= 60 ? "\(mins / 60) h \(mins % 60) min remaining"
                         : (mins > 0 ? "\(mins) min remaining" : "Ending soon"))
                        .scaledFont(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                HStack(spacing: 4) {
                    if !(liveRewind.timeshifting && behindMs > 5_000) {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                    }
                    Text(liveRewind.timeshifting && behindMs > 5_000
                         ? String(format: "-%d:%02d", behindMs / 60_000, (behindMs / 1000) % 60)
                         : "LIVE")
                        .scaledFont(.system(size: 12, weight: .bold))
                        .foregroundStyle(liveRewind.timeshifting && behindMs > 5_000
                                         ? Color.white.opacity(0.8) : Color.white)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    store.audioProgressStore?.seekAction?(Int32(clamping: window))
                }
            }

            // Controls: centered skip/pause cluster; Go Live pill
            // anchors right without disturbing the centering.
            ZStack {
                HStack(spacing: 26) {
                    transportButton(SkipIntervals.backSymbol(skipBackSeconds)) {
                        if let ps = store.audioProgressStore {
                            ps.seekAction?(max(0, (liveRewind.timeshifting ? ps.currentMs : Int32(clamping: window)) - SkipIntervals.backMs))
                        }
                    }
                    .accessibilityLabel(SkipIntervals.backLabel(skipBackSeconds))
                    if let ps = store.audioProgressStore {
                        ProgressStoreReader(progress: ps) { p in
                            transportButton(p.isPaused ? "play.fill" : "pause.fill") {
                                p.userTogglePause()
                            }
                        }
                    } else {
                        transportButton(isPaused ? "play.fill" : "pause.fill") {}
                    }
                    transportButton(SkipIntervals.forwardSymbol(skipForwardSeconds)) {
                        if let ps = store.audioProgressStore {
                            ps.seekAction?((liveRewind.timeshifting ? ps.currentMs : Int32(clamping: window)) + SkipIntervals.forwardMs)
                        }
                    }
                    .accessibilityLabel(SkipIntervals.forwardLabel(skipForwardSeconds))
                }
                if liveRewind.timeshifting {
                    HStack {
                        Spacer()
                        Button {
                            store.audioProgressStore?.seekAction?(Int32(clamping: window))
                        } label: {
                            Text("Go Live")
                                .scaledFont(.system(size: 12, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.accentColor, in: Capsule())
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func transportButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))  // glyph in a fixed box: not text, stays fixed
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.55), in: Circle())
        }
    }
}

// MARK: - iPadOS overflow-menu adapter

/// Thin wrapper that `@ObservedObject`s the audio tile's
/// `PlayerProgressStore` so SwiftUI re-renders the overflow menu
/// when audio/subtitle track lists, speed, sleep timer, or PiP
/// state change. Declared as a nested struct because `@ObservedObject`
/// has to live on a `View` and `PlaybackChromeOverlay` doesn't
/// directly hold the store (the store lookup is conditional on the
/// audio tile being registered, which happens asynchronously).
///
/// Wiring notes:
/// - Picture-in-Picture has no menu entry, PiP is swipe-home-only
///   (auto-PiP) and is gated by the Settings toggle. The
///   single-stream Coordinator builds the AVPictureInPictureController
///   eagerly in `makeUIViewController`; multiview currently does not
///   auto-PiP (known gap).
/// - `toggleStreamInfo` is a cosmetic state flip for now, the
///   stream-info overlay is a later Phase C.6 port.
/// - `toggleAudioOnly` mutates `progressStore.isAudioOnly` on the
///   audio tile's store. `PlaybackChromeOverlay` observes the same
///   store via `AudioOnlyForegroundOverlay` (below) and renders the
///   dark-wash + artwork foreground treatment when the flag is set.
///   Background-audio discipline (audio keeps playing with the app
///   closed when Audio-Only is on) is already honoured by
///   `Coordinator.didEnterBackground` via the same flag.
/// - `onMenuOpen`/`Close` pin `MultiviewChromeState` while the overflow
///   menu (and its nested sub-menus: Audio Track, Subtitles, Speed,
///   Aspect, Sleep Timer, Audio Only, AirPlay) is open, so the
///   auto-hiding chrome can't fade out from under the open menu after
///   the 5s timer. v1.7.x: this was previously a no-op on the
///   assumption that menu interaction already drove the chrome timer,
///   but opening the SwiftUI `Menu` does not call `reportInteraction()`,
///   so a stale fade could fire mid-menu. Now matches the tvOS pin on
///   `showTVOptions`.
private struct iPadOverflowAdapter: View {
    @ObservedObject var progressStore: PlayerProgressStore
    @Binding var sleepTimerEnd: Date?
    @Binding var showStreamInfo: Bool
    /// Gates the "Record Current Program" menu item. Passed down from
    /// `PlaybackChromeOverlay` which computes it from the audio tile's
    /// live EPG state (`canRecordCurrentProgram_iOS`).
    let canRecord: Bool
    /// Fired from the menu. The overlay flips `showRecordSheet` so the
    /// container presents `RecordProgramSheet`.
    let onRecord: () -> Void
    /// Switch Stream (Dispatcharr Direct Connect, admin only). Non-nil
    /// only when the audio tile's channel is eligible; flips
    /// `showSwitchStream` so the container presents `SwitchStreamView`.
    var onSwitchStream: (() -> Void)? = nil
    /// Switch Version for a solo VOD tile (container parity with the
    /// legacy cover; same store-driven context the tvOS panel reads).
    var versionOptions: [VODVersionOption] = []
    var currentVersionOptionID: Int? = nil
    var onSelectVersion: ((VODVersionOption) -> Void)? = nil
    /// True while the session is a solo VOD play; drives the menu's
    /// live-only gating truthfully.
    var isVODSession: Bool = false
    /// Pin / unpin the auto-hiding chrome while the menu popover is open
    /// (fired from `PlayerOverflowMenu`'s `.onAppear`/`.onDisappear`
    /// under `#if os(iOS)`). See the type doc comment.
    var onMenuOpen: (() -> Void)? = nil
    var onMenuClose: (() -> Void)? = nil
    /// Radio Mode (live single channel, local playback only); nil hides it.
    var onRadioMode: (() -> Void)? = nil

    var body: some View {
        PlayerOverflowMenu(
            versionOptions: versionOptions,
            currentVersionOptionID: currentVersionOptionID,
            switchVersionAction: onSelectVersion,
            audioTracks: progressStore.audioTracks,
            currentAudioTrackID: progressStore.currentAudioTrackID,
            subtitleTracks: progressStore.subtitleTracks,
            currentSubtitleTrackID: progressStore.currentSubtitleTrackID,
            speed: progressStore.speed,
            isLive: !isVODSession,
            sleepTimerEnd: sleepTimerEnd,
            showStreamInfo: showStreamInfo,
            isAudioOnly: progressStore.isAudioOnly,
            aspectMode: progressStore.aspectMode,
            canRecord: canRecord,
            audioSyncMs: progressStore.audioSyncMs,
            setAudioTrack: { [weak progressStore] in progressStore?.setAudioTrackAction?($0) },
            setAudioSync: progressStore.setAudioSyncAction == nil
                ? nil
                : { [weak progressStore] in progressStore?.setAudioSyncAction?($0) },
            setSubtitleTrack: { [weak progressStore] in progressStore?.setSubtitleTrackAction?($0) },
            setSpeed: { [weak progressStore] in progressStore?.setSpeedAction?($0) },
            setVideoScale: { [weak progressStore] in progressStore?.setVideoScale($0) },
            setSleepTimer: { newEnd in sleepTimerEnd = newEnd },
            toggleStreamInfo: { showStreamInfo.toggle() },
            recordAction: onRecord,
            switchStreamAction: onSwitchStream,
            radioModeAction: onRadioMode,
            onMenuOpen: onMenuOpen,
            onMenuClose: onMenuClose
        )
    }
}

// MARK: - Audio-Only foreground overlay

/// Dark-wash cover drawn over the sole video tile when the user has
/// flipped Audio Only in the overflow menu. Mirrors the legacy
/// `PlayerView.audioOnlyBackground` visual treatment (gradient +
/// music-note circle + channel name + "Audio Only" caption) so the
/// unified-player path looks the same to the user.
///
/// We deliberately do NOT touch mpv's `vid` property from the
/// foreground, parity with legacy behaviour. The video tile keeps
/// decoding underneath us; this overlay simply hides it. The GPU
/// cost is acceptable for the foreground case; the real power saving
/// kicks in on swipe-home, where `Coordinator.didEnterBackground`
/// sets `vid=no` for audio-only mode.
///
/// Separated from `iPadOverflowAdapter` so it can mount at the
/// chrome-overlay level (behind the top bar) rather than inside the
/// HStack of menu buttons.
private struct AudioOnlyForegroundOverlay: View {
    @ObservedObject var progressStore: PlayerProgressStore
    let title: String

    var body: some View {
        ZStack {
            if progressStore.isAudioOnly {
                ZStack {
                    LinearGradient(
                        colors: [Color(hex: "0A0F0D"), Color(hex: "111916")],
                        startPoint: .top, endPoint: .bottom
                    )
                    .ignoresSafeArea()

                    VStack(spacing: 24) {
                        ZStack {
                            Circle()
                                .fill(Color.accentPrimary.opacity(0.15))
                                .frame(width: 140, height: 140)
                            Image(systemName: "music.note")
                                .scaledFont(.system(size: 56, weight: .light))
                                .foregroundStyle(LinearGradient.accentGradient)
                        }
                        .shadow(color: Color.accentPrimary.opacity(0.3), radius: 30)

                        Text(title)
                            .scaledFont(.title2.bold())
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)

                        Text("Audio Only")
                            .scaledFont(.subheadline)
                            .foregroundColor(.gray)
                    }
                }
                .transition(.opacity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Audio only: \(title)")
                .accessibilityHint("Video is hidden. Audio continues playing. Tap the options button to show video.")
            }
        }
        // Animate flag transitions even when the parent doesn't wrap
        // the toggle in withAnimation. Keeps the fade consistent across
        // entry points (menu tap here, mirroring from elsewhere later).
        .animation(.easeInOut(duration: 0.25), value: progressStore.isAudioOnly)
    }
}

// MARK: - tvOS bottom chrome (inline below the tile)


/// Resolution + frame rate readout for the tvOS player band, e.g.
/// "1080p \u{00B7} 59.94 fps" (Logan 2026-09-11). Mirrors the engine
/// badge's capsule at the other edge, but it is NOT a dev aid: it shows
/// whenever the format is known. The frame rate is omitted while
/// unknown, and the whole badge stays away until something is known.
///
/// Source is `StreamInfo`, which both engines already fill: the AVPlayer
/// driver from the item's `presentationSize` KVO plus the video track's
/// `nominalFrameRate` / `currentVideoFrameRate`, and mpv from
/// `video-params/w`,`/h` with `estimated-vf-fps` falling back to
/// `container-fps`. Both repopulate on every item / track change, so the
/// badge follows a channel flip or a version switch on its own.
struct TVVideoFormatBadge: View {
    /// OBSERVED, not read once: `streamInfo` is published and lands late
    /// (resolution on the presentationSize callback, frame rate once
    /// frames render), so the badge has to re-render with it.
    @ObservedObject var progress: PlayerProgressStore
    /// Text size. tvOS keeps 18; the iOS chrome passes a device-scaled
    /// size (iPad near the TV size, iPhone landscape smaller).
    var fontSize: CGFloat = 18

    private var info: StreamInfo? { progress.streamInfo }

    /// Audio-only program (GH #90): "AAC 48 kHz · 128 kbps", the bitrate
    /// part omitted when unknown. Android parity wording.
    static func audioText(for info: StreamInfo?) -> String? {
        guard let info else { return nil }
        let raw = info.audioCodec.trimmingCharacters(in: .whitespaces).lowercased()
        let codec: String
        switch raw {
        case "": return nil
        case "aac", "mp4a", "aach", "aacl": codec = "AAC"
        case "ac-3", "ac3": codec = "AC-3"
        case "ec-3", "eac3", "e-ac-3": codec = "E-AC-3"
        case ".mp3", "mp3": codec = "MP3"
        case ".mp2", "mp2", ".mp1", "mp1": codec = "MP2"
        default: codec = raw.uppercased()
        }
        var out = codec
        if info.sampleRate > 0 {
            let khz = Double(info.sampleRate) / 1000
            let isWhole = abs(khz - khz.rounded()) < 0.05
            out += " " + (isWhole ? String(Int(khz.rounded())) : String(format: "%.1f", khz)) + " kHz"
        }
        if info.bitrate > 0 {
            out += " \u{00B7} \(Int((info.bitrate * 8 / 1000).rounded())) kbps"
        }
        return out
    }

    static func text(for info: StreamInfo?) -> String? {
        guard let info, info.height > 0 else { return nil }
        // "i" for an interlaced source (broadcast 1080i), "p" otherwise.
        var out = "\(info.height)\(info.isInterlaced ? "i" : "p")"
        if info.fps > 0 {
            let rounded = (info.fps * 100).rounded() / 100
            let isWhole = abs(rounded - rounded.rounded()) < 0.005
            let rate = isWhole
                ? String(Int(rounded.rounded()))
                : String(format: "%.2f", rounded)
            out += " \u{00B7} \(rate) fps"
        }
        return out
    }

    var body: some View {
        if let text = progress.isAudioOnlyProgram ? Self.audioText(for: info) : Self.text(for: info) {
            Text(text)
                .scaledFont(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, fontSize * 16 / 18)
                .padding(.vertical, fontSize * 10 / 18)
                .background(.ultraThinMaterial, in: Capsule())
                .accessibilityLabel(progress.isAudioOnlyProgram ? "Audio format \(text)" : "Video format \(text)")
        }
    }
}

