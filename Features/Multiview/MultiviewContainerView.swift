import SwiftUI

/// Root view of the multiview experience. Composites:
/// - `MultiviewLayoutView` for the animated grid of `MultiviewTileView`s
///   (replaced with a single expanded tile when `fullscreenTileID` is
///   set).
/// - `MultiviewTransportBar` docked at the bottom.
/// - Channel-picker sheet (placeholder here, the real one lands in
///   Phase 5 as `AddToMultiviewSheet`).
/// - Relocate-mode banner (tvOS only, when a tile is being moved).
///
/// Wiring:
/// - Tap "Exit" in the transport bar → `PlayerSession.exit()` which
///   resets the tile list + flips mode back to `.idle`. The parent
///   view (HomeView's mode branch, Phase 4) then tears this view down
///   and shows the Live TV guide.
/// - Tap "Add Tile" → presents the add sheet.
/// - `.focusSection()` on the grid container so tvOS D-pad doesn't
///   escape to the tab bar mid-grid (see plan's focus-engine note).
struct MultiviewContainerView: View {
    /// The N>=2 bottom transport bar (counter, + and X). tvOS dropped it
    /// 2026-10-11 (Menu confirms exit, Add Channel is in the tile menu).
    private static let showsGridTransportBar = true
    @ObservedObject private var store = MultiviewStore.shared
    @ObservedObject private var session = PlayerSession.shared
    /// Watched so the tvOS tile focus can be released the instant
    /// the user minimizes to the corner. The @FocusState binding
    /// below (`focusedTileID`) pins focus to the audio tile during
    /// normal playback, on minimize we explicitly clear it so the
    /// tile drops out of the focus engine's consideration and focus
    /// flows to the guide beneath. Without this observer the
    /// binding stays stale and focus stays trapped in the corner.
    @ObservedObject private var nowPlaying = NowPlayingManager.shared
    /// Phone-side Multiview composite (2026-10-06): an AirPlay composite is
    /// carried by a hidden tile playing the composite TS.
    @ObservedObject private var mvComposite = MultiviewCompositeSession.shared
    @StateObject private var compositeProgress = PlayerProgressStore()

    /// Round 9: while a phone composite feeds a receiver the tiles stay in
    /// the grid branch at one tile, so the remaining tile is not re-mounted
    /// (a re-mount restarts its player and ingest, and the composite's
    /// picture of it would hold for the channel's first-byte time).
    private var compositeKeepsGrid: Bool {
        mvComposite.isActive
    }

    /// When `true`, the add-channel sheet is presented. Wired to the
    /// transport bar's "Add Tile" button.
    @State private var showAddSheet: Bool = false
    // Per-tile menu panel + native Switch Stream dialog (2026-08-28).
    @State private var switchDialogVisible = false
    @State private var switchDialogOptions: [SwitchStreamFlow.Option] = []
    @State private var switchDialogChannelName = ""
    @State private var switchDialogUUID = ""
    @State private var switchDialogError = false
    /// The failure line for the "Stream Not Switched" alert (denial, HTTP
    /// failure, or unconfirmed), worded like the player path.
    @State private var switchDialogErrorMessage = SwitchStreamFlow.switchNotConfirmedMessage

    /// Presentation for the Swap Stream picker. There is no separate
    /// Bool: the store's `pendingSwapTileID` IS the state, so the tile
    /// menu can raise the picker from anywhere in the tree by setting
    /// it, and dismissing clears the target in the same gesture.
    private var swapSheetBinding: Binding<Bool> {
        Binding(
            get: { store.pendingSwapTileID != nil },
            set: { if !$0 { store.pendingSwapTileID = nil } }
        )
    }

    /// When `true`, the exit-confirmation dialog is presented. Set by
    /// the second Menu/Back press (first press summons the chrome;
    /// second press prompts for confirmation instead of exiting
    /// immediately, prevents accidental fat-thumb Menu-spams from
    /// nuking the user's carefully arranged multiview).
    ///
    /// The dialog's wording + action differ by tile count:
    ///   - N=1 on unified path: "Exit playback?" → `session.stop()`
    ///   - N>=2 (or legacy)  : "Exit multiview?" → collapse to the
    ///     audio tile via `exitMultiviewKeepingAudioTile()` (unified
    ///     stays in the container at N=1; legacy swaps to PlayerView).
    @State private var showExitConfirmation: Bool = false
    /// Exit dialog logging: what presented it, and which button closed it
    /// (nil when the system dismissed it, i.e. Menu).
    @State private var exitDialogSource = ""
    @State private var exitDialogDismissReason: String?

    /// When `true` at N=1 on the unified path, the Options panel
    /// (audio / subtitles / sleep timer / stream info) is overlaid
    /// above the tile. Wired to the Options pill in
    /// `PlaybackChromeOverlay`. Declared cross-platform (not behind
    /// `#if os(tvOS)`) because the `PlaybackChromeOverlay` struct
    /// signature needs a non-optional Binding at compile time; iOS
    /// simply never flips the flag so the panel never mounts (and
    /// the panel itself is wrapped in `#if os(tvOS)` anyway).
    @State private var showTVOptions: Bool = false

    /// Presents the `RecordProgramSheet` for the audio tile's
    /// currently-playing program. Triggered by the Record pill in
    /// the tvOS bottom chrome / the iOS record button, so the user
    /// can schedule a recording without going back to the guide
    /// and long-pressing. Only effective when the audio tile has a
    /// non-nil `currentProgram` (EPG data loaded), the pill itself
    /// is gated on that condition.
    @State private var showRecordSheet: Bool = false

    /// iOS ONLY: presents `SwitchStreamView` as a `.sheet` (flipped by the
    /// iOS overflow menu via `PlaybackChromeOverlay`).
    @State private var showSwitchStream: Bool = false

    /// tvOS ONLY: the Switch Stream picker is a SECOND PAGE inside the
    /// Options-panel presentation (`showTVOptions`), not a separate overlay
    /// so it inherits the panel's proven focus trap and touches none of
    /// the bottom-chrome focus/pin machinery. True = show the stream list
    /// in place of the options list while `showTVOptions` stays true.
    @State private var streamPickerVisible: Bool = false


    /// In-session Switch Stream selection, kept here (not in the picker,
    /// which is recreated each open) so re-opening the picker shows the
    /// stream the user actually switched to, `/status.stream_id` goes
    /// stale right after a switch, so it can't be trusted on re-open.
    /// Keyed by channel uuid; a channel change makes it resolve to nil.
    @State private var switchedStreamChannelUUID: String?
    @State private var switchedStreamID: Int?

    /// Sleep-timer state for the Options panel. Lives on the
    /// container so it survives panel dismissals and is shared
    /// between the timer-countdown loop and the Options UI. Was
    /// previously owned by `PlayerRootView`; ported as part of the
    /// PlayerView chrome absorb.
    @State private var sleepTimerEnd: Date? = nil

    /// Stream-info overlay toggle for the Options panel. Same
    /// rationale as `sleepTimerEnd`: container-owned so the panel
    /// binding + future stream-info overlay mount stay in sync.
    /// Phase C.6 mounts the actual overlay; for now the Options
    /// panel's toggle flips this flag with no visible effect in
    /// the unified path (still fires in the legacy path's
    /// `PlayerView`, which is unaffected).
    @State private var showStreamInfo: Bool = false


    /// tvOS default-focus namespace. The audio tile opts into this
    /// so the first tvOS-focus pass when entering multiview lands on
    /// the seed / audio tile (the one the user was JUST watching)
    /// rather than letting the focus engine pick an arbitrary tile
    /// the add-sheet or the transport bar. Without this, the first
    /// thing that lights up can be "Add Tile", which reads as
    /// "do something new" when the user just wants to see their
    /// channel continue playing.

    /// Drives the 5-second auto-fade of multiview chrome (transport
    /// bar, audio badge on each tile, channel label on each tile).
    /// Owned here; injected into children via `.environmentObject`
    /// so the tile view + transport bar can read `isVisible` and
    /// call `reportInteraction()` from their button actions.
    @StateObject private var chromeState = MultiviewChromeState()

    /// Settings → Multiview → "Padding Between Tiles". true (the
    /// default as of v1.7.4) inserts an 8pt gap between tiles so each
    /// stream stands on its own; false keeps adjacent tiles meeting
    /// flush like the original multiview design.
    @AppStorage(multiviewTilePaddingKey)
    private var paddingEnabled: Bool = true

    /// Resolved spacing for the grid math, derived from the user's
    /// preference. 0pt is the legacy flush layout; 8pt is the
    /// "padded" layout (the default as of v1.7.4).
    private var tileSpacing: CGFloat { paddingEnabled ? 8 : 0 }

    /// Issue #48: the user-selected multiview layout shape (Default /
    /// Even Grid / Spotlight / Hero + Corner). Picked live from the player
    /// Options panel; `.auto` preserves the historical per-count layout.
    @AppStorage(MultiviewLayoutMode.storageKey)
    private var layoutMode: MultiviewLayoutMode = .auto

    /// v1.7.x: gates the Apple TV up/down d-pad channel-flip on
    /// single-tile (N=1) playback in the unified-multiview path.
    /// Default ON. Surfaced in Settings → App Behaviors → Apple TV
    /// Remote and shared with `PlayerView` via the same storage
    /// key so the user has one canonical preference.
    @AppStorage("appBehaviorsAppleTVChannelFlip")
    private var appleTVChannelFlip = true

    /// True while an In-Player edge slide owns the touch.
    @ObservedObject private var edgeAdjust = EdgeAdjustState.shared


    /// Top-strip swipe down (Logan 2026-09-14): how far the player follows
    /// the finger, and the container height the strip is measured against
    /// (the same local space the drag gestures report in).
    @State private var topStripDragOffset: CGFloat = 0
    @State private var containerHeight: CGFloat = 0

    /// The AirPlay composite's carrier: an ordinary live tile (its own
    /// TSHLSRemuxer, AirPlayTileDelivery and LAN playlist) on the composite
    /// loopback TS, invisible on the phone. It owns the AirPlay route
    /// (MultiviewCompositeTaps.ownsAirPlay) while the real tiles stay local.
    @ViewBuilder
    private var compositeAirPlayTile: some View {
        if let url = mvComposite.airPlayTileURL {
            AVPlayerMultiviewTile(
                tileID: MultiviewCompositeTaps.compositeTileID,
                streamURL: url,
                headers: [:],
                shouldPause: false,
                channelName: "Multiview",
                progressStore: compositeProgress,
                onEngineFallback: { reason in
                    debugLog("[MV-CAST] composite AirPlay tile failed (\(reason))")
                    MultiviewCompositeSession.shared.stop(detail: "airplay tile failed", endTransport: true)
                }
            )
            .frame(width: 2, height: 2)
            .opacity(0.01)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var topStripSwipeEligible: Bool {
        store.tiles.count == 1 && !nowPlaying.isMinimized
    }

    /// Commit of the top-strip swipe down. NowPlayingManager.minimize()
    /// routes by idiom: iPhone hides the host at once and starts system PiP
    /// (springs back fullscreen when PiP can't run); iPad takes the corner
    /// mini.
    private func performTopStripSwipeDown() {
        DebugLogger.shared.log(
            "[MV-Cmd] top-strip swipe down → minimize (iPhone = foreground PiP)",
            category: "Playback", level: .info
        )
        if store.vodSoloTile != nil { store.saveVODProgressNow() }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            topStripDragOffset = 0
        }
        NowPlayingManager.shared.minimize()
    }

    var body: some View {
        // GH #71: digit keys tune the sole live tile through the same
        // path the Channels overlay pick uses (`tuneDirect`). Only the
        // full-screen single live tile listens; multiview grids, VOD
        // and the minimized mini-player leave digits alone.
        containerBody
            .offset(y: topStripDragOffset)
            .background(compositeAirPlayTile)
            .channelNumberEntry(
                scope: .player,
                isActive: store.tiles.count == 1
                    && !nowPlaying.isMinimized
                    && (store.tiles.first?.kind ?? .live) == .live,
                channels: { ChannelStore.shared.channels },
                onResolve: { item in nowPlaying.tuneDirect(item) }
            )
    }

    @ViewBuilder
    private var containerBody: some View {
        // N=1 treatment, "this is effectively PlayerView", is
        // gated on the unified-playback feature flag. Without the
        // flag, legacy users can still hit N=1 (e.g. by removing a
        // tile from N=2 via its per-tile ×) and we MUST NOT change
        // their UX: leave transport bar visible, leave per-tile
        // chrome + close buttons in place, don't mount the new
        // overlay. The flag is the single contract that says
        // "the user has opted into the unified playback path."
        //
        // Phase C.4 lands the minimum overlay at N=1 (Close + `+`
        // on iOS, `+` pill on tvOS) for flag-on users only; Phase
        // C.6 adds scrubber, options panel, AirPlay, stream info,
        // mini-player.
        let unifiedPath = PlaybackFeatureFlags.useUnifiedPlayback
        let isSoleTile = unifiedPath && store.tiles.count == 1

        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                gridArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Edge-to-edge at every N. The previous
                    // `.padding(.horizontal, 16) / .padding(.top, 4)`
                    // at N>=2 was adding a visible gutter around the
                    // multiview grid that the user flagged as
                    // "padding between streams". With
                    // `MultiviewGridMath.defaultSpacing = 0` the
                    // tiles already sit flush against each other; the
                    // container now pushes that flush layout all the
                    // way to the screen edges too.
                    //
                    // v1.6.17, iPhone-only safe-area carve-out.
                    // Without this, the tiles slide under the notch /
                    // Dynamic Island in portrait and under the speaker
                    // cutout on the leading edge in landscape, eating
                    // into video content the user can't recover. iPad
                    // keeps the edge-to-edge behavior because its
                    // safe-area insets are zero in normal-window
                    // mode anyway. tvOS doesn't have a notch.
                    //
                    // The black background behind the grid still
                    // covers edge-to-edge (see ZStack outer
                    // `Color.black.ignoresSafeArea()`), so what the
                    // user sees during multiview on a notched iPhone
                    // is "tiles render inside the safe boundary,
                    // black fills the corners around them", same
                    // behaviour as iOS PiP or MapKit.
                    .modifier(MultiviewSafeAreaModifier(minimized: nowPlaying.isMinimized))
                    // v1.6.12 (GH #11 follow-up): disable the tile
                    // Button(s) while the TVOptions panel is open so
                    // D-pad-UP from the panel's first row can't
                    // escape to the tile above. Combined with the
                    // chrome-disable below this gives the panel a
                    // hard focus trap on every direction (no other
                    // focusable view exists outside the panel).

                // tvOS N=1 chrome no longer lives here as an inline sibling
                // (which shrank the video). It is now a bottom .overlay on
                // gridArea above so the video stays full-bleed. See that
                // overlay for the focus-trap handling.

                // tvOS (Logan 2026-10-11): no bottom transport bar on the
                // N>=2 grid. Menu goes straight to the Leave Multiview
                // prompt and Add Channel lives in the tile long-press menu.
                // iPhone / iPad keep the bar.
                if !isSoleTile && Self.showsGridTransportBar {
                    // Transport bar spans edge-to-edge with its own
                    // black background, no outer horizontal padding so
                    // it reads as an integrated strip docked at the
                    // bottom, not a floating capsule. At N=1 on the
                    // unified path the PlaybackChromeOverlay's
                    // controls replace it; legacy users always see it.
                    //
                    // When the chrome is faded the transport bar
                    // collapses to height 0 (not just opacity 0) so
                    // the grid can expand into the freed space,
                    // previously this strip reserved ~80pt of
                    // permanent black at the bottom of the screen
                    // even while invisible, which the user flagged
                    // as wasted space.
                    MultiviewTransportBar(
                        store: store,
                        onAdd: { showAddSheet = true },
                        // Every platform: the X closes the SELECTED stream
                        // (the audio tile). Collapsing to the audio tile
                        // instead read as "it closed the wrong one"
                        // (Freyguy1975, Discord 2026-09-09) - it keeps
                        // exactly the tile the user just selected and
                        // removes the other one, the precise inverse of the
                        // intent, because Select on a tile takes audio. That
                        // fix landed on iPhone / iPad only; tvOS kept the
                        // collapse and the same report came back from the
                        // same tester on 1.8.34. The "Exit Multiview"
                        // collapse verb still lives on the Menu press, with
                        // its confirmation dialog.
                        //
                        // iPhone / iPad (Logan 2026-10-07): the red X closes
                        // Multiview completely; a single stream leaves from
                        // its tile's long-press menu. tvOS keeps the
                        // selected-stream close (Back exits there).
                        onExit: {
                            // 2026-10-12: at 2 or more tiles the X asks
                            // first (Back to Guide / Exit Multiview /
                            // Cancel), the same dialog Apple TV shows on
                            // Back. It used to call session.stop() here
                            // with no dialog. At one tile it exits directly.
                            if store.tiles.count >= 2 {
                                DebugLogger.shared.log(
                                    "[MV-Mode] X: exit dialog (tiles=\(store.tiles.count))",
                                    category: "Playback", level: .info)
                                if !showExitConfirmation {
                                    exitDialogSource = "X"
                                    showExitConfirmation = true
                                }
                            } else {
                                DebugLogger.shared.log(
                                    "[MV-Mode] X: close Multiview (tiles=\(store.tiles.count))",
                                    category: "Playback", level: .info)
                                AppOrientationLock.release(reason: "Multiview X")
                                session.stop()
                            }
                        }
                    )
                    .frame(height: chromeState.isVisible ? nil : 0)
                    .opacity(chromeState.isVisible ? 1 : 0)
                    .clipped()
                    .allowsHitTesting(chromeState.isVisible)
                    .animation(.easeInOut(duration: 0.25), value: chromeState.isVisible)
                    // v1.6.12 (GH #11 follow-up): while the TVOptions
                    // panel is open, disable focus on the transport
                    // bar so D-pad-down past the last panel row has
                    // nowhere to escape, the panel's `.focusSection()`
                    // is just a preference; the focus engine still
                    // honors directional moves to other focusable
                    // views unless those views are .disabled. With
                    // this guard the panel becomes a true focus trap.
                }
            }

            // Tap-to-dismiss (Logan 2026-08-26, phone parity with the
            // tvOS Back-hides-chrome rule): while chrome is up on a solo
            // session, a tap on the video / empty space hides it. This
            // clear catcher sits BETWEEN the tiles and the chrome, so
            // chrome buttons above it keep their taps; when chrome is
            // hidden it unmounts and the container's show-gesture (which
            // now only fires with chrome hidden) takes over.
            if chromeState.isVisible, !chromeState.isPinned, store.tiles.count == 1 {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { chromeState.hideNow() }
            }

            // N=1 chrome overlay, top bar (iOS) / bottom pill (tvOS).
            // Only mounted for unified-path users at N=1; legacy
            // users get a bare no-op mount (overlay renders nothing)
            // so `showAddSheet` / `chromeState` observers keep
            // working without introducing visible UI.
            // iOS: never mount the chrome inside the iPad mini. hideNow()
            // on minimize only started a fade, so the shrunken X, AirPlay,
            // "...", + and the engine badge flashed in the mini (Logan,
            // iPad 2026-10-11 21:24). The mini draws its own X in HomeView.
            if unifiedPath && !(isIOSMinimized) {
                PlaybackChromeOverlay(
                    store: store,
                    showAddSheet: $showAddSheet,
                    showTVOptions: $showTVOptions,
                    sleepTimerEnd: $sleepTimerEnd,
                    showStreamInfo: $showStreamInfo,
                    showRecordSheet: $showRecordSheet,
                    showSwitchStream: $showSwitchStream
                )
                // (No `.disabled(showTVOptions)` here, on tvOS this
                // overlay is empty by design; the actual chrome pills
                // live in `PlaybackBottomChrome_tvOS` rendered above
                // and that's where the focus-trap disable is wired.)
            }


            // v1.6.15.x: Stream Info overlay. Mounted when the user
            // toggles "Stream Info" inside the Options panel (tvOS)
            // or the iOS overflow menu. Reads from the audio tile's
            // `PlayerProgressStore` so the values reflect the
            // currently-audible stream regardless of which tile in a
            // multi-tile grid is active.
            //
            // Per-platform positioning matches the new
            // ChannelInfoBanner's dynamic-margin strategy:
            //   - tvOS: bottom-left, 40pt leading / 32pt bottom.
            //     Banner sits top-left so they're diagonally
            //     opposite, never overlapping. Back button dismisses
            //     (handled in `handleMenuPress`).
            //   - iPhone: top-leading, top inset reads the same
            //     dynamic safe-area calc the chrome bar uses, so the
            //     card slides in beneath the Dynamic Island /
            //     status bar instead of being clipped by it.
            //   - iPad / Mac: same dynamic top inset, but room to
            //     spare so we leave the card centered horizontally.
            // iOS gets a small close button on the card so the user
            // doesn't have to reopen the Options menu just to dismiss.
            if showStreamInfo, let audioStore = store.audioProgressStore {
                streamInfoOverlay(audioStore: audioStore)
                    .transition(.opacity)
            }

            if store.relocatingTileID != nil {
                relocateBanner
            }

            if store.isThermallyStressed {
                thermalBanner
            }

        }
        .environmentObject(chromeState)
        // NOTE: intentionally NO `onAppear { chromeState.reportInteraction() }`.
        // Under the new UX the container mounts with chrome hidden
        // (see `MultiviewChromeState.isVisible = false`). The user
        // sees just the stream on a fresh channel start and must
        // press Menu to summon the chrome. Auto-summoning on appear
        // made the first Menu press feel like a no-op because the
        // chrome was technically "visible" but not perceived yet, so
        // the press fell through to the minimize branch.
        //
        // v1.6.15: mirror this container's local chrome visibility
        // up to `NowPlayingManager.chromeIsVisible` so the
        // `ChannelInfoBanner` overlay (which lives in HomeView's
        // outer ZStack, not in this container's environment) can
        // lock its visibility to the same auto-fade timer. Cross-
        // platform, both iPhone/iPad (PlaybackChromeOverlay) and
        // tvOS (inline pills) read the same `chromeState`.
        // `initial: true` (#42): fire on mount too, so a freshly-mounted
        // container (cold launch / suspend-resume remount, where chromeState
        // re-inits to false) force-clears any `chromeIsVisible` left stranded
        // `true` by the previous mount. Without this the mirror only updates
        // on a *change*, so a stale `true` survives the remount and strands
        // the re-coupled ChannelInfoBanner, the v1.7.3 regression.
        .onChange(of: chromeState.isVisible, initial: true) { _, visible in
            nowPlaying.chromeIsVisible = visible
            debugLog("[MV-Chrome] chrome+info visible=\(visible) reason=\(chromeState.lastReason)")
        }
        // v1.6.15: wake chrome only on stream starts that explicitly
        // requested it (cold-launch auto-resume, channel-row tap).
        // Siri Remote up/down flips bump `streamStartedToken` but
        // NOT `chromeWakeToken`, so the channel-scroll path leaves
        // chrome hidden, that way a follow-up up/down keeps flipping
        // channels instead of landing on the chrome's Record pill.
        // The banner still appears on every flip via its own 5s
        // timer driven by `streamStartedToken`.
        // initial: true + consume: a fresh mount (cold launch, tune after a
        // full exit) is created IN the same transaction that publishes the
        // token, so a plain onChange never fires and the tune-in chrome
        // silently fails to appear until some other press summons it
        // (ATV field report 2026-08-13, 17 log-proven fresh tunes; a
        // guide re-tune "fixed" it because swap-from-mini observes from an
        // already-mounted container). Consuming the token keeps it a true
        // one-shot: without the nil-out, initial: true would replay a stale
        // wake on every later mount, including wakeChrome=false flips.
        .onChange(of: nowPlaying.chromeWakeToken, initial: true) { _, newToken in
            guard newToken != nil else { return }
            nowPlaying.chromeWakeToken = nil
            guard !nowPlaying.isMinimized else { return }
            chromeState.reportInteraction(reason: "channel change")
        }
        // Connection issue (2026-07-12, Android parity): when the sole live
        // tile's stream drops, summon + PIN the chrome so the Retry cell is
        // on screen for the whole outage, and land focus on it - a re-tune is
        // one Select away. Unpin on recovery; the normal 5s fade takes over.
        // tvOS-only behavior in effect: the pin + focus targets exist for the
        // sole-tile chrome, and phones use the tappable card instead.
        .onReceive(NotificationCenter.default.publisher(for: .connectionIssueChanged)) { note in
        }
        // v1.6.15.x: bridge `showStreamInfo` → audio tile's
        // `isStreamInfoVisible`. The audio tile's coordinator only
        // runs the volatile stats timer (codec, bitrate, sync,
        // drops) while this flag is true, keeping it off avoids
        // mpv lock contention when nothing is reading the values.
        // Without this bridge the StreamInfoCardView would render
        // with all-zeroes even after the user toggled it on, because
        // the toggle just flipped MultiviewContainerView's @State
        // and never reached the per-tile coordinator that owns the
        // timer. Same pattern PlayerView's legacy single-stream
        // path uses (PlayerView.swift onChange of showStreamInfo).
        .onChange(of: showStreamInfo) { _, visible in
            store.audioProgressStore?.isStreamInfoVisible = visible
            // v1.6.18: see the matching note in PlayerView.swift,
            // ChannelInfoBanner reads this flag to suppress itself
            // while Stream Info is open so the two overlays don't
            // overlap on iPhone.
            nowPlaying.streamInfoIsVisible = visible
        }
        // iPad/iPhone: any tap anywhere in multiview reveals chrome +
        // resets the 5s fade timer. `.simultaneousGesture` so it
        // fires alongside the tile's own `.onTapGesture` (which
        // takes audio) rather than stealing it. Gated to chrome-HIDDEN:
        // with chrome up, the solo tap-catcher above owns the tap
        // (dismiss), and an unguarded report here would instantly
        // re-show what the catcher just hid.
        .simultaneousGesture(
            TapGesture().onEnded {
                if !chromeState.isVisible { chromeState.reportInteraction() }
            }
        )
        // v1.6.18: vertical swipe = channel flip (single-stream
        // live only). Gated on chrome being VISIBLE, the user
        // taps once to summon chrome, then swipes up/down to
        // flip channels. Each flip refreshes the chrome fade
        // timer so the Tap → Swipe → Swipe → Swipe flow keeps
        // working without re-tapping. Inverted from the tvOS
        // gate (which flips on chrome HIDDEN, since on tvOS
        // chrome-visible up/down navigates between Options /
        // Record / Add Stream pills), on iOS chrome doesn't
        // have D-pad navigable elements above the tile, so
        // gating on visible-chrome is the cleanest way to keep
        // accidental swipes during normal viewing from changing
        // the channel. `.simultaneousGesture` so the tile's own
        // tap-to-take-audio path still works (taps require
        // minimal movement; vertical swipes have lots, so the
        // tap recognizer won't fire). Direction matches tvOS:
        // up = next channel (+1), down = previous (-1).
        .simultaneousGesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    guard chromeState.isVisible,
                          nowPlaying.isLive,
                          store.tiles.count == 1,
                          !nowPlaying.isMinimized,
                          // An In-Player edge slide owns its own drag.
                          !edgeAdjust.isEngaged else { return }
                    // The top strip belongs to the swipe-down PiP /
                    // minimize gesture below, never to a flip.
                    guard !PlayerTopStripSwipe.startsInStrip(
                        value.startLocation.y, height: containerHeight) else { return }
                    let dy = value.translation.height
                    let dx = abs(value.translation.width)
                    // Strong vertical bias: at least 40pt of
                    // vertical movement and at least 1.5×
                    // dominance over horizontal so iPad split-
                    // view drag-from-edge gestures don't get
                    // misread as channel flips.
                    guard abs(dy) > 40, abs(dy) > dx * 1.5 else { return }
                    let direction = dy < 0 ? +1 : -1
                    nowPlaying.changeChannel(direction: direction)
                    chromeState.reportInteraction()
                }
        )
        // Top-strip swipe down (Logan 2026-09-14): a downward drag that
        // STARTS in the close-button row pulls the player down; past the
        // threshold iPhone starts system PiP (docked-bar minimize when PiP
        // can't run) and iPad minimizes to the corner mini. Solo tile only:
        // PiP is a fullscreen affordance and the grid has no strip.
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    guard topStripSwipeEligible,
                          PlayerTopStripSwipe.startsInStrip(
                            value.startLocation.y, height: containerHeight) else { return }
                    topStripDragOffset = PlayerTopStripSwipe.followOffset(value.translation)
                }
                .onEnded { value in
                    guard topStripSwipeEligible,
                          PlayerTopStripSwipe.startsInStrip(
                            value.startLocation.y, height: containerHeight) else {
                        if topStripDragOffset != 0 { topStripDragOffset = 0 }
                        return
                    }
                    if PlayerTopStripSwipe.commits(value) {
                        performTopStripSwipeDown()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            topStripDragOffset = 0
                        }
                    }
                }
        )
        // In-Player Gestures (Settings → App Behaviors): edge slides for
        // brightness / volume. This is the host the iPhone actually shows
        // for a plain channel play (unified single-tile path), so the
        // slides have to live here as well as on the legacy chrome.
        .inPlayerEdgeGestures(
            isEnabled: store.tiles.count == 1 && !nowPlaying.isMinimized,
            host: "MultiviewContainerView"
        )
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newValue in
            containerHeight = newValue
        }
        .onChange(of: showAddSheet) { _, presenting in
            // Flip `isPickerPresented` whenever the add-sheet opens
            // or closes. Every tile's `MultiviewTileView.shouldPause`
            // reads this and pauses its mpv handle, stops live
            // decode while the picker's channel list is rendering
            // so we don't OOM at 1.8+ GB RSS on Apple TV 4K.
            // Resumes on dismissal.
            store.isPickerPresented = presenting
            // A presented cover must PAUSE the fade, not race it: the
            // chrome kept counting down behind the picker and was gone
            // when the user came back (Logan 2026-09-11).
            chromeState.setPinned(presenting)
            if !presenting { chromeState.reportInteraction() }
        }
        .task(watchThermalState)
        .onReceive(
            NotificationCenter.default.publisher(for: .multiviewRequestOpenAddSheet)
        ) { _ in
            // ⌘N keyboard shortcut (or any future programmatic
            // request) asks us to open the add-sheet.
            showAddSheet = true
        }
        .sheet(isPresented: $showAddSheet) {
            // The real channel picker: Favorites / Recent / All
            // Channels, routed through `MultiviewStore.add(...)`.
            AddToMultiviewSheet(isPresented: $showAddSheet)
                .presentationDetents([.fraction(0.45), .large])
                .presentationDragIndicator(.visible)
        }
        // Swap Stream: the SAME picker, targeted at one existing tile.
        // Driven by the store so the per-tile menu (which lives deep in
        // the tile view) can raise it without threading a binding down.
        .sheet(isPresented: swapSheetBinding) {
            AddToMultiviewSheet(
                isPresented: swapSheetBinding,
                swapTargetTileID: store.pendingSwapTileID
            )
            .presentationDetents([.fraction(0.45), .large])
            .presentationDragIndicator(.visible)
        }
        // Record sheet, presented by the Record pill in the tvOS
        // bottom chrome or the iOS top chrome's record button.
        // Populated from the audio tile's currently-playing program
        // via `ChannelDisplayItem`'s EPG fields. Closure-safe: if
        // the audio tile has gone away (user removed the last tile
        // between opening the sheet and it rendering), we render
        // an EmptyView so SwiftUI dismisses the sheet cleanly.
        .sheet(isPresented: $showRecordSheet) {
            recordSheetContent
        }
        // Switch Stream picker. iOS presents it as a sheet. tvOS does NOT
        // use a third .fullScreenCover (stacking a third cover breaks the
        // tvOS 27 focus engine, the unpresented cover steals focus from
        // the bottom chrome). tvOS instead renders it as an inline overlay
        // in the gridArea ZStack above, the same pattern as the Options
        // panel.
        .sheet(isPresented: $showSwitchStream) {
            switchStreamSheetContent
        }
        // Per-tile Switch Stream (tile long-press menu, 2026-08-28).
        .sheet(isPresented: Binding(
            get: { store.pendingStreamSwitchTileID != nil },
            set: { if !$0 { store.pendingStreamSwitchTileID = nil } }
        )) {
            if let switchID = store.pendingStreamSwitchTileID,
               let switchTile = store.tiles.first(where: { $0.id == switchID }),
               let switchChannelID = switchTile.item.dispatcharrChannelID,
               let switchUUID = switchTile.item.uuid, !switchUUID.isEmpty {
                SwitchStreamView(
                    channelID: switchChannelID,
                    channelUUID: switchUUID,
                    channelName: switchTile.item.name,
                    onClose: { store.pendingStreamSwitchTileID = nil }
                )
            } else {
                EmptyView()
            }
        }
        // Tile context menu's Add Channel: the menu can't reach
        // showAddSheet directly (it lives deep in the tile view), so it
        // raises a store flag. Small delay lets the system menu finish
        // dismissing before the sheet presents.
        .modifier(AddSheetRequestBridge(store: store, showAddSheet: $showAddSheet))
        // Exit-confirmation dialog. Presented when the user presses
        // Menu/Back with chrome already visible (see the `onExitCommand`
        // comment above for the full Menu stack). Confirming runs
        // the appropriate exit action for the current tile count;
        // cancelling dismisses with no state change. On tvOS the
        // Menu button dismisses the dialog without confirming (SwiftUI
        // built-in), and `reportInteraction()` keeps chrome alive
        // while the dialog is visible so the user isn't stranded
        // staring at faded chrome after they cancel.
        .confirmationDialog(
            exitConfirmationTitle,
            isPresented: $showExitConfirmation,
            titleVisibility: .visible
        ) {
            // "Back to Guide" (2026-10-12, Android parity): the Multiview
            // keeps playing in the background with its channels staged;
            // the guide's long-press menu adds and removes tiles in place
            // and the banner above the guide returns to it. Listed first.
            // (The 2026-08-31 "Back to TV Guide" tore the players down and
            // re-armed staging; this one keeps them running.)
            if MultiviewBackgroundSession.canEnter {
                Button("Back to Guide") {
                    exitDialogDismissReason = "action: Back to Guide"
                    DebugLogger.shared.log(
                        "[MV-Cmd] exit dialog: Back to Guide (tiles=\(store.tiles.count))",
                        category: "Playback", level: .info)
                    MultiviewBackgroundSession.shared.enter()
                }
            }
            Button(exitConfirmationPrimary, role: .destructive) {
                exitDialogDismissReason = "action: \(exitConfirmationPrimary)"
                performConfirmedExit()
            }
            // iOS presents a confirmationDialog as a popover anchored to
            // its source (iPad always; iPhone on iOS 26 and later), and
            // UIKit hides the .cancel action in a popover: tapping outside
            // is the cancel. Logan 2026-10-12: Cancel must be visible as
            // on Apple TV, so iOS lists it as a plain action (no role).
            Button("Cancel") {
                exitDialogDismissReason = "cancel"
                chromeState.reportInteraction()
            }
        } message: {
            Text(exitConfirmationMessage)
        }
        .onChange(of: showExitConfirmation) { _, shown in
            if shown {
                DebugLogger.shared.log("[MV-Cmd] exit dialog presented (source=\(exitDialogSource))",
                                       category: "Playback", level: .info)
            } else {
                DebugLogger.shared.log("[MV-Cmd] exit dialog dismissed (\(exitDialogDismissReason ?? "menu"))",
                                       category: "Playback", level: .info)
                exitDialogDismissReason = nil
            }
        }
    }

    /// Title for the exit-confirmation dialog. Phrased per tile
    /// count so "Exit multiview?" at N=1 doesn't read as nonsensical
    /// (there's nothing "multi" to exit).
    private var exitConfirmationTitle: String {
        if PlaybackFeatureFlags.useUnifiedPlayback && store.tiles.count == 1 {
            return "Exit Playback?"
        }
        return "Leave Multiview?"
    }

    /// Primary-button label for the exit-confirmation dialog. Short
    /// imperative verb matching the title's phrasing.
    /// iOS only: the container sits inside the iPad docked mini. The
    /// chrome overlay is not mounted in that state.
    private var isIOSMinimized: Bool {
        return nowPlaying.isMinimized
    }

    private var exitConfirmationPrimary: String {
        if PlaybackFeatureFlags.useUnifiedPlayback && store.tiles.count == 1 {
            return "Exit"
        }
        return "Exit Multiview"
    }

    /// Content for the Record sheet. Resolves the audio tile and
    /// its `ChannelDisplayItem` at render time so the sheet always
    /// reflects the current audio tile, if the user changed audio
    /// focus between tapping Record and the sheet animating in,
    /// they see the latest channel's program, not a stale snapshot.
    /// Renders `EmptyView` only when there's no audio tile or no
    /// stream URL on it, both are unreachable in practice because
    /// the parent `canRecordCurrentProgram*` gate already requires
    /// a stream URL. v1.6.8 (B1 Phase 1): no longer falls through
    /// to `EmptyView` when EPG metadata is missing, Dispatcharr
    /// playlists routinely have no `currentProgram` populated, and
    /// the prior gate left users on those playlists with an
    /// invisible / empty record sheet. The fallback path uses
    /// generic title + a 60-minute default duration that the user
    /// can override via `RecordProgramSheet`'s pre/post-roll
    /// controls.
    @ViewBuilder
    private var recordSheetContent: some View {
        // Hold the chrome up for as long as the Record cover is on
        // screen; released (and re-armed) on dismissal. Attached to the
        // sheet CONTENT rather than as another onChange on the container,
        // whose modifier chain is already at the type-checker budget.
        recordSheetBody
            .onAppear { chromeState.setPinned(true) }
            .onDisappear {
                chromeState.setPinned(false)
                chromeState.reportInteraction()
            }
    }

    @ViewBuilder
    private var recordSheetBody: some View {
        if let audioID = store.audioTileID,
           let audio = store.tiles.first(where: { $0.id == audioID }),
           audio.item.streamURL != nil {
            let now = Date()
            // Title fallback: prefer the EPG-known program name,
            // otherwise the generic "<channel> live recording" so the
            // sheet has something readable when Dispatcharr playlists
            // don't have `currentProgram` populated yet.
            let programTitle: String = audio.item.currentProgram
                ?? "\(audio.item.name) live recording"
            let start: Date = audio.item.currentProgramStart ?? now
            let end: Date = (audio.item.currentProgramEnd
                .flatMap { $0 > now ? $0 : nil })
                ?? now.addingTimeInterval(3600)
            RecordProgramSheet(
                programTitle: programTitle,
                // `RecordProgramSheet.programDescription` is a
                // non-optional `String`; `ChannelDisplayItem` stores
                // it as `String?`. Fall back to an empty string
                // when EPG didn't provide a description (common for
                // short/news programs), the sheet renders an empty
                // description area cleanly.
                programDescription: audio.item.currentProgramDescription ?? "",
                channelID: audio.item.id,
                channelName: audio.item.name,
                scheduledStart: start,
                scheduledEnd: end,
                // The chrome's Record pill is only enabled when the
                // user is actively watching, so the recording is
                // always "from now", `isLive: true` drives the
                // "Record from Now" wording + the current-time seek.
                // `hasEPG` only affects the title fallback above
                // (use the program name when known, otherwise the
                // generic "<channel> live recording" string).
                isLive: true,
                dispatcharrChannelID: audio.item.dispatcharrChannelID,
                streamURL: audio.item.streamURL,
                channelLogoURL: audio.item.logoURL
            )
        } else {
            EmptyView()
        }
    }

    /// iOS sheet content for the Switch Stream picker. (tvOS presents the
    /// picker as a page inside the Options panel, see the panel block.)
    /// Resolves the audio tile's Dispatcharr ids at render time; EmptyView
    /// if absent so the sheet dismisses cleanly.
    @ViewBuilder
    private var switchStreamSheetContent: some View {
        if let audioID = store.audioTileID,
           let audio = store.tiles.first(where: { $0.id == audioID }),
           let channelID = audio.item.dispatcharrChannelID,
           let uuid = audio.item.uuid, !uuid.isEmpty {
            SwitchStreamView(
                channelID: channelID,
                channelUUID: uuid,
                channelName: audio.item.name,
                onClose: { showSwitchStream = false },
                // Persisted in-session selection for THIS channel, so a
                // re-open shows the switched stream rather than the stale
                // /status.stream_id.
                initialStreamID: switchedStreamChannelUUID == uuid ? switchedStreamID : nil,
                onSwitched: { id in
                    switchedStreamChannelUUID = uuid
                    switchedStreamID = id
                }
            )
        } else {
            EmptyView()
        }
    }


    /// Body text for the exit-confirmation dialog. Explains what
    /// happens after tapping the primary button so the user isn't
    /// surprised by the destination view.
    private var exitConfirmationMessage: String {
        if PlaybackFeatureFlags.useUnifiedPlayback && store.tiles.count == 1 {
            return "Stops playback and returns to the channel guide."
        }
        return "Exit Multiview stops every channel and returns to the guide."
    }

    /// Run the actual exit action that the confirmation dialog was
    /// guarding. Separated from the `onExitCommand` closure so the
    /// confirmation's Yes-button and any future programmatic exit
    /// path (e.g. iPad toolbar "Exit" button) share one code path.
    private func performConfirmedExit() {
        // Exit Multiview stops every channel and returns to the guide
        // (Logan 2026-10-11, parity with Android, where Exit Multiview
        // clears the store). It used to collapse N>=2 to the audio tile,
        // which left a one-tile Multiview playing full screen.
        AppOrientationLock.release(reason: "Exit Multiview")
        session.stop()
    }


    // MARK: - Grid

    @ViewBuilder
    private var gridArea: some View {
        // `isSoleTile` is N=1, the tile is effectively the whole
        // player. `MultiviewTileView` reads it to suppress its own
        // corner chrome (audio badge, label strip, close X) so the
        // container-level `PlaybackChromeOverlay` can paint a
        // top-bar Close + Title without duplicating per-tile chrome.
        // Gated on the unified-playback feature flag so legacy
        // multiview users who hit N=1 mid-session (by removing a
        // tile from N=2) keep ALL their per-tile chrome including
        // the close ×, otherwise they'd have no way to remove the
        // last tile. User-facing fullscreen-within-grid
        // (fullscreenTileID set) is still technically N>1 behind
        // the scenes, so we leave `isSoleTile = false` there.
        let isSole = PlaybackFeatureFlags.useUnifiedPlayback && store.tiles.count == 1 && !compositeKeepsGrid

        if let fullscreenID = store.fullscreenTileID,
           let fullscreenTile = store.tiles.first(where: { $0.id == fullscreenID }) {
            // Fullscreen-within-grid: render only that tile at full
            // size. The menu button / Esc still works because the
            // menu action flips `fullscreenTileID` back to nil. Other
            // tiles keep decoding (no pause) so when we come back
            // they're already at live edge.
            MultiviewTileView(tile: fullscreenTile, store: store)
        } else {
            let grid = MultiviewLayoutView(tiles: store.tiles, spacing: tileSpacing, spotlightTileID: store.spotlightTileID, layoutMode: layoutMode, keepGridAtOne: compositeKeepsGrid) { tile in
                MultiviewTileView(tile: tile, store: store, isSoleTile: isSole)
            }
            grid
        }
    }

    /// Short log-friendly name for `ProcessInfo.ThermalState`,
    /// `String(describing:)` on the raw enum prints "nominal" which
    /// is already what we want, but using a small function keeps
    /// future-proofing simple if Apple adds a new case.


    /// Thermal watch for the container's lifetime (named function, not
    /// an inline .task closure: the modifier chain is at the Xcode 26
    /// Release type-checker budget and inlining this timed out the
    /// archive). The observer posts on the main thread per Apple docs,
    /// so direct @MainActor writes are fine; the initial state primes
    /// the flag for the "already hot when user opens multiview" case.
    @Sendable private func watchThermalState() async {
        store.thermalState = ProcessInfo.processInfo.thermalState
        DebugLogger.shared.log(
            "[MV-Thermal] initial arrival=\(thermalStateName(store.thermalState))",
            category: "Playback", level: .info
        )
        for await _ in NotificationCenter.default.notifications(
            named: ProcessInfo.thermalStateDidChangeNotification
        ) {
            let new = ProcessInfo.processInfo.thermalState
            let old = store.thermalState
            store.thermalState = new
            let line = "[MV-Thermal] state \(thermalStateName(old))→\(thermalStateName(new)) tiles=\(store.tiles.count)"
            DebugLogger.shared.log(line, category: "Playback", level: .warning)
        }
    }

    private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair:    return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Stream Info overlay (v1.6.15.x)

    /// Platform-specific Stream Info card placement. tvOS sits at
    /// bottom-left so it doesn't overlap the top-left
    /// `ChannelInfoBanner`. iPhone hugs the top-left below the
    /// Dynamic Island / status bar via the same `iOSDynamicTopInset`
    /// calc the banner uses. iPad lands center-top because there's
    /// room. iOS gets a close (×) button so the user doesn't have
    /// to re-open Options just to dismiss the card.
    @ViewBuilder
    private func streamInfoOverlay(audioStore: PlayerProgressStore) -> some View {
        VStack {
            HStack {
                streamInfoCardWithCloseButton(audioStore: audioStore)
                    .padding(.leading, 8)
                    .padding(.top, iOSStreamInfoTopInset)
                Spacer()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // v1.6.18: same safe-area carve-out as the chrome overlay
        // see PlaybackChromeOverlay.swift for the rationale. The
        // `iOSStreamInfoTopInset` formula was designed against an
        // absolute screen-top reference; v1.6.17's iPhone safe-
        // area fix made the parent honor safe area, which would
        // otherwise double-count the Dynamic Island clearance and
        // float the Stream Info card too far down in iPhone
        // portrait.
        .ignoresSafeArea(edges: .top)
    }

    /// iOS / iPadOS Stream Info card with an inline close (×)
    /// button. The card itself reads taps; the surrounding overlay
    /// stays hit-test-disabled so the user can still tap through
    /// to the underlying chrome / video.
    @ViewBuilder
    private func streamInfoCardWithCloseButton(audioStore: PlayerProgressStore) -> some View {
        ZStack(alignment: .topTrailing) {
            StreamInfoCardView(info: audioStore.streamInfo)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showStreamInfo = false
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))  // glyph in a fixed box: not text, stays fixed
                        .foregroundStyle(.white)
                }
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close stream info")
            .offset(x: 10, y: -10)
        }
    }

    /// iPhone / iPad top inset for the Stream Info card. Mirrors
    /// `PlaybackChromeOverlay.dynamicTopInset` so the card always
    /// clears the Dynamic Island, notch, or compact status bar
    /// without device-specific branching.
    private var iOSStreamInfoTopInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first
        let windowInset: CGFloat = {
            guard let scene else { return 0 }
            if let key = scene.windows.first(where: { $0.isKeyWindow }) {
                return key.safeAreaInsets.top
            }
            return scene.windows.first?.safeAreaInsets.top ?? 0
        }()
        let statusBarHeight = scene?.statusBarManager?.statusBarFrame.height ?? 0
        let idiomIsPhone = UIDevice.current.userInterfaceIdiom == .phone
        let isLandscapePhone: Bool = {
            guard idiomIsPhone else { return false }
            return scene?.interfaceOrientation.isLandscape ?? false
        }()
        let floor: CGFloat = isLandscapePhone ? 20 : 48
        // +12pt breathing room past whichever inset is reported,
        // so the close button doesn't kiss the Dynamic Island.
        return max(max(windowInset, statusBarHeight) + 12, floor)
    }

    // MARK: - Thermal banner

    private var thermalBanner: some View {
        VStack {
            HStack {
                Spacer()
                Label(
                    "Device is hot, can't add more streams right now",
                    systemImage: "thermometer.high"
                )
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.red.opacity(0.9)))
                Spacer()
            }
            .padding(.top, 12)
            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: store.isThermallyStressed)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("Device is hot, cannot add more streams")
        .allowsHitTesting(false)
        .onAppear {
            // Announce on arrival, `.task` in the container already
            // posts the state change to the store, but VoiceOver
            // needs an explicit notification; the banner's visual
            // insertion doesn't trigger an announcement.
            #if canImport(UIKit)
            UIAccessibility.post(
                notification: .announcement,
                argument: "Device is hot. Cannot add more streams right now."
            )
            #endif
        }
    }

    // MARK: - Relocate banner

    private var relocateBanner: some View {
        // Banner text differs per-platform because the input model
        // does: tvOS drives swaps from the Siri Remote D-pad
        // (handled in `MultiviewContainerView.onMoveCommand`), iPad
        // commits swaps by tapping a second tile (handled in
        // `MultiviewTileView.tappableRegion.onTapGesture`). Keep
        // the orange capsule styling identical so the visual
        // affordance reads the same across devices.
        let message = "Tap a tile to swap"
        return VStack {
            HStack {
                Spacer()
                Label(
                    message,
                    systemImage: "arrow.up.and.down.and.arrow.left.and.right"
                )
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(Color.orange.opacity(0.9))
                )
                Spacer()
            }
            .padding(.top, 12)
            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: store.relocatingTileID)
        .allowsHitTesting(false)
    }
}

// MARK: - Chrome auto-fade state

/// Tracks whether multiview's supplementary chrome (transport bar,
/// per-tile audio badge, per-tile channel-name strip) is currently
/// visible. After 5s of inactivity the chrome fades out so the
/// video grid is unobstructed; the next user interaction fades it
/// back in and restarts the timer.
///
/// "Interaction" means:
/// - iPad: any tap (container's `.simultaneousGesture` catches the
///   tap alongside whatever tile gesture it may belong to)
/// - tvOS: any D-pad move OR any button action (the button's
///   action closure calls `reportInteraction()` before running)
///
/// Focus rings and relocate rings are NOT part of the faded chrome
/// they stay visible because they're critical navigation
/// feedback, not decorative chrome.
@MainActor
final class MultiviewChromeState: ObservableObject {
    /// `true` while the chrome should be visible; `false` once the
    /// 5s idle timer fires. SwiftUI observers wrap this in an
    /// `.animation` so the transition is a fade, not a snap.
    ///
    /// **Chrome** here means the heavy UI: bottom transport bar, the
    /// Options / Add-Stream pills, the N=1 scrubber, etc. It does NOT
    /// include the per-tile focus ring, that's governed by
    /// `focusIndicatorVisible` below so the user can navigate
    /// between tiles without the bottom bar swinging in every time.
    ///
    /// Starts at `false`, the user sees a clean, flush stream on
    /// mount and only the explicit Menu-button press summons the
    /// chrome. Previously this was `true` with an auto-fade to
    /// hidden after 5 s, but that meant Menu pressed *during* the
    /// initial visible window fell through to the "chrome is up, so
    /// this must be the 2nd press → minimize" branch, which looked
    /// like Menu did nothing because the chrome was so subtle the
    /// user hadn't perceived it as "up" yet.
    @Published var isVisible: Bool = false

    /// `true` while the per-tile focus indicator (accent-colored
    /// ring, scale, shadow) should be visible. Bumps on every D-pad
    /// move via `reportFocusActivity()`, fades back after 5s idle.
    ///
    /// Kept separate from `isVisible` so d-pad navigation doesn't
    /// drag the transport bar in with it, the user asked for a
    /// less-jarring "highlight only" experience where the streams
    /// stay full-screen while focus moves between them, and only the
    /// Menu button summons the bottom UI.
    @Published var focusIndicatorVisible: Bool = true

    /// v1.6.12: when `true`, `isVisible` is pinned to `true` and the
    /// auto-hide task is suppressed regardless of how much time has
    /// passed since the last interaction. Used by `MultiviewContainerView`
    /// while the TVOptions panel is open, without it the chrome
    /// would fade out 5s after the panel was summoned, which left
    /// the panel hovering on a fully-faded background and the user
    /// unable to dismiss back to the chrome state. Toggle via
    /// `setPinned(_:)` so any in-flight hide task is cancelled
    /// atomically with the flag change.
    @Published private(set) var isPinned: Bool = false

    /// Distinct reasons the chrome may be pinned. The pin is reference-counted
    /// over these so two independent owners can't clobber each other: closing
    /// the Options panel must NOT unpin a chrome that a live connection issue is
    /// still holding, and a recovering connection issue must NOT unpin a chrome
    /// the Options panel is still holding. `isPinned` is true while ANY reason
    /// is active (2026-07-13 review, the pre-existing single-Bool pin leaked
    /// across these owners and stranded the transport bar visible at N>=2).
    enum PinReason { case options, connectionIssue }
    private var pinReasons: Set<PinReason> = []

    /// Cancellable auto-hide task for the full chrome.
    private var hideTask: Task<Void, Never>?

    /// Cancellable auto-hide task for the focus indicator.
    private var focusHideTask: Task<Void, Never>?

    /// Monotonic timestamp of the most-recent `reportInteraction()`
    /// call that actually rescheduled the hide task. Used to coalesce
    /// high-frequency events: D-pad sweep on tvOS can fire Button
    /// actions 20+ times per second, and each `Task` cancel+create
    /// does a few allocations + a MainActor hop. Since the hide
    /// deadline is 5s out, a reschedule in the first 500ms after
    /// a previous reschedule is redundant, the user still has
    /// 4.5s of visible chrome either way.
    private var lastRescheduleAt: ContinuousClock.Instant?

    /// Delay before the FOCUS INDICATOR fades. Separate from the chrome
    /// fade below: the tile ring is navigation feedback, not controls.
    private static let fadeDelayNs: UInt64 = 5_000_000_000

    /// Delay before the chrome auto-hide fires after the last user
    /// action. One shared constant (`playerChromeFadeSeconds`) across
    /// both tvOS chromes.
    private static var chromeFadeSeconds: Double { playerChromeFadeSeconds }

    /// Immediately dismiss the chrome without waiting out the 5s fade
    /// (Back with chrome visible, solo sessions - Logan 2026-08-26).
    /// A pinned chrome (Options panel open, connection issue) refuses:
    /// the pin owners' visibility guarantee outranks the gesture, and
    /// the Back ladder handles those states earlier anyway.
    /// Explicit-dismiss timestamp: `reportInteraction()` within 300ms of
    /// a `hideNow()` is ignored, because the SAME tap that hit the
    /// dismiss catcher also fires the container's simultaneous
    /// show-gesture, and their order is undefined - without the window
    /// the dismiss could instantly re-show.
    private var lastHideNowAt: ContinuousClock.Instant?

    /// Why the chrome (and the info card that rides on it) last changed
    /// visibility; read by the `[MV-Chrome] chrome+info` log line.
    private(set) var lastReason: String = "tap"

    func hideNow() {
        guard !isPinned else { return }
        lastReason = "tap"
        hideTask?.cancel()
        hideTask = nil
        lastRescheduleAt = nil
        lastHideNowAt = ContinuousClock.now
        if isVisible {
            withAnimation(.easeInOut(duration: 0.2)) { isVisible = false }
        }
    }

    /// Reveal chrome + reset the 5s timer. Safe to call as often as
    /// wanted, the cancel+reschedule loop is the whole point, but
    /// the 500ms coalesce guard stops D-pad/focus bursts from
    /// churning `Task` allocations.
    func reportInteraction(reason: String = "tap") {
        let now = ContinuousClock.now
        // See lastHideNowAt: the dismissing tap must not re-show.
        if let hid = lastHideNowAt, hid.duration(to: now) < .milliseconds(300) {
            return
        }
        // NO coalescing any more (Logan 2026-09-11): every user action
        // restarts the countdown from zero. The old 500ms fast path
        // dropped the reschedule, so an action arriving just after a
        // previous one left the chrome hiding up to half a second early -
        // exactly the "disappears sooner" report. A cancel + re-arm per
        // action is cheap next to the alternative being wrong.

        if !isVisible {
            lastReason = reason
            withAnimation(.easeInOut(duration: 0.25)) {
                isVisible = true
            }
        }
        // Chrome showing implies the focus indicator should be
        // visible too (the user is clearly interacting). This lets
        // tile taps / pill clicks that already call
        // `reportInteraction()` keep the focus ring alive without
        // each call site having to double-bump.
        reportFocusActivity()
        scheduleHide()
    }

    /// Extended-grace variant for surfaces whose CLOSE event is not
    /// trustworthy - the iOS overflow `Menu` skips `onDisappear` on some
    /// dismissals (caught live 2026-08-26: `setPinned(true)` at menu
    /// open, no release, every scheduleHide "SKIPPED (pinned)" for two
    /// minutes = "chrome never fades"). Instead of a pin that can leak
    /// forever, the menu grants a LONG fade delay: a fired close event
    /// restores the normal 5s, and a swallowed one self-heals when the
    /// grace expires (chrome fading under a still-open menu is harmless,
    /// the menu is its own presentation layer). Bypasses the coalesce
    /// guard so it always re-arms with the requested delay.
    func reportInteractionWithGrace(_ seconds: Double) {
        if !isVisible {
            withAnimation(.easeInOut(duration: 0.25)) { isVisible = true }
        }
        reportFocusActivity()
        scheduleHide(delaySeconds: seconds)
    }

    /// Records the reschedule timestamp and (re)arms the auto-hide task.
    /// Suppressed while pinned. Factored out so both `reportInteraction()`
    /// AND `setPinned(false)` arm the fade through the same path. The latter
    /// is the important one: releasing the pin must guarantee a fresh fade
    /// timer even when a (no-op, pinned) `reportInteraction()` just bumped
    /// `lastRescheduleAt`. Without this, the follow-up `reportInteraction()`
    /// in the panel-close path would coalesce-early-return and leave the
    /// chrome with no hide task at all (it was cancelled when the pin went
    /// on), stranding it visible forever, the "exit Switch Stream picker via
    /// Menu, chrome never fades" bug.
    private func scheduleHide(delaySeconds: Double = playerChromeFadeSeconds) {
        lastRescheduleAt = ContinuousClock.now
        hideTask?.cancel()
        // While pinned (e.g. TVOptions panel open) don't schedule the hide
        // task; chrome stays up until the pin is released by the panel-close
        // path, which calls back through here.
        guard !isPinned else {
            debugLog("[MV-Chrome] scheduleHide SKIPPED (pinned) isVisible=\(isVisible)")
            return
        }
        debugLog("[MV-Chrome] scheduleHide armed (\(Int(delaySeconds))s) isVisible=\(isVisible)")
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // Re-check the pin at fire time too: it may have been set during
            // the 5s sleep (the panel could open after chrome was summoned),
            // in which case skip the hide and let the panel-close path arm a
            // fresh timer.
            guard !self.isPinned else {
                debugLog("[MV-Chrome] hideTask fire SKIPPED (pinned at fire)")
                return
            }
            debugLog("[MV-Chrome] hideTask FIRED -> isVisible=false")
            self.lastReason = "timer"
            withAnimation(.easeInOut(duration: 0.4)) {
                self.isVisible = false
            }
        }
    }

    /// v1.6.12: pin chrome visibility on or off. While `pinned ==
    /// true`, `isVisible` is force-set to `true` and any in-flight
    /// hide task is cancelled (auto-hide is fully suppressed).
    /// Releasing the pin (`setPinned(false)`) arms a fresh fade timer
    /// itself via `scheduleHide()`, so the chrome reliably fades after
    /// the panel closes even if a follow-up `reportInteraction()` would
    /// coalesce away. Callers may still follow with `reportInteraction()`
    /// to also refresh the focus ring; it is a harmless no-op for the
    /// fade clock.
    func setPinned(_ pinned: Bool, reason: PinReason = .options) {
        if pinned { pinReasons.insert(reason) } else { pinReasons.remove(reason) }
        let shouldPin = !pinReasons.isEmpty
        guard isPinned != shouldPin else { return }
        debugLog("[MV-Chrome] setPinned(\(pinned) reason=\(reason)) -> isPinned=\(shouldPin) isVisible=\(isVisible)")
        isPinned = shouldPin
        if shouldPin {
            hideTask?.cancel()
            if !isVisible {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isVisible = true
                }
            }
        } else {
            // Unpinning: auto-hide was suppressed while pinned, so there is no
            // valid hide task. Arm a fresh fade now (bypassing
            // reportInteraction's coalesce guard) so the chrome reliably fades
            // after the Options panel / Switch Stream picker closes, no matter
            // which Menu/dismiss path got us here.
            scheduleHide()
        }
    }

    /// Reveal the focus indicator (tile ring / scale / shadow) and
    /// reset its own 5-second fade timer, **without** touching
    /// chrome visibility. Called on every D-pad move from the grid
    /// so the user can navigate between streams without the bottom
    /// UI sweeping in with the focus change.
    ///
    /// Chrome visibility is a separate signal, `reportInteraction()`
    /// brings chrome in; Menu/Back (`onExitCommand`) also does. This
    /// method is the minimum "the user is pointing at something"
    /// signal for focus feedback only.
    func reportFocusActivity() {
        if !focusIndicatorVisible {
            withAnimation(.easeInOut(duration: 0.18)) {
                focusIndicatorVisible = true
            }
        }
        focusHideTask?.cancel()
        focusHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.fadeDelayNs)
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                self.focusIndicatorVisible = false
            }
        }
    }
}

// MARK: - Multiview Safe Area Modifier (v1.6.17)
//
// Carves out the iPhone notch / Dynamic Island / landscape speaker
// cutout so multiview tiles render INSIDE the safe area instead of
// sliding behind the hardware. iPad and tvOS get the legacy
// edge-to-edge behaviour: iPad's safe-area insets are zero in
// normal full-screen mode, and tvOS doesn't have a notch to dodge.
private struct MultiviewSafeAreaModifier: ViewModifier {
    /// tvOS mini player: the 400x225 corner frame sits against the screen's
    /// safe-area region (40pt top/trailing padding), so an unconditional
    /// `.ignoresSafeArea()` expands the player 40pt past its frame while the
    /// clip shape stays at 400x225 - shaving the edges off the video. Only
    /// bleed to the hardware edges when actually fullscreen.
    var minimized: Bool = false

    func body(content: Content) -> some View {
        // Phone AND iPad both bleed to the hardware edges now. The
        // phone's respect-every-edge carve-out shrank the whole video
        // frame ("zoomed out", 2026-08-26 field find): with aspect-fit
        // content the letterboxing keeps the picture clear of the
        // Dynamic Island by itself, exactly like every system video
        // app, and the chrome overlay manages its own insets.
        content.ignoresSafeArea()
    }
}

/// Tile context menu's Add Channel hand-off. A ViewModifier (not one
/// more inline .onChange on the container's chain) because that chain
/// is already at the tvOS type-checker budget - the extra closure blew
/// it. The delay lets the system menu finish dismissing first.
private struct AddSheetRequestBridge: ViewModifier {
    @ObservedObject var store: MultiviewStore
    @Binding var showAddSheet: Bool
    func body(content: Content) -> some View {
        content.onChange(of: store.addSheetRequested) { _, requested in
            guard requested else { return }
            store.addSheetRequested = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                showAddSheet = true
            }
        }
    }
}


/// Re-renders its content whenever the wrapped `PlayerProgressStore`
/// publishes. Used where a store reaches a view as a plain value (the
/// container's options panel) and the view must still track its state.
private struct ObservingProgressStore<Content: View>: View {
    @ObservedObject var store: PlayerProgressStore
    @ViewBuilder var content: (PlayerProgressStore) -> Content

    var body: some View { content(store) }
}


