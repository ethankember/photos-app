import Core
import Foundation
import GRDB
import CloudCore
import Persistence
import UIKit

/// What Collections and Search read: other scopes of the synced library, server
/// collections (albums, memories, trash search) and the profile picture.
extension LibrarySession {
    func observe(_ scope: TimelineScope) -> AsyncValueObservation<[TimelineItem]> {
        TimelineQuery.observeRemote(ownerID: account.userID, scope: scope, in: database)
    }

    // MARK: Recently Deleted

    func trashDates() async -> [String: Date] {
        let ownerID = account.userID
        return (try? await database.reader.read { db in try TimelineQuery.trashDates(ownerID: ownerID, in: db) }) ?? [:]
    }

    /// Days the server keeps deleted items (remembered, 30 until known).
    var trashRetentionDays: Int {
        let days = UserDefaults.standard.integer(forKey: "server.trashDays")
        return days > 0 ? days : 30
    }

    func refreshTrashRetentionDays() async {
        guard let days = try? await connection?.trashRetentionDays(), days > 0 else { return }
        UserDefaults.standard.set(days, forKey: "server.trashDays")
    }

    // MARK: People and smart search (the server's machine learning)

    func people() async throws -> [CloudPerson] {
        try await connected().people()
    }

    func people(inAsset assetID: String) async throws -> [CloudPerson] {
        try await connected().people(inAsset: assetID)
    }

    func updatePerson(id: String, name: String?, birthDate: String?) async throws -> CloudPerson {
        try await connected().updatePerson(id: id, name: name, birthDate: birthDate)
    }

    /// A person's photos in the Library, and in the Archive or the Hidden album when asked
    /// (Hidden must be unlocked), oldest first like the Library grid. Each part is asked for by
    /// name: left out, the server would add Hidden photos whenever the Hidden album is unlocked.
    func personItems(_ personID: String, in visibilities: [CloudVisibility] = [.timeline]) async throws -> [TimelineItem] {
        for visibility in visibilities { try requireSearchable(visibility) }
        let connection = try connected()
        var lists: [[TimelineItem]] = []
        for visibility in visibilities {
            var query = CloudSearchQuery()
            query.personIDs = [personID]
            query.visibility = visibility
            lists.append(try await connection.search(query, limit: 5000).map(TimelineItem.init))
        }
        return TimelineItem.mergedOldestFirst(lists)
    }

    /// The people in one part of the library: the Library's from `/people`; the Archive's and the
    /// Hidden album's (unlocked) from their photos, since `/people` only counts the Library.
    func people(in visibility: CloudVisibility) async throws -> [CloudPerson] {
        try requireSearchable(visibility)
        switch visibility {
        case .timeline:
            return try await people()
        case .archive:
            if let kept = archivePeople, kept.version == peopleVersion, Date.now.timeIntervalSince(kept.at) < 300 {
                return kept.people
            }
            let found = try await connected().people(in: .archive)
            archivePeople = (peopleVersion, .now, found)
            return found
        case .locked:
            let found = try await connected().people(in: .locked)
            hiddenPeopleIDs.formUnion(found.map(\.id))
            return found
        case .hidden:
            return []
        }
    }

    /// Everyone for the People lists: the Library's, then (when asked) people seen only in the
    /// Archive. The Archive's are optional: if finding them fails, the Library's still show.
    func listedPeople(includingArchive: Bool = UserDefaults.standard.bool(forKey: PhotosSettings.peopleFromArchive)) async throws -> [CloudPerson] {
        let library = try await people()
        guard includingArchive, let archive = try? await people(in: .archive) else { return library }
        return Self.merged([library, archive])
    }

    /// Several lists of people as one, each person once, in order.
    static func merged(_ lists: [[CloudPerson]]) -> [CloudPerson] {
        var seen = Set<String>()
        return lists.joined().filter { seen.insert($0.id).inserted }
    }

    /// One person as the server has them now (after a rename or a merge).
    func person(id: String) async throws -> CloudPerson {
        try await connected().person(id: id)
    }

    /// Merges `others` into `personID`: their photos become this person's. It keeps its name and
    /// birthday (taking theirs when it has none). Can't be undone; throws when any wasn't merged.
    func mergePeople(into personID: String, from others: [String]) async throws {
        ActionLog.write("merge people: \(others.count) into one")
        let unmerged = try await connected().mergePeople([personID] + others)
        peopleVersion += 1
        guard unmerged.isEmpty else {
            throw CloudError(kind: .http(status: 400), message: unmerged.count == others.count + 1 || unmerged.contains(personID)
                ? String(localized: "The server didn't merge these people.")
                : String(localized: "\(unmerged.count) of them couldn't be merged."))
        }
    }

    /// Takes a person out of one photo (each of their faces in it), the way Immich's web app does.
    func removePerson(_ personID: String, fromAsset assetID: String) async throws {
        try requireServerItems([assetID])
        let connection = try connected()
        let faces = try await connection.faces(inAsset: assetID).filter { $0.personID == personID }
        guard !faces.isEmpty else {
            throw CloudError(kind: .http(status: 404), message: String(localized: "This person is no longer in this photo."))
        }
        ActionLog.write("remove person from photo: \(faces.count) face(s)")
        for face in faces { try await connection.removeFace(id: face.id) }
    }

    /// Photos matching a description, best matches first, narrowed by `filters`.
    func smartSearch(_ text: String, filters: CloudSearchQuery) async throws -> [TimelineItem] {
        try requireSearchable(filters.visibility)
        return try await connected().smartSearch(text, filters: filters, limit: 300).map(TimelineItem.init)
    }

    /// The server's metadata search (file names, text in photos, albums), newest first.
    func serverSearch(_ query: CloudSearchQuery, limit: Int = 1000) async throws -> [TimelineItem] {
        try requireSearchable(query.visibility)
        return try await connected().search(query, limit: limit).map(TimelineItem.init)
    }

    /// Search can only look in the Hidden album while it's unlocked; every search goes through here.
    func requireSearchable(_ visibility: CloudVisibility?) throws {
        guard visibility == .locked, hiddenVault.state != .unlocked else { return }
        throw CloudError(kind: .unauthorized, message: String(localized: "Unlock the Hidden album to search it."))
    }

    /// A person's face picture, cached on disk for a day (it changes when the face is changed on the server).
    func personFace(_ personID: String) async -> UIImage? {
        let folder = paths.mediaCache.appending(path: "people", directoryHint: .isDirectory)
        let file = folder.appending(path: personID + ".jpg")
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow } ?? .infinity
        if age < 86_400, let data = try? Data(contentsOf: file), let image = UIImage(data: data) { return image }
        guard let request = connection?.personThumbnailRequest(personID: personID) else {
            return (try? Data(contentsOf: file)).flatMap(UIImage.init(data:))
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else { return nil }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return image
        } catch {
            return (try? Data(contentsOf: file)).flatMap(UIImage.init(data:))
        }
    }

    func memories() async throws -> [CloudMemory] {
        try await connected().memories()
    }

    /// An album's photos, oldest first like the Library grid.
    func albumItems(_ albumID: String) async throws -> [TimelineItem] {
        var query = CloudSearchQuery()
        query.albumID = albumID
        return try await connected().search(query, limit: 5000).map(TimelineItem.init).reversed()
    }

    /// Takes photos out of an album; they stay in the library. Throws when the server
    /// removed none (in a shared album, only the owner or whoever added a photo can remove it).
    @discardableResult
    func remove(assetIDs: [String], fromAlbum albumID: String) async throws -> [String] {
        try requireServerItems(assetIDs)
        let result = try await connected().removeAssets(assetIDs, fromAlbum: albumID)
        ActionLog.write("remove from album: \(assetIDs.count) asked, \(result.removed.count) removed, \(result.refused) refused")
        if result.removed.isEmpty, result.refused > 0 {
            throw CloudError(kind: .http(status: 403), message: assetIDs.count == 1
                ? String(localized: "Only the album's owner or the person who added this item can remove it.")
                : String(localized: "Only the album's owner or the people who added these items can remove them."))
        }
        return result.removed
    }

    /// Puts photos back in an album (Undo after Remove from Album).
    func add(assetIDs: [String], toAlbumID albumID: String) async throws {
        try requireServerItems(assetIDs)
        try await connected().addAssets(assetIDs, toAlbum: albumID)
    }

    /// Recently Deleted › Delete. The server only marks them and removes them in a job a
    /// little later (sync meanwhile sends them as trashed again), so they're removed here
    /// at once and kept out until the server has finished.
    func deletePermanently(assetIDs: [String]) async throws {
        try requireServerItems(assetIDs)
        try requireOwnItems(assetIDs)
        ActionLog.write("delete for good: \(assetIDs.count) items")
        try await connected().deletePermanently(assetIDs: assetIDs)
        try await database.writer.write { db in try RemoteStore.markPurged(ids: assetIDs, in: db) }
        syncNow()
    }

    /// Local search over places, captions, file names and cameras (or file names only), in the
    /// Library, Archive or Hidden album; newest first.
    func search(_ text: String, in visibility: CloudVisibility = .timeline, fileNameOnly: Bool = false) async throws -> [TimelineItem] {
        try requireSearchable(visibility)
        let ownerID = account.userID
        let stored = RemoteVisibility(visibility)
        let ids = (try? await database.reader.read { db in
            try LibrarySearch.assetIDs(ownerID: ownerID, text: text, visibility: stored, fileNameOnly: fileNameOnly, in: db)
        }) ?? []
        let scopeItems = try await items(in: visibility)
        let byID = Dictionary(scopeItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// Everything in the Library, Archive or Hidden album on this phone, oldest first like the grids.
    func items(in visibility: CloudVisibility) async throws -> [TimelineItem] {
        try requireSearchable(visibility)
        if visibility == .timeline { return timeline.items }
        let ownerID = account.userID
        let stored = RemoteVisibility(visibility)
        return (try? await database.reader.read { db in try TimelineQuery.remote(ownerID: ownerID, visibility: stored, in: db) }) ?? []
    }

    func topPlaces(limit: Int) async -> [String] {
        let ownerID = account.userID
        return (try? await database.reader.read { db in try LibrarySearch.topPlaces(ownerID: ownerID, limit: limit, in: db) }) ?? []
    }

    /// Uses `image` as the account picture: shown at once (cached on the phone) and set as the
    /// Cloud profile picture so every device shows it.
    func setProfileImage(_ image: UIImage) async throws {
        let square = Self.squareCrop(image, side: 640)
        guard let jpeg = square.jpegData(compressionQuality: 0.88) else { return }
        try jpeg.write(to: paths.mediaCache.appending(path: "profile-image"), options: .atomic)
        profileImageVersion += 1
        try await connected().setProfileImage(jpeg: jpeg)
    }

    private static func squareCrop(_ image: UIImage, side: CGFloat) -> UIImage {
        let size = image.size
        let edge = min(size.width, size.height)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }())
        return renderer.image { _ in
            let scale = side / edge
            image.draw(in: CGRect(x: -(size.width - edge) / 2 * scale, y: -(size.height - edge) / 2 * scale, width: size.width * scale, height: size.height * scale))
        }
    }

    /// The signed-in user's Immich profile picture, cached on disk so it shows offline.
    func profileImage(refresh: Bool = false) async -> UIImage? {
        let file = paths.mediaCache.appending(path: "profile-image")
        if !refresh, let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            return image
        }
        guard let connection else { return (try? Data(contentsOf: file)).flatMap(UIImage.init(data:)) }
        let request = connection.profileImageRequest(userID: account.userID)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else { return nil }
            try? data.write(to: file, options: .atomic)
            return image
        } catch {
            Log.networking.info("Profile image failed: \(error.localizedDescription, privacy: .public)")
            return (try? Data(contentsOf: file)).flatMap(UIImage.init(data:))
        }
    }
}

extension TimelineItem {
    init(_ asset: CloudAsset) {
        let ratio: Double = if let width = asset.width, let height = asset.height, width > 0, height > 0 {
            Double(width) / Double(height)
        } else {
            1
        }
        self.init(
            id: asset.id, date: asset.localDateTime, isVideo: asset.isVideo, durationMs: asset.durationMs,
            isFavorite: asset.isFavorite, isLivePhoto: asset.isLivePhoto, thumbhash: asset.thumbhash,
            aspectRatio: ratio, uploadedAt: asset.uploadedAt, isEdited: asset.isEdited, ownerID: asset.ownerID
        )
    }
}

extension LibrarySession {
    func locations(limit: Int = 5000) async -> [AssetLocation] {
        let ownerID = account.userID
        return (try? await database.reader.read { db in try LibrarySearch.locations(ownerID: ownerID, limit: limit, in: db) }) ?? []
    }
}

extension RemoteVisibility {
    init(_ visibility: CloudVisibility) {
        switch visibility {
        case .timeline: self = .timeline
        case .archive: self = .archive
        case .hidden: self = .hidden
        case .locked: self = .locked
        }
    }
}
