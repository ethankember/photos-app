import Foundation

/// Server image sizes: a small grid tile, or a screen-sized preview.
public enum CloudImageSize: String, Sendable, CaseIterable {
    case thumbnail
    case preview
}

/// Where an asset shows up: the Library, Archive, hidden (Live Photo motion parts) or Hidden (locked).
public enum CloudVisibility: String, Sendable, Hashable {
    case timeline
    case archive
    case hidden
    case locked
}

public struct CloudAlbum: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let assetCount: Int
    public let isShared: Bool
    public var thumbnailAssetID: String?
    /// Newest change, for sorting (recently modified first).
    public var updatedAt: Date?

    public init(id: String, name: String, assetCount: Int, isShared: Bool, thumbnailAssetID: String? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.assetCount = assetCount
        self.isShared = isShared
        self.thumbnailAssetID = thumbnailAssetID
        self.updatedAt = updatedAt
    }
}

/// An asset as a server query returns it, for collections that aren't in the synced
/// library (trash, album contents, memories, search).
public struct CloudAsset: Sendable, Hashable, Identifiable {
    public let id: String
    public let localDateTime: Date
    public let isVideo: Bool
    public let durationMs: Int?
    public let isFavorite: Bool
    public let isLivePhoto: Bool
    public let thumbhash: String?
    public let width: Int?
    public let height: Int?
    public let ownerID: String
    public let uploadedAt: Date
    public let isEdited: Bool
    public let isTrashed: Bool
    /// For downloading the original under its own name (Keep Offline).
    public var originalFileName: String?
    public var livePhotoVideoID: String?
    public var checksum: String?

    public init(
        id: String, localDateTime: Date, isVideo: Bool, durationMs: Int?, isFavorite: Bool, isLivePhoto: Bool,
        thumbhash: String?, width: Int?, height: Int?, ownerID: String, uploadedAt: Date, isEdited: Bool, isTrashed: Bool,
        originalFileName: String? = nil, livePhotoVideoID: String? = nil, checksum: String? = nil
    ) {
        self.originalFileName = originalFileName
        self.livePhotoVideoID = livePhotoVideoID
        self.checksum = checksum
        self.id = id
        self.localDateTime = localDateTime
        self.isVideo = isVideo
        self.durationMs = durationMs
        self.isFavorite = isFavorite
        self.isLivePhoto = isLivePhoto
        self.thumbhash = thumbhash
        self.width = width
        self.height = height
        self.ownerID = ownerID
        self.uploadedAt = uploadedAt
        self.isEdited = isEdited
        self.isTrashed = isTrashed
    }
}

/// A memory ("On This Day" years ago), shown in Collections › Memories.
public struct CloudMemory: Sendable, Hashable, Identifiable {
    public let id: String
    public let memoryAt: Date
    /// The year the photos were taken.
    public let year: Int
    public let assets: [CloudAsset]

    public init(id: String, memoryAt: Date, year: Int, assets: [CloudAsset]) {
        self.id = id
        self.memoryAt = memoryAt
        self.year = year
        self.assets = assets
    }
}

/// What a server-side search filters on; empty fields are ignored and the rest are ANDed.
public struct CloudSearchQuery: Sendable, Hashable {
    public var albumID: String?
    public var city: String?
    public var country: String?
    public var fileName: String?
    public var description: String?
    public var make: String?
    public var model: String?
    public var takenAfter: Date?
    public var takenBefore: Date?
    public var isFavorite: Bool?
    public var isVideo: Bool?
    public var trashedOnly = false
    /// Photos with all of these people in them (face recognition).
    public var personIDs: [String] = []
    /// Only items with this visibility. Unset leaves it to the server, which includes Hidden
    /// (Locked Folder) items while its session is unlocked: searches shown to the user set it.
    public var visibility: CloudVisibility?
    /// Text recognised in the photo (the server's OCR).
    public var text: String?

    public init() {}
}

/// Where an item lives in the library.
public enum CloudVisibility: String, Sendable, Hashable, CaseIterable {
    /// The Library.
    case timeline
    case archive
    /// The Hidden album (Immich's Locked Folder; the server needs its PIN first).
    case locked
}

/// Someone recognised in photos by the server's face recognition (machine learning).
public struct CloudPerson: Sendable, Hashable, Identifiable {
    public let id: String
    /// Empty until named.
    public var name: String
    /// "yyyy-MM-dd", when set.
    public var birthDate: String?
    public var isHidden: Bool
    public var isFavorite: Bool

    public init(id: String, name: String, birthDate: String?, isHidden: Bool, isFavorite: Bool) {
        self.id = id
        self.name = name
        self.birthDate = birthDate
        self.isHidden = isHidden
        self.isFavorite = isFavorite
    }
}

/// A public link to some assets (anyone with it can view and download).
public struct CloudSharedLink: Sendable, Hashable {
    public let id: String
    public let url: URL
    public let expiresAt: Date?

    public init(id: String, url: URL, expiresAt: Date?) {
        self.id = id
        self.url = url
        self.expiresAt = expiresAt
    }
}

/// What the server counts as the main library (not archived or hidden, not trashed).
public struct CloudLibraryCounts: Sendable, Equatable {
    public let images: Int
    public let videos: Int
    public let total: Int

    public init(images: Int, videos: Int, total: Int) {
        self.images = images
        self.videos = videos
        self.total = total
    }
}

public struct CloudSignIn: Sendable, Equatable {
    public let token: String
    public let userID: String
    public let email: String
    public let name: String
    public let isAdmin: Bool

    public init(token: String, userID: String, email: String, name: String, isAdmin: Bool) {
        self.token = token
        self.userID = userID
        self.email = email
        self.name = name
        self.isAdmin = isAdmin
    }
}

/// The ways a server lets people sign in.
public struct CloudSignInOptions: Sendable, Equatable {
    /// Email and password.
    public let password: Bool
    /// Single sign-on through the server's identity provider (OAuth / OpenID Connect).
    public let singleSignOn: Bool
    /// The server's own label for the single sign-on button, when it sets one.
    public let singleSignOnTitle: String?

    public init(password: Bool, singleSignOn: Bool, singleSignOnTitle: String?) {
        self.password = password
        self.singleSignOn = singleSignOn
        self.singleSignOnTitle = singleSignOnTitle
    }
}

/// A single sign-on in progress: the identity provider's page to show in a browser sheet, and
/// what's needed to finish once it sends the browser back to `callbackScheme`.
public struct CloudSingleSignOn: Sendable, Equatable {
    /// The address the sign-in started on; it finishes there too.
    public let server: URL
    public let authorizationURL: URL
    public let callbackScheme: String
    /// OAuth `state`: the answer must carry the same value.
    public let state: String
    /// The PKCE secret behind the code challenge sent at the start.
    public let codeVerifier: String

    public init(server: URL, authorizationURL: URL, callbackScheme: String, state: String, codeVerifier: String) {
        self.server = server
        self.authorizationURL = authorizationURL
        self.callbackScheme = callbackScheme
        self.state = state
        self.codeVerifier = codeVerifier
    }
}

public struct CloudServerInfo: Sendable, Equatable {
    public let version: String
    /// Set when the server's version differs from the one the provider was built for.
    public let warning: String?

    public init(version: String, warning: String?) {
        self.version = version
        self.warning = warning
    }
}

/// The server's private area behind a PIN (shown as Hidden).
public struct CloudLockedFolderStatus: Sendable, Equatable {
    public let hasPin: Bool
    public let isUnlocked: Bool

    public init(hasPin: Bool, isUnlocked: Bool) {
        self.hasPin = hasPin
        self.isUnlocked = isUnlocked
    }
}

/// One file to upload in the foreground (Duplicate).
public struct CloudUploadFile: Sendable {
    public var fileURL: URL
    public var fileName: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var livePhotoVideoID: String?
    public var visibility: CloudVisibility?
    public var isFavorite: Bool

    public init(fileURL: URL, fileName: String, createdAt: Date, modifiedAt: Date, livePhotoVideoID: String? = nil, visibility: CloudVisibility? = nil, isFavorite: Bool = false) {
        self.fileURL = fileURL
        self.fileName = fileName
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.livePhotoVideoID = livePhotoVideoID
        self.visibility = visibility
        self.isFavorite = isFavorite
    }
}

public struct CloudUploadResult: Sendable, Equatable {
    public let assetID: String
    /// False when the server already had this exact file (same checksum).
    public let created: Bool

    public init(assetID: String, created: Bool) {
        self.assetID = assetID
        self.created = created
    }
}

/// The answer to "do you already have this file?" (by checksum), per item.
public struct CloudExistingAsset: Sendable, Equatable {
    /// The caller's id for the item (e.g. the phone's local identifier).
    public let itemID: String
    /// The server's asset with that checksum, if any.
    public let assetID: String?
    public let isTrashed: Bool

    public init(itemID: String, assetID: String?, isTrashed: Bool) {
        self.itemID = itemID
        self.assetID = assetID
        self.isTrashed = isTrashed
    }

    public var exists: Bool { assetID != nil }
}

/// Someone with an account on the same server.
public struct CloudUser: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let email: String

    public init(id: String, name: String, email: String) {
        self.id = id
        self.name = name
        self.email = email
    }
}
