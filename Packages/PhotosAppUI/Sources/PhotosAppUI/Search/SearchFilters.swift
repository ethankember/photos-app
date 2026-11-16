import CloudCore
import SwiftUI

/// What Search looks in and how it matches, besides the typed text.
struct SearchFilters: Hashable {
    enum Scope: Hashable, CaseIterable {
        case library, archive, hidden
    }

    enum Media: Hashable, CaseIterable {
        case all, photos, videos
    }

    /// What the typed text is matched against.
    enum Field: Hashable, CaseIterable {
        /// Places, captions, file names and cameras on this phone, then what's in the photo
        /// (the server's smart search).
        case anything
        case fileName
        /// Text recognised in the photo (the server's OCR).
        case text
    }

    var scope = Scope.library
    var media = Media.all
    var album: CloudAlbum?
    var field = Field.anything

    var isDefault: Bool { self == SearchFilters() }

    /// Shows results before anything is typed: browsing the Archive, Hidden, an album, or only
    /// photos or videos.
    var listsWithoutText: Bool {
        field == .anything && (scope != .library || media != .all || album != nil)
    }

    var visibility: CloudVisibility {
        switch scope {
        case .library: .timeline
        case .archive: .archive
        case .hidden: .locked
        }
    }

    var isVideo: Bool? {
        switch media {
        case .all: nil
        case .photos: false
        case .videos: true
        }
    }

    /// The server query for these filters. The visibility is always set: left out, the server
    /// would include Hidden items whenever the Hidden album is unlocked.
    var cloudQuery: CloudSearchQuery {
        var query = CloudSearchQuery()
        query.albumID = album?.id
        query.isVideo = isVideo
        query.visibility = visibility
        return query
    }
}

extension SearchFilters.Scope {
    var title: String {
        switch self {
        case .library: String(localized: "Library")
        case .archive: String(localized: "Archive")
        case .hidden: String(localized: "Hidden")
        }
    }

    var symbol: String {
        switch self {
        case .library: "photo.on.rectangle"
        case .archive: "archivebox"
        case .hidden: "eye.slash"
        }
    }
}

extension SearchFilters.Media {
    var title: String {
        switch self {
        case .all: String(localized: "Photos & Videos")
        case .photos: String(localized: "Photos")
        case .videos: String(localized: "Videos")
        }
    }

    var symbol: String {
        switch self {
        case .all: "photo.stack"
        case .photos: "photo"
        case .videos: "video"
        }
    }
}

extension SearchFilters.Field {
    var title: String {
        switch self {
        case .anything: String(localized: "Everything")
        case .fileName: String(localized: "File Name")
        case .text: String(localized: "Text in Photo")
        }
    }

    var symbol: String {
        switch self {
        case .anything: "magnifyingglass"
        case .fileName: "doc"
        case .text: "text.viewfinder"
        }
    }
}
