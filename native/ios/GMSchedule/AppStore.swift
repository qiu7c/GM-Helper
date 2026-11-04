import SwiftUI
import UserNotifications
import WebKit

@MainActor final class AppStore: ObservableObject {
    @Published var preferences: Preferences
    @Published var schedule: Schedule?
    @Published var profile: [ProfileField] = []
    @Published var status = "登录后即可同步学校课表"
    @Published var busy = false
    @Published var showLogin = false
    @Published private(set) var pendingLoginCookies: [HTTPCookie] = []
    @Published private(set) var pendingLoginURL: URL?
    var freshLogin = false
    @Published var logs: [String] = []
    @Published var update: UpdateInfo?
    @Published var change: String?
    let disk: LocalStore
    let client = SchoolClient()
    private var triedAutoLogin = false
    @Published private(set) var explicitlyLoggedOut = false
    private var started = false
    init(disk: LocalStore = LocalStore()) {
        self.disk = disk
        preferences = disk.preferences()
    }
    var scope: Scope { Scope(account: preferences.account, term: preferences.term, campus: preferences.campus, week: preferences.week) }
    var calendar: TermCalendar? { preferences.calendarTerm == preferences.term ? preferences.calendar : nil }
    var totalWeeks: Int { calendar?.total ?? max(schedule?.weeks.compactMap { Int($0.value) }.max() ?? 20, preferences.week) }
    var automaticLogin: Bool { preferences.autoLogin && !explicitlyLoggedOut && Keychain.read("password." + preferences.account) != nil }
    var savedPassword: String { Keychain.read("password." + preferences.account).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    func log(_ message: String) {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        logs.append(formatter.string(from: Date()) + " " + message)
        logs = Array(logs.suffix(100))
    }
    func persist() {
        do { try disk.save(preferences) } catch { status = "无法保存设置"; log("本地设置写入失败") }
    }
    func start() async {
        guard !started else { return }; started = true
        do {
            try disk.importLegacyCache()
            try client.restoreCookies()
        } catch { log("旧数据或凭据读取失败；可重新登录") }
        if let calendar = calendar { preferences.week = min(max(calendar.week(on: Date()), 1), calendar.total) }
        restoreCache()
        if !preferences.account.isEmpty { await refresh(followCurrentWeek: true) }
        if schedule == nil { await attemptAutoLogin() }
        do {
            let info = try await UpdateInfo.fetch()
            if info.newer && UserDefaults.standard.string(forKey: "native.announced") != info.version {
                update = info
                UserDefaults.standard.set(info.version, forKey: "native.announced")
            }
        } catch { log("启动更新检查未完成") }
    }
    func attemptAutoLogin() async {
        guard automaticLogin, !triedAutoLogin else { return }
        triedAutoLogin = true; freshLogin = false
        do { try await login(username: preferences.account, password: savedPassword, save: preferences.savePassword, auto: preferences.autoLogin) }
        catch SchoolError.captcha { showLogin = true }
        catch { report(error) }
    }
    func openLogin() {
        guard !busy else { return }
        pendingLoginCookies = []; pendingLoginURL = nil
        freshLogin = true; showLogin = true
    }
    func restoreCache() {
        schedule = disk.entry(scope)?.schedule
        if schedule == nil && preferences.term.isEmpty, let entry = disk.latest(account: preferences.account) {
            schedule = entry.schedule
            preferences.term = entry.scope.term
            preferences.week = entry.scope.week
            preferences.campus = entry.scope.campus
        }
        if let schedule = schedule { status = "已显示缓存 · " + schedule.fetchedAt.formatted(date: .abbreviated, time: .shortened) }
    }
    func select(week: Int? = nil, term: String? = nil, campus: Campus? = nil, followCurrentWeek: Bool = false) async {
        // Scope controls share this gate with refresh/logout: a running query owns its displayed scope.
        guard !busy else { return }
        if let week = week { preferences.week = week }
        if let term = term { preferences.term = term }
        if let campus = campus { preferences.campus = campus }
        persist(); restoreCache()
        await rebuildReminders()
        await refresh(followCurrentWeek: followCurrentWeek)
    }
    func refresh(followCurrentWeek: Bool = false) async {
        guard !busy, !explicitlyLoggedOut, !preferences.account.isEmpty else { return }
        busy = true
        var correctedWeek: Int?
        var requiresAutoLogin = false
        status = schedule == nil ? "正在获取课表…" : "已显示缓存，正在更新…"
        let requested = scope
        do {
            let result = try await client.schedule(term: requested.term, campus: requested.campus, week: requested.week)
            guard (requested.term.isEmpty || result.term == requested.term), result.week == requested.week, result.campus == requested.campus else {
                throw SchoolError.message("学校返回了不同的查询范围，未覆盖课表，请重新选择。")
            }
            let received = Scope(account: requested.account, term: result.term, campus: result.campus, week: result.week)
            let entry = CachedSchedule(scope: received, schedule: result)
            if let diff = ChangeSummary.compare(disk.entry(received), entry), diff.added + diff.removed + diff.changed > 0 {
                change = "本周课表有变化：新增 \(diff.added) 门，取消 \(diff.removed) 门，调整 \(diff.changed) 处。"
            }
            try disk.put(entry)
            schedule = result
            preferences.term = result.term
            status = result.courses.isEmpty ? "本周没有课程 · 已更新" : "已从学校更新"
            log("课表同步成功（第 \(result.week) 周，\(result.courses.count) 门）")
            // A successful timetable is useful even when optional desktop data fails.
            do {
                let desktop = try await client.desktop()
                profile = desktop.1
                if let cal = desktop.0, let currentTerm = result.terms.first?.value, result.term == currentTerm {
                    preferences.calendar = cal; preferences.calendarTerm = result.term
                    let current = min(max(cal.week(on: Date()), 1), cal.total)
                    if followCurrentWeek && current != requested.week { correctedWeek = current }
                }
            } catch {
                status += "；校历/学籍暂未更新"
                log("课表已更新，校历/学籍请求未完成")
            }
            persist()
            do { try client.persistCookies() }
            catch { status += "；会话未能保存"; log("会话安全存储写入失败") }
            await rebuildReminders()
        } catch {
            report(error)
            if case SchoolError.expired = error { requiresAutoLogin = true }
        }
        busy = false
        if requiresAutoLogin { await attemptAutoLogin(); return }
        if let current = correctedWeek {
            preferences.week = current; persist(); restoreCache()
            await refresh()
        }
    }
    func report(_ error: Error) {
        if let error = error as? SchoolError { status = error.localizedDescription }
        else if error is URLError { status = "网络连接未完成，请稍后重试；已保留缓存。" }
        else { status = "本次操作未完成，请重试；已保留缓存。" }
        log(status)
    }
    func login(username: String, password: String, save: Bool, auto: Bool) async throws {
        guard !busy else { throw SchoolError.message("当前同步尚未结束，请稍后登录。") }
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty && !password.isEmpty else { throw SchoolError.message("请输入学校账号和密码。") }
        triedAutoLogin = true
        pendingLoginCookies = []; pendingLoginURL = nil
        status = "正在安全登录学校…"
        busy = true
        do {
            defer { busy = false }
            let candidate = SchoolClient()
            do {
                try await candidate.login(username: account, password: password)
                let desktop = try await candidate.desktop()
                try adoptIdentity(candidate, fields: desktop.1, username: account, password: password, save: save, auto: auto)
            } catch {
                if case SchoolError.captcha = error {
                    pendingLoginCookies = candidate.cookies.cookies ?? []
                    pendingLoginURL = candidate.pendingLoginURL
                }
                report(error)
                throw error
            }
        }
        await rebuildReminders()
        await refresh(followCurrentWeek: true)
    }
    private func adoptIdentity(_ candidate: SchoolClient, fields: [ProfileField], username: String, password: String, save: Bool, auto: Bool) throws {
        let studentID = fields.first { ["学生编号", "学号"].contains($0.label) }?.value ?? ""
        guard !studentID.isEmpty else { throw SchoolError.message("尚未取得有效教务学号，请稍后重试登录。") }
        let previousAccount = preferences.account
        client.accept(candidate.cookies.cookies ?? [])
        preferences.account = studentID
        if previousAccount != studentID { profile = []; schedule = nil; preferences.term = ""; preferences.calendar = nil }
        preferences.savePassword = save && !password.isEmpty && username == studentID
        preferences.autoLogin = auto && preferences.savePassword
        try Keychain.write("password." + studentID, preferences.savePassword ? password.data(using: .utf8) : nil)
        try client.persistCookies()
        profile = fields
        explicitlyLoggedOut = false
        pendingLoginCookies = []; pendingLoginURL = nil
        persist(); showLogin = false
    }
    func completeLogin(cookies: [HTTPCookie], username: String, password: String, save: Bool, auto: Bool) async throws {
        guard !busy else { throw SchoolError.message("当前同步尚未结束，请稍后验证登录。") }
        busy = true
        do {
            defer { busy = false }
            // A failed account switch must leave the current account's Cookie jar untouched.
            // Candidate acceptance and verification use memory only; no Keychain writes occur here.
            let candidate = SchoolClient()
            candidate.accept(cookies)
            try await candidate.verify()
            let desktop = try await candidate.desktop()
            try adoptIdentity(candidate, fields: desktop.1, username: username, password: password, save: save, auto: auto)
        }
        // The verified login finishes its exclusive operation before refresh acquires the same gate.
        await rebuildReminders()
        await refresh(followCurrentWeek: true)
    }
    func logout() async {
        guard !busy else { return }
        explicitlyLoggedOut = true; triedAutoLogin = true
        pendingLoginCookies = []; pendingLoginURL = nil
        do { try client.clearCookies() } catch { report(error) }
        disk.clearCache(); schedule = nil; profile = []; change = nil
        preferences.reminders = false
        persist()
        await rebuildReminders()
        status = "已退出，课表缓存和待发提醒已清除；请点击登录重新连接，本次不会自动登录。"
        log("用户主动退出")
    }
    func note(_ course: Course) -> String { disk.note(account: preferences.account, course: course) }
    func courseColorIndex(course: Course) -> Int { disk.courseColorIndex(account: preferences.account, name: course.name) }
    func setCourseColor(course: Course, index: Int) {
        disk.setCourseColor(account: preferences.account, name: course.name, index: index)
        objectWillChange.send()
    }
    func saveNote(_ course: Course, text: String) { disk.setNote(account: preferences.account, course: course, text: text); objectWillChange.send() }
    func toggleReminders(_ enabled: Bool) async {
        do {
            if enabled {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                guard allowed else { throw SchoolError.message("通知权限未开启，可前往系统设置允许通知。") }
            }
            preferences.reminders = enabled; persist(); await rebuildReminders()
        } catch { preferences.reminders = false; persist(); report(error) }
    }
    func rebuildReminders() async {
        do {
            let plan: [Reminder]
            if preferences.reminders, let calendar = calendar {
                plan = ReminderPlan.make(entries: disk.entries, account: preferences.account, term: preferences.term, campus: preferences.campus, firstMonday: calendar.firstMonday, minutes: preferences.reminderMinutes, now: Date())
            } else { plan = [] }
            try await Notifications.replace(plan)
            if preferences.reminders { log("已安排 \(plan.count) 条本地提醒（仅已缓存课程）") }
        } catch { report(error) }
    }
    func checkUpdate() async {
        do { let info = try await UpdateInfo.fetch(); update = info; status = info.newer ? "发现新版本 \(info.version)" : "当前已是最新版本 3.0.1" }
        catch { status = "更新检查失败，请稍后重试"; log(status) }
    }
    func courseStatus(now: Date) -> String {
        guard let calendar = calendar else { return "校历尚未同步，刷新后显示当前与下节课程" }
        let currentWeek = calendar.week(on: now)
        let current = disk.entries.filter { $0.scope.account == preferences.account && $0.scope.term == preferences.term && $0.scope.campus == preferences.campus }
        var next: (Date, Course)?
        for entry in current where entry.scope.week >= currentWeek {
            for course in entry.schedule.visibleCourses(week: entry.scope.week) where course.period <= preferences.campus.periods.count {
                let period = preferences.campus.periods[course.period - 1]
                let start = SchoolClock.date(firstMonday: calendar.firstMonday, week: entry.scope.week, day: course.day, minute: period.start)
                let end = SchoolClock.date(firstMonday: calendar.firstMonday, week: entry.scope.week, day: course.day, minute: period.end)
                if start <= now && now < end { return "正在上课 · \(course.name) · \(course.room)" }
                if start > now && (next == nil || start < next!.0) { next = (start, course) }
            }
        }
        if let next = next { return "下节 · \(next.1.name) · \(next.0.formatted(date: .abbreviated, time: .shortened)) · \(next.1.room)" }
        return "已缓存课表中暂无接下来的课程"
    }
}
