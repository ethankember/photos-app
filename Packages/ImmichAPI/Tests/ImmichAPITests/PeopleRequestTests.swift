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
