import CloudCore
import Foundation
import OpenAPIRuntime

extension CloudPerson {
    init(_ dto: Components.Schemas.PersonResponseDto) {
        self.init(id: dto.id, name: dto.name, birthDate: dto.birthDate, isHidden: dto.isHidden, isFavorite: dto.isFavorite ?? false)
    }
}

/// Face recognition, smart search and server settings. People and smart search need the
/// server's machine learning (which may run on another computer).
extension Client {
    /// Everyone recognised, not hidden, in pages of 500 (most photographed first, as the server orders them).
    public func people() async throws -> [CloudPerson] {
        var results: [CloudPerson] = []
        var page = 1
        do {
            while page <= 20 {
                switch try await getAllPeople(query: .init(page: page, size: 500, withHidden: false)) {
                case .ok(let response):
                    let body = try response.body.json
                    results += body.people.filter { !$0.isHidden }.map(CloudPerson.init)
                    guard body.hasNextPage == true else { return results }
                    page += 1
                case .undocumented(let status, let payload):
                    throw await APIError.from(statusCode: status, payload: payload, operation: "load people")
                }
            }
            return results
        } catch {
            throw APIError.wrap(error, operation: "People")
        }
    }

    /// The people recognised in one photo.
    public func people(inAsset assetID: String) async throws -> [CloudPerson] {
        do {
            switch try await getAssetInfo(path: .init(id: assetID)) {
            case .ok(let response):
                return try (response.body.json.people ?? []).filter { !$0.isHidden }.map(CloudPerson.init)
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "load the people in this photo")
            }
        } catch {
            throw APIError.wrap(error, operation: "People")
        }
    }

    public func updatePerson(id: String, name: String?, birthDate: String?) async throws -> CloudPerson {
        var dto = Components.Schemas.PersonUpdateDto()
        dto.name = name
        dto.birthDate = birthDate
        do {
            switch try await updatePerson(path: .init(id: id), body: .json(dto)) {
            case .ok(let response):
                return try CloudPerson(response.body.json)
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "name this person")
            }
        } catch {
            throw APIError.wrap(error, operation: "Name person")
        }
    }

    /// The people in the photos with one visibility (the Archive, or the Hidden album while it's
    /// unlocked): `/people` only counts faces in the Library, so someone seen only there is
    /// missing from it. A metadata search with people, every page; see `peopleFound`.
    public func people(in visibility: CloudVisibility, minimumPhotos: Int = Client.minimumPhotosForUnnamed) async throws -> [CloudPerson] {
        var perAsset: [[Components.Schemas.PersonResponseDto]] = []
        var page = 1
        do {
            // Every page (a cap would drop people without saying); the guard only stops a runaway.
            while page <= 2000 {
                switch try await searchAssets(body: .json(Self.peopleScanDto(visibility, page: page))) {
                case .ok(let response):
                    let assets = try response.body.json.assets
                    perAsset += assets.items.map { $0.people ?? [] }
                    guard assets.nextPage != nil, !assets.items.isEmpty else { return Self.peopleFound(perAsset, minimumPhotos: minimumPhotos) }
                    page += 1
                case .undocumented(let status, let payload):
                    throw await APIError.from(statusCode: status, payload: payload, operation: "find the people in these photos")
                }
            }
            return Self.peopleFound(perAsset, minimumPhotos: minimumPhotos)
        } catch {
            throw APIError.wrap(error, operation: "People")
        }
    }

    /// One page of photos with this visibility, with the people in each.
    static func peopleScanDto(_ visibility: CloudVisibility, page: Int) -> Components.Schemas.MetadataSearchDto {
        var query = CloudSearchQuery()
        query.visibility = visibility
        var dto = query.metadataSearchDto(page: page, size: 250)
        dto.withPeople = true
        return dto
    }

    /// Immich's default for listing unnamed people (its "minimum recognised faces" setting is 3).
    public static let minimumPhotosForUnnamed = 3

    /// Each person once, from the people in each photo, the way `/people` lists them: hidden
    /// people left out, and unnamed people only when they're in at least `minimumPhotos` photos.
    /// Most photographed first, then by name.
    static func peopleFound(_ perAsset: [[Components.Schemas.PersonResponseDto]], minimumPhotos: Int) -> [CloudPerson] {
        var counts: [String: Int] = [:]
        var first: [String: Components.Schemas.PersonResponseDto] = [:]
        for people in perAsset {
            for person in Set(people.map(\.id)) { counts[person, default: 0] += 1 }
            for person in people where first[person.id] == nil { first[person.id] = person }
        }
        return first.values
            .filter { !$0.isHidden && (!$0.name.isEmpty || counts[$0.id, default: 0] >= minimumPhotos) }
            .sorted { (counts[$0.id, default: 0], $1.name, $1.id) > (counts[$1.id, default: 0], $0.name, $0.id) }
            .map(CloudPerson.init)
    }

    /// One person as the server has them now.
    public func person(id: String) async throws -> CloudPerson {
        do {
            switch try await getPerson(path: .init(id: id)) {
            case .ok(let response):
                return try CloudPerson(response.body.json)
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "load this person")
            }
        } catch {
            throw APIError.wrap(error, operation: "Person")
        }
    }

    /// `POST /people/merge`: merges the people into the first (Immich keeps the first one's name
    /// and birthday, taking the next one's when it has none). Returns the IDs not merged.
    public func mergePeople(ids: [String]) async throws -> [String] {
        do {
            switch try await mergePeople(body: .json(Self.mergeBody(ids))) {
            case .ok(let response):
                return Self.unmergedIDs(try response.body.json, requested: ids)
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "merge these people")
            }
        } catch {
            throw APIError.wrap(error, operation: "Merge people")
        }
    }

    /// The faces in a photo (soft-deleted ones aren't listed).
    public func faces(inAsset assetID: String) async throws -> [CloudFace] {
        do {
            switch try await getFaces(query: .init(id: assetID)) {
            case .ok(let response):
                return try response.body.json.map { CloudFace(id: $0.id, personID: $0.person?.value1.id) }
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "load the faces in this photo")
            }
        } catch {
            throw APIError.wrap(error, operation: "Faces")
        }
    }

    /// `DELETE /faces/{id}`, the way Immich's web app removes a face: not forced, so the server
    /// keeps it as deleted and face recognition doesn't put it back.
    public func removeFace(id: String) async throws {
        do {
            switch try await deleteFace(path: .init(id: id), body: .json(Self.removeFaceBody)) {
            case .noContent:
                return
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "remove this face")
            }
        } catch {
            throw APIError.wrap(error, operation: "Remove face")
        }
    }

    /// The merge request: the order matters, the first is kept.
    static func mergeBody(_ ids: [String]) -> Components.Schemas.MergePersonDto {
        Components.Schemas.MergePersonDto(ids: ids)
    }

    static let removeFaceBody = Components.Schemas.AssetFaceDeleteDto(force: false)

    /// The requested IDs the server didn't report as merged (the first is the one kept).
    static func unmergedIDs(_ results: [Components.Schemas.BulkIdResponseDto], requested ids: [String]) -> [String] {
        let merged = Set(results.filter(\.success).map(\.id))
        return ids.filter { !merged.contains($0) }
    }

    /// Search by meaning, narrowed by `filters`, in pages of 100 up to `limit`.
    public func smartSearch(_ text: String, filters: CloudSearchQuery = CloudSearchQuery(), limit: Int) async throws -> [CloudAsset] {
        var results: [CloudAsset] = []
        var page = 1
        do {
            while results.count < limit {
                let dto = filters.smartSearchDto(query: text, page: page, size: 100)
                switch try await searchSmart(body: .json(dto)) {
                case .ok(let response):
                    let assets = try response.body.json.assets
                    results += assets.items.map(CloudAsset.init)
                    guard assets.nextPage != nil, !assets.items.isEmpty else { return results }
                    page += 1
                case .undocumented(let status, let payload):
                    throw await APIError.from(statusCode: status, payload: payload, operation: "search")
                }
            }
            return results
        } catch {
            throw APIError.wrap(error, operation: "Smart search")
        }
    }

    /// How many days the server keeps trashed items.
    public func trashRetentionDays() async throws -> Int {
        do {
            switch try await getServerConfig() {
            case .ok(let response):
                return try response.body.json.trashDays
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "read the server settings")
            }
        } catch {
            throw APIError.wrap(error, operation: "Server settings")
        }
    }
}
