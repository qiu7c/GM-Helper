import SwiftUI
import PhotosUI

@main @MainActor struct GMScheduleApp: App {
    @StateObject private var model = AppStore()
    var body: some Scene {
        WindowGroup { MainView().environmentObject(model).preferredColorScheme(model.colorScheme).task { await model.start() } }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppStore
    var body: some View {
        ZStack {
            AppBackground()
            TabView {
                TimetableView().tabItem { Label("课表", systemImage: "calendar") }
                ProfileView().tabItem { Label("我的", systemImage: "person.crop.circle") }
                SettingsView().tabItem { Label("设置", systemImage: "gearshape") }
            }
        }
        .sheet(isPresented: $model.showLogin) { LoginView().environmentObject(model) }
        .alert("课表变动", isPresented: Binding(get: { model.change != nil }, set: { if !$0 { model.change = nil } })) {
            Button("知道了") { model.change = nil }
        } message: { Text(model.change ?? "") }
    }
}

struct AppBackground: View {
    @EnvironmentObject var model: AppStore
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Group {
            if let image = model.background {
                GeometryReader { geometry in Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped().blur(radius: model.preferences.blur) }
            } else {
                let colors: [Color] = model.preferences.background == 0 ? [.blue.opacity(0.22), .cyan.opacity(0.15)] : model.preferences.background == 2 ? [.pink.opacity(0.22), .purple.opacity(0.17)] : model.preferences.background == 3 ? [.green.opacity(0.2), .mint.opacity(0.12)] : [scheme == .dark ? .black : Color(white: 0.97)]
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }.ignoresSafeArea()
    }
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
                HStack {
                    Button { Task { await model.select(week: max(1, model.preferences.week - 1)) } } label: { Image(systemName: "chevron.left") }.disabled(model.preferences.week <= 1 || model.busy)
                    Spacer()
                    Button("第 \(model.preferences.week) 周 · \(model.preferences.campus.name)") { date = Date(); showDates = true }.font(.headline)
                    Spacer()
                    Button { Task { await model.select(week: min(model.totalWeeks, model.preferences.week + 1)) } } label: { Image(systemName: "chevron.right") }.disabled(model.preferences.week >= model.totalWeeks || model.busy)
                }.padding(.horizontal)
                TimelineView(.periodic(from: Date(), by: 30)) { context in Text(model.courseStatus(now: context.date)).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal) }
                HStack {
                    if model.busy { ProgressView().scaleEffect(0.7) }
                    Text(model.status).font(.caption).foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    if !model.preferences.account.isEmpty { Button("刷新") { Task { await model.refresh() } }.disabled(model.busy).font(.caption) }
                }.padding(.horizontal)
                if let info = model.update, info.newer { HStack { Text("新版本 \(info.version)"); Spacer(); if let url = info.download { Link("查看下载", destination: url) } }.font(.caption).padding(8).background(Color.accentColor.opacity(0.12)) }
                if let schedule = model.schedule {
                    ScrollView([.horizontal, .vertical]) {
                        TimetableGrid(schedule: schedule, week: model.preferences.week, calendar: model.calendar, note: { model.note($0) }, select: { selectedCourse = $0 })
                            .frame(minWidth: 720).padding(8)
                    }
                    if !schedule.remark.isEmpty { Text(schedule.remark).font(.caption).foregroundColor(.secondary).padding(.horizontal) }
                } else {
                    Spacer()
                    Image(systemName: "calendar.badge.clock").font(.system(size: 52)).foregroundColor(.secondary)
                    Text(model.preferences.account.isEmpty ? "欢迎使用广贸课表" : "当前范围尚无缓存")
                    Button("登录学校统一认证") { model.openLogin() }.buttonStyle(.borderedProminent)
                    Spacer()
                }
            }
            .background(AppBackground())
            .navigationTitle("广贸课表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("本周") {
                        if let calendar = model.calendar { Task { await model.select(week: min(max(calendar.week(on: Date()), 1), calendar.total)) } }
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
                            }.buttonStyle(.borderedProminent)
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
            TimetableGrid(schedule: schedule, week: model.preferences.week, calendar: model.calendar, note: { model.note($0) }, select: { _ in })
            Text(schedule.remark).font(.caption)
        }.padding(24).frame(width: 1120).background(Color.white).environment(\.colorScheme, .light)
        let controller = UIHostingController(rootView: content)
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
    let select: (Course) -> Void
    private let days = ["一", "二", "三", "四", "五", "六", "日"]
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text("时间").frame(width: 48)
                ForEach(1...7, id: \.self) { day in
                    VStack(spacing: 3) {
                        Text("周" + days[day - 1]).fontWeight(.semibold)
                        if let calendar = calendar {
                            let date = SchoolClock.date(firstMonday: calendar.firstMonday, week: week, day: day, minute: 0)
                            Text(date, format: .dateTime.month().day()).font(.caption2)
                        }
                    }.frame(maxWidth: .infinity)
                }
            }.font(.caption).padding(.vertical, 8)
            ForEach(1...schedule.campus.periods.count, id: \.self) { period in
                HStack(alignment: .top, spacing: 4) {
                    VStack(spacing: 6) {
                        Text("\(period)").font(.headline)
                        Text(schedule.campus.periods[period - 1].text).font(.system(size: 10))
                    }.frame(width: 48).padding(.top, 12)
                    ForEach(1...7, id: \.self) { day in
                        VStack(spacing: 4) {
                            ForEach(schedule.visibleCourses(week: week).filter { $0.day == day && $0.period == period }) { course in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(course.name).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                                    if !course.room.isEmpty { Text(course.room).font(.system(size: 10)) }
                                    if !course.teacher.isEmpty { Text(course.teacher).font(.system(size: 10)) }
                                    if !note(course).isEmpty { Text("✎ " + note(course)).font(.system(size: 10)).lineLimit(3) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(7)
                                .background(courseColor(course.name).opacity(0.19)).cornerRadius(9)
                                .contentShape(Rectangle()).onTapGesture { select(course) }.onLongPressGesture { select(course) }
                            }
                            Spacer(minLength: 0)
                        }.frame(maxWidth: .infinity, minHeight: 110).background(Color.secondary.opacity(0.05)).cornerRadius(9)
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
        }.foregroundColor(.primary)
    }
    private func courseColor(_ name: String) -> Color {
        let index = name.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 6 }
        return [.blue, .green, .orange, .purple, .pink, .teal][index]
    }
}

struct CourseDetail: View {
    @EnvironmentObject var model: AppStore
    @Environment(\.dismiss) private var dismiss
    let course: Course
    @State private var note = ""
    var body: some View {
        NavigationView {
            Form {
                Section("课程详情") {
                    detail("课程", course.name); detail("教师", course.teacher); detail("教室", course.room)
                    detail("教学班", course.teachingClass); detail("周次与节次", course.rawWeeks)
                    detail("时间", "周\(["一","二","三","四","五","六","日"][course.day - 1]) 第\(course.period)大节")
                }
                Section("课程备注（仅当前账号）") { TextEditor(text: $note).frame(minHeight: 160) }
            }.navigationTitle(course.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存") { model.saveNote(course, text: note); dismiss() } } }
            .onAppear { note = model.note(course) }
        }.navigationViewStyle(.stack)
    }
    private func detail(_ label: String, _ text: String) -> some View { HStack { Text(label).foregroundColor(.secondary); Spacer(); Text(text.isEmpty ? "—" : text).multilineTextAlignment(.trailing) } }
}

struct ProfileView: View {
    @EnvironmentObject var model: AppStore
    var body: some View {
        NavigationView {
            List {
                Section("账号") {
                    Text(model.preferences.account.isEmpty ? "尚未登录" : model.preferences.account)
                    Button("登录 / 切换账号") { model.openLogin() }.disabled(model.busy)
                }
                if model.disk.hasLegacyNotes && !model.preferences.account.isEmpty {
                    Section("旧版备注") {
                        Text("旧版备注未记录所属账号。确认这些备注属于自己后，可手动导入到当前账号。").font(.caption)
                        Button("将旧版全局备注导入当前账号") {
                            do { try model.disk.importLegacyNotes(into: model.preferences.account); model.status = "旧版备注已导入当前账号"; model.objectWillChange.send() }
                            catch { model.report(error) }
                        }
                    }
                }
                Section("学籍信息") {
                    if model.profile.isEmpty { Text("联网刷新后显示学校返回的学籍信息").foregroundColor(.secondary) }
                    ForEach(model.profile) { item in HStack { Text(item.label); Spacer(); Text(item.value).foregroundColor(.secondary).multilineTextAlignment(.trailing) } }
                    Button("刷新学籍与课表") { Task { await model.refresh() } }.disabled(model.busy || model.preferences.account.isEmpty)
                }
                if !model.preferences.account.isEmpty {
                    Section { Button("退出登录并清除课表缓存", role: .destructive) { Task { await model.logout() } }.disabled(model.busy) }
                }
            }.navigationTitle("我的")
        }.navigationViewStyle(.stack)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppStore
    @State private var photos = false
    var body: some View {
        NavigationView {
            Form {
                Section("课表") {
                    if let schedule = model.schedule {
                        Picker("学期", selection: Binding(get: { model.preferences.term }, set: { value in Task { await model.select(term: value) } })) { ForEach(schedule.terms) { Text($0.label).tag($0.value) } }.disabled(model.busy)
                    }
                    Picker("校区", selection: Binding(get: { model.preferences.campus }, set: { value in Task { await model.select(campus: value) } })) { ForEach(Campus.allCases) { Text($0.name).tag($0) } }.disabled(model.busy)
                }
                Section("外观") {
                    Picker("主题", selection: $model.preferences.theme) { Text("跟随系统").tag(0); Text("浅色").tag(1); Text("深色").tag(2) }.onChange(of: model.preferences.theme) { _ in model.persist() }
                    Picker("背景预设", selection: $model.preferences.background) { Text("冷岩").tag(0); Text("默认").tag(1); Text("暮樱").tag(2); Text("青林").tag(3) }.onChange(of: model.preferences.background) { _ in model.setBackground(nil); model.persist() }
                    Button("选择自定义背景") { photos = true }
                    if model.background != nil {
                        Slider(value: $model.preferences.blur, in: 0...30) { Text("背景模糊") }.onChange(of: model.preferences.blur) { _ in model.persist() }
                        Button("移除自定义背景") { model.setBackground(nil) }
                    }
                }
                Section("课前提醒") {
                    Toggle("本地课前通知", isOn: Binding(get: { model.preferences.reminders }, set: { value in Task { await model.toggleReminders(value) } }))
                    Picker("提前", selection: $model.preferences.reminderMinutes) { ForEach([0,5,10,15,20,30], id: \.self) { Text("\($0) 分钟").tag($0) } }.onChange(of: model.preferences.reminderMinutes) { _ in model.persist(); Task { await model.rebuildReminders() } }
                    Text("只安排已同步并缓存的课程，最多未来 60 条。关闭 App 后由 iOS 在指定日期通知；不会自动抓取学校的新课表，请定期打开刷新。需要已同步当前学期校历。").font(.caption).foregroundColor(.secondary)
                    Button("打开系统通知设置") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                }
                Section("登录偏好") {
                    Toggle("保存密码", isOn: $model.preferences.savePassword).onChange(of: model.preferences.savePassword) { enabled in
                        if !enabled { model.preferences.autoLogin = false; do { try Keychain.write("password." + model.preferences.account, nil) } catch { model.report(error) } }
                        model.persist()
                    }
                    Toggle("自动登录", isOn: $model.preferences.autoLogin).disabled(!model.preferences.savePassword).onChange(of: model.preferences.autoLogin) { _ in model.persist() }
                    Text("启用保存密码后，请在登录页面输入密码并完成一次登录；密码和会话仅存设备钥匙串。").font(.caption).foregroundColor(.secondary)
                }
                Section("关于") {
                    Text("广贸课表 3.0.0 (20) · iOS 原生版")
                    Text("数据由手机直连学校，课表以教务系统最新发布为准。")
                    Button("检查更新") { Task { await model.checkUpdate() } }
                    Text(model.status).font(.caption).foregroundColor(.secondary)
                    if let info = model.update {
                        Text(info.newer ? "新版本 \(info.version)" : "当前已是最新版本")
                        if info.newer, let url = info.download { Link("使用系统浏览器下载", destination: url) }
                        if info.newer, let notes = info.notes { Text(notes).font(.caption) }
                    }
                    NavigationLink("运行日志") { List(model.logs.reversed(), id: \.self) { Text($0).font(.caption.monospaced()) }.navigationTitle("运行日志") }
                    NavigationLink("版本说明") {
                        ScrollView { Text("3.0.0 (20)\n\n使用 SwiftUI 重建 iOS 客户端。包含学校统一认证、周课表、学籍查询、按账号隔离的缓存和备注、背景主题、课表图片分享和本地课前通知。\n\n本版本移除服务器抓取、Bark 和后台轮询。通知仅依据设备已缓存的课表安排。\n\nHTML 解析使用 SwiftSoup（MIT）：https://github.com/scinfu/SwiftSoup\n\n旧 Flutter 数据仅在相同应用容器内尝试导入可归属账号的偏好与课表；旧版无账号备注不会自动归入新账号，旧密码和 Cookie 不导入。").padding() }.navigationTitle("版本说明")
                    }
                }
            }.navigationTitle("设置")
            .sheet(isPresented: $photos) { PhotoPicker { image in model.setBackground(image); photos = false } }
        }.navigationViewStyle(.stack)
    }
}

struct PhotoPicker: UIViewControllerRepresentable {
    let picked: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(picked) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(); config.filter = .images; config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config); picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let picked: (UIImage?) -> Void
        init(_ picked: @escaping (UIImage?) -> Void) { self.picked = picked }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else { picker.dismiss(animated: true); return }
            provider.loadObject(ofClass: UIImage.self) { [picked] object, _ in DispatchQueue.main.async { picked(object as? UIImage) } }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let image: UIImage
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [image], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
