//
// RemoteInputLogger.swift
//
// DEBUG-only tvOS remote-input logger. Subscribes to GameController events
// for the Siri Remote and prints every button press / dpad movement to
// stdout with a `[REMOTE]` prefix so the devicectl --console capture picks
// them up alongside the rest of the app's log output.
//
// Why GameController (not UIResponder.pressesBegan):
//   tvOS's focus engine consumes many UIPress events before they reach
//   any SwiftUI handler, e.g. the dpad presses that move focus never
//   fire `.onMoveCommand` on your views (SwiftUI rewrites those as focus
//   transitions, not command events). GameController's valueChangedHandler
//   runs in parallel with the focus engine and sees the raw hardware input
//   regardless of who consumes it downstream.
//
// What's logged:
//   [REMOTE] select           pressed   focus=MultiviewTileView
//   [REMOTE] select           released  focus=MultiviewTileView
//   [REMOTE] play_pause       pressed   focus=MultiviewTileView
//   [REMOTE] menu             pressed   focus=MultiviewTileView
//   [REMOTE] dpad             x=+0.98 y=+0.00  focus=MultiviewTileView
//   [REMOTE] controller_attached name=..., vendor=...
//
// To correlate with "what the UI did in response", grep the same
// timespan in the log for side effects, watchdog hangs, tile
// state changes, store mutations, SwiftUI lifecycle prints.
//

enum RemoteInputLogger {
    static func install() {}
}
