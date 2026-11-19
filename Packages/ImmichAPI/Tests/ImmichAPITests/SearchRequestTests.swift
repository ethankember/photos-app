import CloudCore
import Foundation
import Testing
@testable import ImmichAPI

/// The JSON sent to `/search/metadata` and `/search/smart`.
@Suite struct SearchRequestTests {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] ?? [:]
    }

    @Test func metadataSearchSendsTheFilters() throws {
        var query = CloudSearchQuery()
        query.albumID = "album-1"
        query.text = "receipt"
        query.isVideo = false
        query.visibility = .archive
        let body = try json(query.metadataSearchDto(page: 2, size: 250))
        #expect(body["albumIds"] as? [String] == ["album-1"])
        #expect(body["ocr"] as? String == "receipt")
        #expect(body["type"] as? String == "IMAGE")
        #expect(body["visibility"] as? String == "archive")
        #expect(body["order"] as? String == "desc")
        #expect(body["page"] as? Int == 2)
        #expect(body["size"] as? Int == 250)
        #expect(body["originalFileName"] == nil)
    }

    @Test func fileNameSearch() throws {
        var query = CloudSearchQuery()
        query.fileName = "IMG_20"
        query.visibility = .timeline
        let body = try json(query.metadataSearchDto(page: 1, size: 250))
        #expect(body["originalFileName"] as? String == "IMG_20")
        #expect(body["visibility"] as? String == "timeline")
        #expect(body["ocr"] == nil)
        #expect(body["albumIds"] == nil)
    }

    @Test func hiddenMapsToTheLockedFolder() throws {
        var query = CloudSearchQuery()
        query.visibility = .locked
        #expect(try json(query.smartSearchDto(query: "dog", page: 1, size: 100))["visibility"] as? String == "locked")
    }

    @Test func smartSearchSendsTheFilters() throws {
        var query = CloudSearchQuery()
        query.albumID = "album-1"
        query.isVideo = true
        query.visibility = .timeline
        let body = try json(query.smartSearchDto(query: "dog on a beach", page: 1, size: 100))
        #expect(body["query"] as? String == "dog on a beach")
        #expect(body["albumIds"] as? [String] == ["album-1"])
        #expect(body["type"] as? String == "VIDEO")
        #expect(body["visibility"] as? String == "timeline")
        #expect(body["size"] as? Int == 100)
    }

    @Test func laterPagesAskForTheNextPage() throws {
        var query = CloudSearchQuery()
        query.visibility = .timeline
        let smart = try json(query.smartSearchDto(query: "dog", page: 2, size: Client.smartSearchPageSize))
        #expect(smart["page"] as? Int == 2)
        #expect(smart["size"] as? Int == 100)
        #expect(smart["visibility"] as? String == "timeline")
        query.text = "receipt"
        let metadata = try json(query.metadataSearchDto(page: 3, size: Client.metadataSearchPageSize))
        #expect(metadata["page"] as? Int == 3)
        #expect(metadata["size"] as? Int == 250)
        #expect(metadata["ocr"] as? String == "receipt")
    }

    @Test func unsetFiltersAreLeftOut() throws {
        let body = try json(CloudSearchQuery().smartSearchDto(query: "x", page: 1, size: 100))
        #expect(Set(body.keys) == ["query", "page", "size"])
    }
}
