//
//  TVSettingsRows.swift
//  Astral
//
//  Extracted verbatim from SettingsView.swift (Settings redesign Phase 1,
//  SettingsUIRedesign.md A4). No behavior change intended in this move.
//

import SwiftUI
import SwiftData


// MARK: - Server List Row
struct ServerListRow: View {
    let server: ServerConnection
    /// iOS only: when non-nil the leading indicator becomes its own
    /// borderless button that activates this playlist without opening
    /// the row's detail link. tvOS passes nil and keeps one focus stop.
    var onActivate: (() -> Void)? = nil

    init(server: ServerConnection, onActivate: (() -> Void)? = nil) {
        self.server = server
        self.onActivate = onActivate
    }

    private var hasLANConfigured: Bool {
        server.type != .m3uPlaylist && !server.localURL.isEmpty
    }

    private var isOnLAN: Bool {
        hasLANConfigured && server.effectiveBaseURL != server.normalizedBaseURL
    }

    private let checkmarkSize: CGFloat = 22
    private let statusDotSize: CGFloat = 8
    private let chevronSize: CGFloat = 13

    var body: some View {
        // TestFlight 1.8.4 crash (mikec79, 2026-08-05): deleting a playlist
        // trapped in SwiftData's _KKMDBackingData.getValue reading
        // `server.type` from this row's body. The 2026-07-14 sweep guarded the
        // pushed/presented ServerConnection views but deliberately skipped list
        // rows, reasoning that @Query recreates them on delete. It does - but
        // not before SwiftUI renders the row ONE more time with the row's
        // identity still alive and the model already tombstoned, and a
        // @Persisted read on a detached model is a trap, not nil.
        //
        // Same guard as the other views: `.modelContext` is a framework
        // property, not a @Persisted attribute, so reading it after
        // `context.delete` is safe and goes nil. ViewBuilder's `if` only
        // evaluates the taken branch, so rowContent's persisted reads never run
        // once detached. No dismiss here - it is a row, and @Query drops it on
        // the next pass.
        if server.modelContext == nil {
            EmptyView()
        } else {
            rowContent
        }
    }

    /// Phase 3 (Logan 2026-09-18): the row's second line is plain text -
    /// "<Type> · <N> channels" - and NEVER the playlist URL, matching
    /// Android. The channel count is only shown when it is already in
    /// memory: `ChannelStore` holds the active playlist's channels, and
    /// nothing on `ServerConnection` stores a per-playlist count, so an
    /// inactive playlist shows its type alone rather than triggering a
    /// fetch or a SwiftData count during scroll. Read non-observing so a
    /// channel load can't re-render Settings rows mid-scroll.
    private var subtitleText: String {
        // Phase 3 item 10: the SHORT type name, identical on tvOS and
        // the phones ("Dispatcharr", "Xtream Codes", "M3U Playlist").
        let type = server.type.shortName
        guard server.isActive else { return type }
        let n = ChannelStore.shared.channels.count
        return n > 0 ? "\(type) · \(n) channels" : type
    }

    private var indicatorGlyph: some View {
        Image(systemName: server.isActive ? "checkmark.circle.fill" : "circle")
            .scaledFont(.system(size: checkmarkSize))
            .foregroundColor(server.isActive ? .accentPrimary : Color.contrastText(.textTertiary))
    }

    @ViewBuilder
    private var activeIndicator: some View {
        if let onActivate, !server.isActive {
            Button(action: onActivate) {
                indicatorGlyph
                    // 44pt target without changing the drawn size.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            // .borderless keeps the button out of the row's
            // NavigationLink: a plain Image or a default-styled button
            // inside a List row would just trigger the link.
            .buttonStyle(.borderless)
            .accessibilityLabel("Set as active playlist")
        } else {
            // Already active (or no action supplied): same 44pt box so
            // every row's leading column measures the same, but inert.
            indicatorGlyph
                .frame(width: 44, height: 44)
                .accessibilityHidden(!server.isActive)
                .accessibilityLabel("Active playlist")
        }
    }

    private var rowContent: some View {
        HStack(spacing: 14) {
            // Active playlist indicator. On iOS it is also a control
            // (Logan 2026-09-18): tapping the radio activates the
            // playlist through the same `performSetActiveServer` path as
            // the detail page's Set Active row, while the rest of the row
            // still opens the detail. On tvOS it stays a pure glyph so
            // the row keeps exactly one focus stop.
            activeIndicator

            // The type-icon tile is gone (Logan 2026-09-18): with the
            // radio as the leading element a second leading tile read as
            // two competing markers, and the type now says its name in
            // the subtitle. Same single-leading-element look as Android.
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .scaledFont(.bodyMedium)
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                Text(subtitleText)
                    .scaledFont(.labelSmall.subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .lineLimit(1)
            }

            Spacer()

            Circle()
                .fill(server.isVerified ? Color.statusOnline : Color.textTertiary)
                .frame(width: statusDotSize, height: statusDotSize)

            // iOS rows sit inside a NavigationLink that already draws
            // the system disclosure chevron; only tvOS draws its own.
        }
        .padding(.vertical, 4)
    }
}

// MARK: - LAN / WAN Badge
struct LANWANBadge: View {
    let isLAN: Bool

    private let iconSize: CGFloat = 8
    private let textSize: CGFloat = 9
    private let hPad: CGFloat = 5
    private let vPad: CGFloat = 2

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isLAN ? "wifi" : "globe")
                .scaledFont(.system(size: iconSize, weight: .semibold))
            Text(isLAN ? "LAN" : "WAN")
                .scaledFont(.system(size: textSize, weight: .bold))
        }
        .foregroundColor(isLAN ? .statusOnline : .accentSecondary)
        .padding(.horizontal, hPad)
        .padding(.vertical, vPad)
        .background(
            Capsule()
                .fill(isLAN ? Color.statusOnline.opacity(0.15) : Color.accentSecondary.opacity(0.15))
        )
    }
}

// MARK: - Settings Row


// MARK: - Buffer size options
