import Foundation
import Security

enum Keychain {
    private static let service = "cn.gdgm.schedule.gdgmSchedule"
    static func read(_ key: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }
    static func write(_ key: String, _ data: Data?) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        guard let data = data else { return }
        var entry = query
        entry[kSecValueData as String] = data
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(entry as CFDictionary, nil)
        if status != errSecSuccess { throw SchoolError.message("无法安全保存登录凭据（\(status)）。") }
    }
}

struct Preferences: Codable {
    var account = ""
    var term = ""
    var campus = Campus.tianhe
    var week = 1
    var savePassword = false
    var autoLogin = false
    var reminders = false
    var reminderMinutes = 10
    var calendar: TermCalendar?
    var calendarTerm = ""
}

final class LocalStore {
    private let defaults: UserDefaults
    private(set) var entries: [CachedSchedule]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: "native.cache").flatMap { try? JSONDecoder().decode([CachedSchedule].self, from: $0) } ?? []
    }
    func preferences() -> Preferences {
        if let data = defaults.data(forKey: "native.preferences"), let value = try? JSONDecoder().decode(Preferences.self, from: data) { return value }
        var value = Preferences()
        value.account = defaults.string(forKey: "flutter.saved_username") ?? ""
        value.term = defaults.string(forKey: "flutter.last_term") ?? ""
        value.campus = Campus(rawValue: defaults.string(forKey: "flutter.last_campus") ?? "") ?? .tianhe
        // Old plaintext passwords / flat Cookie headers are deliberately not imported.
        return value
    }
    func save(_ value: Preferences) throws { defaults.set(try JSONEncoder().encode(value), forKey: "native.preferences") }
    func entry(_ scope: Scope) -> CachedSchedule? { entries.first { $0.scope == scope } }
    func latest(account: String) -> CachedSchedule? { entries.last { $0.scope.account == account } }
    func put(_ entry: CachedSchedule) throws {
        entries.removeAll { $0.scope == entry.scope }
        entries.append(entry)
        entries = Array(entries.suffix(6))
        defaults.set(try JSONEncoder().encode(entries), forKey: "native.cache")
    }
    func clearCache() { entries = []; defaults.removeObject(forKey: "native.cache"); defaults.removeObject(forKey: "flutter.schedule_cache_v1") }
    func note(account: String, course: Course) -> String { notes(account: account)[course.noteKey] ?? notes(account: account)["legacy.name:" + course.name] ?? "" }
    private func notes(account: String) -> [String: String] { defaults.dictionary(forKey: "native.notes." + account) as? [String: String] ?? [:] }
    func setNote(account: String, course: Course, text: String) {
        var values = notes(account: account)
        values[course.noteKey] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(values, forKey: "native.notes." + account)
    }
    func courseColorIndex(account: String, name: String) -> Int {
        let key = "native.courseColors." + account
        var values = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        if let index = values[name] { return index }
        let index = values.count % 8
        values[name] = index
        defaults.set(values, forKey: key)
        return index
    }
    func setCourseColor(account: String, name: String, index: Int) {
        let key = "native.courseColors." + account
        var values = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        values[name] = index
        defaults.set(values, forKey: key)
    }
    var hasLegacyNotes: Bool { defaults.string(forKey: "flutter.course_notes") != nil }
    func importLegacyNotes(into account: String) throws {
        guard let raw = defaults.string(forKey: "flutter.course_notes"), let data = raw.data(using: .utf8) else { return }
        let old = try JSONDecoder().decode([String: String].self, from: data)
        var values = notes(account: account)
        for (name, note) in old { values["legacy.name:" + name] = note }
        defaults.set(values, forKey: "native.notes." + account)
    }
    // Only import account-attributable data. Flutter's global course_notes has no account;
    // it is left untouched, rather than assigning another person's notes to the current user.
    func importLegacyCache() throws {
        guard !defaults.bool(forKey: "native.migratedCache") else { return }
        struct LegacyCourse: Decodable {
            let name: String; let teacher: String; let room: String; let teachingClass: String
            let rawWeeks: String; let sectionRange: String; let weeks: [Int]; let day: Int; let period: Int
        }
        struct LegacyEntry: Decodable {
            let courses: [LegacyCourse]; let terms: [Choice]; let weeks: [Choice]; let campuses: [Choice]
            let selectedTerm: String?; let selectedWeek: String?; let selectedCampus: String?; let remark: String?; let tableFound: Bool?
        }
        if let raw = defaults.string(forKey: "flutter.schedule_cache_v1"), let data = raw.data(using: .utf8) {
            let legacy = try JSONDecoder().decode([String: LegacyEntry].self, from: data)
            for (key, item) in legacy.sorted(by: { $0.key < $1.key }) {
                let parts = key.components(separatedBy: "|")
                guard parts.count == 4, !parts[0].isEmpty, let campus = Campus(rawValue: parts[2]), let week = Int(parts[3]), (1...60).contains(week), item.tableFound != false,
                      item.courses.allSatisfy({ (1...7).contains($0.day) && (1...6).contains($0.period) }) else { continue }
                let courses = item.courses.map { Course(name: $0.name, teacher: $0.teacher, room: $0.room, teachingClass: $0.teachingClass, rawWeeks: $0.rawWeeks, section: $0.sectionRange, weeks: $0.weeks, day: $0.day, period: $0.period) }
                let schedule = Schedule(courses: courses, terms: item.terms, weeks: item.weeks, campuses: item.campuses, term: parts[1], week: week, campus: campus, remark: item.remark ?? "")
                try put(CachedSchedule(scope: Scope(account: parts[0], term: parts[1], campus: campus, week: week), schedule: schedule))
            }
        }
        defaults.set(true, forKey: "native.migratedCache")
        defaults.removeObject(forKey: "flutter.saved_password")
        defaults.removeObject(forKey: "flutter.jw_cookie")
    }
}
