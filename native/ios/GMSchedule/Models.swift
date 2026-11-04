import Foundation

enum School {
    static let host = "https://jw.gdgm.cn"
    static let main = URL(string: host + "/jsxsd/framework/xsMain.jsp")!
    static let desktop = URL(string: host + "/jsxsd/framework/xsMain_new.jsp")!
    static let schedule = URL(string: host + "/jsxsd/xskb/xskb_list.do")!
    static let entry = URL(string: "https://eportal.gdgm.cn/appShow?appId=5759540940956162")!
    static let login = "https://sfrz.gdgm.cn/authserver/login?service=https%3A%2F%2Feportal.gdgm.cn%2Flogin%3Fservice%3Dhttps%3A%2F%2Feportal.gdgm.cn%2Fnew%2Findex.html%3Fbrowser%3Dno"
    static let update = URL(string: "https://github.com/qiu7c/GMPluse-Release/releases/latest/download/latest.json")!
}

enum SchoolError: LocalizedError {
    case expired, unavailable, unrecognized, message(String)
    var errorDescription: String? {
        switch self {
        case .expired: return "教务会话已失效，请重新登录；已缓存的课表仍可查看。"
        case .unavailable: return "学校系统暂时不可用，已保留上次课表。"
        case .unrecognized: return "学校返回的页面不是完整课表，已保留上次结果。"
        case .message(let text): return text
        }
    }
}

struct Choice: Codable, Hashable, Identifiable {
    let value: String
    let label: String
    var id: String { value }
}

enum Campus: String, CaseIterable, Codable, Identifiable {
    case tianhe = "3589FB3E8AD246BCBAD7BB5C8710D078"
    case liwan = "0A10E5C18E814AEAA9456E91A7092394"
    case baiyun = "29637FA5710B46F3B01242A09D7E9CCD"
    var id: String { rawValue }
    var name: String {
        switch self { case .tianhe: return "天河"; case .liwan: return "荔湾"; case .baiyun: return "白云" }
    }
    var periods: [Period] {
        switch self {
        case .tianhe: return [(480,580),(600,700),(840,935),(955,1050),(1130,1230),(1240,1285)].map { Period(start: $0.0, end: $0.1) }
        case .liwan: return [(510,605),(625,720),(840,935),(955,1050),(1140,1235)].map { Period(start: $0.0, end: $0.1) }
        case .baiyun: return [(510,605),(625,720),(840,935),(955,1050),(1140,1235),(1240,1285)].map { Period(start: $0.0, end: $0.1) }
        }
    }
}

struct Period: Equatable {
    let start: Int
    let end: Int
    var text: String { String(format: "%02d:%02d\n%02d:%02d", start / 60, start % 60, end / 60, end % 60) }
}

struct Course: Codable, Hashable, Identifiable {
    var name: String
    var teacher = ""
    var room = ""
    var teachingClass = ""
    var rawWeeks = ""
    var section = ""
    var weeks: [Int] = []
    var day: Int
    var period: Int
    // A note follows the same teaching course across weeks and campuses, within one account.
    var noteKey: String { [name, teacher, teachingClass].joined(separator: "\u{1F}") }
    var id: String { [noteKey, room, rawWeeks, String(day), String(period)].joined(separator: "\u{1E}") }
    func occurs(in week: Int) -> Bool { weeks.isEmpty || weeks.contains(week) }
}

struct Schedule: Codable, Equatable {
    var courses: [Course]
    var terms: [Choice]
    var weeks: [Choice]
    var campuses: [Choice]
    var term: String
    var week: Int
    var campus: Campus
    var remark: String
    var fetchedAt = Date()
    func visibleCourses(week: Int) -> [Course] { courses.filter { $0.occurs(in: week) } }
}

struct Scope: Codable, Hashable {
    let account: String
    let term: String
    let campus: Campus
    let week: Int
}

struct CachedSchedule: Codable {
    let scope: Scope
    let schedule: Schedule
}

struct TermCalendar: Codable {
    let week: Int
    let total: Int
    let date: Date
    var firstMonday: Date {
        let monday = SchoolClock.monday(of: date)
        return SchoolClock.calendar.date(byAdding: .day, value: -(week - 1) * 7, to: monday)!
    }
    func week(on date: Date) -> Int {
        SchoolClock.calendar.dateComponents([.day], from: firstMonday, to: SchoolClock.calendar.startOfDay(for: date)).day! / 7 + 1
    }
}

enum SchoolClock {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        value.firstWeekday = 2
        return value
    }
    static func monday(of date: Date) -> Date {
        let day = calendar.startOfDay(for: date)
        let offset = (calendar.component(.weekday, from: day) + 5) % 7
        return calendar.date(byAdding: .day, value: -offset, to: day)!
    }
    static func date(firstMonday: Date, week: Int, day: Int, minute: Int) -> Date {
        calendar.date(byAdding: .minute, value: minute, to: calendar.date(byAdding: .day, value: (week - 1) * 7 + day - 1, to: firstMonday)!)!
    }
}

struct ProfileField: Codable, Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

struct ChangeSummary {
    let added: Int
    let removed: Int
    static func compare(_ previous: CachedSchedule?, _ current: CachedSchedule) -> ChangeSummary? {
        guard let previous = previous, previous.scope == current.scope else { return nil }
        let old = Set(previous.schedule.courses)
        let new = Set(current.schedule.courses)
        return ChangeSummary(added: new.subtracting(old).count, removed: old.subtracting(new).count)
    }
}

struct Reminder: Equatable {
    let id: String
    let date: Date
    let course: Course
}

enum ReminderPlan {
    static func make(entries: [CachedSchedule], account: String, term: String, campus: Campus, firstMonday: Date, minutes: Int, now: Date) -> [Reminder] {
        var results: [String: Reminder] = [:]
        for entry in entries where entry.scope.account == account && entry.scope.term == term && entry.scope.campus == campus {
            for course in entry.schedule.visibleCourses(week: entry.scope.week) where course.period <= campus.periods.count {
                let date = SchoolClock.date(firstMonday: firstMonday, week: entry.scope.week, day: course.day, minute: campus.periods[course.period - 1].start - minutes)
                if date > now {
                    let id = "gm.\(entry.scope.week).\(course.id)"
                    results[id] = Reminder(id: id, date: date, course: course)
                }
            }
        }
        return Array(results.values.sorted { $0.date < $1.date }.prefix(60))
    }
}
