import CloudCore
import MediaCache
import Persistence
import SwiftUI

/// Search: a large title, Recents (past searches,
/// Recently Viewed, Recently Shared) with Clear, suggestion chips above a glass
/// search field at the bottom, and ✕ to close. Results come from the metadata on
/// this phone at once (offline too), then from the server's smart search (by what's in the
/// photo) and face recognition, when the server has machine learning.
///
/// Filter chips above the field narrow it to the Library, Archive or Hidden album (which has to
/// be unlocked), photos or videos, or one album, and choose what the text matches: everything,
/// the file name, or text in the photo (the server's OCR).
struct SearchScreen: View {
    let session: LibrarySession
    @Bindable var ui: LibraryUIState
    @State private var text = ""
    @State private var filters = SearchFilters()
    @State private var results: [TimelineItem] = []
    /// Matches from the server (by meaning, file name or text in the photo), after the local ones.
    @State private var serverResults: [TimelineItem] = []
    @State private var isServerSearching = false
    /// Why the server couldn't search (offline, text recognition off, Hidden locked).
    @State private var serverMessage: String?
    /// A short note above the chips (e.g. the Hidden album couldn't be unlocked).
    @State private var notice: String?
    @State private var people: [CloudPerson] = []
    /// The user's albums and those shared with them; nil until loaded (or offline).
    @State private var albums: [CloudAlbum]?
    @State private var albumCache: [AlbumKey: [TimelineItem]] = [:]
    @State private var searchedKey: SearchKey?
    @State private var suggestions: [String] = []
    @State private var recentQueries = SearchHistory.queries
    @State private var viewed = SearchHistory.viewed
    @State private var shared = SearchHistory.shared
    @State private var path = NavigationPath()
    @State private var columns = 3
    @FocusState private var fieldFocused: Bool
    @State private var keyboard = KeyboardObserver()

    private enum Route: Hashable {
        case viewed, shared
        case person(CloudPerson)
    }

    /// What a search ran for: a change to either runs it again.
    private struct SearchKey: Hashable {
        var text: String
        var filters: SearchFilters
    }

    private struct AlbumKey: Hashable {
        var albumID: String
        var visibility: CloudVisibility
        var isVideo: Bool?
    }

    /// Height of the chips, the field and the space around them, kept clear under the content.
    private let barHeight: CGFloat = 36 + 8 + 50 + 8

    private var trimmedText: String { text.trimmingCharacters(in: .whitespaces) }

    /// Results, rather than Home: something typed, or a filter that lists on its own. Always in
    /// Hidden: Home's People and Recents lead to screens that would show Hidden items while it's
    /// unlocked.
    private var showsResults: Bool { !trimmedText.isEmpty || filters.listsWithoutText || filters.scope == .hidden }

    /// Local matches first, then the server's not already among them.
    private var combinedResults: [TimelineItem] {
        let ids = Set(results.map(\.id))
        return results + serverResults.filter { !ids.contains($0.id) }
    }

    /// Not in Hidden: a person's page lists their photos from the server, Hidden ones included
    /// while the Hidden album is unlocked.
    private var matchingPeople: [CloudPerson] {
        guard filters.field == .anything, filters.scope != .hidden else { return [] }
        let query = trimmedText.lowercased()
        guard query.count >= 2 else { return [] }
        return people.filter { !$0.name.isEmpty && $0.name.lowercased().contains(query) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { proxy in
                let keyboardInset = max(keyboard.height - proxy.safeAreaInsets.bottom, 0)
                // The content can't push the field down: it's capped to the space above the
                // keyboard (Home scrolls), and the field is placed on its own just above the
                // keyboard. Before, Home grew taller than that space (with People) and the
                // bottom-aligned stack slid the field under the keyboard.
                // A real container, not a Group: a Group applies the modifiers below to each
                // branch, so the first letter (Home → results) rebuilt the field and dropped the keyboard.
                ZStack(alignment: .top) {
                    if showsResults {
                        resultsView
                    } else {
                        home
                    }
                }
                .padding(.bottom, keyboardInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background { Color(.systemBackground).ignoresSafeArea() }
                .overlay(alignment: .bottom) {
                    bottomBar
                        .padding(.bottom, keyboardInset)
                }
                .animation(.smooth(duration: keyboard.animationDuration), value: keyboard.height)
            }
            .ignoresSafeArea(.keyboard)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                if case .person(let person) = route {
                    PersonScreen(person: person, session: session, bottomInset: 0)
                } else {
                    let ids = route == .viewed ? viewed : shared
                    let byID = Dictionary(session.timeline.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    CollectionGridScreen(
                        title: route == .viewed ? String(localized: "Recently Viewed") : String(localized: "Recently Shared"),
                        items: ids.compactMap { byID[$0] }.reversed(), session: session, bottomInset: 0
                    )
                }
            }
        }
        .task {
            fieldFocused = true
            let places = await session.topPlaces(limit: 2)
            let year = Calendar.current.component(.year, from: .now)
            suggestions = places.map { String(localized: "\($0)") } + [String(localized: "Videos in \(String(year))"), String(localized: "Favourites")]
            people = orderedPeople((try? await session.people()) ?? [])
        }
        .task { await loadAlbums() }
        .task(id: SearchKey(text: text, filters: filters)) {
            await runSearch(SearchKey(text: text, filters: filters))
        }
        // Hidden locks when the app goes to the background: its results go with it.
        .onChange(of: session.hiddenVault.state) { _, state in
            guard state != .unlocked else { return }
            albumCache = albumCache.filter { $0.key.visibility != .locked }
            if filters.scope == .hidden {
                results = []
                serverResults = []
                filters.scope = .library
            }
        }
        // Like the Hidden album itself, leaving Search locks it again.
        .onDisappear {
            if filters.scope == .hidden { Task { await session.hiddenVault.lock() } }
        }
    }

    // MARK: Searching

    private func runSearch(_ key: SearchKey) async {
        let trimmed = key.text.trimmingCharacters(in: .whitespaces)
        let filters = key.filters
        guard !trimmed.isEmpty || filters.listsWithoutText else {
            results = []
            serverResults = []
            serverMessage = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        var albumItems: [TimelineItem]?
        var message: String?
        if let album = filters.album {
            do {
                albumItems = try await items(in: album, filters: filters)
            } catch {
                guard !Task.isCancelled else { return }
                message = Self.message(for: error)
                albumItems = []
            }
        }
        guard !Task.isCancelled else { return }
        let found: [TimelineItem]
        do {
            found = try await SearchEngine.search(trimmed, filters: filters, albumItems: albumItems, in: session)
        } catch {
            found = []
            message = Self.message(for: error)
        }
        // A newer search (or Hidden locking) has the final say.
        guard !Task.isCancelled else { return }
        results = found
        serverResults = []
        serverMessage = message
        searchedKey = key
        guard !trimmed.isEmpty, message == nil else { return }

        // Then the server, once typing pauses: by meaning (needs its machine learning), by file
        // name (partners' and shared albums' items too), or by text in the photo (only there).
        guard session.connection != nil else {
            if filters.field == .text {
                serverMessage = String(localized: "Searching text in photos needs a connection to your server.")
            }
            return
        }
        if filters.field == .anything, SearchEngine.parse(trimmed).words.isEmpty { return }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        isServerSearching = true
        defer { isServerSearching = false }
        var query = filters.cloudQuery
        do {
            let found: [TimelineItem]
            switch filters.field {
            case .anything:
                found = try await session.smartSearch(trimmed, filters: query)
            case .fileName:
                query.fileName = trimmed
                found = try await session.serverSearch(query)
            case .text:
                query.text = trimmed
                found = try await session.serverSearch(query)
            }
            guard !Task.isCancelled else { return }
            serverResults = found
        } catch {
            // Smart search is optional (the server may have no machine learning); the others aren't.
            guard !Task.isCancelled, filters.field == .text else { return }
            serverMessage = Self.message(for: error)
        }
    }

    /// The chosen album's items in the chosen part of the library, from the server (kept while Search is open).
    private func items(in album: CloudAlbum, filters: SearchFilters) async throws -> [TimelineItem] {
        let key = AlbumKey(albumID: album.id, visibility: filters.visibility, isVideo: filters.isVideo)
        if let cached = albumCache[key] { return cached }
        guard session.connection != nil else {
            throw CloudError(kind: .transport, message: String(localized: "Searching an album needs a connection to your server."))
        }
        var query = CloudSearchQuery()
        query.albumID = album.id
        query.visibility = filters.visibility
        query.isVideo = filters.isVideo
        let items = try await session.serverSearch(query, limit: 5000)
        albumCache[key] = items
        return items
    }

    private func loadAlbums() async {
        var loaded: [CloudAlbum] = []
        var failures = 0
        for shared in [false, true] {
            do { loaded += try await session.albums(shared: shared) } catch { failures += 1 }
        }
        guard failures < 2 else { return }
        var seen = Set<String>()
        albums = loaded
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func message(for error: any Error) -> String {
        (error as? CloudError)?.message ?? error.localizedDescription
    }

    /// Hidden needs the Hidden album unlocked (Face ID); the others lock it again.
    private func choose(_ scope: SearchFilters.Scope) {
        guard scope != filters.scope else { return }
        guard scope == .hidden else {
            let wasHidden = filters.scope == .hidden
            filters.scope = scope
            if wasHidden { Task { await session.hiddenVault.lock() } }
            return
        }
        let vault = session.hiddenVault
        guard vault.state != .unlocked else {
            filters.scope = .hidden
            return
        }
        guard vault.hasStoredPin else {
            notice = String(localized: "Open Hidden in Albums first to set it up on this iPhone.")
            return
        }
        Task {
            if await vault.unlock() {
                filters.scope = .hidden
            } else {
                notice = vault.errorMessage ?? String(localized: "The Hidden album is still locked.")
                await vault.lock()
            }
        }
    }

    // MARK: Home (Recents and suggestions)

    private var home: some View {
        GeometryReader { geometry in
            ScrollView {
                homeContent
                    .frame(minHeight: geometry.size.height, alignment: .top)
            }
            // With the keyboard up, the suggestions stay just above the field (People and
            // Recents scroll up out of the way).
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
        }
    }

    private var homeContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Search")
                .font(.system(size: 34, weight: .bold))
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
            if !people.isEmpty {
                Text("People")
                    .font(.system(size: 22, weight: .bold))
                    .padding(.horizontal, 18)
                    .padding(.top, 22)
                peopleStrip(people.prefix(20).map { $0 })
                    .padding(.top, 10)
            }
            if hasRecents {
                HStack {
                    Text("Recents")
                        .font(.system(size: 22, weight: .bold))
                    Spacer()
                    Button("Clear") {
                        SearchHistory.clear()
                        withAnimation {
                            recentQueries = []
                            viewed = []
                            shared = []
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(Color(.secondarySystemFill), in: Capsule())
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
                .padding(.horizontal, 18)
                .padding(.top, 26)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(recentQueries.prefix(6), id: \.self) { query in
                            Button {
                                text = query
                            } label: {
                                RecentQueryCard(query: query, session: session)
                            }
                            .buttonStyle(.plain)
                        }
                        if let item = item(for: viewed.first) {
                            NavigationLink(value: Route.viewed) {
                                RecentCard(title: String(localized: "Recently Viewed"), item: item, pipeline: session.pipeline)
                            }
                            .buttonStyle(.plain)
                        }
                        if let item = item(for: shared.first) {
                            NavigationLink(value: Route.shared) {
                                RecentCard(title: String(localized: "Recently Shared"), item: item, pipeline: session.pipeline)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
                .padding(.top, 12)
            }
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        text = suggestion
                        recordQuery(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.system(size: 17))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 22)
                            .frame(height: 44)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassSurface(Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, barHeight + 26)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Past searches in Recents, except those in the Hidden album.
    private func recordQuery(_ query: String) {
        guard filters.scope != .hidden else { return }
        SearchHistory.recordQuery(query)
        recentQueries = SearchHistory.queries
    }

    private func peopleStrip(_ people: [CloudPerson]) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(people) { person in
                    NavigationLink(value: Route.person(person)) {
                        VStack(spacing: 5) {
                            PersonFaceView(personID: person.id, session: session, size: 64)
                            Text(person.displayName)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .frame(width: 70)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    private var hasRecents: Bool {
        !recentQueries.isEmpty || item(for: viewed.first) != nil || item(for: shared.first) != nil
    }

    private func item(for id: String?) -> TimelineItem? {
        guard let id else { return nil }
        return session.timeline.items.last { $0.id == id }
    }

    // MARK: Results

    private var resultsView: some View {
        let results = combinedResults
        return VStack(alignment: .leading, spacing: 8) {
            if !matchingPeople.isEmpty {
                peopleStrip(matchingPeople)
                    .padding(.top, 12)
            }
            HStack(spacing: 8) {
                Text(results.isEmpty ? (isServerSearching ? String(localized: "Searching…") : String(localized: "No Results")) : results.count == 1 ? String(localized: "1 Result") : String(localized: "\(results.count.formatted()) Results"))
                    .font(.system(size: 22, weight: .bold))
                if isServerSearching { ProgressView() }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            if let serverMessage {
                Label(serverMessage, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
            if results.isEmpty {
                if serverMessage == nil, !isServerSearching {
                    Text(emptyHint)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                }
                Spacer()
            } else {
                PhotoGridView(
                    snapshot: TimelineSnapshot(items: results, version: (searchedKey?.hashValue ?? 0) &+ serverResults.count, isLoaded: true),
                    session: session, columns: $columns,
                    insets: UIEdgeInsets(top: 0, left: 0, bottom: barHeight + 32, right: 0)
                )
                .ignoresSafeArea(edges: .bottom)
            }
        }
    }

    private var emptyHint: String {
        switch filters.field {
        case .anything:
            String(localized: "Try a place, a month or year, “videos”, a person, or what's in the photo (“dog on a beach”).")
        case .fileName:
            String(localized: "Try part of a file name, like “IMG_2024” or “.png”.")
        case .text:
            String(localized: "Finds words the server read in your photos, like signs, receipts or screenshots. It needs text recognition (OCR) turned on in Immich's machine learning settings.")
        }
    }

    // MARK: Search field

    private var placeholder: String {
        switch filters.field {
        case .fileName: return String(localized: "File name…")
        case .text: return String(localized: "Text in photos…")
        case .anything:
            switch filters.scope {
            case .library: return String(localized: "Search your library…")
            case .archive: return String(localized: "Search the Archive…")
            case .hidden: return String(localized: "Search Hidden…")
            }
        }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice {
                Text(notice)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassSurface(Capsule(), interactive: false)
                    .padding(.horizontal, 12)
                    .transition(.opacity)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(4))
                        withAnimation { self.notice = nil }
                    }
            }
            filterBar
            searchField
        }
        .animation(.smooth, value: notice)
    }

    // MARK: Filters

    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                filterChip(filters.scope.title, symbol: filters.scope.symbol, active: filters.scope != .library, label: "Look In") {
                    Picker("Look In", selection: Binding(get: { filters.scope }, set: { choose($0) })) {
                        ForEach(SearchFilters.Scope.allCases, id: \.self) { scope in
                            Label(scope.title, systemImage: scope.symbol).tag(scope)
                        }
                    }
                }
                filterChip(filters.media.title, symbol: filters.media.symbol, active: filters.media != .all, label: "Media Type") {
                    Picker("Media Type", selection: $filters.media) {
                        ForEach(SearchFilters.Media.allCases, id: \.self) { media in
                            Label(media.title, systemImage: media.symbol).tag(media)
                        }
                    }
                }
                filterChip(filters.album?.name ?? String(localized: "Any Album"), symbol: "rectangle.stack", active: filters.album != nil, label: "Album") {
                    Picker("Album", selection: $filters.album) {
                        Text("Any Album").tag(CloudAlbum?.none)
                        if let albums {
                            ForEach(albums) { album in
                                Text(album.name).tag(CloudAlbum?.some(album))
                            }
                        }
                    }
                    if albums == nil {
                        Text("Albums need a connection to your server.")
                    }
                }
                filterChip(filters.field.title, symbol: filters.field.symbol, active: filters.field != .anything, label: "Search By") {
                    Picker("Search By", selection: $filters.field) {
                        ForEach(SearchFilters.Field.allCases, id: \.self) { field in
                            Label(field.title, systemImage: field.symbol).tag(field)
                        }
                    }
                }
                if !filters.isDefault {
                    Button {
                        choose(.library)
                        filters = SearchFilters()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassSurface(Circle())
                    .accessibilityLabel("Clear Filters")
                }
            }
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .frame(height: 36)
    }

    /// A glass chip that opens a menu of choices.
    private func filterChip<Content: View>(
        _ title: String, symbol: String, active: Bool, label: LocalizedStringKey, @ViewBuilder content: () -> Content
    ) -> some View {
        let choices = content()
        return Menu {
            choices
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .padding(.horizontal, 14)
            .frame(height: 36)
            .contentShape(Capsule())
        }
        .glassSurface(Capsule())
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(title))
    }

    private var searchField: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(placeholder, text: $text)
                        .focused($fieldFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .onSubmit { recordQuery(text) }
                    if text.isEmpty {
                        Button { fieldFocused = true } label: {
                            Image(systemName: "mic")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Dictate")
                    } else {
                        Button { text = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .accessibilityLabel("Clear Text")
                    }
                }
                .font(.system(size: 17))
                .padding(.horizontal, 16)
                .frame(height: 50)
                .glassSurface(Capsule())
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 50, height: 50)
                        // Without this the button's own frame is just the ✕ glyph (15 pt):
                        // the whole glass circle is the tap target.
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassSurface(Circle())
                .accessibilityLabel("Close Search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    /// Puts the keyboard away and closes Search through the state that opened it.
    private func close() {
        fieldFocused = false
        ui.showsSearch = false
    }
}

/// A past search, shown with its newest result.
private struct RecentQueryCard: View {
    let query: String
    let session: LibrarySession
    @State private var item: TimelineItem?

    var body: some View {
        RecentCard(title: "“\(query)”", item: item, pipeline: session.pipeline)
            .task(id: query) { item = await SearchEngine.search(query, in: session).first }
    }
}

/// A square Recents card: a photo with its title at the bottom left.
private struct RecentCard: View {
    let title: String
    let item: TimelineItem?
    let pipeline: RemoteImagePipeline

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let item {
                PipelineImage(item: item, pipeline: pipeline, pixelSize: 500)
            } else {
                Color(.secondarySystemBackground)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(12)
        }
        .frame(width: 115, height: 115)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
