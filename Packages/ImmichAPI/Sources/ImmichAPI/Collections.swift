import CloudCore
import Foundation
import OpenAPIRuntime

public typealias RemoteAssetSummary = CloudAsset
public typealias MemorySummary = CloudMemory
public typealias MetadataQuery = CloudSearchQuery

extension CloudAsset {
    init(_ dto: Components.Schemas.AssetResponseDto) {
        self.init(
            id: dto.id, localDateTime: dto.localDateTime, isVideo: dto._type == .video, durationMs: dto.duration,
            isFavorite: dto.isFavorite, isLivePhoto: dto.livePhotoVideoId != nil, thumbhash: dto.thumbhash,
            width: dto.width, height: dto.height, ownerID: dto.ownerId, uploadedAt: dto.createdAt,
            isEdited: dto.isEdited, isTrashed: dto.isTrashed,
            originalFileName: dto.originalFileName, livePhotoVideoID: dto.livePhotoVideoId, checksum: dto.checksum
        )
    }
}

extension MetadataQuery {
    /// One page of `POST /search/metadata`, newest first.
    func metadataSearchDto(page: Int, size: Int) -> Components.Schemas.MetadataSearchDto {
        var dto = Components.Schemas.MetadataSearchDto()
        dto.albumIds = albumID.map { [$0] }
        dto.city = city
        dto.country = country
        dto.originalFileName = fileName
        dto.description = description
        dto.ocr = text
        dto.make = make
        dto.model = model
        dto.takenAfter = takenAfter
        dto.takenBefore = takenBefore
        dto.isFavorite = isFavorite
        dto._type = isVideo.map { $0 ? .video : .image }
        dto.visibility = visibility.map(Components.Schemas.AssetVisibility.init)
        if !personIDs.isEmpty { dto.personIds = personIDs }
        if trashedOnly {
            dto.withDeleted = true
            dto.trashedAfter = Date(timeIntervalSince1970: 0)
        }
        dto.order = .desc
        dto.page = page
        dto.size = size
        return dto
    }

    /// One page of `POST /search/smart` for `query`, with the same filters.
    func smartSearchDto(query: String, page: Int, size: Int) -> Components.Schemas.SmartSearchDto {
        var dto = Components.Schemas.SmartSearchDto()
        dto.query = query
        dto.albumIds = albumID.map { [$0] }
        dto.city = city
        dto.country = country
        dto.ocr = text
        dto.make = make
        dto.model = model
        dto.takenAfter = takenAfter
        dto.takenBefore = takenBefore
        dto.isFavorite = isFavorite
        dto._type = isVideo.map { $0 ? .video : .image }
        dto.visibility = visibility.map(Components.Schemas.AssetVisibility.init)
        if !personIDs.isEmpty { dto.personIds = personIDs }
        dto.page = page
        dto.size = size
        return dto
    }
}

extension Components.Schemas.AssetVisibility {
    init(_ visibility: CloudVisibility) {
        switch visibility {
        case .timeline: self = .timeline
        case .archive: self = .archive
        case .locked: self = .locked
        }
    }
}

extension Client {
    /// Metadata search, newest first, following pages up to `limit` results.
    /// Small pages keep each request light on the Raspberry Pi.
    public func searchAssets(_ query: MetadataQuery, limit: Int = 5000) async throws -> [RemoteAssetSummary] {
        var results: [RemoteAssetSummary] = []
        var page = 1
        let pageSize = 250
        do {
            while results.count < limit {
                let dto = query.metadataSearchDto(page: page, size: pageSize)
                switch try await searchAssets(body: .json(dto)) {
                case .ok(let response):
                    let assets = try response.body.json.assets
                    results += assets.items.map(RemoteAssetSummary.init)
                    guard assets.nextPage != nil, !assets.items.isEmpty else { return results }
                    page += 1
                case .undocumented(let status, let payload):
                    throw await APIError.from(statusCode: status, payload: payload, operation: "search")
                }
            }
            return results
        } catch {
            throw APIError.wrap(error, operation: "Search")
        }
    }

    /// The account's memories (Immich's "On This Day"), newest first.
    public func memories() async throws -> [MemorySummary] {
        do {
            switch try await searchMemories(query: .init(isTrashed: false, order: .desc)) {
            case .ok(let response):
                return try response.body.json
                    .filter { $0.deletedAt == nil && !$0.assets.isEmpty }
                    .map { MemorySummary(id: $0.id, memoryAt: $0.memoryAt, year: $0.data.year, assets: $0.assets.map(RemoteAssetSummary.init)) }
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "load memories")
            }
        } catch {
            throw APIError.wrap(error, operation: "Memories")
        }
    }
}
