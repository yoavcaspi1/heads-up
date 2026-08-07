import Foundation

/// Detects a joinable video-meeting URL for an event, in the same priority
/// order as the original: hangoutLink, then conferenceData video entry point,
/// then a regex scan of location + description.
enum MeetingLink {
    private static let patterns: [(provider: String, regex: NSRegularExpression)] = [
        ("meet", try! NSRegularExpression(pattern: #"https://meet\.google\.com/[^\s"'<>)]+"#, options: [.caseInsensitive])),
        ("zoom", try! NSRegularExpression(pattern: #"https://[a-z0-9.-]*zoom\.us/[^\s"'<>)]+"#, options: [.caseInsensitive])),
        ("teams", try! NSRegularExpression(pattern: #"https://teams\.microsoft\.com/[^\s"'<>)]+"#, options: [.caseInsensitive])),
        ("webex", try! NSRegularExpression(pattern: #"https://[a-z0-9.-]*webex\.com/[^\s"'<>)]+"#, options: [.caseInsensitive])),
    ]

    static func detect(location: String?, description: String?,
                       hangoutLink: String?, conferenceVideoURI: String?) -> (url: String?, provider: String?) {
        if let link = hangoutLink, !link.isEmpty {
            return (link, "meet")
        }
        if let uri = conferenceVideoURI, !uri.isEmpty {
            let provider = patterns.first { $0.regex.firstMatch(in: uri, range: NSRange(uri.startIndex..., in: uri)) != nil }?.provider
            return (uri, provider ?? "other")
        }
        let haystack = "\(location ?? "")\n\(description ?? "")"
        let range = NSRange(haystack.startIndex..., in: haystack)
        for (provider, regex) in patterns {
            if let m = regex.firstMatch(in: haystack, range: range),
               let r = Range(m.range, in: haystack) {
                return (String(haystack[r]), provider)
            }
        }
        return (nil, nil)
    }
}
