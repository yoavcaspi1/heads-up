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

    // Real-world shape (Upwork scheduler invite): the join URL is an
    // Upwork room inside an HTML anchor, with entity-escaped ampersands,
    // sitting after other anchors that are NOT the meeting.
    await test("testUpworkRoomAnchorWithEntities") {
        let description = """
        You're meeting with <a href="https://www.upwork.com/freelancers/~01">Oles M.</a> about \
        <a href="https://www.upwork.com/jobs/~02">Visualiser</a>.<br>\
        <a href="https://www.upwork.com/ab/messages/rooms/room_a40?zoom=true&amp;companyReference=207">Join</a> this meeting.<br>\
        You can also <a href="https://www.upwork.com/ab/messages/scheduler/cancel?x=1">cancel</a>.
        """
        let r = MeetingLink.detect(location: nil, description: description, hangoutLink: nil, conferenceVideoURI: nil)
        try expectEqual(r.url, "https://www.upwork.com/ab/messages/rooms/room_a40?zoom=true&companyReference=207")
        try expectEqual(r.provider, "upwork")
    }

    await test("testGenericJoinAnchorIsOther") {
        let description = #"Details <a href="https://example.com/about">here</a>. <a href="https://rooms.example.com/abc?k=1&amp;v=2">Join meeting</a>"#
        let r = MeetingLink.detect(location: nil, description: description, hangoutLink: nil, conferenceVideoURI: nil)
        try expectEqual(r.url, "https://rooms.example.com/abc?k=1&v=2")
        try expectEqual(r.provider, "other")
    }

    await test("testNonJoinAnchorIgnored") {
        let description = #"Read <a href="https://example.com/about">the brief</a> first."#
        let r = MeetingLink.detect(location: nil, description: description, hangoutLink: nil, conferenceVideoURI: nil)
        try expectNil(r.url)
    }

    // Real-world shape (Teams invite via Outlook): "Join: URL" on its own
    // line, with a webex fallback URL further down that must not win.
    await test("testNewTeamsMeetLinkBeatsWebexFallback") {
        let description = """
        Microsoft Teams meeting
        Join: https://teams.microsoft.com/meet/247400650941423?p=HuTojq
        Meeting ID: 247 400 650 941 423
        More info<https://www.webex.com/msteams?confid=11381953588>
        """
        let r = MeetingLink.detect(location: "Microsoft Teams Meeting", description: description,
                                   hangoutLink: nil, conferenceVideoURI: nil)
        try expectEqual(r.url, "https://teams.microsoft.com/meet/247400650941423?p=HuTojq")
        try expectEqual(r.provider, "teams")
    }

    await test("testTeamsLiveDomain") {
        let r = MeetingLink.detect(location: nil, description: "https://teams.live.com/meet/9x?p=1",
                                   hangoutLink: nil, conferenceVideoURI: nil)
        try expectEqual(r.provider, "teams")
    }

    await test("testPlainJoinLineStripsTrailingStop") {
        let r = MeetingLink.detect(location: nil, description: "Join here https://rooms.example.com/xyz.",
                                   hangoutLink: nil, conferenceVideoURI: nil)
        try expectEqual(r.url, "https://rooms.example.com/xyz")
        try expectEqual(r.provider, "other")
    }

    await test("testLocationThatIsAUrlIsTheLink") {
        let r = MeetingLink.detect(location: " https://www.example.co.uk/webinar-register ",
                                   description: "No links in here", hangoutLink: nil, conferenceVideoURI: nil)
        try expectEqual(r.url, "https://www.example.co.uk/webinar-register")
        try expectEqual(r.provider, "other")
    }

    await test("testLocationWithProseIsNotALink") {
        let r = MeetingLink.detect(location: "Office, see https://example.com/map",
                                   description: nil, hangoutLink: nil, conferenceVideoURI: nil)
        try expectNil(r.url)
    }
}
