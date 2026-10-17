import SwiftUI

// MARK: - Hidden Groups Persistence

/// Reads/writes a set of hidden group names to UserDefaults for a given key.
enum HiddenGroupsStore {
    static func load(forKey key: String) -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: key),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(array)
    }

    static func save(_ groups: Set<String>, forKey key: String) {
        let data = try? JSONEncoder().encode(Array(groups).sorted())
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - Group Sort Mode

/// How the Live TV group list is ordered. Stored as the raw string so it
/// rides SyncManager's plain-string iCloud path.
enum GroupSortMode: String, CaseIterable {
    case `default`
    case alphabetical
    case manual

    var label: String {
        switch self {
        case .default:      return "Default"
        case .alphabetical: return "A-Z"
        case .manual:       return "Manual"
        }
    }
}

// MARK: - Group Order Persistence

/// Reads/writes the user-defined group order + sort mode.
///
/// The manual order MUST preserve sequence, so it is stored as a native
/// `[String]` array (rides SyncManager.syncStringArrayKeys, the
/// order-preserving iCloud path used by `favoriteOrder` - NOT the
/// hidden-group path, which `.sorted()`s on apply). The mode is a plain
/// string (syncStringKeys).
enum GroupOrderStore {
    static func load(forKey key: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func save(_ order: [String], forKey key: String) {
        UserDefaults.standard.set(order, forKey: key)
    }

    static func loadMode(forKey key: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? GroupSortMode.default.rawValue
    }

    static func saveMode(_ mode: String, forKey key: String) {
        UserDefaults.standard.set(mode, forKey: key)
    }

    /// Apply a saved manual order to a fresh server-ordered group list:
    /// groups present in `order` come first (in saved order), then any
    /// groups not in `order` (new since the order was saved) appended in
    /// server order; entries in `order` no longer present are dropped.
    static func apply(_ groups: [String], order: [String]) -> [String] {
        guard !order.isEmpty else { return groups }
        let present = Set(groups)
        var result = order.filter { present.contains($0) }
        let placed = Set(result)
        result.append(contentsOf: groups.filter { !placed.contains($0) })
        return result
    }

    /// Like `apply`, for the full pill token list (Favorites, All Channels,
    /// groups). Tokens the saved order does not mention keep their place:
    /// the pinned ones stay in front (orders saved before All Channels was
    /// movable, Roman via Discord 2026-09-06), new groups go to the end.
    static func applyTokens(_ tokens: [String], order: [String], pinnedFirst: Set<String>) -> [String] {
        guard !order.isEmpty else { return tokens }
        let present = Set(tokens)
        let ordered = order.filter { present.contains($0) }
        let placed = Set(ordered)
        let unlisted = tokens.filter { !placed.contains($0) }
        return unlisted.filter { pinnedFirst.contains($0) } + ordered + unlisted.filter { !pinnedFirst.contains($0) }
    }

    /// Resolve the effective display order for a sort mode.
    static func displayOrder(_ groups: [String], mode: String, order: [String]) -> [String] {
        switch GroupSortMode(rawValue: mode) ?? .default {
        case .alphabetical:
            return groups.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        case .manual:
            return apply(groups, order: order)
        case .default:
            return groups
        }
    }
}

// MARK: - Manage Groups Sheet

/// A sheet that toggles group visibility and (when `orderStorageKey` is
/// supplied) orders the groups via a Default / A-Z / Manual selector.
struct ManageGroupsSheet: View {
    let title: String
    let allGroups: [String]
    let storageKey: String
    let onDismiss: (Set<String>) -> Void

    /// When non-nil, enables the Default/A-Z/Manual order selector and
    /// persists the manual order under this key (mode under
    /// `<key>.sortMode`). Nil keeps the sheet visibility-only (VOD).
    var orderStorageKey: String? = nil
    /// Reports (modeRawValue, manualOrder) whenever the order config
    /// changes so the host can re-render its group pills.
    var onConfigChanged: ((String, [String]) -> Void)? = nil
    /// Live TV only: UserDefaults key holding the group the guide opens on
    /// ("" = All Channels, "favorites", or a group name). The sheet no longer
    /// SETS it (Logan 2026-09-17: that is a long press on the group itself,
    /// in the sidebar / pill row); non-nil now only marks the Live TV caller,
    /// whose pinned rows are orderable. Nil for VOD callers.
    var defaultGroupKey: String? = nil
    /// Whether the Favorites group exists right now (pinned row + default option).
    var favoritesAvailable: Bool = false
    /// Live TV only: whether the synthetic "Recently Watched" group is
    /// offered (pinned row + default option). Hidden by default, like any
    /// group the user has unchecked (Logan 2026-09-14).
    var recentlyWatchedAvailable: Bool = false
    /// VOD only: "Hidden" row, offered when the playlist has hidden titles.
    /// UNCHECKED by default; checking it surfaces the Hidden category pill
    /// on Movies / TV Shows (Logan 2026-09-14). Always the first row.
    var hiddenCategoryAvailable: Bool = false
    var hiddenCategoryOn: Bool = false
    var onToggleHiddenCategory: (() -> Void)? = nil
    /// Apple TV Live TV only: offers the guide Sidebar layout (Overlay / Shift
    /// guide) when Group Selection is Sidebar Menu (Logan 2026-09-14).
    var sidebarLayoutAvailable: Bool = false
    private let favoritesToken = "favorites"
    /// Token for the synthetic "last 25 channels watched" group. Handled
    /// everywhere the Favorites token is: group tokens, hidden groups,
    /// ordering, channel filtering, guide window.
    static let recentGroupToken = "recentlyWatched"
    private var recentToken: String { Self.recentGroupToken }
    private var recentOptionAvailable: Bool { recentlyWatchedAvailable }

    /// One-time seed so Recently Watched starts UNCHECKED (hidden) for
    /// every existing and new install. Runs once per hidden-groups key;
    /// after that the user's own check state is authoritative.
    static func seedRecentlyWatchedHidden(storageKey: String) {
        let marker = "\(storageKey).recentlyWatchedSeeded"
        guard !UserDefaults.standard.bool(forKey: marker) else { return }
        UserDefaults.standard.set(true, forKey: marker)
        var hidden = HiddenGroupsStore.load(forKey: storageKey)
        hidden.insert(recentGroupToken)
        HiddenGroupsStore.save(hidden, forKey: storageKey)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var hiddenGroups: Set<String> = []
    @State private var sortMode: GroupSortMode = .default
    /// The reconciled full manual order (every current group, in saved
    /// sequence). Mutated by drag (iOS) / d-pad move (tvOS).
    @State private var manualOrder: [String] = []

    @AppStorage("ui.iphone.compactChrome") private var compactChromeiPhone = false
    @AppStorage("ui.iphone.hideFilterBar") private var hideFilterBarCompact = false
    @AppStorage("ui.iphone.hideSearchBar") private var hideSearchBarCompact = false
    private var showsCompactLayoutSection: Bool {
        compactChromeiPhone && UIDevice.current.userInterfaceIdiom == .phone
    }

    private var reorderEnabled: Bool { orderStorageKey != nil }
    /// Live TV (has a default-group key): Favorites and All Channels are
    /// ordinary rows in Manual order so any group can go to the very top
    /// (Logan 2026-09-06). VOD callers order plain groups only.
    private var pinnedAreOrderable: Bool { reorderEnabled && defaultGroupKey != nil }
    private var pinnedTokens: [String] {
        (favoritesAvailable ? [favoritesToken] : [])
            + (recentOptionAvailable ? [recentToken] : [])
            + [allChannelsToken]
    }
    private var orderableTokens: [String] { pinnedAreOrderable ? pinnedTokens + allGroups : allGroups }
    private func seededOrder(_ saved: [String]) -> [String] {
        pinnedAreOrderable
            ? GroupOrderStore.applyTokens(orderableTokens, order: saved, pinnedFirst: Set(pinnedTokens))
            : GroupOrderStore.apply(allGroups, order: saved)
    }
    /// True when the pinned rows are folded into the movable list.
    private var pinnedInList: Bool { pinnedAreOrderable && sortMode == .manual }
    private func rowTitle(_ token: String) -> String { defaultTitle(token) }
    /// GH #80: the "All" pill sentinel stored in the hidden set when the user
    /// hides the All Channels pill (same token ChannelListView uses).
    private let allChannelsToken = "All"
    private var modeKey: String? { orderStorageKey.map { $0 + ".sortMode" } }

    /// Groups in the order they should be displayed for the current mode.
    private var displayList: [String] {
        switch sortMode {
        case .alphabetical:
            return allGroups.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        case .manual:
            return manualOrder.isEmpty ? orderableTokens : manualOrder
        case .default:
            return allGroups
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                if allGroups.isEmpty {
                    Text("No groups available")
                        .scaledFont(.bodyMedium.subtext())
                        .foregroundColor(Color.contrastText(.textSecondary))
                } else {
                    iOSGroupList
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if reorderEnabled && sortMode == .manual {
                    ToolbarItem(placement: .navigationBarLeading) {
                        EditButton().foregroundColor(.accentPrimary)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDismiss(hiddenGroups)
                        dismiss()
                    }
                    .foregroundColor(.accentPrimary)
                }
            }
        }
        .onAppear {
            if recentOptionAvailable { Self.seedRecentlyWatchedHidden(storageKey: storageKey) }
            hiddenGroups = HiddenGroupsStore.load(forKey: storageKey)
            if let key = orderStorageKey, let mKey = modeKey {
                sortMode = GroupSortMode(rawValue: GroupOrderStore.loadMode(forKey: mKey)) ?? .default
                manualOrder = seededOrder(GroupOrderStore.load(forKey: key))
            } else {
                sortMode = .default
                manualOrder = orderableTokens
            }
        }
        .onChange(of: sortMode) { _, newMode in
            // Switching into Manual seeds the manual order from whatever is
            // currently visible so dragging starts from the same arrangement.
            if newMode == .manual {
                manualOrder = seededOrder(manualOrder)
            }
            persistConfig()
        }
    }

    // MARK: - Mutations

    private func defaultTitle(_ token: String) -> String {
        if token.isEmpty || token == allChannelsToken { return "All Channels" }
        if token == favoritesToken { return "Favorites" }
        if token == recentToken { return "Recently Watched" }
        return token
    }

    private func toggleHidden(_ group: String) {
        if hiddenGroups.contains(group) { hiddenGroups.remove(group) }
        else { hiddenGroups.insert(group) }
        HiddenGroupsStore.save(hiddenGroups, forKey: storageKey)
    }

    private func persistConfig() {
        guard let key = orderStorageKey, let mKey = modeKey else { return }
        GroupOrderStore.saveMode(sortMode.rawValue, forKey: mKey)
        GroupOrderStore.save(manualOrder, forKey: key)
        onConfigChanged?(sortMode.rawValue, manualOrder)
    }

    private func moveGroups(from source: IndexSet, to destination: Int) {
        guard sortMode == .manual else { return }
        manualOrder.move(fromOffsets: source, toOffset: destination)
        persistConfig()
    }


    // MARK: non-tvOS layout - checkmark list
    private var iOSGroupList: some View {
        List {
            if showsCompactLayoutSection {
                Section {
                    Toggle(isOn: $hideFilterBarCompact) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hide Filter Bar")
                                .scaledFont(.bodyMedium)
                                .foregroundColor(.textPrimary)
                            Text("Removes the group pills strip from Live TV.")
                                .scaledFont(.labelSmall.subtext())
                                .foregroundColor(Color.contrastText(.textTertiary))
                        }
                    }
                    .tint(.accentPrimary)
                    .listRowBackground(Color.cardBackground)

                    Toggle(isOn: $hideSearchBarCompact) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hide Search Bar")
                                .scaledFont(.bodyMedium)
                                .foregroundColor(.textPrimary)
                            Text("Collapses the always-visible search drawer. Pull down on the list to search.")
                                .scaledFont(.labelSmall.subtext())
                                .foregroundColor(Color.contrastText(.textTertiary))
                        }
                    }
                    .tint(.accentPrimary)
                    .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Layout")
                        .scaledFont(.labelSmall.subtext())
                        .foregroundColor(Color.contrastText(.textSecondary))
                        .textCase(nil)
                }
            }

            // Order selector (Live TV only).
            if reorderEnabled {
                Section {
                    Picker("Order", selection: $sortMode) {
                        ForEach(GroupSortMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.cardBackground)
                } header: {
                    Text("Order")
                        .scaledFont(.labelSmall.subtext())
                        .foregroundColor(Color.contrastText(.textSecondary))
                        .textCase(nil)
                } footer: {
                    if sortMode == .manual {
                        Text("Tap Edit and/or long press, then drag to arrange groups.")
                            .scaledFont(.labelSmall.subtext())
                            .foregroundColor(Color.contrastText(.textTertiary))
                            .textCase(nil)
                    }
                }
            }

            // GH #80: the All Channels pill is hideable too; pinned in its own
            // section so the reorderable list's indices stay intact.
            Section {
                if hiddenCategoryAvailable {
                    Button {
                        onToggleHiddenCategory?()
                    } label: {
                        HStack {
                            Image(systemName: hiddenCategoryOn ? "checkmark.square.fill" : "square")
                                .scaledFont(.system(size: 20))
                                .foregroundColor(hiddenCategoryOn ? .accentPrimary : Color.contrastText(.textTertiary))
                                .frame(width: 28)
                            Text("Hidden")
                                .scaledFont(.bodyMedium.weight(.semibold))
                                .foregroundColor(hiddenCategoryOn ? .textPrimary : Color.contrastText(.textTertiary))
                            Spacer()
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
                if favoritesAvailable && !pinnedInList {
                    Button {
                        toggleHidden(favoritesToken)
                    } label: {
                        HStack {
                            Image(systemName: hiddenGroups.contains(favoritesToken) ? "square" : "checkmark.square.fill")
                                .scaledFont(.system(size: 20))
                                .foregroundColor(hiddenGroups.contains(favoritesToken) ? Color.contrastText(.textTertiary) : .accentPrimary)
                                .frame(width: 28)
                            Text("Favorites")
                                .scaledFont(.bodyMedium.weight(.semibold))
                                .foregroundColor(hiddenGroups.contains(favoritesToken) ? Color.contrastText(.textTertiary) : .textPrimary)
                            Spacer()
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
                if recentOptionAvailable && !pinnedInList {
                    Button {
                        toggleHidden(recentToken)
                    } label: {
                        HStack {
                            Image(systemName: hiddenGroups.contains(recentToken) ? "square" : "checkmark.square.fill")
                                .scaledFont(.system(size: 20))
                                .foregroundColor(hiddenGroups.contains(recentToken) ? Color.contrastText(.textTertiary) : .accentPrimary)
                                .frame(width: 28)
                            Text("Recently Watched")
                                .scaledFont(.bodyMedium.weight(.semibold))
                                .foregroundColor(hiddenGroups.contains(recentToken) ? Color.contrastText(.textTertiary) : .textPrimary)
                            Spacer()
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
                if !pinnedInList {
                Button {
                    toggleHidden(allChannelsToken)
                } label: {
                    HStack {
                        Image(systemName: hiddenGroups.contains(allChannelsToken) ? "square" : "checkmark.square.fill")
                            .scaledFont(.system(size: 20))
                            .foregroundColor(hiddenGroups.contains(allChannelsToken) ? Color.contrastText(.textTertiary) : .accentPrimary)
                            .frame(width: 28)
                        Text("All Channels")
                            .scaledFont(.bodyMedium.weight(.semibold))
                            .foregroundColor(hiddenGroups.contains(allChannelsToken) ? Color.contrastText(.textTertiary) : .textPrimary)
                        Spacer()
                    }
                }
                .listRowBackground(Color.cardBackground)
                }
            }

            Section {
                ForEach(displayList, id: \.self) { group in
                    Button {
                        toggleHidden(group)
                    } label: {
                        HStack {
                            Image(systemName: hiddenGroups.contains(group) ? "square" : "checkmark.square.fill")
                                .scaledFont(.system(size: 20))
                                .foregroundColor(hiddenGroups.contains(group) ? Color.contrastText(.textTertiary) : .accentPrimary)
                                .frame(width: 28)

                            Text(rowTitle(group))
                                .scaledFont(pinnedTokens.contains(group) ? .bodyMedium.weight(.semibold) : .bodyMedium)
                                .foregroundColor(hiddenGroups.contains(group) ? Color.contrastText(.textTertiary) : .textPrimary)

                            Spacer()
                        }
                    }
                    .listRowBackground(Color.cardBackground)
                }
                .onMove(perform: moveGroups)
            } header: {
                HStack {
                    Text("Check groups to show, uncheck to hide.")
                        .scaledFont(.labelSmall.subtext())
                        .foregroundColor(Color.contrastText(.textSecondary))
                        .textCase(nil)
                    Spacer()
                    Button("All") {
                        hiddenGroups.removeAll()
                        HiddenGroupsStore.save(hiddenGroups, forKey: storageKey)
                    }
                    .scaledFont(.labelSmall)
                    .foregroundColor(.accentPrimary)
                    .textCase(nil)
                    Text("·").foregroundColor(Color.contrastText(.textTertiary)).textCase(nil)
                    Button("None") {
                        hiddenGroups = Set(allGroups)
                        HiddenGroupsStore.save(hiddenGroups, forKey: storageKey)
                    }
                    .scaledFont(.labelSmall)
                    .foregroundColor(.accentPrimary)
                    .textCase(nil)
                }
            }
        }
        .buttonStyle(.plain)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

}

// MARK: - Filter Bar Button

/// Small icon button shown in the filter bar to open the manage-groups sheet.
struct ManageGroupsButton: View {
    let action: () -> Void
    let hiddenCount: Int

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .scaledFont(.system(size: 16, weight: .medium))
                    .foregroundColor(.accentPrimary)

                if hiddenCount > 0 {
                    Circle()
                        .fill(Color.statusWarning)
                        .frame(width: 7, height: 7)
                        .offset(x: 2, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

