import Foundation
import CoreFoundation
import WebKit
import UserNotifications
import CommonCrypto
import SwiftSoup

final class SchoolClient {
    let cookies: HTTPCookieStorage
    private let session: URLSession
    private(set) var pendingLoginURL: URL?
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
    func accept(_ values: [HTTPCookie]) {
        for cookie in cookies.cookies ?? [] where Self.schoolCookie(cookie) { cookies.deleteCookie(cookie) }
        // HTTPCookieStorage preserves (domain, path, name); same-name SSO cookies never overwrite across hosts.
        for cookie in values where Self.schoolCookie(cookie) { cookies.setCookie(cookie) }
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
    func response(_ url: URL, fields: [String: String] = [:], referer: URL = School.main) async throws -> (html: String, response: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Mobile Safari/537.36", forHTTPHeaderField: "User-Agent")
        if !fields.isEmpty {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formBody(fields)
            request.setValue(url.host == "sfrz.gdgm.cn" ? "https://sfrz.gdgm.cn" : School.host, forHTTPHeaderField: "Origin")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SchoolError.unavailable }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb18030) else { throw SchoolError.unrecognized }
        if response.statusCode >= 500 { throw SchoolError.unavailable }
        return (html, response)
    }
    static func formBody(_ fields: [String: String]) -> Data? {
        var body = URLComponents()
        body.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
    }
    func html(_ url: URL, fields: [String: String] = [:]) async throws -> String {
        let page = try await response(url, fields: fields)
        try SchoolHTML.check(page.html, status: page.response.statusCode, url: page.response.url)
        return page.html
    }
    struct CASForm {
        let action: URL
        let salt: String
        var fields: [String: String]
    }
    static func loginForm(_ html: String, url: URL) throws -> CASForm {
        let doc = try SwiftSoup.parse(html)
        guard let form = try doc.select("#casLoginForm").first() else { throw SchoolError.message("学校登录页面发生变化，未提交密码。") }
        let actionText = try form.attr("action")
        guard let action = URL(string: actionText.isEmpty ? url.absoluteString : actionText, relativeTo: url)?.absoluteURL,
              action.scheme == "https", action.host == "sfrz.gdgm.cn" else { throw SchoolError.message("学校登录表单地址发生变化，未提交密码。") }
        var fields: [String: String] = [:]
        for input in try form.select("input[name]") { fields[try input.attr("name")] = try input.attr("value") }
        let regex = try NSRegularExpression(pattern: #"pwdDefaultEncryptSalt\s*=\s*['"]([^'"]+)['"]"#)
        let salt: String
        if let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let range = Range(match.range(at: 1), in: html) { salt = String(html[range]) }
        else { salt = try doc.select("#pwdEncryptSalt,input[name=pwdEncryptSalt]").attr("value") }
        guard !salt.isEmpty else { throw SchoolError.message("学校登录页面缺少加密参数，未提交密码。") }
        return CASForm(action: action, salt: salt, fields: fields)
    }
    static func captchaSalt(_ text: String, initial: String) throws -> String {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "::::")
        if parts[0].lowercased() == "true" { throw SchoolError.captcha }
        guard parts[0].lowercased() == "false" else { throw SchoolError.message("学校验证码状态无法确认，未提交密码。") }
        return parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : initial
    }
    static func encryptPassword(_ password: String, salt: String, prefix: String? = nil, iv: String? = nil) throws -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678")
        let randomPrefix = prefix ?? String((0..<64).map { _ in alphabet.randomElement()! })
        let randomIV = iv ?? String((0..<16).map { _ in alphabet.randomElement()! })
        let key = Data(salt.utf8)
        let vector = Data(randomIV.utf8)
        let input = Data((randomPrefix + password).utf8)
        guard [16,24,32].contains(key.count), vector.count == kCCBlockSizeAES128, randomPrefix.utf8.count == 64 else {
            throw SchoolError.message("学校密码加密参数不正确，未提交密码。")
        }
        let capacity = input.count + kCCBlockSizeAES128
        var output = [UInt8](repeating: 0, count: capacity)
        var count = 0
        let status = key.withUnsafeBytes { keyBytes in
            vector.withUnsafeBytes { vectorBytes in
                input.withUnsafeBytes { inputBytes in
                    output.withUnsafeMutableBytes { outputBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count, vectorBytes.baseAddress, inputBytes.baseAddress, input.count, outputBytes.baseAddress, capacity, &count)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw SchoolError.message("密码加密未完成，未提交密码。") }
        return Data(output.prefix(count)).base64EncodedString()
    }
    static func loginFailure(_ html: String, username: String, password: String) throws -> SchoolError {
        let doc = try SwiftSoup.parse(html)
        var message = try doc.select("#showErrorTip,#msg,.errors,.login-error").text()
        if message.isEmpty {
            let regex = try NSRegularExpression(pattern: #"showTips\(\s*(['"])(.*?)\1\s*\)"#, options: [.dotMatchesLineSeparators])
            if let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let range = Range(match.range(at: 2), in: html) { message = String(html[range]) }
        }
        if message.contains("验证码") { return .captcha }
        if !username.isEmpty { message = message.replacingOccurrences(of: username, with: "[账号]") }
        if !password.isEmpty { message = message.replacingOccurrences(of: password, with: "[密码]") }
        message = message.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return .message(message.isEmpty ? "学校未完成认证，请检查账号密码后手动重试。" : "学校返回：\(String(message.prefix(300)))；不会自动重试。")
    }
    func login(username: String, password: String) async throws {
        let page = try await response(URL(string: School.login)!)
        guard page.response.statusCode == 200, let pageURL = page.response.url else { throw SchoolError.message("暂时无法打开学校认证服务。") }
        pendingLoginURL = pageURL
        var form = try Self.loginForm(page.html, url: pageURL)
        var query = URLComponents(string: "https://sfrz.gdgm.cn/authserver/needCaptcha.html")!
        query.queryItems = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "pwdEncrypt2", value: "pwdEncryptSalt"), URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000)))]
        let check = try await response(query.url!, referer: pageURL)
        guard check.response.statusCode == 200 else { throw SchoolError.message("无法确认验证码状态，未提交密码。") }
        let salt = try Self.captchaSalt(check.html, initial: form.salt)
        form.fields["username"] = username
        form.fields["password"] = try Self.encryptPassword(password, salt: salt)
        let result = try await response(form.action, fields: form.fields, referer: pageURL)
        if result.response.url?.host == "sfrz.gdgm.cn" || result.html.contains("casLoginForm") {
            pendingLoginURL = result.response.url ?? pageURL
            throw try Self.loginFailure(result.html, username: username, password: password)
        }
        guard result.response.statusCode == 200 else { throw SchoolError.message("学校认证未完成，请手动重试。") }
        _ = try await response(School.entry, referer: URL(string: "https://eportal.gdgm.cn")!)
        var authorization = URLComponents(string: "https://sfrz.gdgm.cn/authserver/login")!
        authorization.queryItems = [URLQueryItem(name: "service", value: School.host + "/jsxsd/sso.jsp")]
        _ = try await response(authorization.url!, referer: URL(string: School.host + "/jsxsd/sso.jsp")!)
        try await verify()
        pendingLoginURL = nil
    }
    func verify() async throws {
        let html = try await html(School.main)
        guard ["/jsxsd/", "xsMain_new.jsp", "ckgrxx"].contains(where: html.contains) else { throw SchoolError.message("尚未取得有效教务会话，请在网页继续完成授权。") }
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
        if let code = versionCode { return code > 21 }
        return version.compare("3.0.1", options: .numeric) == .orderedDescending
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
