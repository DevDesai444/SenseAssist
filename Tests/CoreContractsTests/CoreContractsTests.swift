import CoreContracts
import Foundation
import Testing

@Test func updateCardRoundTripJSON() throws {
    let card = UpdateCard(
        source: .gmail,
        providerIDs: ProviderIDs(messageID: "m-1", threadID: "t-1"),
        receivedAtUTC: Date(timeIntervalSince1970: 1_700_000_000),
        from: "noreply@buffalo.edu",
        subject: "CSE312 Assignment",
        bodyText: "Due on March 2",
        parserMethod: .ruleBased,
        parseConfidence: 0.9
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let data = try encoder.encode(card)
    let decoded = try decoder.decode(UpdateCard.self, from: data)

    #expect(decoded == card)
}
