import SwiftUI
import SwiftData

// MARK: - DVR tab

/// Media-center DVR tab (2026-09-05): hero for the recording in progress
/// (or the newest resumable recording), Recording Now / Scheduled /
/// Recent shelves, then every recording as 16:9 cards behind content-type
/// pills (Movies, TV Shows, Sports) and a sort circle. Same scaffold and
/// focus rules as the Movies and TV Shows tabs.
struct DVRView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Recording.createdAt, order: .reverse) private var allRecordings: [Recording]
    @Query private var servers: [ServerConnection]
    @StateObject private var coordinator = RecordingCoordinator.shared
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var art = DVRArtResolver.shared
    @ObservedObject private var playerSession = PlayerSession.shared
    @Binding var isPlaying: Bool
    var isSelected: Bool = true

    enum SortOrder: String, CaseIterable {
        case newest, oldest, title, channel
        var label: String {
            switch self {
            case .newest:  return "Newest First"
            case .oldest:  return "Oldest First"
            case .title:   return "Title A to Z"
            case .channel: return "Channel"
            }
        }
    }

    // Title A to Z by default: the library has an alphabet rail (Logan
    // 2026-09-06). A stored choice still wins.
    @AppStorage("dvrSortOrder") private var sortOrderRaw = SortOrder.title.rawValue
    private var sortOrder: SortOrder { SortOrder(rawValue: sortOrderRaw) ?? .title }
    @State private var selectedKind: DVRContentKind?
    @State private var showSortMenu = false
    // Search and Filter beside Sort, like Movies and TV Shows (Logan
    // 2026-09-10, all platforms): search matches title, subtitle and
    // description; Filter hides channels (HiddenGroupsStore "hiddenDvrChannels").
    @State private var searchText = ""
    @State private var showSearchField = false
    @State private var searchFieldFocused = false
    @State private var hiddenChannels: Set<String> = HiddenGroupsStore.load(forKey: "hiddenDvrChannels")
    @State private var showFilterMenu = false
    @State private var showManageChannels = false
    @FocusState private var iosSearchFocused: Bool

    @State private var playingRecording: PlayingRecording?
    @State private var recordingToDelete: Recording?
    @State private var showDeleteConfirmation = false
    @State private var showDeleteFromServerAlert = false
    /// "Delete from Device" on a SERVER recording that was saved to this
    /// device: removes the local file only, never the server's copy.
    @State private var showDeleteDeviceCopyAlert = false
    @State private var showDownloadConfirmation = false
    @State private var tabBarTracker = TabBarScrollTracker()
    @State private var infoTarget: ProgramInfoTarget?

    private var gridColumns: Int { isPhone ? 3 : 2 }
    private var gridSpacing: CGFloat { isPhone ? 8 : 12 }
    private let railWidth: CGFloat = 14   // matches Movies (Logan 2026-09-09)
    /// Scroll-time numbers read only by the rail jump math, kept OUT of
    /// view state: written on every scroll frame they re-rendered the whole
    /// tab (phone stutter, Logan 2026-09-09; same fix as Movies).
    private final class ScrollNumbers { var lastScrollY: CGFloat = 0; var gridTopVisible: CGFloat = 0; var rowPitch: CGFloat = 0
        /// Phone rail state. Observed ONLY by the rail overlay (DVRPhoneRail),
        /// never by DVRView: flipping it as @State here re-rendered the whole
        /// tab (~25 ms) at every pills crossing (Instruments 2026-09-09).
        let phoneRail = DVRPhoneRailState()
    }
    @State private var scrollNumbers = ScrollNumbers()
    private var lastScrollY: CGFloat { scrollNumbers.lastScrollY }
    @State private var scrollPosition = ScrollPosition()
    @State private var railVisible = false
    @State private var railTop: CGFloat?
    private var gridTopVisible: CGFloat { scrollNumbers.gridTopVisible }
    // Row pitch is measured by the first grid cell's onAppear, which fires
    // exactly as the pills scroll off; as @State that write re-rendered the
    // tab at that moment (the DVR "stutter right past the pills", 2026-09-09).
    private var rowPitch: CGFloat { scrollNumbers.rowPitch }
    /// The rail appears only for libraries worth jumping around in.
    private let railMinimumCount = 15
    private let phoneRailMinimumCount = 9

    // MARK: Data

    private var activeServer: ServerConnection? {
        servers.first(where: { $0.isActive }) ?? servers.first
    }

    /// Recordings for the active playlist. A capture running right now is
    /// exempt so the user can always stop it (see MyRecordingsView).
    private var visibleRecordings: [Recording] {
        func isCapturing(_ r: Recording) -> Bool { coordinator.activeSessions[r.id] != nil }
        guard let active = activeServer else { return allRecordings.filter(isCapturing) }
        let sid = active.id.uuidString
        // Dispatcharr 0.30 dvr_access "none": server-side recordings are not
        // listable for this account, but rows fetched while it still had
        // access can be sitting in the local store. Show only what this
        // device recorded itself (plus anything capturing right now, which
        // the user must always be able to stop). UNKNOWN never filters:
        // `dispatcharrCanViewDVR` is true for an unprobed account.
        if !active.dispatcharrCanViewDVR {
            return allRecordings.filter {
                isCapturing($0) || ($0.serverID == sid && $0.destination == .local)
            }
        }
        return allRecordings.filter { $0.serverID == sid || isCapturing($0) }
    }

    private static let terminalStatuses: [RecordingStatus] =
        [.completed, .stopped, .interrupted, .failed, .cancelled]

    private func isAiringNow(_ r: Recording) -> Bool {
        let now = Date()
        return r.effectiveStart <= now && now < r.effectiveEnd
    }

    private var recordingNow: [Recording] {
        visibleRecordings.filter {
            !Self.terminalStatuses.contains($0.status) && ($0.status == .recording || isAiringNow($0))
        }
    }

    private var scheduled: [Recording] {
        visibleRecordings
            .filter { !Self.terminalStatuses.contains($0.status) && $0.status != .recording && !isAiringNow($0) }
            .sorted { $0.effectiveStart < $1.effectiveStart }
    }

    /// Finished recordings that can be watched (failed / cancelled rows
    /// stay in the Settings list, not in the library).
    private var completed: [Recording] {
        visibleRecordings.filter { $0.status == .completed || $0.status == .stopped || $0.status == .interrupted }
    }

    /// The library: everything recorded or recording, newest first.
    private var library: [Recording] { recordingNow + completed }

    private var kindsPresent: [DVRContentKind] {
        let kinds = Set(library.map(DVRClassifier.kind(for:)))
        return DVRContentKind.allCases.filter { kinds.contains($0) }
    }

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }
    /// Channels with at least one recording, for the Filter page.
    private var channelNames: [String] {
        Array(Set(library.map(\.channelName).filter { !$0.isEmpty })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    private func clearSearch() {
        searchText = ""
        showSearchField = false
    }

    private var filteredLibrary: [Recording] {
        var items = library
        if let k = selectedKind { items = items.filter { DVRClassifier.kind(for: $0) == k } }
        if !hiddenChannels.isEmpty { items = items.filter { !hiddenChannels.contains($0.channelName) } }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            items = items.filter {
                $0.programTitle.localizedCaseInsensitiveContains(q)
                    || ($0.subTitle ?? "").localizedCaseInsensitiveContains(q)
                    || $0.programDescription.localizedCaseInsensitiveContains(q)
            }
        }
        switch sortOrder {
        case .newest:  items.sort { $0.scheduledStart > $1.scheduledStart }
        case .oldest:  items.sort { $0.scheduledStart < $1.scheduledStart }
        case .title:   items.sort { $0.programTitle.localizedCaseInsensitiveCompare($1.programTitle) == .orderedAscending }
        case .channel: items.sort { ($0.channelName, $0.scheduledStart) < ($1.channelName, $1.scheduledStart) }
        }
        return items
    }

    private var recent: [Recording] {
        Array(completed.sorted { $0.scheduledStart > $1.scheduledStart }.prefix(20))
    }

    /// Resume fractions by recording id, refreshed on appear, when the set of
    /// recordings changes, and after playback. Reading WatchProgress inside
    /// the body ran a SwiftData fetch per card per render (dozens per
    /// switch to this tab; the switch visibly lagged, Logan 2026-09-05).
    @State private var progressByID: [UUID: Double] = [:]

    private func progressFraction(_ rec: Recording) -> Double {
        progressByID[rec.id] ?? 0
    }

    private func refreshProgress() {
        var out: [UUID: Double] = [:]
        for rec in visibleRecordings {
            guard let id = rec.watchProgressID ?? (rec.destination == .local ? "local-\(rec.id.uuidString)" : nil),
                  let ms = WatchProgressManager.getResumePosition(vodID: id, serverID: rec.serverID), ms > 0 else { continue }
            // A capture still running has only recorded up to now.
            let end = rec.status == .recording ? min(Date(), rec.effectiveEnd) : rec.effectiveEnd
            let total = end.timeIntervalSince(rec.effectiveStart) * 1000
            guard total > 0 else { continue }
            out[rec.id] = min(1, Double(ms) / total)
        }
        if out != progressByID { progressByID = out }
    }

    /// Recording in progress first, else the newest recording with saved
    /// progress, else the newest recording.
    /// Phone deck: recordings in progress first, then finished ones with a
    /// saved position short of the end, newest first.
    private var continueWatching: [Recording] {
        let live = recordingNow.sorted { $0.scheduledStart > $1.scheduledStart }
        let partial = completed
            .filter { progressFraction($0) > 0 && progressFraction($0) < 0.97 }
            .sorted { $0.scheduledStart > $1.scheduledStart }
        return live + partial
    }

    private var heroRecording: Recording? {
        if let live = recordingNow.first(where: { actions.canPlay($0) }) ?? recordingNow.first { return live }
        let done = completed.sorted { $0.scheduledStart > $1.scheduledStart }
        if let partial = done.first(where: { progressFraction($0) > 0 && progressFraction($0) < 0.97 }) { return partial }
        return done.first
    }

    /// Title for the section header above the hero, matching the phone
    /// deck's wording (Logan 2026-09-11).
    private var continueWatchingTitle: String {
        let cw = continueWatching
        return (!cw.isEmpty && cw.allSatisfy(\.isInProgress)) ? "Recording Now" : "Continue Watching"
    }

    /// True when the hero is the Continue Watching hero (a capture running,
    /// or a finished recording with a saved position short of the end)
    /// rather than the library fallback pick (the newest finished
    /// recording), which carries no progress and is never labeled.
    private var heroIsContinueWatching: Bool {
        guard let lead = heroRecording else { return false }
        return continueWatching.contains { $0.id == lead.id }
    }

    private var headers: [String: String] { activeServer?.authHeaders ?? [:] }


    private var actions: RecordingActions {
        RecordingActions(servers: servers, modelContext: modelContext, coordinator: coordinator,
                         present: { playingRecording = $0 })
    }

    // MARK: Body

    var body: some View {
        let _ = TabProbe.body("DVRView")
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                if visibleRecordings.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            // Phone pass (Logan 2026-09-05): no navigation bar; the hero
            // starts under the status bar, sort sits in the library header.
            .toolbar(.hidden, for: .navigationBar)
        }
        .confirmationDialog("Sort Recordings", isPresented: $showSortMenu, titleVisibility: .visible) {
            ForEach(SortOrder.allCases, id: \.self) { order in
                Button(order.label) { sortOrderRaw = order.rawValue }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete Recording?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let rec = recordingToDelete { actions.deleteLocal(rec) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage(device: true))
        }
        .alert("Delete from Server?", isPresented: $showDeleteFromServerAlert) {
            Button("Delete", role: .destructive) {
                if let rec = recordingToDelete { actions.deleteFromServer(rec) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage(device: false))
        }
        .alert("Delete from Device?", isPresented: $showDeleteDeviceCopyAlert) {
            Button("Delete", role: .destructive) {
                if let rec = recordingToDelete { actions.deleteDeviceCopy(rec) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The copy saved on this device will be deleted. The recording stays on the Dispatcharr server.")
        }
        .alert("Save to Device?", isPresented: $showDownloadConfirmation) {
            Button("Save") {
                if let rec = recordingToDelete { actions.download(rec) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Download this recording from the Dispatcharr server to your device's local storage.")
        }
        .programInfoPresenter(item: $infoTarget)
        .fullScreenCover(item: $playingRecording) { item in
            PlayerView(
                urls: [item.url],
                title: item.title,
                headers: item.headers,
                isLive: false,
                isDVR: item.isDVR,
                vodID: item.vodID,
                vodServerID: item.serverID,
                vodType: "recording",
                resumePositionMs: item.resumePositionMs
            )
            .onDisappear { refreshProgress() }
        }
        .onChange(of: playerSession.mode) { _, mode in
            // Progress bars refresh after the container player closes.
            if mode == .idle { refreshProgress() }
        }
        .task {
            await reconcile()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                if Task.isCancelled { break }
                await reconcile()
            }
        }
        .onAppear {
            refreshProgress()
            art.resolve(visibleRecordings, modelContext: modelContext)
        }
        // Leaving this tab, or entering the fullscreen player, cancels and
        // closes search (Logan 2026-09-16).
        .onDismissSearch {
            iosSearchFocused = false
            if showSearchField || !searchText.isEmpty { clearSearch() }
        }
        .onChange(of: visibleRecordings.count) { _, _ in
            refreshProgress()
            art.resolve(visibleRecordings, modelContext: modelContext)
        }
    }

    private func deleteMessage(device: Bool) -> String {
        let where_ = device ? "from your device" : "from the Dispatcharr server"
        if let rec = recordingToDelete, !rec.programTitle.isEmpty {
            return "\u{201C}\(rec.programTitle)\u{201D} will be permanently deleted \(where_)."
        }
        return "This recording will be permanently deleted \(where_)."
    }

    private func reconcile() async {
        guard let active = activeServer, active.type == .dispatcharrAPI else { return }
        let api = DispatcharrAPI(baseURL: active.effectiveBaseURL,
                                 auth: .apiKey(active.effectiveApiKey),
                                 userAgent: active.effectiveUserAgent,
                                 authMode: active.dispatcharrHeaderMode)
        await coordinator.reconcileDispatcharrRecordings(api: api, serverID: active.id.uuidString,
                                                         modelContext: modelContext)
        art.resolve(visibleRecordings, modelContext: modelContext)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isPhone {
            phoneContent
        } else {
            legacyContent
        }
    }

    /// Phone: the shared media page, same as Movies and TV Shows (Logan
    /// 2026-09-09); the second deck is Recently Recorded.
    private var phoneContent: some View {
        let library = filteredLibrary
        let cwTitle = continueWatching.allSatisfy(\.isInProgress) ? "Recording Now" : "Continue Watching"
        let recentDeck = recent.count > 1 ? recent : []
        var rows: [PhoneRow] = []
        if !scheduled.isEmpty {
            rows.append(PhoneRow(id: "scheduled") { AnyView(shelf(title: "Scheduled", items: scheduled)) })
        }
        if coordinator.isApproachingQuotaLimit {
            rows.append(PhoneRow(id: "quota") { AnyView(quotaWarning) })
        }
        let kinds = kindsPresent
        return PhoneMediaPage(
            decks: [
                PhoneDeck(title: cwTitle, cards: continueWatching.map { rec in
                    PhoneDeckCard(id: rec.id.uuidString) { AnyView(phoneHero(rec)) }
                }),
                PhoneDeck(title: "Recently Recorded", cards: recentDeck.map { rec in
                    PhoneDeckCard(id: "recent-" + rec.id.uuidString) { AnyView(phoneHero(rec)) }
                }),
            ],
            rows: rows,
            headerTitle: "All Recordings",
            headerCount: library.count,
            sortMenu: {
                AnyView(ForEach(SortOrder.allCases, id: \.self) { order in
                    Button { sortOrderRaw = order.rawValue } label: {
                        if order == sortOrder { Label(order.label, systemImage: "checkmark") } else { Text(order.label) }
                    }
                })
            },
            pills: kinds.count > 1 ? kinds.map(\.label) : [],
            selectedPill: Binding(
                get: { selectedKind?.label },
                set: { label in selectedKind = kinds.first { $0.label == label } }
            ),
            itemCount: library.count,
            cell: { index in AnyView(card(library[index], inGrid: true)) },
            railLetters: railLetters,
            railTarget: { letter in
                library.firstIndex { AlphabetRail.bucket(for: $0.programTitle) == letter }
                    .map(VODWindowList.anchorID)
            },
            // DVR pushes through plain NavigationLinks with no path to read,
            // so this page cannot tell a pushed detail from its root. UIKit
            // pops the detail on the same re-tap either way; the scroll just
            // lands on the list the pop is uncovering.
            owningTab: .dvr
        )
    }

    private func phoneHero(_ rec: Recording) -> some View {
        DVRHero(recording: rec, headers: headers,
                progress: progressFraction(rec), canPlay: actions.canPlay(rec),
                inDeck: true,
                onPrimary: { heroPrimary(rec) },
                onSecondary: { heroSecondary(rec) },
                onStop: { actions.stop(rec) }, canManage: actions.canManage(rec),
                onInfo: { showInfo(rec) },
                menu: { menuItems(for: rec) })
    }

    private var legacyContent: some View {
        GeometryReader { outer in
            ZStack(alignment: .topLeading) {
                scrollBody(outer: outer)
                // Phone: same rail as Movies, parked at the right edge and
                // centered on the visible grid (Logan 2026-09-05).
                // Three columns: nine posters fill the display, so the rail
                // is worth having from nine (Logan 2026-09-05); tvOS keeps 15.
                // Stays mounted and fades with a local animation (a sibling
                // mount with a transition caught the scroll; same as Movies).
                if isPhone, filteredLibrary.count >= phoneRailMinimumCount {
                    DVRPhoneRail(state: scrollNumbers.phoneRail, letters: railLetters, railWidth: railWidth,
                                 boxWidth: outer.size.width, boxHeight: outer.size.height + outer.safeAreaInsets.top) { letter in
                        jumpToLetter(letter)
                    }
                }
            }
            .onPreferenceChange(GridTopKey.self) { gridTopY in
                guard let gridTopY else { return }
                scrollNumbers.gridTopVisible = gridTopY
                // Same rules as Movies: the flip runs in no animation
                // transaction (the rail animates itself), and the park
                // position moves in 4pt steps only while the rail shows.
                let want = gridTopY <= 110
                // The park position is set ONCE, at the moment the rail
                // appears, and never tracks the scroll. Writes go to the rail's
                // own observable so only the rail overlay re-renders.
                let rail = scrollNumbers.phoneRail
                if want != rail.visible {
                    if want { rail.top = (max(0, gridTopY) / 8).rounded() * 4 }
                    rail.visible = want
                }
            }
        }
    }

    private struct GridTopKey: PreferenceKey {
        nonisolated(unsafe) static var defaultValue: CGFloat? = nil
        static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
            if let v = nextValue() { value = v }
        }
    }

    private var railLetters: Set<String> {
        Set(filteredLibrary.map { AlphabetRail.bucket(for: $0.programTitle) })
    }

    private func jumpToLetter(_ letter: String) {
        let items = filteredLibrary
        guard let index = items.firstIndex(where: { AlphabetRail.bucket(for: $0.programTitle) == letter }) else { return }
        let id = items[index].id
        debugLog("[RAIL] dvr jump \(letter) index=\(index) pitch=\(rowPitch) gridTop=\(gridTopVisible) scrollY=\(lastScrollY)")
        if rowPitch > 0 {
            // Absolute offset: scrollTo(id) silently no-ops for lazy grid
            // rows not yet built.
            let row = index / gridColumns
            let gridTopContent = gridTopVisible + lastScrollY
            let gridLead: CGFloat = 0
            let y = gridTopContent + gridLead + CGFloat(row) * rowPitch - 24
            withAnimation(.easeInOut(duration: 0.25)) { scrollPosition.scrollTo(y: max(0, y)) }
        }
    }


    private func scrollBody(outer: GeometryProxy) -> some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
            // Plain stack: a LazyVStack unloaded the Recording Now shelf once
            // it scrolled off, so Up from Recent landed on a UIKit filler and
            // nudged the scroll before the shelf came back (trace 2026-09-05
            // 01:47:12). The grid below stays lazy.
            VStack(alignment: .leading, spacing: sectionSpacing) {
                if isPhone, !continueWatching.isEmpty {
                    // Phone (Logan 2026-09-05): a deck of every recording that
                    // is started but unfinished, a recording in progress first.
                    Text(continueWatching.allSatisfy(\.isInProgress) ? "Recording Now" : "Continue Watching")
                        .scaledFont(.headlineSmall)
                        .foregroundColor(.textPrimary)
                        .padding(.horizontal, sectionInset)
                    PhoneCardDeck(items: continueWatching, cardHeight: 220) { rec in
                        DVRHero(recording: rec, headers: headers,
                                progress: progressFraction(rec), canPlay: actions.canPlay(rec),
                                inDeck: true,
                                onPrimary: { heroPrimary(rec) },
                                onSecondary: { heroSecondary(rec) },
                                onStop: { actions.stop(rec) }, canManage: actions.canManage(rec),
                                onInfo: { showInfo(rec) },
                                menu: { menuItems(for: rec) })
                    }
                } else if let hero = heroRecording {
                    DVRHero(recording: hero, headers: headers,
                            progress: progressFraction(hero), canPlay: actions.canPlay(hero),
                            onPrimary: { heroPrimary(hero) },
                            onSecondary: { heroSecondary(hero) },
                            onStop: { actions.stop(hero) }, canManage: actions.canManage(hero),
                            onInfo: { showInfo(hero) },
                            menu: { menuItems(for: hero) })
                }
                if !recordingNow.isEmpty {
                    shelf(title: "Recording Now", items: recordingNow)
                }
                if !scheduled.isEmpty {
                    shelf(title: "Scheduled", items: scheduled)
                }
                if recent.count > 1 {
                    if isPhone {
                        // Phone (Logan 2026-09-05): the same deck as Continue Watching.
                        Text("Recent Recordings")
                            .scaledFont(.headlineSmall)
                            .foregroundColor(.textPrimary)
                            .padding(.horizontal, sectionInset)
                        PhoneCardDeck(items: recent, cardHeight: 220) { rec in
                            DVRHero(recording: rec, headers: headers,
                                    progress: progressFraction(rec), canPlay: actions.canPlay(rec),
                                    inDeck: true,
                                    onPrimary: { heroPrimary(rec) },
                                    onSecondary: { heroSecondary(rec) },
                                    onStop: { actions.stop(rec) }, canManage: actions.canManage(rec),
                                    onInfo: { showInfo(rec) },
                                    menu: { menuItems(for: rec) })
                        }
                    } else {
                        shelf(title: "Recent Recordings", items: recent)
                    }
                }
                if coordinator.isApproachingQuotaLimit {
                    quotaWarning
                }
                if !library.isEmpty {
                    libraryHeader(proxy: proxy)
                        .id("dvr-library")
                    grid
                }
            }
            .padding(.bottom, PadTabPill.isActive ? PadTabPill.clearanceUnderSafeArea : 80)
        }
        .coordinateSpace(name: "dvrScroll")
        // Content flows under the tab bar like Movies and Live TV: without
        // these the system bar painted a solid platter over a hard edge
        // (Logan 2026-09-09).
        .ignoresSafeArea(.container, edges: .bottom)
        .astralContentUnderTabBar()
        .astralNoTopScrollEdge()
        .scrollPosition($scrollPosition)
        // iPad: re-tapping the DVR tab while on it brings the page back to the
        // top (phone does the same inside PhoneMediaPage).
        .onReceive(
            NotificationCenter.default.publisher(for: .astralTabReselected)
        ) { note in
            guard (note.userInfo?["tab"] as? String) == AppTab.dvr.rawValue else { return }
            withAnimation(.easeInOut(duration: 0.3)) { scrollPosition.scrollTo(edge: .top) }
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            // Same tracker as Movies and Live TV (hide after 48 pt down, show
            // after 12 pt up); the flag is read, not observed, so no DVR
            // re-render per frame.
            if let flip = tabBarTracker.update(oldY: scrollNumbers.lastScrollY, newY: y,
                                               hidden: TabBarCollapseState.shared.collapsed) {
                TabBarCollapseState.shared.set(flip)
            }
            scrollNumbers.lastScrollY = y
        }
        }   // ScrollViewReader
    }

    /// Same warning My Recordings shows on iOS: local storage near its cap.
    private var quotaWarning: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
            Text("Storage is approaching the limit. New recordings may not finish.")
                .scaledFont(.labelMedium)
                .foregroundColor(.textPrimary)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.yellow.opacity(0.15)))
        .padding(.horizontal, sectionInset)
    }

    /// The Continue Watching header (24 pt semibold) plus the 8 pt shelf gap
    /// under it pushes the hero down by 37 pt (Logan 2026-09-11).
    private var heroHideThreshold: CGFloat {
        (heroRecording != nil ? 620 : 260) + (heroIsContinueWatching ? 37 : 0)
    }

    private var sectionSpacing: CGFloat {
        return 20
    }

    private func heroPrimary(_ rec: Recording) {
        if rec.isInProgress {
            // Watch from Start while the recording continues.
            if rec.destination == .dispatcharrServer { actions.playServer(rec, fromStart: true) }
        } else {
            actions.play(rec)
        }
    }

    private func heroSecondary(_ rec: Recording) {
        if rec.isInProgress {
            if rec.destination == .dispatcharrServer { actions.playServer(rec, liveEdge: true) }
        } else if rec.destination == .local, let path = rec.localFilePath {
            // Play from Beginning: local files ignore the saved position.
            if let id = rec.watchProgressID {
                WatchProgressManager.delete(vodID: id, serverID: rec.serverID)
            }
            actions.playLocal(rec, path: path)
        } else {
            actions.playServer(rec, fromStart: true)
        }
    }

    // MARK: Shelves

    private func shelf(title: String, items: [Recording]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .scaledFont(.headlineSmall)
                .foregroundColor(.textPrimary)
                .padding(.horizontal, sectionInset)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: gridSpacing) {
                    ForEach(items, id: \.id) { rec in
                        card(rec)
                            .frame(width: shelfCardWidth)
                    }
                }
                .padding(.horizontal, sectionInset)
            }
        }
    }

    private var sectionInset: CGFloat {
        return 16
    }

    private var shelfCardWidth: CGFloat {
        return isPhone ? 150 : 220
    }

    private var isPhone: Bool {
        return UIDevice.current.userInterfaceIdiom == .phone
    }

    // MARK: Library header + grid

    private func libraryHeader(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                // Plain text, tappable on the phone: scrolls the library to
                // the top of the page (Logan 2026-09-05), same as Movies.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(isSearching ? "Results" : "All Recordings")
                        .scaledFont(.headlineSmall)
                        .foregroundColor(.textPrimary)
                    Text("\(filteredLibrary.count)")
                        .scaledFont(.labelMedium.subtext())
                        .foregroundColor(Color.contrastText(.textTertiary))
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard isPhone else { return }
                    withAnimation(.easeInOut(duration: 0.55)) { proxy.scrollTo("dvr-library", anchor: .top) }
                }
                Spacer()
                iOSHeaderControls
            }
            .padding(.horizontal, sectionInset)
            if showSearchField {
                iOSSearchField
                    .padding(.horizontal, sectionInset)
            }

            if kindsPresent.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        kindPill("All", isSelected: selectedKind == nil) { selectedKind = nil }
                        ForEach(kindsPresent) { k in
                            kindPill(k.label, isSelected: selectedKind == k) {
                                selectedKind = (selectedKind == k) ? nil : k
                            }
                        }
                    }
                    .padding(.horizontal, sectionInset)
                }
            }
        }
    }


    private var iOSHeaderControls: some View {
        HStack(spacing: 8) {
            Button {
                if showSearchField {
                    withAnimation(.spring(response: 0.3)) { clearSearch() }
                } else {
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { showSearchField = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { iosSearchFocused = true }
                }
            } label: { iOSCircle("magnifyingglass") }
                .accessibilityLabel(showSearchField ? "Close search" : "Search")
            Menu {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Button {
                        sortOrderRaw = order.rawValue
                    } label: {
                        if order == sortOrder {
                            Label(order.label, systemImage: "checkmark")
                        } else {
                            Text(order.label)
                        }
                    }
                }
            } label: { iOSCircle("arrow.up.arrow.down") }
            .accessibilityLabel("Sort")
            Button { showManageChannels = true } label: { iOSCircle("line.3.horizontal.decrease") }
                .accessibilityLabel("Filter")
        }
        .sheet(isPresented: $showManageChannels) {
            ManageGroupsSheet(
                title: "Manage Channels",
                allGroups: channelNames,
                storageKey: "hiddenDvrChannels",
                onDismiss: { updated in hiddenChannels = updated }
            )
        }
    }

    private var iOSSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .scaledFont(.system(size: 15, weight: .semibold))
                .foregroundColor(Color.contrastText(.textSecondary))
            TextField("Search recordings", text: $searchText)
                .scaledFont(.system(size: 16))
                .foregroundColor(.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($iosSearchFocused)
            Button {
                iosSearchFocused = false
                withAnimation(.spring(response: 0.25)) { clearSearch() }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(.system(size: 16))
                    .foregroundColor(Color.contrastText(.textSecondary))
            }
            .accessibilityLabel("Clear and close search")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .background(Capsule().fill(Color.elevatedBackground))
    }

    private func iOSCircle(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))  // glyph in a fixed box: not text, stays fixed
            .foregroundColor(.textPrimary)
            .frame(width: 38, height: 38)
            .background(Circle().fill(Color.textPrimary.opacity(0.08)))
    }

    @ViewBuilder
    private func kindPill(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .scaledFont(.labelMedium)
                .foregroundColor(isSelected ? .appBackground : Color.contrastText(.textSecondary))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(isSelected ? Color.accentPrimary : Color.elevatedBackground))
        }
        .buttonStyle(.plain)
    }

    private var grid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: gridColumns)
        let items = filteredLibrary
        let firstID = items.first?.id
        return LazyVGrid(columns: columns, alignment: .leading, spacing: gridRowSpacing) {
            ForEach(items, id: \.id) { rec in
                card(rec, inGrid: true)
                    .background(GeometryReader { g in
                        Color.clear.onAppear {
                            if rec.id == firstID { scrollNumbers.rowPitch = g.size.height + gridRowSpacing }
                        }
                    })
            }
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: GridTopKey.self,
                                   value: g.frame(in: .named("dvrScroll")).minY.rounded())
        })
        // Phone: 2 pt extra each side (column gap 8) so the alphabet rail
        // at the edge clears the posters (Logan 2026-09-09).
        .padding(.horizontal, isPhone ? 2 : 0)
        .padding(.horizontal, sectionInset)
    }

    private var gridRowSpacing: CGFloat {
        return 16
    }

    // MARK: Cards

    @ViewBuilder
    private func card(_ rec: Recording, inGrid: Bool = false) -> some View {
        let button = Button {
            select(rec)
        } label: {
            if isPhone {
                DVRPosterCard(recording: rec, headers: headers, progress: progressFraction(rec))
            } else {
                DVRRecordingCard(recording: rec, headers: headers, progress: progressFraction(rec))
            }
        }
        .buttonStyle(.plain)
        .contextMenu { menuItems(for: rec) }
        .id(rec.id)
        button
    }

    /// The Live TV program info sheet for a recording. The guide row that
    /// matches by title and air window lends its description, category and
    /// Dispatcharr program id (the sheet lazy-loads art and categories from
    /// it); the recording's own fields cover the rest.
    private func showInfo(_ rec: Recording) {
        debugLog("[DECK] card tap (DVR) \(Int((CACurrentMediaTime() - PhoneCardDeckStats.lastDragEnded) * 1000)) ms after last drag end")
        let title = rec.programTitle
        let sid = rec.serverID
        let start = rec.scheduledStart
        let end = rec.scheduledEnd
        var descriptor = FetchDescriptor<EPGProgram>(
            predicate: #Predicate<EPGProgram> { p in
                p.serverID == sid && p.title == title && p.startTime < end && p.endTime > start
            }
        )
        descriptor.fetchLimit = 1
        let epg = try? modelContext.fetch(descriptor).first
        let channelName = rec.channelName.isEmpty
            ? (ChannelStore.shared.channels.first(where: {
                $0.id == rec.channelID || $0.dispatcharrChannelID.map(String.init) == rec.channelID
            })?.name ?? "")
            : rec.channelName
        infoTarget = ProgramInfoTarget(
            channelName: channelName,
            title: title.isEmpty ? "Recording" : title,
            start: epg?.startTime ?? start,
            end: epg?.endTime ?? end,
            description: rec.programDescription.isEmpty ? (epg?.programDescription ?? "") : rec.programDescription,
            category: (rec.epgCategory ?? "").isEmpty ? (epg?.category ?? "") : (rec.epgCategory ?? ""),
            programID: rec.dispatcharrProgramID ?? epg?.programID,
            subTitle: rec.subTitle ?? epg?.subTitle,
            season: rec.seasonNumber ?? epg?.season,
            episode: rec.episodeNumber ?? epg?.episode,
            isNew: epg?.isNew ?? false,
            isLiveBroadcast: epg?.isLiveBroadcast ?? false,
            isPremiere: epg?.isPremiere ?? false,
            isFinale: epg?.isFinale ?? false,
            isRepeat: epg?.isRepeat ?? false,
            recording: recordingFacts(rec))
    }

    private func recordingFacts(_ rec: Recording) -> RecordingFacts {
        let path = rec.dispatcharrFileURL ?? rec.localFilePath ?? ""
        var ext = URL(string: path).map { $0.pathExtension } ?? (path as NSString).pathExtension
        if ext.isEmpty, let name = rec.remoteFileName ?? rec.localFilePath {
            ext = (name as NSString).pathExtension
        }
        let location: String
        if rec.destination == .local {
            location = "This Device"
        } else {
            location = servers.first(where: { $0.id.uuidString == rec.serverID })?.name ?? "Dispatcharr"
        }
        let status: String
        switch rec.status {
        case .scheduled: status = "Scheduled"
        case .recording: status = "Recording"
        case .completed: status = "Completed"
        default: status = rec.statusRaw.capitalized
        }
        return RecordingFacts(recordedOn: rec.scheduledStart,
                              windowStart: rec.scheduledStart, windowEnd: rec.scheduledEnd,
                              fileSizeBytes: rec.fileSizeBytes,
                              format: ext.lowercased() == "m3u8" ? "HLS" : ext,
                              location: location, status: status,
                              videoCodec: rec.videoCodec, resolution: rec.videoResolution,
                              frameRate: rec.videoFrameRate, videoBitrateKbps: rec.videoBitrateKbps,
                              audioCodec: rec.audioCodec, audioChannels: rec.audioChannels)
    }

    private func select(_ rec: Recording) {
        if actions.canPlay(rec) {
            actions.play(rec)
        } else if rec.isUpcoming {
            // Scheduled: nothing to play; the menu carries Cancel.
            debugLog("[DVR] select scheduled \(rec.programTitle): use the context menu to cancel")
        }
    }

    // MARK: Menu

    @ViewBuilder
    private func menuItems(for rec: Recording) -> some View {
        Button { showInfo(rec) } label: { Label("Program Info", systemImage: "info.circle") }
        if rec.isCompleted || rec.status == .stopped || rec.status == .interrupted {
            // Same wording as the hero card's primary button: "Resume" when
            // the recording has saved progress (GH #93 follow-up, Logan
            // 2026-10-12: the long-press menu had no Resume).
            Button { actions.play(rec) } label: {
                Label(progressFraction(rec) > 0 ? "Resume" : "Play", systemImage: "play.fill")
            }
            if rec.destination == .dispatcharrServer, rec.remoteRecordingID != nil {
                Button { actions.playServer(rec, fromStart: true) } label: {
                    Label("Watch from Beginning", systemImage: "backward.end.fill")
                }
                Button { recordingToDelete = rec; showDownloadConfirmation = true } label: {
                    Label("Save to Device", systemImage: "square.and.arrow.down")
                }
                if actions.canManage(rec) {
                    Button { actions.runComskip(rec) } label: {
                        Label("Remove Commercials", systemImage: "scissors")
                    }
                }
            }
        }
        if rec.isInProgress {
            if rec.destination == .dispatcharrServer, rec.dispatcharrFileURL != nil {
                if progressFraction(rec) > 0 {
                    Button { actions.playServer(rec) } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                }
                Button { actions.playServer(rec, liveEdge: true) } label: {
                    Label("Start at Live", systemImage: "play.fill")
                }
                Button { actions.playServer(rec, fromStart: true) } label: {
                    Label("Watch from Beginning", systemImage: "backward.end.fill")
                }
            }
            if actions.canManage(rec) {
                Button { actions.stop(rec) } label: { Label("Stop Recording", systemImage: "stop.fill") }
            }
        }
        if rec.isUpcoming, actions.canManage(rec) {
            Button(role: .destructive) { actions.cancel(rec) } label: {
                Label("Cancel Recording", systemImage: "xmark.circle")
            }
        }
        if !rec.isUpcoming {
            if rec.destination == .local {
                Button(role: .destructive) { recordingToDelete = rec; showDeleteConfirmation = true } label: {
                    Label("Delete from Device", systemImage: "trash")
                }
            } else {
                // A server recording saved with "Save to Device" also has
                // bytes on this device: offer BOTH, and never gate the
                // device copy on DVR access (it is the user's own file).
                if actions.hasDeviceCopy(rec) {
                    Button(role: .destructive) { recordingToDelete = rec; showDeleteDeviceCopyAlert = true } label: {
                        Label("Delete from Device", systemImage: "trash")
                    }
                }
                if actions.canManage(rec) {
                    Button(role: .destructive) { recordingToDelete = rec; showDeleteFromServerAlert = true } label: {
                        Label("Delete from Server", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "record.circle")
                .scaledFont(.system(size: 56))
                .foregroundColor(Color.contrastText(.textTertiary))
            Text("No Recordings")
                .scaledFont(.headlineLarge)
                .foregroundColor(.textPrimary)
            Text("Recordings for the active playlist show up here. Schedule one from the guide.")
                .scaledFont(.bodySmall.subtext())
                .foregroundColor(Color.contrastText(.textSecondary))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding()
    }
}

// MARK: - Hero

/// Full-bleed hero, same construction as MoviesHero (art clipped to the
/// rounded shape, alpha-mask fades, copy over it, capsule actions).
struct DVRHero<Menu: View>: View {
    /// Settings > Appearance > Text Size: the hero keeps its fixed height
    /// (focus and scroll thresholds depend on it), so copy sheds lines instead.
    @Environment(\.astralTextScale) private var textScale
    @Environment(\.astralSubtextScale) private var subtextScale
    let recording: Recording
    var headers: [String: String] = [:]
    let progress: Double
    let canPlay: Bool
    /// Inside the phone card deck: the deck owns the margins.
    var inDeck: Bool = false
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    let onStop: () -> Void
    /// Dispatcharr 0.30 DVR access: a "view" account never sees Stop
    /// Recording on the hero (the row menu hides it the same way).
    var canManage: Bool = true
    /// Phone: a tap on the card itself (outside its buttons) opens the
    /// program info sheet (Logan 2026-09-05).
    var onInfo: (() -> Void)? = nil
    /// tvOS pager: focus ids become "<prefix>|<role>" so each page's
    /// buttons are distinct (Movies uses "<page id>|primary" the same way).
    var focusPrefix: String? = nil
    @ViewBuilder let menu: () -> Menu
    /// The row menu behind the right-most options circle (Logan 2026-09-10, all platforms).
    @State private var showOptions = false

    private let heroHeight: CGFloat = 220
    private let corner: CGFloat = 16
    private let copyInset: CGFloat = 16
    private let metaSize: CGFloat = 13
    private var titleFont: AstralFont { .displayMedium }

    private var artworkURL: URL? { (recording.backdropURL ?? recording.posterURL).flatMap { URL(string: $0) } }
    private var logoURL: URL? { recording.channelLogoURL.flatMap { URL(string: $0) } }

    var body: some View {
        ZStack(alignment: .leading) {
            artwork
            LinearGradient(
                stops: [
                    .init(color: Color.appBackground.opacity(0.05), location: 0),
                    .init(color: Color.appBackground.opacity(0.92), location: 1)
                ],
                startPoint: .top, endPoint: .bottom)
            copy
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .onTapGesture { onInfo?() }
        // In the deck the deck places the card at the grid's edge; only the
        // standalone hero keeps its own 16 pt (was unconditional on iOS,
        // which is why the DVR deck sat 16 pt in, Logan 2026-09-09).
        .padding(.horizontal, inDeck ? 0 : 16)
    }

    @ViewBuilder
    private var artwork: some View {
        GeometryReader { geo in
            if let url = artworkURL {
                // Opaque placeholder: a clear one let the page show through
                // the card while its art loaded (Logan 2026-09-09).
                AuthPosterImage(url: url, headers: headers, placeholder: .cardBackground, maxPixel: 1920)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                ZStack {
                    Color.cardBackground
                    if let logoURL {
                        AuthPosterImage(url: logoURL, headers: headers, placeholder: .clear, maxPixel: 600)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width * 0.28)
                            .opacity(0.9)
                            .offset(x: geo.size.width * 0.28)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }


    private var metaParts: [String] {
        var parts: [String] = []
        if !recording.channelName.isEmpty { parts.append(recording.channelName) }
        parts.append(DVRFormat.dateRange(recording.scheduledStart, recording.scheduledEnd))
        if recording.isInProgress {
            let sec = max(0, Date().timeIntervalSince(recording.effectiveStart))
            parts.append("\(DVRFormat.duration(seconds: sec)) recorded")
        } else if let se = recording.displaySeasonEpisode {
            parts.append("S\(se.season) E\(se.episode)")
        } else {
            parts.append(DVRFormat.duration(seconds: recording.effectiveEnd.timeIntervalSince(recording.effectiveStart)))
        }
        if let r = recording.contentRating, !r.isEmpty { parts.append(r) }
        return parts
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: copySpacing) {
            if recording.isInProgress {
                HStack(spacing: 8) {
                    Circle().fill(Color.red).frame(width: 10, height: 10)
                    Text("Recording now")
                }
                .scaledFont(.system(size: metaSize - 2, weight: .bold))
                .foregroundColor(.red)
            }
            // The page's "Continue Watching" section header above the hero
            // replaces the in-card label (Logan 2026-09-11).
            Text(recording.programTitle.isEmpty ? "Recording" : recording.programTitle)
                .scaledFont(titleFont)
                .foregroundColor(.textPrimary)
                .lineLimit(textScale > 1.1 ? 1 : 2)
            if let sub = recording.subTitle, !sub.isEmpty {
                Text(sub)
                    .scaledFont(.system(size: metaSize + 2, weight: .semibold))
                    .foregroundColor(.textPrimary.opacity(0.9))
                    .lineLimit(1)
            }
            // Phone: the channel on its own line, the rest on one line
            // (one HStack wrapped the date mid-range, 2026-09-05).
            VStack(alignment: .leading, spacing: 2) {
                if !recording.channelName.isEmpty {
                    Text(recording.channelName).lineLimit(1)
                }
                Text(metaParts.filter { $0 != recording.channelName }.joined(separator: " · "))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .scaledFont(.system(size: metaSize, weight: .medium).subtext())
            .foregroundColor(Color.contrastText(.textSecondary))
            actions
        }
        .padding(copyInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    /// Secondary hero buttons are icon-only circles on the phone, labelled
    /// pills on tvOS (same rule as MoviesHeroCard).
    private func secondaryTitle(_ title: String) -> String {
        return ""
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if recording.isInProgress {
                if canPlay {
                    focusable(MoviesHeroButton(title: "Watch from Start", systemImage: "play.fill",
                                               isPrimary: true, action: onPrimary), role: "primary")
                    focusable(MoviesHeroButton(title: "Jump to Live", systemImage: "dot.radiowaves.left.and.right",
                                               isPrimary: false, action: onSecondary), role: "secondary")
                }
                if canManage {
                    focusable(MoviesHeroButton(title: "Stop Recording", systemImage: "stop.fill",
                                               isPrimary: !canPlay, action: onStop), role: canPlay ? "stop" : "primary")
                }
            } else {
                focusable(MoviesHeroButton(title: progress > 0 ? "Resume" : "Play", systemImage: "play.fill",
                                           isPrimary: true, action: onPrimary), role: "primary")
                if progress > 0 {
                    // iPhone: icon circle like the Movies / TV Shows hero and
                    // the Android DVR card (Logan 2026-09-09); tvOS keeps the
                    // labelled pill.
                    focusable(MoviesHeroButton(title: secondaryTitle("Play from Beginning"), systemImage: "gobackward",
                                               isPrimary: false, action: onSecondary), role: "secondary")
                }
            }
            // Details on every card, deck included (was hidden in the phone
            // decks; Android and the Movies hero always show it).
            if let onInfo {
                focusable(MoviesHeroButton(title: secondaryTitle("Details"), systemImage: "info.circle",
                                           isPrimary: false, action: onInfo), role: "details")
            }
            focusable(MoviesHeroButton(title: "", systemImage: "ellipsis",
                                       isPrimary: false, action: { showOptions = true }), role: "options")
        }
        .padding(.top, 4)
        .confirmationDialog("Options", isPresented: $showOptions, titleVisibility: .hidden) { menu() }
    }

    @ViewBuilder
    private func focusable<V: View>(_ view: V, role: String) -> some View {
        view
    }

    private var copySpacing: CGFloat {
        return 6
    }
}


// MARK: - Card

/// 16:9 recording card: art (server, EPG, TMDB or TheSportsDB; channel
/// logo when none), REC / Scheduled badge, channel logo bottom-left,
/// Phone library tile: a 2:3 poster (TMDB or the library's, channel logo
/// when neither exists), REC badge, progress bar, title and meta below,
/// like the Movies grid (Logan 2026-09-05).
struct DVRPosterCard: View {
    @Environment(\.astralTextScale) private var textScale
    let recording: Recording
    var headers: [String: String] = [:]
    var progress: Double = 0
    @ObservedObject private var art = DVRArtResolver.shared

    private var posterURL: URL? { recording.posterURL.flatMap { URL(string: $0) } }
    private var logoURL: URL? { recording.channelLogoURL.flatMap { URL(string: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            poster
                .aspectRatio(2/3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            // Centered under the poster like the Movies cards (Logan 2026-09-10).
            VStack(alignment: .center, spacing: 2) {
                Text(recording.programTitle.isEmpty ? "Recording" : recording.programTitle)
                    .scaledFont(.labelSmall)
                    .foregroundColor(.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .frame(height: TextScale.grow(34, textScale), alignment: .top)
                Text(meta)
                    .scaledFont(.system(size: 11).subtext())
                    .foregroundColor(Color.contrastText(.textSecondary))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
        }
        .contentShape(Rectangle())
    }

    private var meta: String {
        var parts = [DVRFormat.day(recording.scheduledStart)]
        if recording.isInProgress {
            parts.append("Recording")
        } else if recording.isUpcoming {
            parts.append(DVRFormat.time(recording.scheduledStart))
        } else {
            parts.append(DVRFormat.duration(seconds: recording.effectiveEnd.timeIntervalSince(recording.effectiveStart)))
        }
        if let se = recording.displaySeasonEpisode { parts.append("S\(se.season) E\(se.episode)") }
        return parts.joined(separator: " · ")
    }

    private var poster: some View {
        Color.cardBackground
            .overlay {
                if let posterURL {
                    AuthPosterImage(url: posterURL, headers: headers, placeholder: .cardBackground, maxPixel: 500)
                        .aspectRatio(contentMode: .fill)
                } else if let logoURL {
                    AuthPosterImage(url: logoURL, headers: headers, placeholder: .clear, maxPixel: 240)
                        .aspectRatio(contentMode: .fit)
                        .padding(18)
                } else {
                    NoPosterPlaceholder()
                }
            }
            .clipped()
        .overlay(alignment: .topLeading) {
            if recording.isInProgress {
                HStack(spacing: 3) {
                    Circle().fill(Color.red).frame(width: 5, height: 5)
                    Text("REC").scaledFont(.system(size: 9, weight: .heavy))
                }
                .foregroundColor(.red)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.7)))
                .padding(5)
            }
        }
        .overlay(alignment: .bottom) {
            if progress > 0 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.black.opacity(0.45))
                        Rectangle().fill(Color.accentPrimary).frame(width: g.size.width * progress)
                    }
                }
                .frame(height: 3)
            }
        }
    }
}

/// duration bottom-right, progress bar, centred title and meta below.
struct DVRRecordingCard: View {
    let recording: Recording
    var headers: [String: String] = [:]
    var progress: Double = 0
    @ObservedObject private var art = DVRArtResolver.shared

    private let corner: CGFloat = 10
    private let titleSize: CGFloat = 14
    private let metaSize: CGFloat = 12
    private let badgeSize: CGFloat = 11

    private var artworkURL: URL? { (recording.backdropURL ?? recording.posterURL).flatMap { URL(string: $0) } }
    private var logoURL: URL? { recording.channelLogoURL.flatMap { URL(string: $0) } }
    private var isLive: Bool {
        recording.isInProgress || (recording.isUpcoming && recording.effectiveStart <= Date() && Date() < recording.effectiveEnd)
    }

    var body: some View {
        VStack(spacing: 8) {
            artworkBlock
            VStack(spacing: 2) {
                Text(recording.programTitle.isEmpty ? "Recording" : recording.programTitle)
                    .scaledFont(.system(size: titleSize, weight: .semibold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                Text(metaLine)
                    .scaledFont(.system(size: metaSize).subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .lineLimit(1)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        }
    }

    private var metaLine: String {
        if let sub = recording.subTitle, !sub.isEmpty {
            if let se = recording.displaySeasonEpisode { return "S\(se.season) E\(se.episode) · \(sub)" }
            return sub
        }
        if let se = recording.displaySeasonEpisode { return "S\(se.season) E\(se.episode)" }
        if recording.isUpcoming { return DVRFormat.dateRange(recording.scheduledStart, recording.scheduledEnd) }
        return DVRFormat.day(recording.scheduledStart)
    }

    private var artworkBlock: some View {
        // The 16:9 base owns the size; the art is an overlay clipped to it
        // (a filled image inside the stack made the card take the image's
        // own aspect, Logan 2026-09-05).
        Color.cardBackground
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { artLayer }
            .overlay(alignment: .bottom) { bottomBand }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(alignment: .topLeading) { badge }
    }

    @ViewBuilder
    private var artLayer: some View {
        GeometryReader { g in
            if let url = artworkURL {
                AuthPosterImage(url: url, headers: headers, placeholder: .cardBackground, maxPixel: 800)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: g.size.width, height: g.size.height)
                    .clipped()
            } else if let logoURL {
                AuthPosterImage(url: logoURL, headers: headers, placeholder: .clear, maxPixel: 400)
                    .aspectRatio(contentMode: .fit)
                    .padding(28)
                    .opacity(0.9)
                    .frame(width: g.size.width, height: g.size.height)
            } else {
                NoPosterPlaceholder()
                    .frame(width: g.size.width, height: g.size.height)
            }
        }
    }

    /// Bottom band so the logo and duration read on any art.
    private var bottomBand: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0.75), location: 1)
                ],
                startPoint: .top, endPoint: .bottom)
            .frame(height: bandHeight)
            HStack(alignment: .bottom) {
                if artworkURL != nil, let logoURL {
                    AuthPosterImage(url: logoURL, headers: headers, placeholder: .clear, maxPixel: 200)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: logoWidth, height: logoWidth * 0.5, alignment: .leading)
                } else if artworkURL != nil, !recording.channelName.isEmpty {
                    Text(recording.channelName)
                        .scaledFont(.system(size: badgeSize, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(durationText)
                    .scaledFont(.system(size: badgeSize, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, progress > 0 ? 12 : 10)
            if progress > 0 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.25))
                        Rectangle().fill(Color.accentPrimary).frame(width: g.size.width * progress)
                    }
                }
                .frame(height: 4)
            }
        }
    }

    private var bandHeight: CGFloat {
        return 56
    }

    private var logoWidth: CGFloat {
        return 48
    }

    private var durationText: String {
        if recording.isInProgress {
            return DVRFormat.duration(seconds: max(0, Date().timeIntervalSince(recording.effectiveStart)))
        }
        if recording.isUpcoming { return DVRFormat.time(recording.scheduledStart) }
        return DVRFormat.duration(seconds: recording.effectiveEnd.timeIntervalSince(recording.effectiveStart))
    }

    @ViewBuilder
    private var badge: some View {
        if isLive {
            HStack(spacing: 6) {
                Circle().fill(Color.white).frame(width: 7, height: 7)
                Text("REC")
            }
            .scaledFont(.system(size: badgeSize, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.red))
            .padding(10)
        } else if recording.isUpcoming {
            HStack(spacing: 6) {
                Image(systemName: "clock.fill")
                Text(DVRFormat.day(recording.scheduledStart))
            }
            .scaledFont(.system(size: badgeSize, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .padding(10)
        } else if recording.status == .interrupted {
            Text("Partial")
                .scaledFont(.system(size: badgeSize, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.orange.opacity(0.85)))
                .padding(10)
        }
    }
}

// MARK: - Formatting

enum DVRFormat {
    static func duration(seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 {
            let m = minutes % 60
            return m == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(m) min"
        }
        return "\(max(1, minutes)) min"
    }

    /// Honours the app's 12/24-hour setting like every other clock.
    static func time(_ date: Date) -> String {
        ClockFormat.short().string(from: date)
    }

    /// "Today", "Tomorrow", "Yesterday", else "Sep 5".
    static func day(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(cal.isDate(date, equalTo: Date(), toGranularity: .year) ? "MMM d" : "MMM d yyyy")
        return f.string(from: date)
    }

    static func dateRange(_ start: Date, _ end: Date) -> String {
        "\(day(start)) \(time(start)) to \(time(end))"
    }
}


/// Phone rail state, published to the rail overlay only (declared for both
/// platforms: the scroll holder that owns it is shared).
final class DVRPhoneRailState: ObservableObject {
    @Published var visible = false
    @Published var top: CGFloat = 0
}


/// The phone rail overlay: stays mounted, fades with a local animation,
/// and is the only view that observes DVRPhoneRailState, so a visibility
/// flip re-renders this overlay and nothing else.
private struct DVRPhoneRail: View {
    @ObservedObject var state: DVRPhoneRailState
    let letters: Set<String>
    let railWidth: CGFloat
    let boxWidth: CGFloat
    let boxHeight: CGFloat
    let onSelect: (String) -> Void

    var body: some View {
        AlphabetRail(available: letters, onSelect: onSelect)
            .frame(width: railWidth)
            // Fixed-height box + padding: an offset rail's taps fell through
            // to the grid (Logan 2026-09-05).
            .padding(.top, max(0, (boxHeight - AlphabetRail.totalHeight) / 2) + state.top)
            .frame(width: boxWidth, height: boxHeight, alignment: .topTrailing)
            .clipped()
            .padding(.trailing, 2)
            .opacity(state.visible ? 1 : 0)
            .allowsHitTesting(state.visible)
            .animation(.easeInOut(duration: 0.25), value: state.visible)
            .ignoresSafeArea(.container, edges: .top)
    }
}

