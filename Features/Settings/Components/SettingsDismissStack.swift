//
//  SettingsDismissStack.swift
//  Astral
//
//  Extracted verbatim from SettingsView.swift (Settings redesign Phase 1,
//  SettingsUIRedesign.md A4). No behavior change intended in this move.
//

import SwiftUI
import SwiftData


extension View {
    /// tvOS: logs "sheet open/close <name>" (with a landing line after the
    /// close) and names the page for rows inside it. iOS: no-op.
    @ViewBuilder
    func settingsSheetLog(_ name: String) -> some View {
        self
    }

    /// tvOS: logs "push/pop <name>" for a NavigationStack destination (with
    /// a landing line after the pop) and names the page. iOS: no-op.
    @ViewBuilder
    func settingsPushLog(_ name: String) -> some View {
        self
    }
}
