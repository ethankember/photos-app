import Foundation
import Persistence

/// Turns a typed search into filters: years, months and seasons, media words
/// ("videos", "favourites", "screenshots", "live photos") and free text, which is
/// matched against places, captions, file names and cameras on this phone.
enum SearchEngine {
    struct Query: Equatable {
        var years: Set<Int> = []
        var months: Set<Int> = []
        var videos = false
        var photos = false
        var favourites = false
        var screenshots = false
        var livePhotos = false
        var words: [String] = []

        var hasStructure: Bool { !years.isEmpty || !months.isEmpty || videos || photos || favourites || screenshots || livePhotos }
    }

    private static let stopWords: Set<String> = ["in", "the", "of", "from", "at", "on", "and", "my", "a", "an", "with"]

    static func parse(_ text: String) -> Query {
        var query = Query()
        let monthNames = monthLookup()
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            defer { index += 1 }
            if let year = Int(token), (1900...2100).contains(year) {
                query.years.insert(year)
            } else if let month = monthNames[token] {
                query.months.insert(month)
            } else if let season = season(token) {
                query.months.formUnion(season)
            } else if ["video", "videos"].contains(token) {
                query.videos = true
            } else if ["photo", "photos", "picture", "pictures", "image", "images"].contains(token) {
                query.photos = true
            } else if ["favourite", "favourites", "favorite", "favorites"].contains(token) {
                query.favourites = true
            } else if ["screenshot", "screenshots"].contains(token) {
                query.screenshots = true
            } else if token == "live", index + 1 < tokens.count, ["photo", "photos"].contains(tokens[index + 1]) {
                query.livePhotos = true
                index += 1
            } else if !stopWords.contains(token) {
                query.words.append(token)
            }
        }
        return query
    }

    /// Matching Library items, newest first (Recents' cards).
    @MainActor
    static func search(_ text: String, in session: LibrarySession) async -> [TimelineItem] {
        (try? await search(text, filters: SearchFilters(), albumItems: nil, in: session)) ?? []
    }

    /// Matches on this phone, newest first, within `filters`. `albumItems`: the chosen album's
    /// items (from the server, newest first) when an album is chosen. Text in photos is only on
    /// the server, so that search has no matches here. Throws for Hidden while it's locked.
    @MainActor
    static func search(_ text: String, filters: SearchFilters, albumItems: [TimelineItem]?, in session: LibrarySession) async throws -> [TimelineItem] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let query: Query
        var candidates: [TimelineItem]
        switch filters.field {
        case .text:
            try session.requireSearchable(filters.visibility)
            return []
        case .fileName:
            // As typed: a file name like "IMG_2024" isn't a year.
            guard !trimmed.isEmpty else { return [] }
            query = Query()
            candidates = try await session.search(trimmed, in: filters.visibility, fileNameOnly: true)
        case .anything:
            query = parse(trimmed)
            if query.words.isEmpty {
                guard query.hasStructure || filters.listsWithoutText else {
                    try session.requireSearchable(filters.visibility)
                    return []
                }
                if let albumItems {
                    candidates = albumItems
                } else {
                    candidates = try await session.items(in: filters.visibility).reversed()
                }
            } else {
                candidates = try await session.search(query.words.joined(separator: " "), in: filters.visibility)
            }
        }
        let inAlbum = albumItems.map { Set($0.map(\.id)) }
        let calendar = Formatting.wallClock
        return candidates.filter { item in
            if let inAlbum, !inAlbum.contains(item.id) { return false }
            if filters.media == .videos && !item.isVideo { return false }
            if filters.media == .photos && item.isVideo { return false }
            if query.videos && !item.isVideo { return false }
            if query.photos && item.isVideo { return false }
            if query.favourites && !item.isFavorite { return false }
            if query.screenshots && !item.isScreenshot { return false }
            if query.livePhotos && !item.isLivePhoto { return false }
            if !query.years.isEmpty || !query.months.isEmpty {
                let parts = calendar.dateComponents([.year, .month], from: item.date)
                if !query.years.isEmpty && !query.years.contains(parts.year ?? 0) { return false }
                if !query.months.isEmpty && !query.months.contains(parts.month ?? 0) { return false }
            }
            return true
        }
    }

    /// Month names and short names in English and the current language.
    private static func monthLookup() -> [String: Int] {
        var lookup: [String: Int] = [:]
        for identifier in ["en_GB", Locale.current.identifier] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: identifier)
            for (index, name) in (formatter.monthSymbols ?? []).enumerated() { lookup[name.lowercased()] = index + 1 }
            for (index, name) in (formatter.shortMonthSymbols ?? []).enumerated() { lookup[name.lowercased().trimmingCharacters(in: .punctuationCharacters)] = index + 1 }
        }
        return lookup
    }

    /// Northern-hemisphere seasons (India's monsoon too).
    private static func season(_ word: String) -> Set<Int>? {
        switch word {
        case "spring": [3, 4, 5]
        case "summer": [6, 7, 8]
        case "autumn", "fall": [9, 10, 11]
        case "winter": [12, 1, 2]
        case "monsoon": [6, 7, 8, 9]
        default: nil
        }
    }
}
