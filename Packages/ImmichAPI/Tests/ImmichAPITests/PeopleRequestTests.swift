import CloudCore
import Foundation
import Testing
@testable import ImmichAPI

/// The JSON sent to merge people and remove faces, and how the answers are read.
@Suite struct PeopleRequestTests {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] ?? [:]
    }

    @Test func mergeKeepsTheOrder() throws {
        let body = try json(Client.mergeBody(["kept", "merged-1", "merged-2"]))
        #expect(body["ids"] as? [String] == ["kept", "merged-1", "merged-2"])
    }

    @Test func removingAFaceIsNotForced() throws {
        #expect(try json(Client.removeFaceBody)["force"] as? Bool == false)
    }

    @Test func unmergedIDsAreTheOnesNotReportedAsMerged() {
        let results: [Components.Schemas.BulkIdResponseDto] = [
            .init(id: "kept", success: true),
            .init(id: "merged-1", success: true),
            .init(error: .noPermission, id: "merged-2", success: false),
        ]
        #expect(Client.unmergedIDs(results, requested: ["kept", "merged-1", "merged-2", "missing"]) == ["merged-2", "missing"])
        #expect(Client.unmergedIDs([], requested: ["kept", "other"]) == ["kept", "other"])
    }

    @Test func peopleScanNamesTheVisibilityAndAsksForPeople() throws {
        let body = try json(Client.peopleScanDto(.locked, page: 3))
        #expect(body["visibility"] as? String == "locked")
        #expect(body["withPeople"] as? Bool == true)
        #expect(body["page"] as? Int == 3)
        #expect(body["size"] as? Int == 250)
    }

    private func person(_ id: String, _ name: String, hidden: Bool = false) -> Components.Schemas.PersonResponseDto {
        .init(id: id, isHidden: hidden, name: name, otherPeople: [], sharedBy: [], sharedWith: [], thumbnailPath: "")
    }

    @Test func peopleFoundFollowsThePeopleListRules() {
        let ann = person("ann", "Ann"), bob = person("bob", "Bob"), stranger = person("x", ""), regular = person("y", "")
        let secret = person("z", "Zed", hidden: true)
        let photos: [[Components.Schemas.PersonResponseDto]] = [
            [ann, stranger, regular], [ann, regular, ann], [regular, secret], [bob], [],
        ]
        let found = Client.peopleFound(photos, minimumPhotos: 3)
        // Unnamed "x" is in one photo (left out), "y" in three; hidden Zed is left out.
        // Most photographed first: y (3), Ann (2, counted once per photo), Bob (1).
        #expect(found.map(\.id) == ["y", "ann", "bob"])
        // With no minimum, the one-photo stranger is listed too (ties by name: unnamed first).
        #expect(Client.peopleFound(photos, minimumPhotos: 1).map(\.id) == ["y", "ann", "x", "bob"])
    }

    @Test func personSearchSendsPeopleWithAVisibility() throws {
        var query = CloudSearchQuery()
        query.personIDs = ["person-1", "person-2"]
        query.visibility = .archive
        let body = try json(query.metadataSearchDto(page: 1, size: 250))
        #expect(body["personIds"] as? [String] == ["person-1", "person-2"])
        #expect(body["visibility"] as? String == "archive")
        let smart = try json(query.smartSearchDto(query: "beach", page: 1, size: 100))
        #expect(smart["personIds"] as? [String] == ["person-1", "person-2"])
        #expect(smart["visibility"] as? String == "archive")
    }
}
