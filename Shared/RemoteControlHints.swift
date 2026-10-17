import Foundation
import SwiftUI

/// Human copy for the on-screen gesture hint chips, derived from the EFFECTIVE
/// remote map so a remapped button never advertises a stale gesture.
///
/// Actions without a natural short phrase return nil and their sentence is
/// simply omitted - a hint that says nothing beats one that lies.
///
/// Swift port of the Android `RemoteControlHints.kt` (core/remote).
enum RemoteControlHints {

    private static func playerPhrase(_ action: PlayerRemoteAction) -> String? {
        switch action {
        case .showProgramInfo:  return "program info"
        case .toggleControls:   return "player controls"
        case .optionsMenu:      return "options"
        case .channelList:      return "the channel list"
        // "recently watched channels" made the combined Left/Right chip
        // run past its width cap; the short form reads the same.
        case .recentChannels:   return "recent channels"
        case .openSearch:       return "search"
        case .lastChannel:      return "the previous channel"
        case .minimizeToGuide:  return "the TV guide"
        default:                return nil
        }
    }

    /// The player's Select line, compressed: "Select: X  ·  Hold Select: Y".
    /// Nil when neither OK slot maps to a phrasable action.
    static func selectHint(_ map: RemoteControlMap) -> String? {
        var parts: [String] = []
        if let short = playerPhrase(map.playerAction(.okShort)) { parts.append("Select: \(short)") }
        if let long = playerPhrase(map.playerAction(.okLong)) { parts.append("Hold Select: \(long)") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// Whether Up/Down still channel-surf (gates the flip hint chip).
    static func verticalFlipMapped(_ map: RemoteControlMap) -> Bool {
        map.playerAction(.upShort) == .channelUp && map.playerAction(.downShort) == .channelDown
    }

    /// The player's Left/Right line (Android parity, Logan 2026-08-06: users
    /// forgot what the horizontal presses do). channelList gets the fixed
    /// second-press note - Left inside the channel list opens the group
    /// sidebar - because that stage is built into the overlay, not the map.
    /// Nil when neither slot maps to a phrasable action.
    static func playerHorizontalHint(_ map: RemoteControlMap) -> String? {
        var parts: [String] = []
        let left = map.playerAction(.leftShort)
        if left == .channelList {
            parts.append("Left = channel list")
            parts.append("Left again = groups")
        } else if let phrase = playerPhrase(left) {
            parts.append("Left = \(phrase)")
        }
        if let phrase = playerPhrase(map.playerAction(.rightShort)) {
            parts.append("Right = \(phrase)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private static func guidePhrase(_ action: GuideRemoteAction) -> String? {
        switch action {
        case .timelineBack:     return "browse earlier programs"
        case .timelineForward:  return "browse later programs"
        case .focusGroupPills:  return "jump to the group pills"
        case .pageUp:           return "page channels up"
        case .pageDown:         return "page channels down"
        case .jumpToNow:        return "jump to now"
        case .jumpToTop:        return "jump to the top channel"
        case .resumePlayer:     return "return to the player"
        case .openGroupSidebar: return "open channel groups"
        case .programInfo:      return "open the program menu"
        case .programDetails:   return "show program info"
        case .record:           return "record"
        case .play:             return "play the channel"
        default:                return nil
        }
    }

    /// The guide's hold-Left chip; nil when the slot is unmapped. Sidebar
    /// mode owns the hold (Logan 2026-08-06 ruling), so the chip advertises
    /// the group menu instead of whatever the map says.
    @MainActor
    static func guideHoldLeftHint(_ map: RemoteControlMap) -> String? {
        let action = map.effectiveGuideAction(.leftLong,
                                              useGroupSidebar: RemoteControlStore.shared.useGroupSidebar)
        guard let phrase = guidePhrase(action) else { return nil }
        return "Hold left on remote to \(phrase)."
    }

    /// Terse phrases for the corner hint chip. `guidePhrase` is written for
    /// full sentences ("browse earlier programs"); dropped verbatim into the
    /// chip it pushed the pill under the centered tab bar, so the chip gets
    /// its own two-or-three-word forms.
    private static func guidePhraseShort(_ action: GuideRemoteAction) -> String? {
        switch action {
        case .timelineBack:     return "earlier"
        case .timelineForward:  return "later"
        case .focusGroupPills:  return "group pills"
        case .pageUp:           return "page up"
        case .pageDown:         return "page down"
        case .jumpToNow:        return "now"
        case .jumpToTop:        return "top channel"
        case .resumePlayer:     return "player"
        case .openGroupSidebar: return "groups"
        case .programInfo:      return "menu"
        case .programDetails:   return "info"
        case .record:           return "record"
        case .play:             return "play"
        default:                return nil
        }
    }

    /// Terse form for the compact combined guide nav chip: "Hold Left = X".
    /// In sidebar mode SHORT Left opens the sidebar too, so the chip says
    /// plain "Left = groups" - "Left / Hold Left = groups" was true but ran
    /// the pill into the tab bar for no extra information.
    @MainActor
    static func guideHoldLeftShort(_ map: RemoteControlMap) -> String? {
        let sidebar = RemoteControlStore.shared.useGroupSidebar
        if map.effectiveGuideAction(.leftShort, useGroupSidebar: sidebar) == .openGroupSidebar {
            return "Left = groups"
        }
        guard let phrase = guidePhraseShort(map.effectiveGuideAction(.leftLong, useGroupSidebar: sidebar)) else { return nil }
        return "Hold Left = \(phrase)"
    }
}


// MARK: - Remote hint strip (Logan 2026-09-11)

/// Synced preference backing the on-screen remote hint strip. Named to
/// match the Android twin's `show_remote_hints` so SyncManager maps the
/// two by name. Default ON.
let showRemoteHintsKey = "showRemoteHints"

/// Opacity of the black band behind the tvOS player chrome's bottom
/// control block (Logan 2026-09-11). One constant so both chromes and
/// the hint strip's own banded variant stay identical.
let playerChromeBandOpacity: Double = 0.88

/// Seconds of inactivity before the player controls fade, on BOTH tvOS
/// chromes (Logan 2026-09-11: exactly 3 s after the LAST user action).
/// One constant so the two paths cannot drift apart again.
let playerChromeFadeSeconds: Double = 3.0


