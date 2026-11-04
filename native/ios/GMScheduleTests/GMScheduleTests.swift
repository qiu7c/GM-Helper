import XCTest
@testable import GMSchedule

final class GMScheduleTests: XCTestCase {
    private func fixture(body: String = "", week: Int = 7, campus: Campus = .tianhe) -> String {
        """
        <select id="xnxq01id"><option value="2026-2027-1">本学期</option></select>
        <select id="zc"><option selected value="\(week)">第\(week)周</option></select>
        <select id="kbjcmsid"><option selected value="\(campus.rawValue)">校区</option></select>
        <table id="kbtable"><tr><th>星期</th></tr><tr><th>第一大节</th><td>\(body)</td>\(String(repeating: "<td></td>", count: 6))</tr></table>
        """
    }
    private func makeStore() -> (LocalStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "tests." + UUID().uuidString)!
        return (LocalStore(defaults: defaults), defaults)
    }
    func testWeekRangesAndParity() {
        XCTAssertEqual(SchoolHTML.weeks("1-8(单周)[01-02节]"), [1,3,5,7])
        XCTAssertEqual(SchoolHTML.weeks("2-6,10(双周)"), [2,4,6,10])
        XCTAssertEqual(SchoolHTML.weeks("4,4,7(周)"), [4,7])
    }
    func testDetailedMultipleCoursesAndTeachingClass() throws {
        let body = "<div class='kbcontent'>数学(班A)<br><font title='老师'>甲</font><br><font title='教室'>A101</font><font title='周次(节次)'>1-9(单周)[01-02节]</font><br><br>英语<br><font title='老师'>乙</font></div><div class='kbcontent sykb2'>不应出现</div>"
        let result = try SchoolHTML.schedule(fixture(body: body))
        XCTAssertEqual(result.courses.count, 2)
        XCTAssertEqual(result.courses.first?.room, "A101")
        XCTAssertEqual(result.courses.first?.section, "01-02节")
        XCTAssertEqual(result.visibleCourses(week: 8).count, 1)
    }
    func testTrueEmptyWeekIsValidButMissingTableIsNot() throws {
        XCTAssertTrue(try SchoolHTML.schedule(fixture()).courses.isEmpty)
        XCTAssertThrowsError(try SchoolHTML.schedule("<html>维护</html>"))
        XCTAssertThrowsError(try SchoolHTML.schedule("<table id=kbtable></table>"))
    }
    func testSessionsAndUnavailableRemainDistinct() {
        XCTAssertThrowsError(try SchoolHTML.check("请先登录系统", status: 200, url: School.schedule)) { XCTAssertTrue($0 is SchoolError) }
        XCTAssertThrowsError(try SchoolHTML.check("维护", status: 503, url: School.schedule)) {
            guard case SchoolError.unavailable = $0 else { return XCTFail("must preserve unavailable distinction") }
        }
    }
    func testCampusTimesAndLiwanNoSixth() {
        XCTAssertEqual(Campus.liwan.periods.count, 5)
        XCTAssertEqual(Campus.baiyun.periods[0].start, 510)
        XCTAssertEqual(Campus.tianhe.periods[0].start, 480)
    }
    func testCacheSixEntriesAndScopeIsolation() throws {
        let (store, _) = makeStore()
        for week in 1...8 {
            let result = try SchoolHTML.schedule(fixture(week: week))
            try store.put(CachedSchedule(scope: Scope(account: "synthetic-A", term: result.term, campus: result.campus, week: week), schedule: result))
        }
        XCTAssertEqual(store.entries.count, 6)
        XCTAssertNil(store.entry(Scope(account: "synthetic-A", term: "2026-2027-1", campus: .tianhe, week: 1)))
        XCTAssertNotNil(store.entry(Scope(account: "synthetic-A", term: "2026-2027-1", campus: .tianhe, week: 8)))
        XCTAssertNil(store.entry(Scope(account: "synthetic-B", term: "2026-2027-1", campus: .tianhe, week: 8)))
        store.clearCache(); XCTAssertTrue(store.entries.isEmpty)
    }
    func testChangesOnlyComparedInsideSameScope() throws {
        let schedule = try SchoolHTML.schedule(fixture())
        let scope = Scope(account: "A", term: schedule.term, campus: .tianhe, week: 7)
        let old = CachedSchedule(scope: scope, schedule: schedule)
        let other = CachedSchedule(scope: Scope(account: "A", term: schedule.term, campus: .tianhe, week: 8), schedule: schedule)
        XCTAssertNil(ChangeSummary.compare(old, other))
        var changed = schedule
        changed.courses.append(Course(name: "新增", day: 1, period: 1))
        XCTAssertEqual(ChangeSummary.compare(old, CachedSchedule(scope: scope, schedule: changed))?.added, 1)
    }
    func testNotesAreAccountIsolated() {
        let (store, _) = makeStore()
        let course = Course(name: "数学", day: 1, period: 1)
        store.setNote(account: "A", course: course, text: "带教材")
        XCTAssertEqual(store.note(account: "A", course: course), "带教材")
        XCTAssertEqual(store.note(account: "B", course: course), "")
    }
    func testCookieIdentityIncludesDomainAndPath() throws {
        let a = HTTPCookie(properties: [.name: "JSESSIONID", .value: "synthetic-a", .domain: "jw.gdgm.cn", .path: "/jsxsd"])!
        let b = HTTPCookie(properties: [.name: "JSESSIONID", .value: "synthetic-b", .domain: "sfrz.gdgm.cn", .path: "/authserver"])!
        let storage = HTTPCookieStorage.shared
        storage.setCookie(a); storage.setCookie(b)
        defer { storage.deleteCookie(a); storage.deleteCookie(b) }
        XCTAssertEqual(storage.cookies(for: School.schedule)?.first(where: { $0.name == "JSESSIONID" })?.value, "synthetic-a")
        XCTAssertEqual(storage.cookies(for: URL(string: School.login)!)?.first(where: { $0.name == "JSESSIONID" })?.value, "synthetic-b")
    }
    func testRemindersUseRealDatesFutureOnlyAndCap60() throws {
        let first = SchoolClock.calendar.date(from: DateComponents(year: 2026, month: 9, day: 7))!
        var entries: [CachedSchedule] = []
        for week in 1...3 {
            var schedule = try SchoolHTML.schedule(fixture(week: week))
            schedule.courses = (1...7).flatMap { day in (1...6).map { Course(name: "\(day)-\($0)", day: day, period: $0) } }
            entries.append(CachedSchedule(scope: Scope(account: "A", term: schedule.term, campus: .tianhe, week: week), schedule: schedule))
        }
        let plan = ReminderPlan.make(entries: entries, account: "A", term: "2026-2027-1", campus: .tianhe, firstMonday: first, minutes: 10, now: first)
        XCTAssertEqual(plan.count, 60)
        XCTAssertEqual(plan.first?.date, SchoolClock.date(firstMonday: first, week: 1, day: 1, minute: 470))
        XCTAssertTrue(plan.allSatisfy { $0.date > first })
        XCTAssertTrue(ReminderPlan.make(entries: entries, account: "B", term: "2026-2027-1", campus: .tianhe, firstMonday: first, minutes: 10, now: first).isEmpty)
    }
    func testCalendarUsesSchoolTimezone() throws {
        let calendar = try XCTUnwrap(SchoolHTML.calendar("<div id='li_showWeek'>第7周/20周</div><input id='rq' value='2026-10-21'>"))
        XCTAssertEqual(calendar.week, 7)
        XCTAssertEqual(SchoolClock.calendar.component(.weekday, from: calendar.firstMonday), 2)
        XCTAssertEqual(calendar.week(on: calendar.date), 7)
    }
    func testOlderPublicReleaseDoesNotPrompt() throws {
        let older = try JSONDecoder().decode(UpdateInfo.self, from: Data(#"{"version":"2.2.7","versionCode":19,"ipa":"https://example.com/old.ipa"}"#.utf8))
        XCTAssertFalse(older.newer)
        let newer = try JSONDecoder().decode(UpdateInfo.self, from: Data(#"{"version":"3.0.1","versionCode":21}"#.utf8))
        XCTAssertTrue(newer.newer)
    }
}
