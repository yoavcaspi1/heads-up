import Foundation

struct GoogleEventDateTime: Codable, Equatable {
    var date: String?
    var dateTime: String?
}

struct GoogleEntryPoint: Codable, Equatable {
    var entryPointType: String?
    var uri: String?
}

struct GoogleConferenceData: Codable, Equatable {
    var entryPoints: [GoogleEntryPoint]?
}

struct GoogleEvent: Codable, Equatable {
    var id: String?
    var iCalUID: String?
    var status: String?
    var summary: String?
    var location: String?
    var description: String?
    var hangoutLink: String?
    var htmlLink: String?
    var start: GoogleEventDateTime?
    var end: GoogleEventDateTime?
    var conferenceData: GoogleConferenceData?
}

struct CalendarListEntry: Codable, Equatable {
    var id: String?
    var summary: String?
    var summaryOverride: String?
    var primary: Bool?
    var deleted: Bool?
    var hidden: Bool?
    var accessRole: String?
}

struct GoogleCalendarListResponse: Codable {
    var items: [CalendarListEntry]?
}

struct GoogleEventsResponse: Codable {
    var items: [GoogleEvent]?
    var nextPageToken: String?
}
