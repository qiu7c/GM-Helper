import SwiftUI

@main @MainActor struct GMScheduleApp: App {
    @StateObject private var model: AppStore
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-login") || ProcessInfo.processInfo.arguments.contains("--preview-timetable") || ProcessInfo.processInfo.arguments.contains("--preview-settings") {
            let id = "GMSchedule.preview." + UUID().uuidString
            let disk = LocalStore(defaults: UserDefaults(suiteName: id)!)
            let preview = AppStore(disk: disk)
            Self.preparePreview(preview)
            _model = StateObject(wrappedValue: preview)
            return
        }
        #endif
        _model = StateObject(wrappedValue: AppStore())
    }
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--preview-login") { LoginView(preview: true) }
                else { MainView() }
                #else
                MainView()
                #endif
            }.environmentObject(model).tint(Brand.blue)
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--preview-login") || ProcessInfo.processInfo.arguments.contains("--preview-timetable") || ProcessInfo.processInfo.arguments.contains("--preview-settings") { return }
                    #endif
                    await model.start()
                }
        }
    }
    #if DEBUG
    private static func preparePreview(_ model: AppStore) {
        model.preferences.account = ""; model.preferences.term = "2026-2027-1"; model.preferences.week = 9
        model.preferences.campus = .tianhe; model.showLogin = false
        model.preferences.calendarTerm = model.preferences.term
        model.preferences.calendar = TermCalendar(week: 9, total: 20, date: Date())
        let courses = [
            Course(name: "大学英语", teacher: "示例教师", room: "博学楼 A302", rawWeeks: "1-16周", day: 1, period: 1),
            Course(name: "高等数学", teacher: "示例教师", room: "明德楼 B205", rawWeeks: "1-16周", day: 2, period: 1),
            Course(name: "程序设计", teacher: "示例教师", room: "实训楼 401", rawWeeks: "1-16周", day: 4, period: 1),
            Course(name: "计算机网络", teacher: "示例教师", room: "博学楼 A206", rawWeeks: "1-16周", day: 1, period: 2),
            Course(name: "大学体育", teacher: "示例教师", room: "体育馆", rawWeeks: "1-16周", day: 3, period: 2),
            Course(name: "视觉设计", teacher: "示例教师", room: "创意楼 502", rawWeeks: "1-16周", day: 5, period: 2),
            Course(name: "思想道德与法治", teacher: "示例教师", room: "明德楼 B102", rawWeeks: "1-16周", day: 2, period: 3),
            Course(name: "职业发展", teacher: "示例教师", room: "博学楼 A108", rawWeeks: "1-16周", day: 4, period: 3),
            Course(name: "劳动教育", teacher: "示例教师", room: "综合楼 201", rawWeeks: "1-16周", day: 3, period: 4)
        ]
        model.schedule = Schedule(courses: courses, terms: [Choice(value: model.preferences.term, label: "2026—2027 第一学期")], weeks: [], campuses: [], term: model.preferences.term, week: 9, campus: .tianhe, remark: "演示课表 · 所有课程均为虚构示例")
        if let schedule = model.schedule {
            try? model.disk.put(CachedSchedule(scope: model.scope, schedule: schedule))
            for (index, course) in courses.enumerated() { model.setCourseColor(course: course, index: index < 8 ? index : 0) }
        }
        model.status = "演示课表 · 虚构课程"
    }
    #endif
}

enum Brand {
    static let blue = Color(red: 0.19, green: 0.43, blue: 0.78)
    static let teal = Color(red: 0.20, green: 0.68, blue: 0.64)
    static let gradient = LinearGradient(colors: [blue, teal], startPoint: .leading, endPoint: .trailing)
    static let ink = Color.primary
    static let surface = Color(UIColor.secondarySystemGroupedBackground)
    static let field = Color(UIColor.tertiarySystemGroupedBackground)
    static let courseColors: [Color] = [Color(red: 0.29, green: 0.53, blue: 0.83), Color(red: 0.19, green: 0.62, blue: 0.65), Color(red: 0.58, green: 0.46, blue: 0.76), Color(red: 0.85, green: 0.49, blue: 0.44), Color(red: 0.73, green: 0.58, blue: 0.28), Color(red: 0.41, green: 0.47, blue: 0.72), Color(red: 0.34, green: 0.62, blue: 0.45), Color(red: 0.76, green: 0.43, blue: 0.60)]
}

struct BrandMark: View {
    var size: CGFloat = 48
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3).fill(Brand.gradient)
            Image(systemName: "graduationcap.fill").font(.system(size: size * 0.43, weight: .medium)).foregroundColor(.white)
            Circle().fill(Color.white.opacity(0.3)).frame(width: size * 0.22).offset(x: size * 0.32, y: -size * 0.29)
        }.frame(width: size, height: size).shadow(color: Brand.blue.opacity(0.17), radius: 12, y: 5).accessibilityHidden(true)
    }
}

struct BrandCard<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(title).font(.subheadline.bold()).foregroundColor(Brand.ink)
            content
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Brand.surface).cornerRadius(22)
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Brand.blue.opacity(0.06), lineWidth: 1))
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppStore
    @State private var selectedTab: Int
    init() {
        #if DEBUG
        _selectedTab = State(initialValue: ProcessInfo.processInfo.arguments.contains("--preview-settings") ? 2 : 0)
        #else
        _selectedTab = State(initialValue: 0)
        #endif
    }
    var body: some View {
        ZStack {
            AppBackground()
            TimetableView().opacity(selectedTab == 0 ? 1 : 0).allowsHitTesting(selectedTab == 0).accessibilityHidden(selectedTab != 0)
            ProfileView().opacity(selectedTab == 1 ? 1 : 0).allowsHitTesting(selectedTab == 1).accessibilityHidden(selectedTab != 1)
            SettingsView().opacity(selectedTab == 2 ? 1 : 0).allowsHitTesting(selectedTab == 2).accessibilityHidden(selectedTab != 2)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 5) {
                tab("课表", icon: "calendar", index: 0)
                tab("我的", icon: "person.crop.circle", index: 1)
                tab("设置", icon: "slider.horizontal.3", index: 2)
            }.padding(7).frame(maxWidth: 360).background(.ultraThinMaterial).clipShape(Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.08), radius: 18, y: 5)
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 10)
        }
        .sheet(isPresented: $model.showLogin) { LoginView().environmentObject(model) }
        .alert("课表变动", isPresented: Binding(get: { model.change != nil }, set: { if !$0 { model.change = nil } })) {
            Button("知道了") { model.change = nil }
        } message: { Text(model.change ?? "") }
    }
    private func tab(_ title: String, icon: String, index: Int) -> some View {
        Button { selectedTab = index } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 18, weight: .medium))
                Text(title).font(.system(size: 10, weight: selectedTab == index ? .semibold : .medium))
            }.foregroundColor(selectedTab == index ? Brand.blue : .secondary)
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(selectedTab == index ? Brand.blue.opacity(0.11) : Color.clear).clipShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selectedTab == index ? .isSelected : [])
    }
}

struct AppBackground: View {
    var body: some View { Color(UIColor.systemGroupedBackground).ignoresSafeArea() }
}

struct TimetableView: View {
    @EnvironmentObject var model: AppStore
    @State private var selectedCourse: Course?
    @State private var showDates = false
    @State private var date = Date()
    @State private var sharedImage: UIImage?
    @State private var share = false
    var body: some View {
        NavigationView {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.schedule?.terms.first(where: { $0.value == model.preferences.term })?.label ?? "我的课表").font(.subheadline.weight(.semibold)).foregroundColor(Brand.ink).lineLimit(1)
                        Text(model.preferences.campus.name + "校区").font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 3)
                    Button { Task { await model.select(week: max(1, model.preferences.week - 1)) } } label: { Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)).frame(width: 30, height: 36) }.disabled(model.preferences.week <= 1 || model.busy)
                    Button { date = Date(); showDates = true } label: {
                        HStack(spacing: 5) { Text("第 \(model.preferences.week) 周").font(.system(size: 15, weight: .semibold, design: .rounded)); Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
                            .foregroundColor(Brand.ink).padding(.horizontal, 12).frame(height: 36).background(Brand.surface).clipShape(Capsule())
                    }
                    Button { Task { await model.select(week: min(model.totalWeeks, model.preferences.week + 1)) } } label: { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).frame(width: 30, height: 36) }.disabled(model.preferences.week >= model.totalWeeks || model.busy)
                }.padding(.horizontal, 16).padding(.top, 4)
                TimelineView(.periodic(from: Date(), by: 30)) { context in
                    Label(model.courseStatus(now: context.date), systemImage: "clock").font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18)
                }
                HStack(spacing: 5) {
                    if model.busy { ProgressView().scaleEffect(0.7).frame(width: 14) }
                    else { Circle().fill(Brand.teal).frame(width: 5, height: 5) }
                    Text(model.status).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if !model.preferences.account.isEmpty { Button { Task { await model.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise").font(.caption2.weight(.medium)) }.disabled(model.busy) }
                }.padding(.horizontal, 22)
                if let info = model.update, info.newer { HStack { Text("新版本 \(info.version)"); Spacer(); if let url = info.download { Link("查看下载", destination: url) } }.font(.caption).padding(8).background(Color.accentColor.opacity(0.12)) }
                if let schedule = model.schedule {
                    GeometryReader { geometry in
                        TimetableGrid(schedule: schedule, week: model.preferences.week, calendar: model.calendar, note: { model.note($0) }, colorIndex: { model.courseColorIndex(course: $0) }, select: { selectedCourse = $0 }, width: geometry.size.width - 16, compact: true, availableHeight: geometry.size.height - 8)
                            .padding(.horizontal, 8).padding(.bottom, 8)
                    }
                    if !schedule.remark.isEmpty { Text(schedule.remark).font(.caption2).foregroundColor(.secondary).lineLimit(1).padding(.horizontal) }
                } else {
                    Spacer()
                    BrandMark(size: 56)
                    Text(model.preferences.account.isEmpty ? "登录查看课表" : "这一周，等待同步").font(.headline).foregroundColor(Brand.ink)
                    Text(model.preferences.account.isEmpty ? "登录后即可查看课程、添加备注与课前提醒" : "连接学校，获取这一周的最新课程").font(.caption).foregroundColor(.secondary)
                    Button { model.openLogin() } label: { Label("连接校园账号", systemImage: "arrow.right").padding(.horizontal, 24).padding(.vertical, 14).foregroundColor(.white).background(Brand.gradient).clipShape(Capsule()) }.padding(.top, 10)
                    Spacer()
                }
            }
            .background(AppBackground())
            .navigationTitle("广贸课表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("本周") {
                        if let calendar = model.calendar { Task { await model.select(week: min(max(calendar.week(on: Date()), 1), calendar.total), followCurrentWeek: true) } }
                        else { model.status = "请先刷新同步当前学期校历" }
                    }.disabled(model.busy)
                }
                ToolbarItem(placement: .navigationBarTrailing) { Button { export() } label: { Image(systemName: "square.and.arrow.up") }.disabled(model.schedule == nil) }
            }
            .sheet(item: $selectedCourse) { course in CourseDetail(course: course).environmentObject(model) }
            .sheet(isPresented: $share) { if let image = sharedImage { ShareSheet(image: image) } }
            .sheet(isPresented: $showDates) {
                NavigationView {
                    VStack {
                        if let calendar = model.calendar {
                            DatePicker("选择日期跳转周次", selection: $date, displayedComponents: .date).datePickerStyle(.graphical)
                            Button("跳到第 \(min(max(calendar.week(on: date), 1), calendar.total)) 周") {
                                showDates = false
                                Task { await model.select(week: min(max(calendar.week(on: date), 1), calendar.total)) }
                            }.buttonStyle(.borderedProminent).disabled(model.busy)
                        } else { Text("当前学期校历尚未同步，请联网刷新。") }
                        Picker("周次", selection: Binding(get: { model.preferences.week }, set: { value in showDates = false; Task { await model.select(week: value) } })) {
                            ForEach(1...model.totalWeeks, id: \.self) { Text("第 \($0) 周").tag($0) }
                        }.pickerStyle(.wheel).disabled(model.busy)
                    }.padding().navigationTitle("跳转课表").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showDates = false } } }
                }.navigationViewStyle(.stack)
            }
        }.navigationViewStyle(.stack)
    }
    @MainActor private func export() {
        guard let schedule = model.schedule else { return }
        let content = VStack(spacing: 20) {
            Text("广贸课表 · \(schedule.term) · 第 \(model.preferences.week) 周").font(.title.bold())
            Text("\(schedule.campus.name)校区").foregroundColor(.secondary)
            TimetableGrid(schedule: schedule, week: model.preferences.week, calendar: model.calendar, note: { model.note($0) }, colorIndex: { model.courseColorIndex(course: $0) }, select: { _ in })
            Text(schedule.remark).font(.caption)
        }.padding(24).frame(width: 1120).background(Color.white).environment(\.colorScheme, .light)
        let controller = UIHostingController(rootView: content)
        controller.overrideUserInterfaceStyle = .light
        controller.view.bounds = CGRect(x: 0, y: 0, width: 1120, height: 2000)
        let size = controller.view.systemLayoutSizeFitting(CGSize(width: 1120, height: UIView.layoutFittingCompressedSize.height), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        controller.view.bounds = CGRect(origin: .zero, size: size)
        controller.view.backgroundColor = .white
        controller.view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(size: size)
        sharedImage = renderer.image { context in controller.view.layer.render(in: context.cgContext) }
        share = true
    }
}

struct TimetableGrid: View {
    let schedule: Schedule
    let week: Int
    let calendar: TermCalendar?
    let note: (Course) -> String
    let colorIndex: (Course) -> Int
    let select: (Course) -> Void
    var width: CGFloat = 1072
    var compact = false
    var availableHeight: CGFloat = 0
    @Environment(\.colorScheme) private var scheme
    private let days = ["一", "二", "三", "四", "五", "六", "日"]
    private var gap: CGFloat { compact ? 3 : 6 }
    private var timeWidth: CGFloat { compact ? 27 : 48 }
    private var columnWidth: CGFloat { (width - timeWidth - gap * 7) / 7 }
    var body: some View {
        VStack(spacing: compact ? 6 : 10) {
            HStack(spacing: gap) {
                VStack(spacing: 3) { Text("\(month)月").font(.system(size: compact ? 10 : 14, weight: .semibold)); Text("时间").font(.system(size: compact ? 8 : 10)).foregroundColor(.secondary) }.frame(width: timeWidth, height: compact ? 46 : 70)
                ForEach(1...7, id: \.self) { day in
                    VStack(spacing: 5) {
                        Text(days[day - 1]).font(.system(size: compact ? 11 : 15, weight: .medium))
                        if let calendar = calendar {
                            let date = SchoolClock.date(firstMonday: calendar.firstMonday, week: week, day: day, minute: 0)
                            Text("\(SchoolClock.calendar.component(.day, from: date))").font(.system(size: compact ? 14 : 20, weight: .semibold, design: .rounded))
                        }
                    }.frame(width: columnWidth, height: compact ? 46 : 70)
                        .foregroundColor(isToday(day) ? .white : Brand.ink)
                        .background(LinearGradient(colors: isToday(day) ? [Brand.blue, Brand.teal] : [Brand.surface.opacity(0.68)], startPoint: .topLeading, endPoint: .bottomTrailing)).cornerRadius(compact ? 13 : 18)
                }
            }
            ForEach(1...schedule.campus.periods.count, id: \.self) { period in
                let periodCourses = schedule.visibleCourses(week: week).filter { $0.period == period }
                let stackCount = max(1, (1...7).map { day in periodCourses.filter { $0.day == day }.count }.max() ?? 1)
                let cardHeight: CGFloat = 180
                let rowHeight = compact ? (availableHeight - 46 - CGFloat(schedule.campus.periods.count) * 6) / CGFloat(schedule.campus.periods.count) : CGFloat(stackCount) * cardHeight + CGFloat(stackCount - 1) * 4
                HStack(alignment: .top, spacing: gap) {
                    VStack(spacing: compact ? 2 : 5) {
                        Text(String(format: "%02d", period)).font(.system(size: compact ? 11 : 19, weight: .semibold, design: .rounded)).foregroundColor(Brand.ink)
                        Text(schedule.campus.periods[period - 1].text).font(.system(size: compact ? 7.5 : 10, design: .rounded)).foregroundColor(.secondary).lineSpacing(compact ? 1 : 3)
                    }.frame(width: timeWidth).padding(.top, compact ? 3 : 12)
                    ForEach(1...7, id: \.self) { day in
                        let cellCourses = periodCourses.filter { $0.day == day }
                        VStack(spacing: 4) {
                            if compact {
                                if let first = cellCourses.first {
                                    if cellCourses.count == 1 {
                                        courseCard(first, height: rowHeight).contentShape(Rectangle()).onTapGesture { select(first) }.onLongPressGesture { select(first) }
                                    } else {
                                        Menu {
                                            ForEach(cellCourses) { course in
                                                Button(course.name + (course.room.isEmpty ? "" : " · " + course.room)) { select(course) }
                                            }
                                        } label: {
                                            courseCard(first, height: rowHeight, additional: cellCourses.count - 1)
                                        }.buttonStyle(.plain).accessibilityLabel("此节共 \(cellCourses.count) 门课程，点按选择")
                                    }
                                }
                            } else {
                                ForEach(cellCourses) { course in
                                    courseCard(course, height: cardHeight).contentShape(Rectangle()).onTapGesture { select(course) }.onLongPressGesture { select(course) }
                                }
                            }
                        }.frame(width: columnWidth, height: rowHeight, alignment: .top)
                            .background(isToday(day) ? Brand.blue.opacity(0.035) : Brand.surface.opacity(0.3)).cornerRadius(compact ? 11 : 16)
                    }
                }.frame(height: rowHeight, alignment: .top)
            }
        }.frame(width: width).foregroundColor(Brand.ink)
    }
    private func courseCard(_ course: Course, height: CGFloat, additional: Int = 0) -> some View {
        let color = Brand.courseColors[colorIndex(course)]
        return VStack(alignment: .leading, spacing: compact ? 3 : 6) {
            if !compact { Capsule().fill(color).frame(width: 22, height: 3) }
            Text(course.name).font(.system(size: compact ? 10 : 14, weight: .semibold)).foregroundColor(scheme == .dark ? color.opacity(0.95) : Brand.ink).lineLimit(compact ? (height >= 72 ? 3 : 2) : 3).fixedSize(horizontal: false, vertical: true)
            if !course.room.isEmpty { Text(course.room).font(.system(size: compact ? 8 : 11)).foregroundColor(scheme == .dark ? .white.opacity(0.72) : color).lineLimit(compact ? 1 : 2).padding(.trailing, additional > 0 ? 12 : 0) }
            if !compact && !course.teacher.isEmpty { Text(course.teacher).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1) }
            if !compact && !note(course).isEmpty { Image(systemName: "pencil.line").font(.system(size: 11)).foregroundColor(color).accessibilityLabel("有课程备注") }
            Spacer(minLength: 0)
        }.padding(.horizontal, compact ? 4 : 10).padding(.vertical, compact ? 5 : 12).frame(width: columnWidth, height: height, alignment: .topLeading).clipped()
            .background(color.opacity(scheme == .dark ? 0.20 : 0.13)).cornerRadius(compact ? 8 : 16)
            .overlay(RoundedRectangle(cornerRadius: compact ? 8 : 16).stroke(color.opacity(0.13), lineWidth: 0.7))
            .overlay(alignment: .bottomTrailing) {
                if additional > 0 { Text("+\(additional)").font(.system(size: 7, weight: .semibold)).foregroundColor(color).padding(3).background(Brand.surface.opacity(0.8)).cornerRadius(4).padding(2) }
            }
    }
    private var month: Int {
        let date = calendar.map { SchoolClock.date(firstMonday: $0.firstMonday, week: week, day: 1, minute: 0) } ?? Date()
        return SchoolClock.calendar.component(.month, from: date)
    }
    private func isToday(_ day: Int) -> Bool {
        guard let calendar = calendar else { return false }
        let date = SchoolClock.date(firstMonday: calendar.firstMonday, week: week, day: day, minute: 0)
        return SchoolClock.calendar.isDate(date, inSameDayAs: Date())
    }
}

struct CourseDetail: View {
    @EnvironmentObject var model: AppStore
    @Environment(\.dismiss) private var dismiss
    let course: Course
    @State private var note = ""
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 12) {
                        Image(systemName: "books.vertical.fill").font(.system(size: 30)).foregroundColor(Brand.courseColors[model.courseColorIndex(course: course)]).padding(20).background(Brand.surface).cornerRadius(24)
                        Text(course.name).font(.title2.bold()).foregroundColor(Brand.ink).multilineTextAlignment(.center)
                        Text("周\(["一","二","三","四","五","六","日"][course.day - 1]) · 第 \(course.period) 大节").font(.subheadline).foregroundColor(.secondary)
                    }.padding(.vertical, 14)
                    BrandCard("课程信息") {
                        detail("教师", course.teacher); Divider(); detail("教室", course.room); Divider()
                        detail("教学班", course.teachingClass); Divider(); detail("周次与节次", course.rawWeeks)
                    }
                    BrandCard("课程颜色") {
                        HStack {
                            ForEach(0..<Brand.courseColors.count, id: \.self) { index in
                                Button { model.setCourseColor(course: course, index: index) } label: {
                                    Circle().fill(Brand.courseColors[index]).frame(width: 28, height: 28).overlay(Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(.white).opacity(model.courseColorIndex(course: course) == index ? 1 : 0))
                                }.buttonStyle(.plain).accessibilityLabel("课程颜色 \(index + 1)")
                                if index < 7 { Spacer(minLength: 2) }
                            }
                        }
                    }
                    BrandCard("课程备注") {
                        Text("仅自己可见，按当前账号保存").font(.caption).foregroundColor(.secondary)
                        TextEditor(text: $note).frame(minHeight: 130).padding(8).background(Brand.field).cornerRadius(12)
                    }
                }.padding(20)
            }.background(AppBackground()).navigationTitle("课程详情").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { model.saveNote(course, text: note); dismiss() }.font(.body.bold()) }
                }.onAppear { note = model.note(course) }
        }.navigationViewStyle(.stack)
    }
    private func detail(_ label: String, _ text: String) -> some View { HStack(alignment: .top, spacing: 18) { Text(label).font(.subheadline).foregroundColor(.secondary); Spacer(minLength: 0); Text(text.isEmpty ? "—" : text).font(.subheadline.weight(.medium)).multilineTextAlignment(.trailing) } }
}

struct ProfileView: View {
    @EnvironmentObject var model: AppStore
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    HStack(spacing: 16) {
                        BrandMark(size: 42)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(model.preferences.account.isEmpty ? "尚未登录" : "校园账号").font(.headline).foregroundColor(Brand.ink)
                            Text(model.preferences.account.isEmpty ? "登录后同步课表与学籍" : model.explicitlyLoggedOut ? "当前已退出登录" : model.preferences.account).font(.subheadline).foregroundColor(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Brand.surface).cornerRadius(20)
                    Button { model.openLogin() } label: {
                        HStack { Label(model.preferences.account.isEmpty ? "登录校园账号" : "登录 / 切换账号", systemImage: "person.crop.circle.badge.checkmark"); Spacer(); Image(systemName: "arrow.up.right") }.font(.subheadline.weight(.semibold)).foregroundColor(.white).padding(19).background(Brand.gradient).cornerRadius(19)
                    }.disabled(model.busy)
                    BrandCard("学籍信息") {
                        if model.profile.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("你的校园身份").font(.subheadline.weight(.medium))
                                Text("登录并刷新后，学籍信息将显示在这里。").font(.caption).foregroundColor(.secondary)
                            }.padding(.vertical, 8)
                        }
                        ForEach(model.profile) { item in
                            HStack(alignment: .top) { Text(item.label).font(.subheadline).foregroundColor(.secondary); Spacer(); Text(item.value).font(.subheadline.weight(.medium)).multilineTextAlignment(.trailing) }
                            if item.id != model.profile.last?.id { Divider() }
                        }
                        Button { Task { await model.refresh() } } label: { Label("刷新学籍与课表", systemImage: "arrow.clockwise").font(.subheadline.weight(.medium)) }.disabled(model.busy || model.preferences.account.isEmpty)
                    }
                    if model.disk.hasLegacyNotes && !model.preferences.account.isEmpty {
                        BrandCard("旧版备注") {
                            Text("确认旧版备注属于自己后，可导入到当前账号。").font(.caption).foregroundColor(.secondary)
                            Button("导入我的旧版备注") {
                                do { try model.disk.importLegacyNotes(into: model.preferences.account); model.status = "旧版备注已导入当前账号"; model.objectWillChange.send() }
                                catch { model.report(error) }
                            }.font(.subheadline)
                        }
                    }
                    if !model.preferences.account.isEmpty {
                        Button(role: .destructive) { Task { await model.logout() } } label: { Label("退出登录并清除课表缓存", systemImage: "rectangle.portrait.and.arrow.right").font(.subheadline).frame(maxWidth: .infinity).padding(18).background(Brand.surface).cornerRadius(19) }.disabled(model.busy)
                    }
                    Text("GMPluse · 广贸课表").font(.caption2).foregroundColor(.secondary).padding(.vertical, 12)
                }.padding(20)
            }.background(AppBackground()).navigationTitle("我的").navigationBarTitleDisplayMode(.inline)
        }.navigationViewStyle(.stack)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppStore
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                BrandCard("课表") {
                    if let schedule = model.schedule {
                        HStack { Text("学期").font(.subheadline); Spacer(minLength: 8); Picker("学期", selection: Binding(get: { model.preferences.term }, set: { value in Task { await model.select(term: value) } })) { ForEach(schedule.terms) { Text($0.label).tag($0.value) } }.disabled(model.busy).labelsHidden().pickerStyle(.menu) }
                    }
                    HStack { Text("校区").font(.subheadline); Spacer(minLength: 8); Picker("校区", selection: Binding(get: { model.preferences.campus }, set: { value in Task { await model.select(campus: value) } })) { ForEach(Campus.allCases) { Text($0.name).tag($0) } }.disabled(model.busy).labelsHidden().pickerStyle(.menu) }
                }
                BrandCard("课前提醒") {
                    Toggle("本地课前通知", isOn: Binding(get: { model.preferences.reminders }, set: { value in Task { await model.toggleReminders(value) } }))
                    HStack { Text("提前").font(.subheadline); Spacer(minLength: 8); Picker("提前", selection: $model.preferences.reminderMinutes) { ForEach([0,5,10,15,20,30], id: \.self) { Text("\($0) 分钟").tag($0) } }.onChange(of: model.preferences.reminderMinutes) { _ in model.persist(); Task { await model.rebuildReminders() } }.labelsHidden().pickerStyle(.menu) }
                    Text("只安排已同步并缓存的课程，最多未来 60 条。关闭 App 后由 iOS 在指定日期通知；不会自动抓取学校的新课表，请定期打开刷新。需要已同步当前学期校历。").font(.caption).foregroundColor(.secondary)
                    Button("打开系统通知设置") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                }
                BrandCard("登录偏好") {
                    Toggle("保存密码", isOn: $model.preferences.savePassword).onChange(of: model.preferences.savePassword) { enabled in
                        if !enabled { model.preferences.autoLogin = false; do { try Keychain.write("password." + model.preferences.account, nil) } catch { model.report(error) } }
                        model.persist()
                    }
                    Toggle("自动登录", isOn: $model.preferences.autoLogin).disabled(!model.preferences.savePassword).onChange(of: model.preferences.autoLogin) { _ in model.persist() }
                    Text("启用保存密码后，请在登录页面输入密码并完成一次登录；密码和会话仅存设备钥匙串。").font(.caption).foregroundColor(.secondary)
                }
                BrandCard("关于") {
                    HStack { BrandMark(size: 39); VStack(alignment: .leading, spacing: 3) { Text("GMPluse · 广贸课表").font(.headline); Text("3.0.1 (21)").font(.caption).foregroundColor(.secondary) } }
                    Text("课表以学校教务系统最新发布为准。").font(.caption).foregroundColor(.secondary)
                    Button("检查更新") { Task { await model.checkUpdate() } }
                    Text(model.status).font(.caption).foregroundColor(.secondary)
                    if let info = model.update {
                        Text(info.newer ? "新版本 \(info.version)" : "当前已是最新版本")
                        if info.newer, let url = info.download { Link("使用系统浏览器下载", destination: url) }
                        if info.newer, let notes = info.notes { Text(notes).font(.caption) }
                    }
                    NavigationLink("运行日志") { List(model.logs.reversed(), id: \.self) { Text($0).font(.caption.monospaced()) }.navigationTitle("运行日志") }
                    NavigationLink("版本说明") {
                        ScrollView { Text("3.0.1 (21)\n\n使用 SwiftUI 重建 iOS 客户端。包含学校统一认证、周课表、学籍查询、按账号隔离的缓存和备注、系统明暗适配、课表图片分享和本地课前通知。\n\n本版本移除服务器抓取、Bark 和后台轮询。通知仅依据设备已缓存的课表安排。\n\nHTML 解析使用 SwiftSoup（MIT）：https://github.com/scinfu/SwiftSoup\n\n旧 Flutter 数据仅在相同应用容器内尝试导入可归属账号的偏好与课表；旧版无账号备注不会自动归入新账号，旧密码和 Cookie 不导入。").padding() }.navigationTitle("版本说明")
                    }
                }
                }.padding(20)
            }.background(AppBackground()).navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
        }.navigationViewStyle(.stack)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let image: UIImage
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [image], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
