@testable import HeadsUpKit
import Foundation

func meetingLinkTests() async {
    suite("MeetingLinkTests")

    await test("testHangoutLinkWins") {
        let r = MeetingLink.detect(location: "https://zoom.us/j/1", description: nil,
                                   hangoutLink: "https://meet.google.com/abc-defg-hij",
                                   conferenceVideoURI: nil)
        try expectEqual(r.provider, "meet")
        try expectEqual(r.url, "https://meet.google.com/abc-defg-hij")
    }

    await test("testConferenceEntryPointClassified") {
        let r = MeetingLink.detect(location: nil, description: nil, hangoutLink: nil,
                                   conferenceVideoURI: "https://company.zoom.us/j/123?pwd=x")
        try expectEqual(r.provider, "zoom")
    }

    await test("testConferenceEntryPointUnknownProviderIsOther") {
        let r = MeetingLink.detect(location: nil, description: nil, hangoutLink: nil,
                                   conferenceVideoURI: "https://example.com/room/9")
        try expectEqual(r.provider, "other")
        try expectEqual(r.url, "https://example.com/room/9")
    }

    await test("testScanLocationAndDescription") {
        let r = MeetingLink.detect(
            location: "Room 4",
            description: "Join: https://teams.microsoft.com/l/meetup-join/xyz end",
            hangoutLink: nil, conferenceVideoURI: nil)
        try expectEqual(r.provider, "teams")
        try expectEqual(r.url, "https://teams.microsoft.com/l/meetup-join/xyz")
    }

    await test("testNoMeeting") {
        let r = MeetingLink.detect(location: "Cafe", description: "chat", hangoutLink: nil, conferenceVideoURI: nil)
        try expectNil(r.url)
        try expectNil(r.provider)
    }
}
