import Foundation
import CoreFoundation
import WebKit
import UserNotifications

final class SchoolClient {
    let cookies: HTTPCookieStorage
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        cookies = config.httpCookieStorage!
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
    }
    static func schoolCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domain == "gdgm.cn" || domain.hasSuffix(".gdgm.cn")
    }
    func restoreCookies() throws {
        guard let data = Keychain.read("cookies") else { return }
        let rows = try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] ?? []
        for row in rows {
            let properties = Dictionary(uniqueKeysWithValues: row.map { (HTTPCookiePropertyKey($0.key), $0.value) })
            if let cookie = HTTPCookie(properties: properties), Self.schoolCookie(cookie), cookie.expiresDate.map({ $0 > Date() }) ?? true { cookies.setCookie(cookie) }
        }
    }
    func accept(_ values: [HTTPCookie]) throws {
        // HTTPCookieStorage preserves (domain, path, name); same-name SSO cookies never overwrite across hosts.
        for cookie in values where Self.schoolCookie(cookie) { cookies.setCookie(cookie) }
        try persistCookies()
    }
    func persistCookies() throws {
        let rows = (cookies.cookies ?? []).filter(Self.schoolCookie).compactMap { cookie -> [String: Any]? in
            cookie.properties.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) }
        }
        try Keychain.write("cookies", PropertyListSerialization.data(fromPropertyList: rows, format: .binary, options: 0))
    }
    func clearCookies() throws {
        for cookie in cookies.cookies ?? [] where Self.schoolCookie(cookie) { cookies.deleteCookie(cookie) }
        try Keychain.write("cookies", nil)
    }
    func html(_ url: URL, fields: [String: String] = [:]) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(School.main.absoluteString, forHTTPHeaderField: "Referer")
        if !fields.isEmpty {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var body = URLComponents()
            body.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SchoolError.unavailable }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb18030) else { throw SchoolError.unrecognized }
        try SchoolHTML.check(html, status: response.statusCode, url: response.url)
        return html
    }
    func verify() async throws {
        let html = try await html(School.main)
        guard ["/jsxsd/", "xsMain_new.jsp", "ckgrxx"].contains(where: html.contains) else { throw SchoolError.message("尚未取得有效教务会话，请在网页继续完成授权。") }
        try persistCookies()
    }
    func schedule(term: String, campus: Campus, week: Int) async throws -> Schedule {
        var fields = ["kbjcmsid": campus.rawValue, "zc": String(week)]
        if !term.isEmpty { fields["xnxq01id"] = term }
        return try SchoolHTML.schedule(await html(School.schedule, fields: fields))
    }
    func desktop() async throws -> (TermCalendar?, [ProfileField]) {
        let html = try await html(School.desktop)
        var fields = try SchoolHTML.profile(html)
        if !fields.contains(where: { ["学生编号", "学号"].contains($0.label) }) {
            let fallback = try SchoolHTML.frameProfile(await self.html(School.main))
            for field in fallback where !fields.contains(where: { $0.label == field.label }) { fields.append(field) }
        }
        return (try SchoolHTML.calendar(html), fields)
    }
}

enum Notifications {
    static func replace(_ plan: [Reminder]) async throws {
        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: old.filter { $0.identifier.hasPrefix("gm.") }.map(\.identifier))
        for item in plan {
            let content = UNMutableNotificationContent()
            content.title = "即将上课 · " + item.course.name
            content.body = [item.course.room, item.course.teacher].filter { !$0.isEmpty }.joined(separator: " · ")
            content.sound = .default
            var components = SchoolClock.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: item.date)
            components.timeZone = SchoolClock.calendar.timeZone
            try await center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
        }
    }
}

struct UpdateInfo: Decodable {
    let version: String
    let versionCode: Int?
    let ipa: String?
    let notes: String?
    var newer: Bool {
        if let code = versionCode { return code > 20 }
        return version.compare("3.0.0", options: .numeric) == .orderedDescending
    }
    var download: URL? {
        guard let value = ipa, let url = URL(string: value), url.scheme == "https" else { return nil }
        return url
    }
    static func fetch() async throws -> UpdateInfo {
        var request = URLRequest(url: School.update)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SchoolError.message("暂时无法检查更新。") }
        return try JSONDecoder().decode(UpdateInfo.self, from: data)
    }
}
