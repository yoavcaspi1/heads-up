import Foundation

/// Detects a joinable video-meeting URL for an event, in priority order:
/// hangoutLink, then conferenceData video entry point, then a scan of
/// location + description for a known provider, then generic "Join" links
/// (an HTML anchor or plain-text line labelled Join), then a location that
/// is itself a URL. The generic tiers exist because plenty of real invites
/// (Upwork rooms, webinar platforms, Teams "new" links) carry their join
/// URL on a domain no provider list will ever be complete for.
enum MeetingLink {
    /// One URL: runs to whitespace or a delimiter that ends links in HTML
    /// and plain text alike.
    private static let urlBody = #"[^\s"'<>)\]]+"#

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let patterns: [(provider: String, regex: NSRegularExpression)] = [
        ("meet", regex(#"https://meet\.google\.com/"# + urlBody)),
        ("zoom", regex(#"https://[a-z0-9.-]*zoom\.(?:us|com)/"# + urlBody)),
        ("teams", regex(#"https://teams\.(?:microsoft|live)\.com/"# + urlBody)),
        ("webex", regex(#"https://[a-z0-9.-]*webex\.com/"# + urlBody)),
        ("whereby", regex(#"https://whereby\.com/"# + urlBody)),
        ("jitsi", regex(#"https://meet\.jit\.si/"# + urlBody)),
        ("gotomeeting", regex(#"https://[a-z0-9.-]*goto(?:meeting|webinar)\.com/"# + urlBody)),
        ("upwork", regex(#"https://www\.upwork\.com/ab/messages/rooms/"# + urlBody)),
    ]

    /// `<a href="URL">Join …</a>`: an anchor whose visible text starts with
    /// "Join" (Upwork's "Join this meeting", generic "Join meeting").
    private static let joinAnchor =
        regex(#"<a\b[^>]*\bhref\s*=\s*["']("# + urlBody + #")["'][^>]*>\s*join\b"#)

    /// Plain text: "Join: URL", "Join Zoom Meeting\nURL", "Join here URL".
    private static let joinLine =
        regex(#"\bjoin\b[^\n<]{0,60}?[:\s]\s*(https?://"# + urlBody + #")"#)

    private static let bareUrl = regex(#"^https?://"# + urlBody + "$")

    static func detect(location: String?, description: String?,
                       hangoutLink: String?, conferenceVideoURI: String?) -> (url: String?, provider: String?) {
        if let link = hangoutLink, !link.isEmpty {
            return (link, "meet")
        }
        if let uri = conferenceVideoURI, !uri.isEmpty {
            return (uri, classify(uri))
        }
        let haystack = "\(location ?? "")\n\(description ?? "")"
        let range = NSRange(haystack.startIndex..., in: haystack)
        for (provider, regex) in patterns {
            if let m = regex.firstMatch(in: haystack, range: range),
               let r = Range(m.range, in: haystack) {
                return (clean(String(haystack[r])), provider)
            }
        }
        for regex in [joinAnchor, joinLine] {
            if let m = regex.firstMatch(in: haystack, range: range),
               let r = Range(m.range(at: 1), in: haystack) {
                let url = clean(String(haystack[r]))
                return (url, classify(url))
            }
        }
        if let loc = location?.trimmingCharacters(in: .whitespacesAndNewlines),
           bareUrl.firstMatch(in: loc, range: NSRange(loc.startIndex..., in: loc)) != nil {
            return (clean(loc), classify(loc))
        }
        return (nil, nil)
    }

    /// Provider name for a URL, "other" when no known provider matches.
    static func classify(_ url: String) -> String {
        patterns.first { $0.regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }?
            .provider ?? "other"
    }

    /// URLs lifted out of HTML carry entity-escaped query separators
    /// (`&amp;`), and ones lifted out of prose can end in a sentence's
    /// full stop or comma. Both would break the link when opened.
    static func clean(_ url: String) -> String {
        var s = url
        for (entity, char) in [("&amp;", "&"), ("&#39;", "'"), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        while let last = s.last, ".,;".contains(last) { s.removeLast() }
        return s
    }
}
