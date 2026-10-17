import SwiftUI
import SwiftData
import UIKit

// MARK: - Authenticated Poster Image
// AsyncImage can't send auth headers. Dispatcharr's /media/ endpoints are protected,
// so we fetch with URLSession + the server's API key and cache in NSCache.

private final class AuthImageCache: @unchecked Sendable {
    static let shared = AuthImageCache()
    private let cache = NSCache<NSString, UIImage>()
    private init() { cache.countLimit = 300 }
    func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    func store(_ image: UIImage, for key: String) { cache.setObject(image, forKey: key as NSString) }
}

struct AuthPosterImage: View {
    let url: URL?
    var headers: [String: String] = [:]
    /// GH #53: reports the loaded image's pixel size so callers that
    /// frame the poster (Program Info) can follow the REAL aspect ratio
    /// instead of hard-cropping landscape EPG art into a 2:3 portrait
    /// frame. nil callers (grids with uniform poster cells) are unchanged.
    var onImageLoaded: ((CGSize) -> Void)? = nil
    /// Painted until the image arrives. The Movies hero passes .clear so
    /// nothing shows through its fade while the backdrop loads.
    var placeholder: Color = .cardBackground
    /// Longest side, in pixels, the decoded bitmap is downsampled to. Grid
    /// posters draw at a few hundred points; decoding a 2000px file for
    /// each on the main thread was a scroll stutter (Logan 2026-09-03).
    var maxPixel: CGFloat = 1024

    @State private var uiImage: UIImage? = nil

    var body: some View {
        Group {
            if let img = uiImage {
                Image(uiImage: img).resizable()
            } else {
                placeholder
            }
        }
        // Keyed on url + the active effective host so a LAN/WAN probe flip
        // re-attempts covers that failed under the previous routing.
        .task(id: (url?.absoluteString ?? "") + "|" + (ChannelStore.shared.activeServer?.effectiveBaseURL ?? "")) {
            guard let url else { return }
            let key = url.absoluteString
            if let cached = AuthImageCache.shared.image(for: key) {
                uiImage = cached
                onImageLoaded?(cached.size)
                return
            }
            var req = URLRequest(url: url, timeoutInterval: 20)
            // SECURITY: attach the server's credential headers ONLY when the
            // image is on one of the configured server's OWN hosts (public
            // base + LAN local). A malicious backend can return a poster URL
            // pointing at an attacker host; without this gate the Dispatcharr
            // X-API-Key / Authorization would be sent there and harvested.
            // Foreign posters (TMDB / CDN) are public and load with no
            // headers. v1.7.9 regression fix: the old check compared against
            // the SINGLE `effectiveBaseURL` host at render time, but poster
            // URLs are built at fetch time and the effective host flips
            // between local/public per TVLANProbe - dual-URL setups routinely
            // diverged, headers were withheld, and every cover 401'd blank.
            let allowedHosts = ChannelStore.shared.activeServer?.ownHosts ?? []
            VODService.registerOwnHosts(allowedHosts)
            if let host = url.host?.lowercased(), allowedHosts.contains(host) {
                headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            } else if !headers.isEmpty, url.host?.lowercased() != "image.tmdb.org" {
                // Diagnostics for the next covers report: one grep-able line
                // that says exactly why credentials were withheld. TMDB's
                // CDN is expected and skipped: with TMDB-first art it wrote
                // a line per poster and flooded the log (2026-09-04).
                debugLog("🖼️ AuthPosterImage: headers WITHHELD host=\(url.host?.lowercased() ?? "nil") trusted=\(allowedHosts.sorted().joined(separator: ","))")
            }
            let data: Data
            do {
                let (d, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    debugLog("🖼️ AuthPosterImage: HTTP \(http.statusCode) host=\(url.host ?? "nil") path=\(url.path.suffix(40))")
                    return
                }
                data = d
            } catch {
                debugLog("🖼️ AuthPosterImage: FAILED host=\(url.host ?? "nil") \(error.localizedDescription)")
                return
            }
            let limit = maxPixel
            // Decode, downsample, and force-decompress OFF the main thread:
            // UIImage(data:) is lazy and would otherwise decode on first
            // draw, mid-scroll. GH #61: SVG artwork still decodes here.
            let prepared: UIImage? = await Task.detached(priority: .userInitiated) {
                guard let raw = AstralImageDecoding.decode(data) else { return nil }
                let longest = max(raw.size.width, raw.size.height) * raw.scale
                if longest > limit {
                    let f = limit / longest
                    let target = CGSize(width: raw.size.width * raw.scale * f,
                                        height: raw.size.height * raw.scale * f)
                    if let thumb = await raw.byPreparingThumbnail(ofSize: target) { return thumb }
                }
                return await raw.byPreparingForDisplay() ?? raw
            }.value
            guard let img = prepared else { return }
            AuthImageCache.shared.store(img, for: key)
            guard !Task.isCancelled else { return }
            uiImage = img
            onImageLoaded?(img.size)
        }
    }
}

// MARK: - Movies View
struct MoviesView: View {
    @ObservedObject var vodStore: VODStore
    @Query private var servers: [ServerConnection]
    @Binding var isPlaying: Bool
    @Binding var isDetailPushed: Bool
    @Binding var popRequested: Bool
    /// False while another tab is selected: both VOD tabs stay mounted in
    /// the TabView, so observers that move focus are gated on this.
    var isSelected: Bool = true
    /// Movies or TV shows: one library view, two data sources.
    var kind: VODItemType = .movie

    /// Sweep progress + screen presence (Logan 2026-09-16). The view reports
    /// whether it is actually in front of the user, which is what lets the
    /// catalog sweep drop its background pacing while the user is watching
    /// the count grow, and reads back "a sweep is running" for the header.
    @ObservedObject private var sweepActivity = VODSweepActivity.shared
    @Environment(\.scenePhase) private var scenePhase

    private var tab: AppTab { kind == .series ? .tvShows : .movies }
    private var kindString: String { kind == .series ? "series" : "movie" }
    /// WatchProgress rows that feed this tab's Continue Watching hero.
    private var progressType: String { kind == .series ? "episode" : "movie" }
    private var kindTitle: String { kind == .series ? "TV Shows" : "Movies" }
    private var kindLower: String { kind == .series ? "TV shows" : "movies" }
    private var kindIcon: String { kind == .series ? "tv" : "film.stack" }
    /// How many titles the catalog holds for this tab. The library itself
    /// is never materialized: `derived.library` is a windowed view of the
    /// catalog, and this count is what the empty / loading gates test.
    private var libraryCount: Int { kind == .series ? vodStore.seriesCount : vodStore.moviesCount }
    private var libraryCategories: [VODCategory] { kind == .series ? vodStore.seriesCategories : vodStore.movieCategories }
    private var searchResults: [VODDisplayItem] { kind == .series ? vodStore.seriesSearchResults : vodStore.movieSearchResults }
    private var isSearchingLibrary: Bool { kind == .series ? vodStore.isSearchingSeries : vodStore.isSearchingMovies }
    private var isLoadingLibrary: Bool { kind == .series ? vodStore.isLoadingSeries : vodStore.isLoadingMovies }
    private var libraryError: String? { kind == .series ? vodStore.seriesError : vodStore.moviesError }
    private var hasLoadedLibrary: Bool { kind == .series ? vodStore.hasLoadedSeries : vodStore.hasLoadedMovies }
    /// True while this tab's catalog sweep is still walking the provider, so
    /// the header can say "Updating" and the user knows the count is still
    /// growing (Android parity, Logan 2026-09-16). Only shown once there is
    /// something on screen: with an empty library the full LoadingView is
    /// already saying the same thing. `isRefilling*` covers the sweep the
    /// store itself is running; `VODSweepActivity` covers the scheduled one
    /// that has not started yet (the series sweep waits for the movie sweep).
    private var isUpdatingLibrary: Bool {
        guard libraryCount > 0 else { return false }
        let refilling = kind == .series ? vodStore.isRefillingSeries : vodStore.isRefillingMovies
        return refilling || sweepActivity.isActive(kind)
    }
    /// Background TMDB art pass over the library once a sweep completes
    /// (hero titles first so the carousel gets its art immediately).
    private func enrichArt() {
        guard hasLoadedLibrary, let key = vodStore.catalogKey else { return }
        TMDBArtCache.shared.enrichCatalog(playlistKey: key, isMovie: kind == .movie,
                                          priority: heroPages.map(\.item))
    }
    /// Tell the sweep whether this tab is really in front of the user.
    private func reportScreenPresence() {
        VODSweepActivity.shared.setOnScreen(kind, isSelected && scenePhase == .active)
    }
    private func applyPendingDerived() {
        guard let p = pendingDerived else { return }
        pendingDerived = nil
        // Only if nothing newer has been requested since it was computed.
        if p.key == libraryKey { derived = p.value }
    }

    private func searchLibrary(_ query: String, providerID: Int?) {
        if kind == .series {
            vodStore.searchSeries(query: query, servers: servers, providerID: providerID)
        } else {
            vodStore.searchMovies(query: query, servers: servers, providerID: providerID)
        }
    }

    private func handleMoviesAppear() {
        hiddenGroups = HiddenGroupsStore.load(forKey: hiddenGroupsKey)
        disabledProviders = HiddenGroupsStore.load(forKey: disabledProvidersKey)
        // v1.6.22: same guard as TVShowsView.onAppear. The
        // previous `movies.isEmpty && !isLoadingMovies`
        // check re-fired refreshMovies every time SwiftUI
        // rebuilt the view after a legitimately-empty load,
        // producing a refresh loop. Compare the active
        // server's id to `currentMoviesServerID` (set when
        // a load begins) so we tell "fresh server" from
        // "already tried this server, server has no
        // movies". Pull-to-refresh and the Try Again
        // button still bypass this guard.
        let activeServer: ServerConnection? = servers.first(where: { $0.isActive }) ?? servers.first
        let activeServerID: UUID? = activeServer?.id
        let alreadyTriedThisServer: Bool = activeServerID != nil
            && vodStore.currentMoviesServerID == activeServerID
        // Type-check budget workaround (Xcode 26.6): the folded
        // 3-term `&&` chain blew the solver budget at this `if`
        // (unable to type-check in reasonable time). Name each
        // condition so the `if` expression stays trivial.
        let libraryIsEmpty = libraryCount == 0
        let librarySettled = !isLoadingLibrary
        let isUntriedServer = !alreadyTriedThisServer
        if libraryIsEmpty && librarySettled && isUntriedServer {
            refreshLibrary()
        }
    }

    private func refreshLibrary() {
        if kind == .series { vodStore.refreshSeries(servers: servers) } else { vodStore.refreshMovies(servers: servers) }
    }
    /// The hero page an episode row belongs to: its series.
    private func heroKey(_ p: WatchProgress) -> String? {
        kind == .series ? p.seriesID : p.vodID
    }
    /// Nested-push router for pushed details (identity-stable, see
    /// VODPushRouter).
    @State private var pushRouter = VODPushRouter()
    /// tvOS: like heroFocusRequest, but lands on the hero button that had
    /// focus last (Up from Play from Beginning returned to Resume, Logan
    /// 2026-09-04). Declared unguarded: the carousel binding is built in
    /// shared code.
    @State private var heroRestoreRequest = false
    /// tvOS grid: seven columns, 24 pt gutters (shelf width + rail math use it too).
    private let tvGridColumns = 7
    private let tvGridColumnSpacing: CGFloat = 24

    // Search / filter state. Declared unguarded: the search, provider and
    // people helpers are shared code even though only tvOS shows the
    // inline field (iOS build broke when these sat under #if os(tvOS)).
    @State private var showSearchField = false
    /// Dispatcharr Direct Connect: M3U account id -> name, for the provider
    /// filter on search results. Empty for other server types.
    @State private var providerNames: [Int: String] = [:]
    @State private var selectedProviderID: Int?
    /// Cast & crew search: the TMDB person the query resolved to and their
    /// films found in the library.
    @State private var personMatchName: String?
    @State private var personMatches: [VODDisplayItem] = []
    @State private var personSearchTask: Task<Void, Never>?
    /// Search circle focus: Menu collapses the field and lands here.
    @FocusState private var searchCircleFocused: Bool

    @State private var searchText = ""
    @State private var hiddenGroups: Set<String> = []
    @State private var showManageGroups = false
    /// GH #20 (Android parity): auto-hide the iPhone tab bar while the
    /// poster grid scrolls down; any upward scroll reveals it
    /// (TabBarScrollTracker). Phone-gated in the observer, so iPad
    /// keeps its bar.
    @State private var gridTabBarHidden = false
    @State private var tabBarTracker = TabBarScrollTracker()
    /// System search presented (the header's search icon opens it).
    @FocusState private var iosSearchFocused: Bool
    /// Bumped when the phone search opens; the library header's onChange
    /// scrolls itself to the top (the proxy lives at that call site).
    @State private var scrollToLibraryTick = 0
    @State private var navPath = NavigationPath()
    /// Re-sorted library waiting until the user is back at the top: applying
    /// it mid-scroll reordered the grid under the focused poster.
    /// Result held while the grid must not rebuild, with the key it was
    /// computed for (a newer key drops it rather than applying stale order).
    @State private var pendingDerived: (key: LibraryKey, value: LibraryDerived)?
    /// Rail top edge. Written only while the rail rides with the grid; once
    /// parked the value stops changing, so scrolling the grid costs no
    /// body re-evaluation. nil until the grid is first measured.
    @State private var railTop: CGFloat?
    /// Rail slides in while a grid poster or a rail letter has focus.
    @State private var railVisible = false  // touch: only while the grid fills the display
    @State private var railFocused = false
    @State private var railHideTask: Task<Void, Never>?
    /// Scroll geometry for the rail jump, kept OUT of view state so the
    /// per-frame writes never re-evaluate the body. Row pitch and the
    /// grid's content-space top let a click scroll to an absolute offset:
    /// ScrollViewReader.scrollTo(id) silently no-ops for lazy grid rows
    /// that have not been built yet (device log 2026-09-03).
    private final class ScrollGeometryBox {
        /// Phone rail visibility and park offset, observed ONLY by
        /// PhoneRailFade (never by this view): a @State flip on the tab at
        /// the pills crossing re-rendered the whole tab, ~25 ms (Instruments
        /// on DVR 2026-09-09; same structure here, TV Shows included).
        let phoneRail = DVRPhoneRailState()
        /// The ScrollView's position, held OUTSIDE @State: bound as @State
        /// it wrote view state on every scroll frame and re-rendered the
        /// whole tab (phone probe 2026-09-09: 102 of 128 layout passes over
        /// 12 ms during a bounce, plus a re-grab after it). Programmatic
        /// scrolls go through scrollContent(toY:), which bumps a tick so the
        /// ScrollView re-reads the binding once.
        var position = ScrollPosition()
        var contentOffsetY: CGFloat = 0
        var gridTopVisible: CGFloat = 0
        var rowPitch: CGFloat = 0
        var gridWidth: CGFloat = 0
    var watchlistShelfHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    }
    @State private var geometryBox = ScrollGeometryBox()
    @State private var scrollPositionTick = 0
    private var scrollPositionBinding: Binding<ScrollPosition> {
        Binding(get: { geometryBox.position }, set: { geometryBox.position = $0 })
    }
    private func scrollContent(toY y: CGFloat) {
        geometryBox.position.scrollTo(y: y)
        scrollPositionTick += 1
    }
    @State private var resumePlayingURL: IdentifiableURL?
    @State private var resumePlayingTitle = ""
    @State private var resumePlayingHeaders: [String: String] = [:]
    @State private var resumeVodID: String?
    @State private var resumePosterURL: String?
    @State private var resumeServerID: String?
    @State private var resumePositionMs: Int32 = 0
    /// Continue Watching version switching (ATV log 2026-08-17). Populated
    /// best-effort as the resume cover mounts so the in-player Switch Version
    /// list matches what the detail page offers for the same title.
    @State private var resumeVersionOptions: [VODVersionOption] = []
    @State private var resumeVersionSelectionKey: String = ""

    private var hiddenGroupsKey: String { kind == .series ? "hiddenSeriesGroups" : "hiddenMovieGroups" }
    /// Filter page, Providers tab: M3U account ids the user switched off.
    private var disabledProvidersKey: String { kind == .series ? "disabledSeriesProviders" : "disabledMovieProviders" }
    @State private var disabledProviders: Set<String> = []

    /// Groups the user hid PLUS every group that only lives on disabled
    /// providers. This is what the library, pills and shelves filter by.
    private var effectiveHiddenGroups: Set<String> {
        guard !disabledProviders.isEmpty else { return hiddenGroups }
        var out = hiddenGroups
        for cat in libraryCategories where !cat.providerIDs.isEmpty {
            if cat.providerIDs.allSatisfy({ disabledProviders.contains(String($0)) }) {
                out.insert(cat.name)
            }
        }
        return out
    }

    /// Groups offered on the Filter page's Groups tab: only those on an
    /// enabled provider (categories with no provider info always show).
    private var groupsForEnabledProviders: [String] {
        libraryCategories.filter { cat in
            cat.providerIDs.isEmpty || cat.providerIDs.contains { !disabledProviders.contains(String($0)) }
        }.map(\.name)
    }

    // Movies tab redesign (2026-09): hero + shelves + library grid.
    /// Unfinished watch progress, newest first; filtered to movies on the
    /// active playlist below. Same query ContinueWatchingSection runs, held
    /// here too so the hero can lead with the newest resume point.
    @Query(
        filter: #Predicate<WatchProgress> { !$0.isFinished },
        sort: \WatchProgress.updatedAt, order: .reverse
    ) private var allProgress: [WatchProgress]
    /// Watchlist, newest first; scoped to the active playlist below.
    @Query(sort: \WatchlistEntry.addedAt, order: .reverse)
    private var watchlistEntries: [WatchlistEntry]
    @AppStorage("moviesSortOrder") private var movieSortRaw = MoviesSortOrder.titleAZ.rawValue
    @AppStorage("seriesSortOrder") private var seriesSortRaw = MoviesSortOrder.titleAZ.rawValue
    private var sortOrderRaw: String {
        get { kind == .series ? seriesSortRaw : movieSortRaw }
        nonmutating set { if kind == .series { seriesSortRaw = newValue } else { movieSortRaw = newValue } }
    }
    /// Genre pill selection; nil = All. Not persisted: a filter that
    /// silently survives a relaunch reads as "my movies vanished".
    @State private var selectedGenre: String? = nil

    /// Hidden titles for this playlist (long-press Hide). Observed so the
    /// grid, shelves and pills update the moment a title is hidden.
    @ObservedObject private var hiddenTitles = HiddenVODStore.shared
    /// Pill label for the Hidden category. Sits first in the pill row,
    /// only while this playlist has at least one hidden title of this kind.
    static let hiddenPillLabel = "Hidden"
    private var hasHiddenTitles: Bool {
        hiddenTitles.hasHidden(type: kindString, serverID: activeServerIDString)
    }
    /// The Filter list's "Hidden" row, checked by the user. Unchecked by
    /// default, so the category pill appears only once they ask for it.
    private var hiddenCategoryOn: Bool {
        hiddenTitles.isCategoryVisible(type: kindString, serverID: activeServerIDString)
    }
    /// The pill exists only when the row is offered AND checked.
    private var hiddenPillAvailable: Bool { hasHiddenTitles && hiddenCategoryOn }
    /// True while the Hidden category is selected: every list shows only
    /// hidden titles, and the long-press offers Unhide.
    private var showingHiddenOnly: Bool {
        hiddenPillAvailable && selectedGenre == MoviesView.hiddenPillLabel
    }
    private var hiddenKeys: Set<String> {
        hiddenTitles.snapshot(serverID: activeServerIDString)
    }
    /// Library grid's top edge in scroll-view coordinates. The alphabet
    /// rail rides with it, then sticks once it reaches the top inset.
    /// Grid top edge reaches the rail through a layout preference (not
    /// @State): a state write per scroll frame re-evaluated this whole
    /// body, 5k grid rows included (Logan 2026-09-03: still not smooth).
    private struct GridTopKey: PreferenceKey {
        nonisolated(unsafe) static var defaultValue: CGFloat? = nil
        static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
            if let v = nextValue() { value = v }
        }
    }
    @State private var scrollIsIdle = true

    /// User-tunable UI scale (0.85-1.5). Text scales everywhere (VODDisplayScale); the grid only
    /// where the default 120 px minimum can feel cramped on wide displays;
    /// iPhone grids stay at their designed minimums (user scale is a no-op in
    /// the ternary below), and tvOS ignores the setting entirely.
    @AppStorage("uiScale") private var uiScale: Double = 1.0

    private var columns: [GridItem] {
        // On iPhone the phone-sized minimum is always used. On iPad / Mac the
        // user's uiScale slider stretches the minimum so posters read larger.
        let clamped = max(0.85, min(1.5, uiScale))
        let isRegular = UIDevice.current.userInterfaceIdiom != .phone
        // Phone: three across, like the mockup (Logan 2026-09-05).
        if !isRegular { return Array(repeating: GridItem(.flexible(), spacing: 8), count: 3) }
        let minimum: CGFloat = 120 * clamped
        let maximum: CGFloat = 160 * clamped
        return [GridItem(.adaptive(minimum: minimum, maximum: maximum), spacing: 12)]
    }
    private let gridRowSpacing: CGFloat = 16

    /// Auth headers for the active Dispatcharr server, used by AuthPosterImage.
    /// Cached: `authHeaders` reads the Keychain (API key) and sysctl
    /// (default User-Agent) every call, and every poster cell asked for it
    /// on every layout pass (Time Profiler 2026-09-04: a third of main
    /// thread time during the scroll).
    @State private var dispatcharrHeaders: [String: String] = [:]

    private var dispatcharrHeadersKey: String {
        servers.map { "\($0.id)|\($0.isActive)|\($0.supportsVOD)|\($0.type)" }.joined(separator: ",")
    }

    private func refreshDispatcharrHeaders() {
        guard let s = servers.first(where: { $0.supportsVOD && $0.type == .dispatcharrAPI && $0.isActive })
                   ?? servers.first(where: { $0.supportsVOD && $0.type == .dispatcharrAPI })
        else { dispatcharrHeaders = [:]; return }
        dispatcharrHeaders = s.authHeaders
    }

    private var isSearching: Bool { !searchText.isEmpty }

    /// Search hits before the provider filter (drives the provider pills).
    /// Title matches (local + server), plus local rows whose cast or
    /// director text contains the query, plus the TMDB person's films
    /// that exist in the library (personMatches). Sorted by the tab's
    /// sort order (Logan 2026-09-04).
    private var searchHits: [VODDisplayItem] { catalogSearchHits }

    /// Library hits for the current query, answered by a catalog query
    /// instead of a walk of an in-memory array (the array is gone, and on a
    /// 350k library the walk was the whole point of the change). Refreshed
    /// per keystroke, off the main actor, by `refreshSearchHits`.
    @State private var catalogSearchHits: [VODDisplayItem] = []
    @State private var searchHitsTask: Task<Void, Never>?

    /// Re-runs the library half of the search. Kept per keystroke by design
    /// (feedback: VOD search fires per keystroke BY DESIGN); the work is now
    /// one indexed LIKE on a background queue rather than a full scan.
    private func refreshSearchHits() {
        searchHitsTask?.cancel()
        let q = searchText
        guard !q.isEmpty else { catalogSearchHits = []; return }
        let hidden = hiddenKeys
        let onlyHidden = showingHiddenOnly
        let sort = sortOrder
        let extra = searchResults + personMatches
        let k = kind
        searchHitsTask = Task { @MainActor in
            var combined = await vodStore.searchCatalog(kind: k, query: q, hiddenTitleKeys: onlyHidden ? [] : hidden)
            guard !Task.isCancelled else { return }
            var ids = Set(combined.map { $0.id })
            for r in extra where ids.insert(r.id).inserted { combined.append(r) }
            combined = HiddenVODStore.apply(combined, hiddenKeys: hidden, onlyHidden: onlyHidden)
            catalogSearchHits = MoviesView.sortItems(combined, by: sort)
        }
    }

    private var filteredMovies: [VODDisplayItem] {
        if !searchText.isEmpty {
            // A provider pick re-runs the server search with the account
            // filter; local rows carry no provider, so only the server's
            // answer counts then.
            if selectedProviderID != nil {
                return MoviesView.sortItems(
                    HiddenVODStore.apply(searchResults, hiddenKeys: hiddenKeys, onlyHidden: showingHiddenOnly),
                    by: sortOrder)
            }
            return searchHits
        }
        // Not searching: the grid reads `libraryMovies`, the windowed
        // catalog list, and never this array.
        return []
    }

    /// Whether the navigation stack is at root (no detail pushed).
    var isAtRoot: Bool { navPath.isEmpty }

    /// Movies & TV Shows Display Scale (Android parity, Logan 2026-09-27):
    /// multiplies the app text scale for this page on every platform, the
    /// way Android's WithDisplayScale multiplies fontScale.
    var body: some View {
        vodPageContent.modifier(VODDisplayScale())
    }

    @ViewBuilder
    private var vodPageContent: some View {
        let _ = TabProbe.body("MoviesView")
        NavigationStack(path: $navPath) {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                if libraryCount == 0 && (isLoadingLibrary || (!hasLoadedLibrary && libraryError == nil)) {
                    // Before the first sweep of this session has run (the
                    // series sweep starts after the movie one), this is
                    // "loading", not "No TV Shows" (Logan 2026-09-04).
                    LoadingView(message: "Loading \(kindLower)…")
                } else if let err = libraryError, libraryCount == 0 {
                    errorView(err)
                } else if libraryCount == 0 {
                    emptyState
                } else {
                    content
                }
            }
            .navigationDestination(for: VODDisplayItem.self) { item in
                VODDetailView(item: item, isPlaying: $isPlaying)
                    // Nested pushes (Related, Known For) append to THIS path.
                    // A detail's own navigationDestination(item:) pushing a
                    // value already in the path wedged the stack (Logan
                    // 2026-09-04 16:11/16:14: A -> Related B -> Related A hung).
                    .environment(\.vodPushHandler, pushRouter)
            }
            // No .navigationTitle on iOS, OnDemandView hosts the
            // Movies / Series pill selector above this view and the
            // pills serve as the section identifier. A title here
            // would duplicate the header.
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            // Phone pass (Logan 2026-09-05): no navigation bar; the hero
            // starts under the status bar. Search is an inline pill field
            // under the library header, where the search circle is, like
            // Android (Logan 2026-09-09); the page scrolls the header to
            // the top so the results land in view.
            .toolbar(.hidden, for: .navigationBar)
            .task(id: libraryKey) {
                // The filter and the sort run in SQL and hand back row ids
                // plus rail buckets, never rows: about 9 bytes per title, so
                // a 350,000 title library costs a few MB here instead of the
                // gigabytes the mapped array needed.
                let hidden = effectiveHiddenGroups
                let genre = selectedGenre == MoviesView.hiddenPillLabel ? nil : selectedGenre
                let hiddenIDs = hiddenKeys
                let onlyHidden = showingHiddenOnly
                let list = await vodStore.library(kind: kind, hiddenGroups: hidden,
                                                  hiddenTitleKeys: hiddenIDs, genre: genre,
                                                  onlyHidden: onlyHidden, sortRaw: sortOrderRaw)
                guard !Task.isCancelled else { return }
                let recent = await vodStore.recentlyAdded(kind: kind, hiddenGroups: hidden,
                                                          hiddenTitleKeys: hiddenIDs)
                guard !Task.isCancelled else { return }
                let result = LibraryDerived(library: list, recentlyAdded: recent)
                // Phone: same hold while the finger is down or the scroll is
                // decelerating (Logan 2026-09-06, "a lot of refreshing when I
                // scroll down"); applied as soon as the scroll rests.
                let hold = !scrollIsIdle
                if hold && !derived.library.isEmpty {
                    pendingDerived = (libraryKey, result)
                } else {
                    derived = result
                    pendingDerived = nil
                }
            }
            .onChange(of: hiddenPillAvailable) { _, has in
                // Unhiding the last title takes the pill away; drop the
                // selection with it so the grid is not left on a dead filter.
                if !has, selectedGenre == MoviesView.hiddenPillLabel { selectedGenre = nil }
            }
            .onAppear {
                pushRouter.push = { navPath.append($0) }
                refreshDispatcharrHeaders(); refreshHeroPages(); refreshWatchlistItems()
                enrichArt()
                reportScreenPresence()
            }
            // Screen presence for the sweep's foreground mode (Logan
            // 2026-09-16). Both VOD tabs stay MOUNTED in the TabView, so
            // appear / disappear alone is not enough: the tab has to be the
            // selected one AND the app has to be active.
            .onChange(of: isSelected) { _, _ in reportScreenPresence() }
            .onChange(of: scenePhase) { _, _ in reportScreenPresence() }
            .onDisappear { VODSweepActivity.shared.setOnScreen(kind, false) }
            .onChange(of: heroPagesKey) { _, _ in refreshHeroPages() }
            .onChange(of: hasLoadedLibrary) { _, loaded in if loaded { enrichArt() } }
            .onChange(of: TMDBArtCache.shared.version) { _, _ in heroPages = heroPages.map { applyBackdrop($0) } }
            .onChange(of: watchlistKey) { _, _ in refreshWatchlistItems() }
            .onChange(of: dispatcharrHeadersKey) { _, _ in refreshDispatcharrHeaders() }
            .onAppear {
                handleMoviesAppear()
            }
            .sheet(isPresented: $showManageGroups) {
                ManageGroupsSheet(
                    title: "Manage Groups",
                    allGroups: libraryCategories.map(\.name),
                    storageKey: hiddenGroupsKey,
                    onDismiss: { updated in
                        hiddenGroups = updated
                    },
                    hiddenCategoryAvailable: hasHiddenTitles,
                    hiddenCategoryOn: hiddenCategoryOn,
                    onToggleHiddenCategory: {
                        hiddenTitles.setCategoryVisible(!hiddenCategoryOn,
                                                        type: kindString,
                                                        serverID: activeServerIDString)
                    }
                )
            }
            .refreshable {
                refreshLibrary()
                // Allow the task one tick to start so isLoadingMovies flips to true first.
                try? await Task.sleep(for: .milliseconds(50))
                while isLoadingLibrary {
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            .onChange(of: searchText) { _, query in
                // Fire server-side search so items not yet locally fetched are found.
                if query.isEmpty { selectedProviderID = nil }
                searchLibrary(query, providerID: selectedProviderID)
                searchPeople(query)
                // Library half of the search: a catalog query per keystroke,
                // off the main actor.
                refreshSearchHits()
            }
            .onChange(of: searchResults.count) { _, _ in refreshSearchHits() }
            .onChange(of: personMatches.count) { _, _ in refreshSearchHits() }
            .onChange(of: sortOrderRaw) { _, _ in if isSearching { refreshSearchHits() } }
            .task(id: activeServerIDString) { await loadProviderNames() }
            .onChange(of: navPath) { _, path in
                isDetailPushed = !path.isEmpty
            }
            .onChange(of: popRequested) { _, pop in
                if pop && !navPath.isEmpty {
                    navPath.removeLast()
                    popRequested = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .syncManagerDidApplyPreferences)) { _ in
                // Reload hidden groups from UserDefaults after an iCloud sync applies remote prefs.
                hiddenGroups = HiddenGroupsStore.load(forKey: hiddenGroupsKey)
                disabledProviders = HiddenGroupsStore.load(forKey: disabledProvidersKey)
            }
            .fullScreenCover(item: $resumePlayingURL) { wrapper in
                PlayerView(
                    urls: [wrapper.url],
                    title: resumePlayingTitle,
                    headers: resumePlayingHeaders,
                    isLive: false,
                    artworkURL: resumePosterURL.flatMap { URL(string: $0) },
                    vodID: resumeVodID,
                    vodPosterURL: resumePosterURL,
                    vodServerID: resumeServerID,
                    vodType: progressType,
                    resumePositionMs: resumePositionMs,
                    vodVersionOptions: resumeVersionOptions,
                    vodSelectedVersionID: VODVersionSelectionStore
                        .selection(forKey: resumeVersionSelectionKey),
                    vodVersionSelectionKey: resumeVersionSelectionKey
                )
                .onDisappear { isPlaying = false }
            }
            // Leaving this tab, or entering the fullscreen player, cancels
            // and closes search (Logan 2026-09-16).
            .onDismissSearch {
                iosSearchFocused = false
                // Sendable workaround: split the "search is open" test into
                // a sub-expression local so the type checker doesn't fold
                // the guard branch into the dismissal assignments below.
                let searchActive = showSearchField || !searchText.isEmpty
                guard searchActive else { return }
                showSearchField = false
                searchText = ""
                selectedProviderID = nil
                personMatchName = nil
                personMatches = []
            }
        }
    }


    /// `startAt`: override the saved position (Play from Beginning).
    /// Continue Watching resume: asks Play Here / Play on <receiver> while a
    /// remote session is active (PlayWhereRouter). Without a stored URL it
    /// opens the detail page, whose Play asks instead.
    private func resumeFromContinueWatching(_ progress: WatchProgress, startAt: Int32? = nil) {
        guard progress.streamURL.flatMap(URL.init(string:)) != nil else {
            resumePicked(progress, startAt: startAt)
            return
        }
        PlayWhereRouter.shared.request(title: progress.title, item: .nonLive) {
            resumePicked(progress, startAt: startAt)
        }
    }

    private func resumePicked(_ progress: WatchProgress, startAt: Int32? = nil) {
        // If we have a stored stream URL, launch playback directly with the saved position
        if let urlStr = progress.streamURL, let url = URL(string: urlStr) {
            resumePlayingTitle = progress.title
            resumeVodID = progress.vodID
            resumePosterURL = progress.posterURL
            resumeServerID = progress.serverID
            resumePositionMs = startAt ?? progress.positionMs
            let resumeServer: ServerConnection? = progress.serverID
                .flatMap(UUID.init(uuidString:))
                .flatMap { uuid in servers.first(where: { $0.id == uuid }) }
            resumePlayingHeaders = resumeServer?.authHeaders ?? dispatcharrHeaders
            // ATV log 2026-08-17 (Logan): this fast path mounted the player
            // cover directly, skipping the teardown VODDetailView does before
            // its own cover. A minimized live channel therefore kept decoding
            // UNDER the movie - two mpv instances, both audible - until the
            // user stopped the live stream by hand. Same call, same reason as
            // the v1.6.23 fix in VODDetailView.startPlayback.
            PlayerSession.shared.exit()
            // Same log, second symptom: Continue Watching passed no version
            // options, so Switch Version was empty in the player even for a
            // title that shows several copies when opened from Movies. Load
            // them for this resume so the two entry points behave alike; the
            // fetch is best-effort and never gates playback starting.
            resumeVersionOptions = []
            resumeVersionSelectionKey = progress.serverID
                .flatMap(UUID.init(uuidString:))
                .map { uuid in
                    VODVersionSelectionStore.storageKey(serverID: uuid,
                                                        itemType: kindString,
                                                        itemID: progress.vodID)
                } ?? ""
            loadResumeVersionOptions(progress: progress, resumeURL: url, server: resumeServer)
            // TEST (AVPlayer VOD): unified container first; false = engine
            // off or non-VOD shape, legacy cover mounts unchanged.
            if PlayerSession.shared.beginVOD(
                title: progress.title,
                streamURL: url,
                headers: resumePlayingHeaders,
                posterURL: progress.posterURL.flatMap { URL(string: $0) },
                vodID: progress.vodID,
                serverID: progress.serverID,
                vodType: progressType,
                resumePositionMs: startAt ?? progress.positionMs,
                versionSelectionKey: resumeVersionSelectionKey.isEmpty ? nil : resumeVersionSelectionKey) {
                isPlaying = true
                return
            }
            resumePlayingURL = IdentifiableURL(url: url)
            isPlaying = true
            return
        }
        // Fallback: find the title in the catalog and push to its detail view
        if let key = heroKey(progress) {
            let k = kind
            Task { @MainActor in
                if let item = await vodStore.items(kind: k, ids: [key])[key] { navPath.append(item) }
            }
        }
    }

    /// Fetch this title's provider copies so the resume player can offer
    /// Switch Version. Mirrors VODDetailView.loadVersionProviders +
    /// buildVersionOptions for the movie case; failures are silent (older
    /// Dispatcharr builds lack /provider-info/, and a missing list just
    /// means the player shows no version row, exactly as before).
    private func loadResumeVersionOptions(progress: WatchProgress,
                                          resumeURL: URL,
                                          server: ServerConnection?) {
        // Movie copies only; episode versions are picked on the series page.
        guard kind == .movie else { return }
        // Fall back to the active Dispatcharr server: a watch-progress row
        // synced from another device can carry a serverID this install does
        // not have, and the resume itself already falls back the same way.
        let resolved = server ?? servers.first(where: {
            $0.isActive && $0.type == .dispatcharrAPI
        }) ?? servers.first(where: { $0.type == .dispatcharrAPI })
        guard let resolved, resolved.type == .dispatcharrAPI,
              let numericID = Int(progress.vodID) else {
            debugLog("[VOD-VERSION] resume skipped: no dispatcharr server or non-numeric id \(progress.vodID)")
            return
        }
        // Take the movie's Dispatcharr UUID straight out of the resume URL
        // (/proxy/vod/movie/<uuid>[/<session>]) rather than looking the title
        // up in libraryItems. The first attempt did the catalog lookup and
        // silently found nothing on device (ATV retest 2026-08-17) - the row
        // may not be loaded yet during the 2.5-minute VOD sync, and a synced
        // progress row can name a title this device never fetched. The URL is
        // always present because it is what we are about to play.
        let comps = resumeURL.pathComponents
        let uuid = comps.firstIndex(of: "movie")
            .flatMap { i in i + 1 < comps.count ? comps[i + 1] : nil } ?? ""
        guard !uuid.isEmpty else {
            debugLog("[VOD-VERSION] resume skipped: no uuid in \(resumeURL.path)")
            return
        }
        let server = resolved
        let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                 auth: .apiKey(server.effectiveApiKey),
                                 userAgent: server.effectiveUserAgent,
                                 authMode: server.dispatcharrHeaderMode)
        Task { @MainActor in
            guard let providers = try? await api.getMovieProviders(movieID: numericID) else {
                debugLog("[VOD-VERSION] resume \(progress.vodID): providers fetch failed")
                return
            }
            guard providers.count > 1 else {
                debugLog("[VOD-VERSION] resume \(progress.vodID): \(providers.count) copy, no picker")
                return
            }
            // Same label pipeline as the detail page's picker (Logan
            // 2026-08-26: the in-player rows must show the same measured
            // quality info): account + container, then measured
            // descriptors, then the AVPlayer support note. Learn-cache
            // fills in immediately; server measurements land in a second
            // context push below.
            var learned: [Int: VODLearnedStream] = [:]
            for rel in providers {
                if let l = VODVersionMeasurementStore.lookup(optionID: rel.id) {
                    learned[rel.id] = l
                }
            }
            var media: [Int: DispatcharrVODProviderMedia] = [:]
            // Local funcs are nonisolated by default even inside a
            // @MainActor Task closure; annotate or the store call fails
            // to compile under strict concurrency.
            @MainActor func pushOptions() {
                let labels = VODVersionLabeler.labels(providers: providers,
                                                      media: media, learned: learned)
                resumeVersionOptions = providers.compactMap { rel in
                    guard let url = api.proxyMovieURL(uuid: uuid,
                                                      preferredStreamID: rel.streamID.flatMap(Int.init),
                                                      m3uAccountID: rel.account.id) else { return nil }
                    return VODVersionOption(id: rel.id,
                                            label: labels[rel.id] ?? rel.displayLabel,
                                            url: url)
                }
                // Container path (beginVOD): the options resolved AFTER the
                // launch; hand them to the session so Switch Version works
                // there too. No-op when the legacy cover is playing.
                MultiviewStore.shared.updateVODVersionContext(
                    vodID: progress.vodID,
                    options: resumeVersionOptions,
                    selectedID: VODVersionSelectionStore.selection(forKey: resumeVersionSelectionKey),
                    selectionKey: resumeVersionSelectionKey.isEmpty ? nil : resumeVersionSelectionKey)
            }
            pushOptions()
            debugLog("[VOD-VERSION] resume \(progress.vodID): \(resumeVersionOptions.count) provider copies")
            // Measured stream properties, capped at 3 concurrent fetches
            // (mirrors VODDetailView.loadVersionMedia): a copy the server
            // has not inspected yet costs an upstream round trip.
            let relationIDs = providers.map(\.id)
            await withTaskGroup(of: (Int, DispatcharrVODProviderMedia?).self) { group in
                var next = 0
                func addTask() {
                    guard next < relationIDs.count else { return }
                    let relationID = relationIDs[next]
                    next += 1
                    group.addTask {
                        (relationID, try? await api.getMovieProviderMedia(movieID: numericID,
                                                                          relationID: relationID))
                    }
                }
                for _ in 0..<min(3, relationIDs.count) { addTask() }
                for await (relationID, m) in group {
                    if let m, m.hasAnyMeasurement { media[relationID] = m }
                    addTask()
                }
            }
            if !media.isEmpty { pushOptions() }
        }
    }

    // MARK: - Derived data (redesign)

    private var sortOrder: MoviesSortOrder {
        MoviesSortOrder(rawValue: sortOrderRaw) ?? .titleAZ
    }

    private var activeServerIDString: String? {
        (servers.first(where: { $0.isActive }) ?? servers.first)?.id.uuidString
    }

    /// Movie progress rows scoped to the active playlist (rows with no
    /// serverID predate per-server progress and stay visible everywhere).
    private var movieProgress: [WatchProgress] {
        let rows = allProgress.filter { p in
            guard p.vodType == progressType else { return false }
            guard let sid = activeServerIDString else { return true }
            return p.serverID == nil || p.serverID == sid
        }
        guard kind == .series else { return rows }
        // One hero page per series: the newest episode row wins.
        var seen = Set<String>()
        return rows.filter { p in
            guard let sid = p.seriesID else { return false }
            return seen.insert(sid).inserted
        }
    }

    /// Newest resume point, if any. The hero leads with it.
    private var heroProgress: WatchProgress? { movieProgress.first }

    /// Library minus hidden groups, before genre and sort.

    // Perf (Logan 2026-09-03: 4 fps scrolling the grid): these used to be
    // computed properties, so every body evaluation (every focus move and
    // every scroll frame that updates gridTopY) re-sorted all ~5k titles
    // with a localized compare, several times over. They are now computed
    // once per input change, off the main thread, into `derived`.
    struct LibraryDerived: Equatable {
        /// The grid's list: a windowed view of the catalog, not an array of
        /// titles. Only the row ids and rail buckets are resident.
        var library: VODWindowList = .empty
        var recentlyAdded: [VODDisplayItem] = []
        /// Rail letters present in the library, straight off the window list.
        var railLetters: Set<String> { library.railLetters }
        /// First grid row anchor per rail letter. Index based, so a rail jump
        /// never reads a row to know where to go.
        var firstGridID: [String: String] { library.firstAnchorByLetter }

        static func == (lhs: LibraryDerived, rhs: LibraryDerived) -> Bool {
            lhs.library === rhs.library && lhs.recentlyAdded.map(\.id) == rhs.recentlyAdded.map(\.id)
        }
    }
    @State private var derived = LibraryDerived()

    private struct LibraryKey: Hashable {
        let revision: Int
        let count: Int
        let catalogKey: String?
        let hidden: Set<String>
        let genre: String?
        let sort: String
        let hiddenIDs: Set<String>
        let onlyHidden: Bool
    }
    private var libraryKey: LibraryKey {
        LibraryKey(revision: vodStore.catalogRevision,
                   count: libraryCount,
                   catalogKey: vodStore.catalogKey,
                   hidden: effectiveHiddenGroups, genre: selectedGenre, sort: sortOrderRaw,
                   hiddenIDs: hiddenKeys, onlyHidden: showingHiddenOnly)
    }

    /// The library sort, also applied to search results (Logan 2026-09-04).
    /// The library grid itself is sorted in SQL; this stays for the search
    /// result array, which is bounded.
    nonisolated static func sortItems(_ items: [VODDisplayItem], by sort: MoviesSortOrder) -> [VODDisplayItem] {
        var library = items
        let keys = Dictionary(uniqueKeysWithValues: library.map {
            ($0.id, String(AlphabetRail.stripQualityPrefix($0.name))
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        })
        func byTitle(_ a: VODDisplayItem, _ b: VODDisplayItem) -> Bool {
            let ka = keys[a.id] ?? "", kb = keys[b.id] ?? ""
            if ka != kb { return ka < kb }
            return a.id < b.id
        }
        func ratingValue(_ i: VODDisplayItem) -> Double { Double(i.rating) ?? 0 }
        switch sort {
        case .titleAZ:    library.sort(by: byTitle)
        case .titleZA:    library.sort { byTitle($1, $0) }
        case .yearNewest:
            library.sort {
                if $0.releaseYear != $1.releaseYear { return $0.releaseYear > $1.releaseYear }
                return byTitle($0, $1)
            }
        case .yearOldest:
            // Unknown years sink to the end rather than leading the list.
            library.sort {
                let a = $0.releaseYear.isEmpty ? "9999" : $0.releaseYear
                let b = $1.releaseYear.isEmpty ? "9999" : $1.releaseYear
                if a != b { return a < b }
                return byTitle($0, $1)
            }
        case .ratingHigh:
            library.sort {
                let a = ratingValue($0), b = ratingValue($1)
                if a != b { return a > b }
                return byTitle($0, $1)
            }
        case .recentlyAdded:
            library.sort {
                let a = $0.addedAt ?? .distantPast
                let b = $1.addedAt ?? .distantPast
                if a != b { return a > b }
                return byTitle($0, $1)
            }
        }
        return library
    }

    /// Up to 20 newest titles by source add time (cached).
    private var recentlyAdded: [VODDisplayItem] { derived.recentlyAdded }

    /// Hero pages: every Continue Watching title (newest first, up to 12).
    /// Empty when nothing is resumable: the hero section is Continue
    /// Watching and nothing else (Logan 2026-09-14).
    /// Cached hero pages. The old computed form ran a linear search over
    /// the whole library for each resume row on EVERY body pass, and a
    /// tvOS focus move re-evaluates the body (Time Profiler 2026-09-04
    /// 15:24: a third of main thread time while stepping rows).
    @State private var heroPages: [MoviesHeroPage] = []
    /// TMDB landscape art per hero item id, for rows without a backdrop
    /// (a portrait poster cropped to the hero frame read as badly scaled,
    /// Logan 2026-09-04).
    @State private var heroBackdrops: [String: URL] = [:]

    /// True when the hero carries at least one WatchProgress row. With the
    /// library fallback page gone this is true whenever a hero exists.
    private var heroIsContinueWatching: Bool {
        heroPages.contains { $0.progress != nil }
    }

    private var heroPagesKey: String {
        let progress = movieProgress.prefix(12).map { "\($0.vodID)|\($0.positionMs)" }.joined(separator: ",")
        return "\(progress)#\(libraryCount)#\(recentlyAdded.first?.id ?? "")#\(effectiveHiddenGroups.count)#\(hiddenKeys.count)#\(showingHiddenOnly)#\(isLoadingLibrary)"
    }

    @State private var heroPagesTask: Task<Void, Never>?

    private func refreshHeroPages() {
        heroPagesTask?.cancel()
        let progress = Array(movieProgress.prefix(12))
        let wanted = Array(Set(progress.compactMap(heroKey)))
        let k = kind
        heroPagesTask = Task { @MainActor in
            // One indexed read for the dozen resume rows, instead of a linear
            // walk of the whole library on every body pass.
            let byID = wanted.isEmpty ? [:] : await vodStore.items(kind: k, ids: wanted)
            guard !Task.isCancelled else { return }
            applyHeroPages(progress: progress, byID: byID)
        }
    }

    private func applyHeroPages(progress: [WatchProgress], byID: [String: VODDisplayItem]) {
        let resumes: [MoviesHeroPage] = progress.compactMap { p in
            guard let key = heroKey(p) else { return nil }
            // Series rows have no synthetic fallback: the episode row does
            // not carry the show's name or art.
            let item = byID[key] ?? (kind == .movie ? MoviesView.syntheticItem(from: p) : nil)
            // A hidden title stays out of Continue Watching too.
            guard let item, !hiddenTitles.isHidden(item) else { return nil }
            return MoviesHeroPage(item: item, progress: p)
        }
        if !resumes.isEmpty {
            heroPages = resumes.map { applyBackdrop($0) }
            fetchHeroBackdrops(for: resumes)
            return
        }
        // Progress rows exist but their titles are not loaded yet (the
        // sweep is still running): keep what is showing rather than
        // clearing the hero mid-sweep (Logan 2026-09-04: "carousel
        // replaced by a static single card" on TV Shows).
        if !progress.isEmpty, isLoadingLibrary { return }
        // The hero section exists ONLY for Continue Watching (Logan
        // 2026-09-14). With nothing resumable there is no hero at all: no
        // "Recently added" / "Featured" fallback card and no reserved
        // space, the page starts with the first shelf.
        heroPages = []
    }

    private func applyBackdrop(_ page: MoviesHeroPage) -> MoviesHeroPage {
        var p = page
        p.backdropOverride = TMDBArtCache.shared.backdropURL(for: page.item) ?? heroBackdrops[page.item.id]
        return p
    }

    /// Fills heroBackdrops from TMDB for every hero page (TMDB is the
    /// priority when a key is set; the provider's art is the fallback);
    /// re-applies to the pages once fetched.
    private func fetchHeroBackdrops(for pages: [MoviesHeroPage]) {
        guard TMDBPosters.isEnabled, let apiKey = TMDBPosters.apiKey else { return }
        let missing = pages.filter { heroBackdrops[$0.item.id] == nil && TMDBArtCache.shared.backdropURL(for: $0.item) == nil }
        guard !missing.isEmpty else { return }
        let isMovie = kind == .movie
        Task { @MainActor in
            for page in missing {
                if let url = await TMDBService.backdropURL(forTitle: page.item.displayName, isMovie: isMovie, apiKey: apiKey) {
                    heroBackdrops[page.item.id] = url
                }
            }
            heroPages = heroPages.map { applyBackdrop($0) }
        }
    }

    /// Genre pills: the visible categories, in store order, "All" first.
    private var genrePills: [String] {
        let hidden = effectiveHiddenGroups
        var pills = libraryCategories.map(\.name).filter { !hidden.contains($0) }
        // "Hidden" leads the Filter row, and only exists while something is
        // hidden. It is an ordinary pill: one press selects, another clears.
        if hiddenPillAvailable {
            pills.removeAll { $0 == MoviesView.hiddenPillLabel }
            pills.insert(MoviesView.hiddenPillLabel, at: 0)
        }
        return pills
    }

    /// The library grid: visible movies, genre-filtered, sorted (cached).
    private var libraryMovies: VODWindowList { derived.library }

    private func cycleSort() {
        let all = MoviesSortOrder.allCases
        let idx = all.firstIndex(of: sortOrder) ?? 0
        sortOrderRaw = all[(idx + 1) % all.count].rawValue
    }

    /// Minimal item for a resume row whose catalog entry is not loaded
    /// (same shape ContinueWatchingSection synthesizes for View Movie).
    /// Watchlist rows for the active playlist, resolved against the loaded
    /// library (so the card carries the full movie) with a synthetic
    /// fallback so a saved title still shows before the sweep reaches it.
    /// Cached: as a computed property it walked all ~5k rows on every body
    /// pass of the focus scroll (Time Profiler 2026-09-04 18:50, ~80 ms per
    /// Up from the shelf to the hero).
    @State private var watchlistItems: [VODDisplayItem] = []

    private var watchlistKey: String {
        let rows = watchlistEntries.map { "\($0.vodID)|\($0.serverID ?? "")" }.joined(separator: ",")
        return "\(rows)#\(activeServerIDString ?? "")#\(libraryCount)"
    }

    @State private var watchlistTask: Task<Void, Never>?

    private func refreshWatchlistItems() {
        watchlistTask?.cancel()
        let sid = activeServerIDString
        let rows = watchlistEntries.filter { e in
            guard e.vodType == kindString else { return false }
            guard let sid else { return true }
            return e.serverID == nil || e.serverID == sid
        }
        guard !rows.isEmpty else { watchlistItems = []; return }
        let wanted = Array(Set(rows.map(\.vodID)))
        let hidden = hiddenKeys
        let k = kind
        watchlistTask = Task { @MainActor in
            // Indexed read for the saved ids, not a walk of the catalog.
            let byID = await vodStore.items(kind: k, ids: wanted)
            guard !Task.isCancelled else { return }
            watchlistItems = HiddenVODStore.apply(
                rows.compactMap { e in byID[e.vodID] ?? MoviesView.syntheticItem(from: e) },
                hiddenKeys: hidden, onlyHidden: false)
        }
    }

    private static func syntheticItem(from e: WatchlistEntry) -> VODDisplayItem? {
        guard let sid = e.serverID, let serverUUID = UUID(uuidString: sid) else { return nil }
        if e.vodType == "series" {
            let show = VODSeries(
                id: e.vodID, name: e.title,
                posterURL: e.posterURL.flatMap { URL(string: $0) }, backdropURL: nil,
                rating: e.rating, plot: "", genre: "", releaseDate: e.releaseYear,
                cast: "", director: "", categoryID: "", categoryName: "",
                serverID: serverUUID, seasons: [], episodeCount: 0)
            return VODDisplayItem(series: show)
        }
        let movie = VODMovie(
            id: e.vodID, name: e.title,
            posterURL: e.posterURL.flatMap { URL(string: $0) }, backdropURL: nil,
            rating: e.rating, plot: "", genre: "", releaseDate: e.releaseYear, duration: "",
            cast: "", director: "", imdbID: "", categoryID: "", categoryName: "",
            streamURL: nil, containerExtension: "", serverID: serverUUID)
        return VODDisplayItem(movie: movie)
    }

    /// Long-press menu on a poster: Details, then Add to / Remove from
    /// Watchlist.
    @ViewBuilder
    private func watchlistMenuButton(_ item: VODDisplayItem) -> some View {
        let saved = watchlistEntries.contains { $0.vodID == item.id
            && ($0.serverID == nil || $0.serverID == item.serverID.uuidString) }
        Button {
            navPath.append(item)
        } label: {
            Label("Details", systemImage: "info.circle")
        }
        Button {
            WatchlistManager.toggle(item)
        } label: {
            Label(saved ? "Remove from Watchlist" : "Add to Watchlist",
                  systemImage: saved ? "bookmark.slash" : "bookmark")
        }
        HiddenVODStore.menuButton(item)
    }

    private static func syntheticItem(from p: WatchProgress) -> VODDisplayItem? {
        guard let sid = p.serverID, let serverUUID = UUID(uuidString: sid) else { return nil }
        let movie = VODMovie(
            id: p.vodID, name: p.title,
            posterURL: p.posterURL.flatMap { URL(string: $0) }, backdropURL: nil,
            rating: "", plot: "", genre: "", releaseDate: "", duration: "",
            cast: "", director: "", imdbID: "", categoryID: "", categoryName: "",
            streamURL: p.streamURL.flatMap { URL(string: $0) },
            containerExtension: "", serverID: serverUUID)
        return VODDisplayItem(movie: movie)
    }

    // MARK: - Hero playback

    /// Hero primary action: resume when there is progress, else play.
    private func heroPrimary(_ page: MoviesHeroPage) {
        let item = page.item
        if let p = page.progress {
            resumeFromContinueWatching(p)
        } else {
            playMovie(item, resumePositionMs: WatchProgressManager.getResumePosition(
                vodID: item.id, serverID: item.serverID.uuidString) ?? 0)
        }
    }

    /// Direct play, the same steps VODDetailView.startPlayback takes for a
    /// movie: resolve the Dispatcharr session URL, drop the API key when
    /// the session lives off-host, tear down live playback, then the
    /// unified container first and the legacy cover as fallback.
    private func playMovie(_ item: VODDisplayItem, resumePositionMs startAt: Int32) {
        guard item.movie?.streamURL != nil else {
            navPath.append(item)
            return
        }
        PlayWhereRouter.shared.request(title: item.name, item: .nonLive) {
            playMoviePicked(item, resumePositionMs: startAt)
        }
    }

    private func playMoviePicked(_ item: VODDisplayItem, resumePositionMs startAt: Int32) {
        guard let movie = item.movie, let url = movie.streamURL else { return }
        let server = servers.first(where: { $0.id == item.serverID })
        var headers = server?.authHeaders ?? [:]
        let key = VODVersionSelectionStore.storageKey(serverID: item.serverID,
                                                      itemType: "movie", itemID: item.id)
        Task { @MainActor in
            var resolved = url
            if let server, server.type == .dispatcharrAPI {
                let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                         auth: .apiKey(server.effectiveApiKey),
                                         userAgent: server.effectiveUserAgent,
                                         authMode: server.dispatcharrHeaderMode)
                resolved = (try? await api.resolveFinalURLForPlayback(url)) ?? url
                if !api.isOwnHost(resolved) {
                    headers = headers.filter {
                        $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame
                    }
                }
            }
            PlayerSession.shared.exit()
            if PlayerSession.shared.beginVOD(
                title: item.displayName,
                streamURL: resolved,
                headers: headers,
                posterURL: item.posterURL,
                vodID: item.id,
                serverID: item.serverID.uuidString,
                vodType: "movie",
                resumePositionMs: startAt,
                versionSelectionKey: key) {
                isPlaying = true
                return
            }
            resumePlayingTitle = item.name
            resumeVodID = item.id
            resumePosterURL = item.posterURL?.absoluteString
            resumeServerID = item.serverID.uuidString
            resumePositionMs = startAt
            resumePlayingHeaders = headers
            resumeVersionOptions = []
            resumeVersionSelectionKey = key
            resumePlayingURL = IdentifiableURL(url: resolved)
            isPlaying = true
        }
    }

    // MARK: - Content
    @ViewBuilder
    private var content: some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            phoneContent
        } else {
            legacyContent
        }
    }

    /// Phone: the shared media page (Logan 2026-09-09, one template for
    /// Movies, TV Shows and DVR). This view only supplies data and cards.
    private var phoneContent: some View {
        let gridCount = isSearching ? filteredMovies.count : libraryMovies.count
        let watchlistPages = watchlistItems.map { MoviesHeroPage(item: $0, progress: nil) }
        return VStack(spacing: 0) {
            if !hiddenGroups.isEmpty && searchText.isEmpty {
                hiddenGroupsBanner
            }
            PhoneMediaPage(
                decks: [
                    PhoneDeck(title: "Continue Watching", cards: heroPages.map { page in
                        PhoneDeckCard(id: page.id) { AnyView(phoneHero(page, inWatchlistDeck: false)) }
                    }),
                    PhoneDeck(title: "Watchlist", cards: watchlistPages.map { page in
                        PhoneDeckCard(id: "wl-" + page.id) { AnyView(phoneHero(page, inWatchlistDeck: true)) }
                    }),
                ],
                headerTitle: isSearching ? "Results" : "All \(kindTitle)",
                headerCount: gridCount,
                headerIsUpdating: !isSearching && isUpdatingLibrary,
                search: PhoneSearch(isActive: $showSearchField, text: $searchText,
                                    placeholder: "Search \(kindLower)", onClose: clearSearch),
                searchExtras: phoneSearchExtras,
                sortMenu: {
                    AnyView(ForEach(MoviesSortOrder.allCases, id: \.self) { order in
                        Button { sortOrderRaw = order.rawValue } label: {
                            if order == sortOrder { Label(order.label, systemImage: "checkmark") } else { Text(order.label) }
                        }
                    })
                },
                onFilter: { showManageGroups = true },
                pills: genrePills,
                selectedPill: $selectedGenre,
                itemCount: gridCount,
                cell: { index in
                    let item = isSearching ? filteredMovies[index] : libraryMovies[index]
                    return AnyView(
                        NavigationLink(value: item) {
                            VODPosterCard(item: item, headers: dispatcharrHeaders)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { watchlistMenuButton(item) }
                    )
                },
                emptyView: isSearching && !isSearchingLibrary ? {
                    AnyView(Text("No results").scaledFont(.labelMedium.subtext()).foregroundColor(Color.contrastText(.textTertiary)))
                } : nil,
                railLetters: railLetters,
                railTarget: { letter in firstGridID(for: letter) },
                footer: TMDBPosters.isEnabled
                    ? { AnyView(TMDBAttributionView(style: .long)) }
                    : nil,
                owningTab: kind == .series ? .tvShows : .movies,
                isAtRoot: isAtRoot
            )
        }
    }

    private func phoneHero(_ page: MoviesHeroPage, inWatchlistDeck: Bool) -> some View {
        let saved = watchlistEntries.contains { $0.vodID == page.item.id
            && ($0.serverID == nil || $0.serverID == page.item.serverID.uuidString) }
        return MoviesHero(
            item: page.item,
            progress: page.progress,
            backdropOverride: page.backdropOverride,
            headers: dispatcharrHeaders,
            onPrimary: { heroPrimary(page) },
            onPlayFromStart: {
                if kind == .series, let p = page.progress {
                    resumeFromContinueWatching(p, startAt: 0)
                } else {
                    playMovie(page.item, resumePositionMs: 0)
                }
            },
            onDetails: { navPath.append(page.item) },
            onRemove: (!inWatchlistDeck && page.progress != nil) ? {
                guard let p = page.progress else { return }
                WatchProgressManager.delete(vodID: p.vodID, serverID: p.serverID)
            } : nil,
            isOnWatchlist: inWatchlistDeck ? true : saved,
            onToggleWatchlist: { WatchlistManager.toggle(page.item) },
            primaryFocusID: page.id
        )
    }

    private var phoneSearchExtras: [PhoneRow] {
        var rows: [PhoneRow] = []
        if let who = personMatchName {
            rows.append(PhoneRow(id: "person") {
                AnyView(Text("Includes titles with \(who)")
                    .scaledFont(.labelMedium.subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .padding(.horizontal, 16))
            })
        }
        let ids = providerNames.keys.sorted()
        if ids.count >= 2 {
            rows.append(PhoneRow(id: "providers") {
                AnyView(ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        DVRSegmentPill(label: "All Providers", isSelected: selectedProviderID == nil) { selectProvider(nil) }
                        ForEach(ids, id: \.self) { pid in
                            DVRSegmentPill(label: providerNames[pid] ?? "Provider \(pid)", isSelected: selectedProviderID == pid) {
                                selectProvider(selectedProviderID == pid ? nil : pid)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                })
            })
        }
        if isSearchingLibrary {
            rows.append(PhoneRow(id: "searching") {
                AnyView(HStack(spacing: 10) {
                    ProgressView().tint(.accentPrimary)
                    Text("Searching server…").scaledFont(.labelMedium.subtext()).foregroundColor(Color.contrastText(.textTertiary))
                }
                .padding(.horizontal, 16))
            })
        }
        return rows
    }

    private var hiddenGroupsBanner: some View {
        HStack(spacing: 6) {
            Text("\(hiddenGroups.count) group\(hiddenGroups.count == 1 ? "" : "s") hidden")
                .scaledFont(.labelMedium.subtext())
                .foregroundColor(Color.contrastText(.textSecondary))
            Button {
                hiddenGroups.removeAll()
                HiddenGroupsStore.save(hiddenGroups, forKey: hiddenGroupsKey)
            } label: {
                Text("Show All").scaledFont(.labelMedium).foregroundColor(Color.contrastText(.accentPrimary))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var legacyContent: some View {
        VStack(spacing: 0) {
            // Hidden groups indicator
            if !hiddenGroups.isEmpty && searchText.isEmpty {
                HStack(spacing: 6) {
                    Text("\(hiddenGroups.count) group\(hiddenGroups.count == 1 ? "" : "s") hidden")
                        .scaledFont(.labelMedium.subtext())
                        .foregroundColor(Color.contrastText(.textSecondary))
                    Button {
                        hiddenGroups.removeAll()
                        HiddenGroupsStore.save(hiddenGroups, forKey: hiddenGroupsKey)
                    } label: {
                        Text("Show All")
                            .scaledFont(.labelMedium)
                            .foregroundColor(Color.contrastText(.accentPrimary))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

                GeometryReader { outer in
                ScrollViewReader { proxy in
                ZStack(alignment: .topLeading) {
                ScrollView {
                    VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("movies-top")
                    // Search replaces only the library grid (Logan
                    // 2026-09-04); the hero and shelves stay put and the
                    // header with the field is never re-created mid-typing.
                    Group {
                        VStack(alignment: .leading, spacing: sectionSpacing) {
                            if UIDevice.current.userInterfaceIdiom == .phone {
                                // Header at DVR's height: measured 131 vs 104
                                // (2026-09-09), so 22 pt of spacer and the
                                // scroll view's implicit spacing come off.
                                Color.clear.frame(height: 3)
                            }
                            // Continue Watching IS the hero: one page per title
                            // in progress (Logan 2026-09-03), so the separate
                            // poster row is gone from this tab.
                            let pages = heroPages
                            if !pages.isEmpty {
                                // Section header above the hero (Logan
                                // 2026-09-11), styled and inset exactly like
                                // the shelf titles below ("Watchlist"), with a
                                // shelf's title-to-cards gap under it. Only
                                // for the Continue Watching hero: the library
                                // fallback page (newest addition) carries no
                                // progress and was never labeled.
                                VStack(alignment: .leading, spacing: shelfTitleSpacing) {
                                if heroIsContinueWatching {
                                    Text("Continue Watching")
                                        .scaledFont(.headlineSmall)
                                        .foregroundColor(.textPrimary)
                                        .padding(.horizontal, 16)
                                        .padding(.leading, contentLeadingInset)
                                }
                                MoviesHeroCarousel(
                                    pages: pages,
                                    headers: dispatcharrHeaders,
                                    focusRequest: heroFocusRequestBinding,
                                    restoreRequest: Binding(get: { heroRestoreRequest },
                                                            set: { heroRestoreRequest = $0 }),
                                    onHeroFocusChange: { focused in
                                    },
                                    onPrimary: { heroPrimary($0) },
                                    onPlayFromStart: { page in
                                        if kind == .series, let p = page.progress {
                                            resumeFromContinueWatching(p, startAt: 0)
                                        } else {
                                            playMovie(page.item, resumePositionMs: 0)
                                        }
                                    },
                                    onDetails: { navPath.append($0.item) },
                                    onRemove: { page in
                                        guard let p = page.progress else { return }
                                        WatchProgressManager.delete(vodID: p.vodID, serverID: p.serverID)
                                    },
                                    isOnWatchlist: { page in
                                        watchlistEntries.contains { $0.vodID == page.item.id
                                            && ($0.serverID == nil || $0.serverID == page.item.serverID.uuidString) }
                                    },
                                    onToggleWatchlist: { page in WatchlistManager.toggle(page.item) }
                                )
                                }
                            }

                            let watchlist = watchlistItems
                            if !watchlist.isEmpty {
                                if UIDevice.current.userInterfaceIdiom == .phone {
                                    // Phone: the Watchlist is a second card deck, same
                                    // cards and gestures as Continue Watching (Logan
                                    // 2026-09-05).
                                    Text("Watchlist")
                                        .scaledFont(.headlineSmall)
                                        .foregroundColor(.textPrimary)
                                        .padding(.horizontal, 16)
                                    MoviesHeroCarousel(
                                        pages: watchlist.map { MoviesHeroPage(item: $0, progress: nil) },
                                        headers: dispatcharrHeaders,
                                        onPrimary: { heroPrimary($0) },
                                        onPlayFromStart: { playMovie($0.item, resumePositionMs: 0) },
                                        onDetails: { navPath.append($0.item) },
                                        onRemove: { _ in },
                                        isOnWatchlist: { _ in true },
                                        onToggleWatchlist: { page in WatchlistManager.toggle(page.item) }
                                    )
                                    .background(GeometryReader { g in
                                        Color.clear.onAppear { geometryBox.watchlistShelfHeight = g.size.height }
                                            .onChange(of: g.size.height) { _, h in geometryBox.watchlistShelfHeight = h }
                                    })
                                } else {
                                    posterShelf(title: "Watchlist", items: watchlist)
                                        .padding(.leading, contentLeadingInset)
                                        .background(GeometryReader { g in
                                            Color.clear.onAppear { geometryBox.watchlistShelfHeight = g.size.height }
                                                .onChange(of: g.size.height) { _, h in geometryBox.watchlistShelfHeight = h }
                                        })
                                }
                            }
                            // No Recently Added shelf (Logan 2026-09-04): the Watchlist
                            // is the one shelf under the hero. recentlyAdded still
                            // feeds the hero's fallback page.

                            let gridCount = isSearching ? filteredMovies.count : libraryMovies.count
                            libraryHeader(title: isSearching ? "Results" : "All \(kindTitle)",
                                          count: gridCount, showPills: !isSearching,
                                          onTitleTap: {
                                              // Phone (Logan 2026-09-05): the title scrolls the
                                              // library to the top of the page, rail and all.
                                              withAnimation(.easeInOut(duration: 0.55)) {
                                                  proxy.scrollTo("movies-library", anchor: .top)
                                              }
                                          })
                                .id("movies-library")
                                .padding(.leading, contentLeadingInset)
                                .onChange(of: scrollToLibraryTick) { _, _ in
                                    withAnimation(.easeInOut(duration: 0.45)) {
                                        proxy.scrollTo("movies-library", anchor: .top)
                                    }
                                }
                            if isSearching {
                                if let who = personMatchName {
                                    Text("Includes titles with \(who)")
                                        .scaledFont(.labelMedium.subtext())
                                        .foregroundColor(Color.contrastText(.textTertiary))
                                        .padding(.horizontal, 16)
                                        .padding(.leading, contentLeadingInset)
                                }
                                providerPills
                                    .padding(.leading, contentLeadingInset)
                                if isSearchingLibrary {
                                    HStack(spacing: 10) {
                                        ProgressView().tint(.accentPrimary)
                                        Text("Searching server…")
                                            .scaledFont(.labelMedium.subtext())
                                            .foregroundColor(Color.contrastText(.textTertiary))
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.leading, contentLeadingInset)
                                }
                            }
                            Group {
                                if isSearching {
                                    railCatcherAndGrid(filteredMovies)
                                } else {
                                    railCatcherAndGrid(libraryMovies)
                                }
                            }
                                .background(GeometryReader { g in
                                    Color.clear.preference(
                                        key: GridTopKey.self,
                                        value: g.frame(in: .named("moviesScroll")).minY.rounded())
                                })
                            // TMDB asks for the logo and the required line
                            // wherever their data or images are shown, so it
                            // rides under the library grid as well as on the
                            // detail page. Appended only: no focus or scroll
                            // behavior changes.
                            if TMDBPosters.isEnabled {
                                TMDBAttributionView(style: .long)
                                    .padding(.horizontal, 18)
                                    .padding(.leading, contentLeadingInset)
                                    .padding(.bottom, 24)
                            }
                        }
                    }

                    Color.clear.frame(height: 96)
                    }
                }
                // Alphabet rail: pinned to the leading edge, jumps the
                // library grid to the first title for a letter.
                .coordinateSpace(name: "moviesScroll")
                .scrollPosition(scrollPositionBinding)
                .onChange(of: scrollPositionTick) { _, _ in }
                // iPad: re-tapping the tab you are already on takes the page
                // back to the top (phone does the same through
                // PhoneMediaPage). Skipped while a detail is pushed - that
                // re-tap is UIKit's pop.
                .onReceive(
                    NotificationCenter.default.publisher(for: .astralTabReselected)
                ) { note in
                    let tab: AppTab = kind == .series ? .tvShows : .movies
                    guard isAtRoot,
                          (note.userInfo?["tab"] as? String) == tab.rawValue else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { scrollContent(toY: 0) }
                }
                .onPreferenceChange(GridTopKey.self) { gridTopY in
                    guard let gridTopY else { return }
                    geometryBox.gridTopVisible = gridTopY
                    // Phone: parked at the vertical centre of the right edge,
                    // shown only once the library header has scrolled past
                    // the top so the grid owns the display (Logan 2026-09-05),
                    // fading out again when the hero or shelves come back.
                    // Centered on the VISIBLE grid, not the screen: while the
                    // library header is still on screen the rail moves down
                    // by half of it (Logan 2026-09-05). An offset, so it can
                    // never feed back into layout.
                    // State writes here re-render the whole tab, so they run
                    // only when something visible changes: the rail's park
                    // position is updated in 4pt steps and only while the
                    // rail is (about to be) shown; never while searching.
                    // Written every frame, it capped scrolling at ~40 layout
                    // passes a second (Logan 2026-09-09, probe).
                    let want = gridTopY <= 110 && searchText.isEmpty
                    // No global animation transaction here: the rail animates
                    // itself (see railMounted). A withAnimation around this
                    // write animated the scroll view's own pending layout.
                    // Writes go to the rail's own observable so only the fade
                    // wrapper re-renders; the park offset is set once when the
                    // rail appears. railTop (@State) is written a single time
                    // so the shared mount condition holds; railVisible is
                    // unused on the phone.
                    let rail = geometryBox.phoneRail
                    if want != rail.visible {
                        if want { rail.top = (max(0, gridTopY) / 8).rounded() * 4 }
                        rail.visible = want
                    }
                    if railTop == nil { railTop = 0 }
                }


                // Rail: a sibling of the ScrollView, not an overlay on it and
                // not in its content, so focusing it never scrolls the grid.
                // Shown only while focus is in the grid or on the rail itself:
                // it slides in from the left edge on the first poster focus and
                // stays out of the way of the hero and shelves (Logan 2026-09-05).
                // iPhone: the rail stays MOUNTED and fades with a local
                // animation. Inserting it as a sibling with a transition
                // inside a global withAnimation caught the scroll as the pills
                // left the screen and bounced it twice at the top (Logan
                // 2026-09-09). tvOS keeps the focus-driven mount.
                let railMounted = searchText.isEmpty && railTop != nil
                if railMounted, let railTop {
                    ZStack(alignment: .topLeading) {
                        AlphabetRail(
                            available: railLetters,
                            focusRequest: railFocusRequestBinding,
                            onFocusChange: { focused in
                                railFocused = focused
                                updateRailVisibility()
                            },
                            onExitRight: {
                            },
                            onExitUp: {
                            }
                        ) { letter in
                            let found = firstGridID(for: letter)
                            debugLog("[RAIL] movies jump \(letter) id=\(found ?? "nil") pitch=\(geometryBox.rowPitch) width=\(geometryBox.gridWidth) gridTop=\(geometryBox.gridTopVisible) offset=\(geometryBox.contentOffsetY)")
                            guard let id = found,
                                  let index = Int(id.dropFirst("grid-row-".count)),
                                  index < libraryMovies.count else { return }
                            // One row read for the landing title, not a scan.
                            let itemID = libraryMovies[index].id
                            if geometryBox.rowPitch > 0, geometryBox.gridWidth > 0 {
                                let cols = UIDevice.current.userInterfaceIdiom == .phone
                                    ? 3 : max(1, Int(geometryBox.gridWidth / 132))
                                let row = index / cols
                                let gridTopContent = geometryBox.gridTopVisible + geometryBox.contentOffsetY
                                let y = gridTopContent + 16 + CGFloat(row) * geometryBox.rowPitch - 24
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    scrollContent(toY: max(0, y))
                                }
                            } else {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                            }
                        }
                        .frame(width: railWidth)
                        // Offset, not padding: padding made the rail column
                        // taller than the scroll area, which shifted the
                        // scroll view's coordinate space by the top safe
                        // area, which moved the grid-top preference, which
                        // moved railTop again: an infinite layout loop that
                        // froze the phone (log 2026-09-05 18:13, gridTopY
                        // flipping 350 / 514 every frame).
                        // Centered by frame alignment (Logan 2026-09-05), not
                        // by an offset from the top.
                        // Real layout inside a FIXED-height box, not .offset:
                        // an offset rail drew in the right place but its taps
                        // fell through to the poster beneath (Logan 2026-09-05,
                        // "tapping a letter opens the closest item"). The box
                        // is pinned to the scroll area's height, so the padding
                        // can never feed back into the layout (the 18:13 loop).
                        .modifier(PhoneRailFade(state: geometryBox.phoneRail,
                                                restingTop: railRestingTop(in: outer),
                                                boxWidth: outer.size.width,
                                                boxHeight: outer.size.height + outer.safeAreaInsets.top))
                    }
                    .ignoresSafeArea(.container, edges: .top)
                }
                }
                }
                .onScrollGeometryChange(for: [CGFloat].self) { scrollGeo in
                    // Resting offset at the end of the content (measured on
                    // the iPhone 2026-09-09: content 1984, container 894,
                    // insets 49 bottom / 62 top rest at 1077).
                    [scrollGeo.contentOffset.y,
                     scrollGeo.contentSize.height - scrollGeo.containerSize.height
                        + scrollGeo.contentInsets.bottom - scrollGeo.contentInsets.top]
                } action: { old, new in
                    guard UIDevice.current.userInterfaceIdiom == .phone else { return }
                    let oldY = old[0], y = new[0], maxY = new[1]
                    // Rubber-band past the end: the content moves up as it
                    // springs back, which read as a scroll-up and brought the
                    // bar back mid-bounce; the bar's inset then re-laid the
                    // grid out, the "re-grab" at the bottom of the results
                    // (Logan 2026-09-09). No bar changes while overscrolled.
                    if y > maxY - 1 || oldY > maxY - 1 { return }
                    if let hidden = tabBarTracker.update(oldY: oldY, newY: y,
                                                         hidden: gridTabBarHidden) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            gridTabBarHidden = hidden
                        }
                    }
                }
                .onScrollPhaseChange { _, phase in
                    scrollIsIdle = phase == .idle
                    if phase == .idle { applyPendingDerived() }
                }
                .scrollAwayTabBar(collapsed: gridTabBarHidden)
                .ignoresSafeArea(.container, edges: .bottom)
                .astralContentUnderTabBar()
                .astralNoTopScrollEdge()
            }
        }
    }

    /// Top padding that centers the rail in the scroll area (the box spans
    /// the top safe area too); `railTop` then moves it down by half of the
    /// visible library header.
    private func railRestingTop(in outer: GeometryProxy) -> CGFloat {
        max(0, (outer.size.height + outer.safeAreaInsets.top - AlphabetRail.totalHeight) / 2)
    }

    /// Where the rail parks once the grid has scrolled under it: centered
    /// vertically in the scroll area.
    private func railCenteredTop(in height: CGFloat) -> CGFloat {
        // Sits a little below true center (Logan 2026-09-03): the eye reads
        // the rail against the poster rows, which start below the top edge.
        return max(8, (height - AlphabetRail.totalHeight) / 2)
    }

    /// Grid padding (16) plus the card style's own inset so the first
    /// letter lines up with the first poster's top edge.
    /// Show at once when focus enters the grid or rail; hide after a short
    /// grace so the grid -> rail handoff (gridFocus nil, then the letter
    /// focuses) does not unmount the rail mid-hop.
    private func updateRailVisibility() {
    }

    private var railGridOffset: CGFloat {
        return 16
    }

    private var railWidth: CGFloat {
        // Narrow lane at the screen edge: it only needs to be tappable
        // (Logan 2026-09-09), and the grid no longer reserves room for it.
        return 14
    }

    /// Leading inset for shelves, header and grid. tvOS: 0, the rail lives
    /// in the 80 pt safe-area margin so the content lines up with the hero
    /// card's left edge (Logan 2026-09-04). iOS keeps the rail's width.
    private var contentLeadingInset: CGFloat {
        // The phone rail overlays the right edge and only while the grid
        // fills the display, so the content reserves nothing for it.
        return 0
    }

    /// Letters that have at least one title in the library grid (cached).
    private var railLetters: Set<String> { derived.railLetters }

    /// Grid row id of the first title in this letter's bucket (cached).
    private func firstGridID(for letter: String) -> String? {
        derived.firstGridID[letter]
    }

    private var sectionSpacing: CGFloat {
        return 18
    }

    private var railFocusRequestBinding: Binding<String?> { .constant(nil) }
    private var heroFocusRequestBinding: Binding<Bool> { .constant(false) }

    private func railCatcherAndGrid<C: RandomAccessCollection>(_ items: C) -> some View
    where C.Element == VODDisplayItem, C.Index == Int {
        posterGrid(items).padding(.leading, contentLeadingInset)
    }

    /// "All Movies · N" with the genre pills and, on tvOS, the search /
    /// sort / filter controls on the right.
    private func libraryHeader(title: String, count: Int, showPills: Bool,
                               onTitleTap: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                // Plain text, but tappable on the phone: no button look.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title)
                        .scaledFont(.headlineSmall)
                        .foregroundColor(.textPrimary)
                    Text("\(count)")
                        .scaledFont(.labelMedium.subtext())
                        .foregroundColor(Color.contrastText(.textTertiary))
                    // The count is still growing: say so rather than let the
                    // user read a partial library as the whole one (Logan
                    // 2026-09-16, Android parity).
                    if isUpdatingLibrary { VODUpdatingBadge() }
                }
                .contentShape(Rectangle())
                .onTapGesture { if UIDevice.current.userInterfaceIdiom == .phone { onTitleTap?() } }
                Spacer()
                iOSHeaderControls
            }
            .padding(.horizontal, 16)
            if showSearchField {
                iOSSearchField
                    .padding(.horizontal, 16)
            }

            if showPills && !genrePills.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: pillSpacing) {
                        genrePill("All", isSelected: selectedGenre == nil) { selectedGenre = nil }
                        ForEach(genrePills, id: \.self) { g in
                            genrePill(g, isSelected: selectedGenre == g) {
                                selectedGenre = (selectedGenre == g) ? nil : g
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    /// Search, sort and filter beside the library title, where they act
    /// (Logan 2026-09-05: no separate row at the top).
    private var iOSHeaderControls: some View {
        HStack(spacing: 8) {
            Button {
                if showSearchField {
                    withAnimation(.spring(response: 0.3)) { clearSearch() }
                } else {
                    // Insert the field with no animation, run ONE scroll, and
                    // raise the keyboard only after the scroll has settled:
                    // the insert transition, the scroll and the keyboard
                    // avoidance all animating at once read as jitter (Logan
                    // 2026-09-09).
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { showSearchField = true }
                    DispatchQueue.main.async { scrollToLibraryTick += 1 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { iosSearchFocused = true }
                }
            } label: { iOSCircle("magnifyingglass") }
                .accessibilityLabel(showSearchField ? "Close search" : "Search")
            Menu {
                ForEach(MoviesSortOrder.allCases, id: \.self) { order in
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
            Button { showManageGroups = true } label: { iOSCircle("line.3.horizontal.decrease") }
                .accessibilityLabel("Manage Groups")
        }
    }

    /// Pill search field under the library header (phone).
    private var iOSSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .scaledFont(.system(size: 15, weight: .semibold))
                .foregroundColor(Color.contrastText(.textSecondary))
            TextField("Search \(kindLower)", text: $searchText)
                .scaledFont(.system(size: 16))
                .foregroundColor(.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($iosSearchFocused)
            // Always shown: clears the query and closes the field (Logan
            // 2026-09-09).
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

    /// Provider filter for search results. Dispatcharr Direct Connect only
    /// (the only source that says which account carries a copy); shown when
    /// the hits span more than one provider.
    @ViewBuilder
    private var providerPills: some View {
        let ids = providerNames.keys.sorted()
        if ids.count >= 2 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: pillSpacing) {
                    genrePill("All Providers", isSelected: selectedProviderID == nil) { selectProvider(nil) }
                    ForEach(ids, id: \.self) { pid in
                        genrePill(providerNames[pid] ?? "Provider \(pid)", isSelected: selectedProviderID == pid) {
                            selectProvider(selectedProviderID == pid ? nil : pid)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    /// Cast & crew: resolve the query to a TMDB person (debounced), pull
    /// their film credits, keep the ones in the library. The server search
    /// only covers title/description/genre and list rows carry no cast.
    private func searchPeople(_ query: String) {
        personSearchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3, TMDBPosters.isEnabled, let apiKey = TMDBPosters.apiKey else {
            personMatchName = nil
            personMatches = []
            return
        }
        personSearchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let people = await TMDBService.searchPeople(q, apiKey: apiKey)
            guard !Task.isCancelled, !people.isEmpty else {
                personMatchName = nil; personMatches = []
                return
            }
            // Each candidate's credits are matched with two indexed
            // catalog reads (strict tmdb id, then normalized title for rows
            // that carry no id). The old path built a dictionary over the
            // WHOLE library for every search, which a 350k catalog cannot do.
            var best: (name: String, hits: [VODDisplayItem])? = nil
            for person in people {
                guard !Task.isCancelled else { return }
                let credits = await TMDBService.personCredits(personID: person.id, isMovie: kind == .movie, apiKey: apiKey)
                guard !credits.isEmpty else { continue }
                let byTMDB = await vodStore.itemsByTMDBID(kind: kind, tmdbIDs: credits.map(\.id))
                let titles = credits.map { VODCatalogStore.normalized($0.title) }
                let byTitle = await vodStore.itemsByNormalizedTitle(kind: kind, titles: titles,
                                                                    requireNoTMDBID: true)
                var seen = Set<String>()
                var hits: [VODDisplayItem] = []
                for c in credits {
                    let hit = byTMDB[c.id] ?? byTitle[VODCatalogStore.normalized(c.title)]
                    guard let hit, seen.insert(hit.id).inserted else { continue }
                    hits.append(hit)
                }
                if hits.count > (best?.hits.count ?? 0) { best = (person.name, hits) }
            }
            guard !Task.isCancelled else { return }
            personMatchName = best?.name
            personMatches = best?.hits ?? []
        }
    }

    private func selectProvider(_ pid: Int?) {
        guard pid != selectedProviderID else { return }
        selectedProviderID = pid
        searchLibrary(searchText, providerID: pid)
    }

    /// Clears the search and collapses the field, landing on Search.
    private func clearSearch() {
        searchCircleFocused = true
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.25)) {
                showSearchField = false
                searchText = ""
                selectedProviderID = nil
                personMatchName = nil
                personMatches = []
            }
        }
    }

    private func loadProviderNames() async {
        guard let server = servers.first(where: { $0.isActive }) ?? servers.first,
              server.type == .dispatcharrAPI else {
            providerNames = [:]
            return
        }
        let api = DispatcharrAPI(baseURL: server.effectiveBaseURL,
                                 auth: .apiKey(server.effectiveApiKey),
                                 userAgent: server.effectiveUserAgent,
                                 authMode: server.dispatcharrHeaderMode)
        let accounts = (try? await api.getM3UAccounts()) ?? []
        var map: [Int: String] = [:]
        for a in accounts {
            // Skip the locked built-in "custom" account and disabled ones
            // (Logan 2026-09-04: "custom" showed up as a provider).
            if a.locked == true || a.isActive == false { continue }
            if a.name?.lowercased() == "custom" { continue }
            map[a.id] = (a.name?.isEmpty == false) ? a.name! : "Provider \(a.id)"
        }
        providerNames = map
    }

    private var pillSpacing: CGFloat {
        return 8
    }

    @ViewBuilder
    private func genrePill(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        DVRSegmentPill(label: label, isSelected: isSelected, action: action)
    }

    /// Horizontal poster rail (Recently Added).
    private func posterShelf(title: String, items: [VODDisplayItem]) -> some View {
        VStack(alignment: .leading, spacing: shelfTitleSpacing) {
            Text(title)
                .scaledFont(.headlineSmall)
                .foregroundColor(.textPrimary)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: shelfCardSpacing) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            VODPosterCard(item: item, headers: dispatcharrHeaders)
                                .frame(width: shelfCardWidth)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { watchlistMenuButton(item) }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var shelfTitleSpacing: CGFloat {
        return 8
    }
    private var shelfCardSpacing: CGFloat {
        return 12
    }
    private var shelfCardWidth: CGFloat {
        return UIDevice.current.userInterfaceIdiom == .phone ? 96 : 120
    }

    /// The library grid (also the search results grid).
    ///
    /// Generic over the collection so the same grid serves the search result
    /// array and `VODWindowList`, the catalog-backed library. The `ForEach`
    /// walks INDEXES, never the elements: an item-id identity would have to
    /// read every row in the catalog just to build the list, which is exactly
    /// what the windowed store exists to avoid. LazyVGrid only materializes
    /// the rows it draws, so only a window of titles is ever resident.
    private func posterGrid<C: RandomAccessCollection>(_ items: C) -> some View
    where C.Element == VODDisplayItem, C.Index == Int {
        LazyVGrid(columns: columns, spacing: gridRowSpacing) {
            ForEach(items.startIndex..<items.endIndex, id: \.self) { index in
                let item = items[index]
                NavigationLink(value: item) {
                    VODPosterCard(item: item, headers: dispatcharrHeaders)
                }
                .buttonStyle(.plain)
                .contextMenu { watchlistMenuButton(item) }
                .id(VODWindowList.anchorID(index))
                .background(GeometryReader { g in
                    Color.clear.onAppear {
                        if index == items.startIndex {
                            geometryBox.rowPitch = g.size.height + gridRowSpacing
                        }
                    }
                })
            }
        }
        // Symmetric 18 pt margins so the posters sit centered (Logan
        // 2026-09-09); the alphabet rail overlays the right edge instead of
        // owning a gutter. Column gap 8 gives the two extra edge points.
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .background(GeometryReader { g in
            Color.clear.onAppear { geometryBox.gridWidth = g.size.width - 36 }
                .onChange(of: g.size.width) { _, w in geometryBox.gridWidth = w - 36 }
        })
    }

    // MARK: - Empty / Error
    @ViewBuilder
    private var emptyState: some View {
        if servers.isEmpty {
            EmptyStateView(
                icon: kindIcon,
                title: "No \(kindTitle)",
                message: "Add an Xtream Codes or Dispatcharr server to browse \(kindLower)."
            )
        } else if servers.first(where: { $0.isActive })?.supportsVOD == false {
            EmptyStateView(
                icon: kindIcon,
                title: "\(kindTitle) Unavailable",
                message: "M3U playlists do not include VOD content. Switch to an Xtream Codes or Dispatcharr API playlist in Settings > Playlists to browse \(kindLower)."
            )
        } else {
            EmptyStateView(
                icon: kindIcon,
                title: "No \(kindTitle)",
                message: serverContext("No \(kindLower) were returned by"),
                action: { refreshLibrary() },
                actionTitle: "Retry"
            )
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(.system(size: 40)).foregroundColor(.statusWarning)
            Text("Failed to load movies")
                .scaledFont(.headlineLarge).foregroundColor(.textPrimary)
            if let serverName = vodStore.lastMoviesServerName {
                Text("Server: \(serverName)")
                    .scaledFont(.labelMedium.subtext()).foregroundColor(Color.contrastText(.textSecondary))
            }
            Text(msg)
                .scaledFont(.bodyMedium.subtext()).foregroundColor(Color.contrastText(.textSecondary))
                .multilineTextAlignment(.center)
            PrimaryButton("Try Again") { refreshLibrary() }
                .frame(maxWidth: 200)
        }
        .padding(32)
    }

    private func serverContext(_ prefix: String) -> String {
        if let name = vodStore.lastMoviesServerName {
            return "\(prefix) \(name). Tap the retry button to try again."
        }
        return "Tap the retry button to try again."
    }
}

// MARK: - VOD Poster Card
struct VODPosterCard: View {
    @Environment(\.astralTextScale) private var textScale
    let item: VODDisplayItem
    var headers: [String: String] = [:]
    /// TMDB art first when the cache has it (key set), provider poster
    /// otherwise. The card observes the cache so art lands as the
    /// background pass resolves titles.
    @ObservedObject private var art = TMDBArtCache.shared
    private var posterURL: URL? { art.posterURL(for: item) ?? item.posterURL }


    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Poster image, uses authenticated fetch so Dispatcharr /media/ images load correctly
            // The 2:3 box is the SIZE ANCHOR and never changes: the image is
            // an overlay on it. With the image as the cell's only child, the
            // placeholder colour had no height until the art arrived and the
            // grid reflowed under the finger as posters loaded (Logan
            // 2026-09-09). Spinner only while there is no art URL at all; an
            // animating ProgressView under every poster invalidated layout.
            Rectangle()
                .fill(Color.cardBackground)
                .aspectRatio(2/3, contentMode: .fit)
                .overlay {
                    if posterURL != nil {
                        AuthPosterImage(url: posterURL, headers: headers)
                            .aspectRatio(2/3, contentMode: .fill)
                    } else {
                        ProgressView().tint(.textTertiary).scaleEffect(0.8)
                    }
                }
                .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if !item.rating.isEmpty {
                    Text(item.rating)
                        .scaledFont(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(Color.black.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(4)
                }
            }

            // Text footer, fixed height so every card in the grid row is the same total
            // height regardless of title length or whether a year is present.
            // tvOS centres the title and year under the poster, like the
            // cast cards (Logan 2026-09-05); iOS keeps leading.
            VStack(alignment: textAlignment, spacing: 2) {
                // Title: reserves exactly 2-line height via a fixed frame so all cards
                // in the same grid row align regardless of actual title length.
                Text(item.displayName)
                    .scaledFont(.labelSmall)
                    .foregroundColor(.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(textAlignment == .center ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: textAlignment == .center ? .top : .topLeading)
                    .frame(height: TextScale.grow(32, textScale)) // 2 lines at labelSmall on iOS, grows with Text Size

                // Year: always rendered (non-breaking space when absent) so every
                // card reserves the same vertical space for this line.
                Text(item.releaseYear.isEmpty ? "\u{00A0}" : item.releaseYear)
                    .scaledFont(.system(size: 10).subtext())
                    .foregroundColor(item.releaseYear.isEmpty ? .clear : Color.contrastText(.textTertiary))
            }
            .padding(.bottom, 4)
        }
    }

    // Title and year centered under the poster on every platform (Logan
    // 2026-09-10; tvOS had it since 2026-09-05).
    private var textAlignment: HorizontalAlignment { .center }
}

// TVCategoryPill is defined in Components.swift

// MARK: - Movies tab redesign: sort order

enum MoviesSortOrder: String, CaseIterable {
    case titleAZ, titleZA, yearNewest, yearOldest, ratingHigh, recentlyAdded

    var label: String {
        switch self {
        case .titleAZ:       return "Title · A to Z"
        case .titleZA:       return "Title · Z to A"
        case .yearNewest:    return "Year · Newest"
        case .yearOldest:    return "Year · Oldest"
        case .ratingHigh:    return "Rating · Highest"
        case .recentlyAdded: return "Recently Added"
        }
    }
}

// MARK: - Movies tab redesign: hero

/// Continue Watching title at the top of the Movies tab: backdrop (poster
/// when the source has no backdrop), title, metadata line, plot, and the
/// action row.
/// One hero page: a title plus its resume row when it is in progress.
struct MoviesHeroPage: Identifiable {
    let item: VODDisplayItem
    let progress: WatchProgress?
    /// TMDB landscape art fetched by the owner when the row has none.
    var backdropOverride: URL? = nil
    var id: String { item.id }
}

/// Paged hero: one full-width MoviesHero per Continue Watching title. On
/// tvOS, focus moving right off a page's last button lands on the next
/// page's first button and the banner slides over; on iOS it swipes.
struct MoviesHeroCarousel: View {
    let pages: [MoviesHeroPage]
    var headers: [String: String] = [:]
    /// Owner sets true to put focus on the aligned page's Resume; reset here.
    var focusRequest: Binding<Bool> = .constant(false)
    /// tvOS: Up from a hero button while the tab bar is hidden (page
    /// scrolled). The owner snaps to the top and shows the bar; the next
    /// Up then reaches the bar normally. The focus engine found the hidden
    /// bar from Resume but not from the other buttons (Logan 2026-09-03).
    /// tvOS: set true to put focus back on the hero button that held it
    /// last (falls back to Resume).
    var restoreRequest: Binding<Bool> = .constant(false)

    /// tvOS: true while any hero button has focus (owner shows the fixed
    /// tab-bar focus guide).
    var onHeroFocusChange: ((Bool) -> Void)? = nil
    let onPrimary: (MoviesHeroPage) -> Void
    let onPlayFromStart: (MoviesHeroPage) -> Void
    let onDetails: (MoviesHeroPage) -> Void
    let onRemove: (MoviesHeroPage) -> Void
    /// Long press on the primary button: Add to / Remove from Watchlist.
    var isOnWatchlist: ((MoviesHeroPage) -> Bool)? = nil
    var onToggleWatchlist: ((MoviesHeroPage) -> Void)? = nil

    /// tvOS: focus arriving from above is forwarded to the aligned page's
    /// Resume (geometry alone landed on the page peeking in on the right).
    /// The catcher exists only while focus is outside the hero, so Up from
    /// a hero button goes straight to the tab bar.
    @State private var currentID: String?

    /// Page the dots mark. While a hero button has focus that button's page
    /// wins: the scroll view nudges to keep a focused button visible, which
    /// can flip the view-aligned position id to the neighbour while the
    /// user is still on the same card (Logan 2026-09-05, Resume to Play
    /// from Beginning on page 2).
    private var activePageID: String? {
        return currentID ?? pages.first?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            if UIDevice.current.userInterfaceIdiom == .phone {
                cardStack
            } else {
                carousel
            }
        }
    }

    /// Phone hero: the shared card deck (Logan's wife, 2026-09-05); same
    /// pages and actions as the carousel.
    private var cardStack: some View {
        PhoneCardDeck(items: pages, cardHeight: heroHeight,
                      onCurrentChange: { currentID = $0.id }) { page in
            MoviesHero(
                item: page.item,
                progress: page.progress,
                backdropOverride: page.backdropOverride,
                headers: headers,
                onPrimary: { onPrimary(page) },
                onPlayFromStart: { onPlayFromStart(page) },
                onDetails: { onDetails(page) },
                onRemove: page.progress != nil ? { onRemove(page) } : nil,
                isOnWatchlist: isOnWatchlist?(page) ?? false,
                onToggleWatchlist: onToggleWatchlist.map { toggle in { toggle(page) } },
                primaryFocusID: page.id
            )
        }
    }

    @ViewBuilder
    private func heroPage(_ page: MoviesHeroPage, width: CGFloat) -> some View {
        MoviesHero(
            item: page.item,
            progress: page.progress,
            backdropOverride: page.backdropOverride,
            headers: headers,
            onPrimary: { onPrimary(page) },
            onPlayFromStart: { onPlayFromStart(page) },
            onDetails: { onDetails(page) },
            onRemove: page.progress != nil ? { onRemove(page) } : nil,
            isOnWatchlist: isOnWatchlist?(page) ?? false,
            onToggleWatchlist: onToggleWatchlist.map { toggle in { toggle(page) } },
            primaryFocusID: page.id
        )
        .frame(width: width)
        .id(page.id)
    }

    /// Page dots centred just beneath the carousel (Logan 2026-09-05),
    /// hung off the bottom edge so the hero's height is unchanged.
    @ViewBuilder
    private var dots: some View {
        if pages.count > 1 {
            HStack(spacing: 8) {
                ForEach(pages) { page in
                    Circle()
                        .fill(page.id == activePageID
                              ? Color.accentPrimary : Color.textTertiary.opacity(0.5))
                        .frame(width: dot, height: dot)
                }
            }
            .offset(y: dotInset)
        }
    }

    private var carousel: some View {
        GeometryReader { geo in
            // Pages are narrower than the row so the next title peeks in
            // (Logan 2026-09-03). Single page keeps the full width.
            let pageWidth = pages.count > 1 ? geo.size.width * pageFraction : geo.size.width
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: pageSpacing) {
                    ForEach(pages) { page in heroPage(page, width: pageWidth) }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $currentID)
            .scrollClipDisabled()
            .overlay(alignment: .bottom) { dots }
        }
        .frame(height: heroHeight)
        // Room for the dots hung below the card; without it they sat on
        // the next section's header (screenshot 2026-09-05 16:27).
        .padding(.bottom, 24)
    }

    private let heroHeight: CGFloat = 220
    private let dot: CGFloat = 6
    private let dotInset: CGFloat = 28
    /// Narrower page so the next title peeks in (Logan 2026-09-05).
    private let pageFraction: CGFloat = 0.78
    private let pageSpacing: CGFloat = 8
}

struct MoviesHero: View {
    /// Settings > Appearance > Text Size: the hero keeps its fixed height
    /// (focus and scroll thresholds depend on it), so copy sheds lines instead.
    @Environment(\.astralTextScale) private var textScale
    @Environment(\.astralSubtextScale) private var subtextScale
    let item: VODDisplayItem
    let progress: WatchProgress?
    var backdropOverride: URL? = nil
    var headers: [String: String] = [:]
    /// TMDB synopsis first when cached (Logan 2026-09-04: the provider's
    /// plot arrived in Polish), provider plot otherwise.
    @ObservedObject private var art = TMDBArtCache.shared
    let onPrimary: () -> Void
    let onPlayFromStart: () -> Void
    let onDetails: () -> Void
    /// Long press on Resume: Remove from Continue Watching. nil when the
    /// page is not a resume row.
    var onRemove: (() -> Void)? = nil
    var isOnWatchlist: Bool = false
    var onToggleWatchlist: (() -> Void)? = nil
    /// The hero menu behind the right-most options circle (Logan 2026-09-10, all platforms).
    @State private var showOptions = false
    /// Pixel size of the loaded hero art; nil until it lands. Decides
    /// whether the art fills the wide slot or gets a poster-shaped one.
    @State private var artPixelSize: CGSize? = nil
    /// tvOS: base id the carousel uses to focus this page's buttons
    /// ("<id>|primary", "<id>|start", "<id>|details").
    var primaryFocusID: String? = nil

    private var metaParts: [String] {
        var parts: [String] = []
        if !item.releaseYear.isEmpty { parts.append(item.releaseYear) }
        // Episode rows lead with where the viewer is in the show.
        if let p = progress, p.seasonNumber > 0 {
            parts.append("S\(p.seasonNumber) E\(p.episodeNumber)")
        }
        let d = item.durationText
        if !d.isEmpty { parts.append(d) }
        if let g = item.genreText.components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespaces), !g.isEmpty { parts.append(g) }
        return parts
    }

    private var remainingLabel: String? {
        guard let p = progress, p.durationMs > 0 else { return nil }
        let leftMin = max(0, Int((p.durationMs - p.positionMs) / 60_000))
        if leftMin >= 60 { return "\(leftMin / 60) h \(leftMin % 60) min left" }
        return "\(leftMin) min left"
    }

    private var fraction: Double {
        guard let p = progress, p.durationMs > 0 else { return 0 }
        return Double(p.positionMs) / Double(p.durationMs)
    }

    /// TMDB art first when a key is set, then the provider's (Logan
    /// 2026-09-04), then the poster.
    private var artworkURL: URL? { backdropOverride ?? item.backdropURL ?? item.posterURL }

    private let heroHeight: CGFloat = 220
    private let corner: CGFloat = 16

    var body: some View {
        ZStack(alignment: .leading) {
            // Opaque base: portrait art sits at the trailing edge and the
            // placeholder is clear, so without it the card behind in the
            // phone deck showed its title and buttons through this one.
            Color.appBackground
            artwork
            gradient
            copy
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        // On the phone the card deck places the card (its front edge lines
        // up with the library grid, Logan 2026-09-09); iPad's carousel keeps
        // the 16 pt inset.
        .padding(.horizontal, UIDevice.current.userInterfaceIdiom == .phone ? 0 : 16)
    }

    /// The hero art slot.
    ///
    /// A LANDSCAPE image (a real backdrop) fills the full-width slot: aspect
    /// fill scales it to the hero's height and only the sides are trimmed.
    /// A PORTRAIT image (the poster fallback, used when neither TMDB nor the
    /// provider has a backdrop) used to go through the same aspect fill,
    /// which blew a 2:3 poster up to the hero's WIDTH and cropped away
    /// everything but a band across the middle (Logan 2026-09-14: "a huge
    /// crop showing only torsos"). Portrait art now keeps the hero's HEIGHT,
    /// takes its width from its own aspect and sits at the trailing edge,
    /// drawn whole, with the copy column beside it (same treatment as the
    /// Live TV preview banner, b2fc738).
    @ViewBuilder
    private var artwork: some View {
        GeometryReader { geo in
            if let url = artworkURL {
                let image = AuthPosterImage(url: url,
                                            headers: headers,
                                            onImageLoaded: { size in
                                                if artPixelSize != size { artPixelSize = size }
                                            },
                                            placeholder: .clear,
                                            maxPixel: 1920)
                    .id(url)
                if let width = portraitArtWidth {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        image
                            .aspectRatio(contentMode: .fit)
                            .frame(width: width, height: geo.size.height)
                            .clipped()
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    image
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            } else {
                Color.clear
            }
        }
    }

    /// Width of the poster-shaped slot when the loaded art is portrait;
    /// nil for landscape art, which keeps the full-width
    /// slot. Unknown until the bitmap lands, so the first pass draws the
    /// landscape slot and swaps once measured.
    private var portraitArtWidth: CGFloat? {
        guard let s = artPixelSize, s.width > 0, s.height > 0 else { return nil }
        let ratio = s.width / s.height
        // Only TRUE portrait (under 0.8, same cutoff as the Live TV preview
        // banner) gets the poster slot; near-square art keeps the fill slot.
        guard ratio < GuidePreviewPortraitArt.maxAspect else { return nil }
        return max(80, (heroHeight * ratio).rounded())
    }


    private var gradient: some View {
        LinearGradient(
            stops: [
                .init(color: Color.appBackground.opacity(0.05), location: 0),
                .init(color: Color.appBackground.opacity(0.92), location: 1)
            ],
            startPoint: .top, endPoint: .bottom)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: copySpacing) {
            // No eyebrow (Logan 2026-09-03): the carousel is Continue
            // Watching, the label was redundant.
            Text(item.displayName)
                .scaledFont(titleFont)
                .foregroundColor(.textPrimary)
                .lineLimit(textScale > 1.1 ? 1 : 2)
            if !metaParts.isEmpty || !item.rating.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(metaParts.enumerated()), id: \.offset) { idx, part in
                        if idx > 0 { Text("·").foregroundColor(Color.contrastText(.textTertiary)) }
                        Text(part)
                    }
                    if !item.rating.isEmpty {
                        if !metaParts.isEmpty { Text("·").foregroundColor(Color.contrastText(.textTertiary)) }
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill").scaledFont(.system(size: metaSize - 4))
                            Text(item.rating)
                        }
                        .foregroundColor(.accentPrimary)
                    }
                }
                .scaledFont(.system(size: metaSize, weight: .medium).subtext())
                .foregroundColor(Color.contrastText(.textSecondary))
                // One line on the phone card; a long genre list wrapped to three.
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
            actions
        }
        .padding(copyInset)
        // A portrait poster owns the trailing edge of the slot: the copy
        // column stops short of it instead of running underneath.
        .padding(.trailing, portraitArtWidth ?? 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var hasOptions: Bool { onToggleWatchlist != nil || onRemove != nil }

    private var actions: some View {
        HStack(spacing: 12) {
            primaryButton
            if progress != nil {
                MoviesHeroButton(title: "", systemImage: "gobackward",
                                 isPrimary: false, action: onPlayFromStart)
            }
            MoviesHeroButton(title: "", systemImage: "info.circle",
                             isPrimary: false, action: onDetails)
            if hasOptions {
                MoviesHeroButton(title: "", systemImage: "ellipsis",
                                 isPrimary: false, action: { showOptions = true })
            }
            if let remainingLabel {
                Text(remainingLabel)
                    .scaledFont(.labelSmall.subtext())
                    .foregroundColor(Color.contrastText(.textSecondary))
            }
        }
        .padding(.top, 4)
        // The menu that used to sit behind a long press on Resume.
        .confirmationDialog("Options", isPresented: $showOptions, titleVisibility: .hidden) {
            if let onToggleWatchlist {
                Button(action: onToggleWatchlist) {
                    Label(isOnWatchlist ? "Remove from Watchlist" : "Add to Watchlist",
                          systemImage: isOnWatchlist ? "bookmark.slash" : "bookmark")
                }
            }
            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove from Continue Watching", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        heroFocusable(MoviesHeroButton(
            title: progress != nil ? "Resume" : "Play",
            systemImage: "play.fill", isPrimary: true, action: onPrimary), role: "primary")
    }

    /// tvOS: binds a hero button to the carousel's focus state under
    /// "<page id>|<role>" so the carousel knows when ANY hero button has
    /// focus (its Up catcher must not exist then; tracking only Resume
    /// left Up from Details bouncing back to Resume, Logan 2026-09-03).
    @ViewBuilder
    private func heroFocusable<V: View>(_ view: V, role: String) -> some View {
        view
    }

    private let copySpacing: CGFloat = 6
    private let copyInset: CGFloat = 16
    private let eyebrowSize: CGFloat = 11
    private let metaSize: CGFloat = 13
    private var titleFont: AstralFont { .displayMedium }
}

/// Hero action: accent-filled primary, elevated secondary. tvOS focus is a
/// white ring on the primary (an accent ring would vanish on the accent
/// fill) and the usual accent ring on secondaries.
struct MoviesHeroButton: View {
    let title: String
    let systemImage: String
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .scaledFont(.system(size: iconSize, weight: .semibold))
                if !title.isEmpty {
                    Text(title)
                        .scaledFont(.system(size: textSize, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .foregroundColor(isPrimary ? .appBackground : .textPrimary)
            .padding(.horizontal, title.isEmpty ? 0 : hPad)
            .frame(width: title.isEmpty ? height : nil, height: height)
            // Pills, like the rest of the app (Logan 2026-09-05).
            .background(
                Capsule()
                    .fill(isPrimary ? Color.accentPrimary : Color.elevatedBackground)
            )
        }
        .buttonStyle(MoviesHeroButtonStyle(isPrimary: isPrimary))
    }

    private let iconSize: CGFloat = 15
    private let textSize: CGFloat = 15
    private let hPad: CGFloat = 18
    private let height: CGFloat = 40
}

private struct MoviesHeroButtonStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

// MARK: - Filter page (Providers + Groups)


/// tvOS action-sheet row look: translucent capsule at rest, white with
/// accent text when focused; a selected tab is accent-filled.
private struct NativeSheetRowStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isFocused ? .accentPrimary : (isSelected ? .appBackground : .accentPrimary))
            .padding(.horizontal, 22)
            .frame(minHeight: 66)
            .background(
                Capsule().fill(isFocused ? Color.white
                               : (isSelected ? Color.accentPrimary : Color.white.opacity(0.10)))
            )
            .scaleEffect(isFocused ? 1.03 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

private extension View {
    /// Liquid Glass panel on tvOS 26+, material fallback before that.
    @ViewBuilder
    func glassPanel() -> some View {
        if #available(iOS 26, tvOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: 36))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
        }
    }
}

// MARK: - Movies tab redesign: alphabet rail

/// # then A to Z down the leading edge. Letters with no titles are dimmed
/// and inert. On tvOS a letter jumps as soon as it takes focus (and on
/// click); on iOS a tap jumps.
struct AlphabetRail: View {
    let available: Set<String>
    /// Set by the owner to move focus onto a letter (tvOS); cleared here.
    var focusRequest: Binding<String?> = .constant(nil)
    var onFocusChange: ((Bool) -> Void)? = nil
    /// tvOS: Right on a letter leaves the rail (the owner puts focus back
    /// on the grid). Moves are handled here because the focus engine did
    /// not cross between the rail and the scroll content on its own.
    var onExitRight: (() -> Void)? = nil
    /// tvOS: Up from # leaves the rail upward (owner focuses the hero).
    var onExitUp: (() -> Void)? = nil
    let onSelect: (String) -> Void

    nonisolated static let letters: [String] = ["#"] + (65...90).map { String(UnicodeScalar($0)!) }

    /// Full column height (27 cells), for centering the parked rail.
    static var totalHeight: CGFloat {
        return 27 * 21
    }

    /// Rail bucket for a title: its first letter, folded to A to Z, or #
    /// for anything else (digits, symbols, leading articles kept as-is).
    nonisolated static func bucket(for name: String) -> String {
        guard let first = stripQualityPrefix(name).first else { return "#" }
        let folded = String(first).folding(options: .diacriticInsensitive, locale: nil).uppercased()
        guard let c = folded.first, c.isLetter, c.isASCII else { return "#" }
        return String(c)
    }

    /// Provider quality tags in front of the real title ("4K: Thor",
    /// "[HD] Alien", "UHD - Dune", "FHD | Heat") are dropped so the rail
    /// buckets on the title itself (Logan 2026-09-03).
    nonisolated static func stripQualityPrefix(_ name: String) -> Substring {
        var s = Substring(name.trimmingCharacters(in: .whitespaces))
        while true {
            var t = s
            if t.first == "[" || t.first == "(" { t = t.dropFirst() }
            guard let tag = ["UHD", "FHD", "4K", "HD", "SD"].first(where: {
                t.uppercased().hasPrefix($0)
            }) else { break }
            t = t.dropFirst(tag.count)
            if t.first == "]" || t.first == ")" { t = t.dropFirst() }
            // Require a separator (or space) after the tag so "Hidden" is
            // not mistaken for an HD tag.
            guard let sep = t.first, sep == ":" || sep == "-" || sep == "|" || sep == " " else { break }
            while let c = t.first, c == ":" || c == "-" || c == "|" || c == " " { t = t.dropFirst() }
            guard !t.isEmpty, t != s else { break }
            s = t
        }
        return s
    }


    /// Letter under the last touch, so a slide only fires on a change.
    @State private var touchedLetter: String?

    var body: some View {
        // Phone: the whole column is one touch surface, like the Contacts
        // index. Tap or slide anywhere across the rail's width and the
        // letter at that height is chosen; a per-letter Button left the
        // gaps and the lane beside the glyphs to the poster grid beneath
        // (Logan 2026-09-05, "tapped M and ended up in a movie").
        VStack(spacing: spacing) {
            ForEach(Self.letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))  // index rail: fixed-height control, not scaled
                    .foregroundColor(letterColor(letter, enabled: available.contains(letter)))
                    .frame(width: cell, height: cell)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { choose(at: $0.location.y) }
                .onEnded { _ in touchedLetter = nil }
        )
    }

    private func choose(at y: CGFloat) {
        let pitch = cell + spacing
        let index = min(Self.letters.count - 1, max(0, Int(y / pitch)))
        let letter = Self.letters[index]
        guard letter != touchedLetter else { return }
        touchedLetter = letter
        let target = nearestAvailable(to: letter)
        debugLog("[RAIL] touch \(letter) -> \(target ?? "none")")
        if let target { onSelect(target) }
    }

    /// The letter itself when it has titles, else the closest one after
    /// it, else the closest one before it.
    private func nearestAvailable(to letter: String) -> String? {
        if available.contains(letter) { return letter }
        guard let idx = Self.letters.firstIndex(of: letter) else { return nil }
        if let after = Self.letters[idx...].first(where: { available.contains($0) }) { return after }
        return Self.letters[..<idx].last(where: { available.contains($0) })
    }

    private func letterColor(_ letter: String, enabled: Bool) -> Color {
        return enabled ? .textSecondary : .textTertiary.opacity(0.35)
    }

    // Condensed (Logan 2026-09-03): 27 cells at these sizes run ~700pt on
    // TV and ~400pt on phone, so the whole column fits with room to spare.
    // Phone: taller cells make the letters easier to hit (Logan 2026-09-05).
    private let spacing: CGFloat = 0
    private let fontSize: CGFloat = 12
    private let cell: CGFloat = 21
    private let leadingInset: CGFloat = 6
}


extension Notification.Name {
    /// A tab handled Menu itself and found nothing to do; MainTabView runs
    /// its normal Menu routing (switch to Live TV, etc.).
    static let astralTabMenuPassthrough = Notification.Name("astralTabMenuPassthrough")
    /// MainTabView got Menu while the current tab had scrolled its bar
    /// away: the tab scrolls back to the top and shows the bar.
    static let astralTabScrollToTop = Notification.Name("astralTabScrollToTop")
    /// iPhone/iPad: the user tapped the tab they are already on. The tab
    /// brings itself home: a pushed page pops first, otherwise its main
    /// scroll container animates to the top and the floating bar re-expands.
    /// userInfo["tab"] is the AppTab rawValue, so a tab only reacts to its
    /// own re-tap. Posted once per tap (never during a scroll) by
    /// MainTabView's selection binding.
    static let astralTabReselected = Notification.Name("astralTabReselected")
    /// tvOS: Down from the nav circles on Live TV; the tab focuses its entry
    /// point (Channel Preview description or the first channel).
    static let astralLiveTVEntryFromTop = Notification.Name("astralLiveTVEntryFromTop")
}





/// Applies the phone rail's park offset and fade. The ONLY observer of the
/// rail state, so a show/hide flip re-renders this modifier's content and
/// not the tab.

/// Applies Settings > Movies & TV Shows > Display Scale (`uiScale`,
/// 0.85 to 1.5) to a Movies or TV Shows page by multiplying the inherited
/// `astralTextScale`, mirroring Android's `WithDisplayScale` (fontScale x scale).
struct VODDisplayScale: ViewModifier {
    @AppStorage("uiScale") private var uiScale: Double = 1.0
    @Environment(\.astralTextScale) private var textScale

    func body(content: Content) -> some View {
        let clamped = CGFloat(max(0.85, min(1.5, uiScale)))
        content.environment(\.astralTextScale, textScale * clamped)
    }
}
