package cn.gdgm.nativeapp

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.app.DatePickerDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.RenderEffect
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.*
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.HttpCookie
import java.net.URL
import java.time.LocalDate
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.util.concurrent.Executors

class MainActivity : Activity() {
    private lateinit var store: NativeStore
    private val client = SchoolClient()
    private val executor = Executors.newSingleThreadExecutor()
    private val clock = Handler(Looper.getMainLooper())
    private lateinit var root: FrameLayout
    private lateinit var page: LinearLayout
    private var status: TextView? = null
    private var schedule: Schedule? = null
    private var profile: StudentProfile? = null
    private var week = 1
    private var tab = 0
    private var busy = false
    private var sessionExpired = false
    private var message = "登录后，课表会缓存在此设备"
    private var authSuppressed = false
    private var autoAttempted = false
    private var loginDialog: AlertDialog? = null
    private var loginWeb: WebView? = null
    private var loginVerified = false
    private var verifying = false
    private var loginPassword = ""
    private var loginUsername = ""
    private var loginRemember = false
    private var loginQr = false
    private var loginScreen = false
    private var loginFormUser = ""
    private var loginFormPassword = ""
    private var loginFormRemember = false
    private var loginFormAuto = false
    private var loginError = ""
    private var previewScreen: String? = null
    private val tick = object : Runnable {
        override fun run() { updateNow(); clock.postDelayed(this, 20_000) }
    }
    private val dark: Boolean get() = when (store.prefs.getString("theme", "system")) {
        "dark" -> true; "light" -> false
        else -> resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    }
    private val ink: Int get() = if (dark) 0xfff2f3fc.toInt() else 0xff252c42.toInt()
    private fun dp(n: Int) = (n * resources.displayMetrics.density).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = NativeStore(this)
        if (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0) previewScreen = intent.getStringExtra("preview_screen")
        week = store.currentWeek()
        schedule = store.readSchedule(week)
        if (previewScreen == "timetable") {
            val day = LocalDate.now().dayOfWeek.value
            schedule = Schedule(listOf(Course("高等数学", "陈老师", "教学楼 A301", day = day, period = 1), Course("大学英语", "林老师", "博学楼 B205", day = (day % 7) + 1, period = 2), Course("程序设计基础", "王老师", "实训楼 C402", day = day, period = 3)), emptyList(), emptyList(), emptyList(), "2026-2027-1", week.toString(), SchoolConfig.campuses.keys.first())
            message = "演示课表 · 虚构课程"
        }
        if (previewScreen == "login") { loginScreen = true; loginFormRemember = true; loginFormAuto = true }
        if (schedule != null) message = "已载入离线课表"
        render()
        clock.post(tick)
        if (previewScreen == null && store.username.isNotBlank()) load()
    }
    override fun onDestroy() {
        clock.removeCallbacks(tick); loginWeb?.destroy(); executor.shutdown(); super.onDestroy()
    }
    override fun onConfigurationChanged(newConfig: Configuration) { super.onConfigurationChanged(newConfig); render() }
    @Deprecated("Platform back API")
    override fun onBackPressed() {
        if (loginScreen) {
            if (busy) toast("正在登录，请稍候") else { loginScreen = false; loginFormPassword = ""; render() }
        } else super.onBackPressed()
    }

    private fun label(text: String, size: Float = 15f, bold: Boolean = false) = TextView(this).apply {
        this.text = text; textSize = size; setTextColor(ink)
        if (bold) setTypeface(null, Typeface.BOLD)
    }
    private fun button(title: String, action: () -> Unit) = Button(this).apply {
        text = title; isAllCaps = false; textSize = 13f; setTextColor(ink); minWidth = 0; minimumWidth = 0; minHeight = 0; minimumHeight = 0
        setPadding(dp(15), dp(10), dp(15), dp(10)); stateListAnimator = null
        backgroundTintList = null
        background = GradientDrawable().apply { setColor(if (dark) 0xff27394a.toInt() else 0xffeef3f2.toInt()); cornerRadius = dp(14).toFloat() }
        setOnClickListener { action() }
    }
    private fun card(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL; setPadding(dp(18), dp(18), dp(18), dp(18))
        background = GradientDrawable().apply { setColor(if (dark) 0xee1d2d40.toInt() else 0xeeffffff.toInt()); cornerRadius = dp(24).toFloat(); setStroke(dp(1), if (dark) 0x334b6580 else 0x99ffffff.toInt()) }
    }
    private fun render() {
        setTheme(if (dark) android.R.style.Theme_Material_NoActionBar else android.R.style.Theme_Material_Light_NoActionBar)
        window.statusBarColor = if (dark) 0xff122132.toInt() else 0xfff6f7f2.toInt()
        window.navigationBarColor = window.statusBarColor
        window.decorView.systemUiVisibility = if (dark) 0 else View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
        root = FrameLayout(this)
        root.setOnApplyWindowInsetsListener { view, insets ->
            view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop, insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
            insets
        }
        val styles = arrayOf(intArrayOf(0xffe8edf9.toInt(), 0xfff4e8ed.toInt()), intArrayOf(0xfff8f8f2.toInt(), 0xffedf3ef.toInt()), intArrayOf(0xffd9f0e9.toInt(), 0xffedf1e3.toInt()), intArrayOf(0xfff9e7d9.toInt(), 0xfff3e2eb.toInt()), intArrayOf(0xffdce5ec.toInt(), 0xffe9edf0.toInt()))
        root.background = GradientDrawable(GradientDrawable.Orientation.TL_BR, if (dark) intArrayOf(0xff122132.toInt(), 0xff182c3d.toInt()) else styles[store.prefs.getInt("bg_style", 1).coerceIn(0, 4)])
        if (store.backgroundFile.exists()) {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(store.backgroundFile.path, bounds)
            val options = BitmapFactory.Options().apply { inSampleSize = (maxOf(bounds.outWidth, bounds.outHeight) / 1800).coerceAtLeast(1) }
            var bitmap = BitmapFactory.decodeFile(store.backgroundFile.path, options)
            if (bitmap != null) {
                val blur = store.prefs.getFloat("bg_blur", 0f)
                if (Build.VERSION.SDK_INT < 31 && blur > 0) {
                    val small = Bitmap.createScaledBitmap(bitmap, (bitmap.width / 2).coerceAtLeast(1), (bitmap.height / 2).coerceAtLeast(1), true)
                    val rs = android.renderscript.RenderScript.create(this)
                    val input = android.renderscript.Allocation.createFromBitmap(rs, small)
                    val output = android.renderscript.Allocation.createTyped(rs, input.type)
                    val script = android.renderscript.ScriptIntrinsicBlur.create(rs, android.renderscript.Element.U8_4(rs))
                    script.setRadius((blur / 2).coerceIn(.1f, 25f)); script.setInput(input); script.forEach(output); output.copyTo(small)
                    script.destroy(); input.destroy(); output.destroy(); rs.destroy()
                    bitmap = small
                }
                val image = ImageView(this).apply {
                    setImageBitmap(bitmap); scaleType = ImageView.ScaleType.CENTER_CROP
                    if (Build.VERSION.SDK_INT >= 31 && blur > 0) setRenderEffect(RenderEffect.createBlurEffect(blur, blur, Shader.TileMode.CLAMP))
                }
                root.addView(image, FrameLayout.LayoutParams(-1, -1))
                root.addView(View(this).apply { setBackgroundColor(if (dark) 0x8820293b.toInt() else 0x55ffffff) }, FrameLayout.LayoutParams(-1, -1))
            }
        }
        page = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(14), dp(12), dp(14), 0) }
        root.addView(page, FrameLayout.LayoutParams(-1, -1))
        setContentView(root)
        if (loginScreen) { renderLogin(); return }
        if (tab == 0) renderTimetable() else renderMine()
        val nav = LinearLayout(this).apply { gravity = Gravity.CENTER; setPadding(dp(6), dp(6), dp(6), dp(6)); elevation = dp(8).toFloat(); background = GradientDrawable().apply { setColor(if (dark) 0xff223448.toInt() else Color.WHITE); cornerRadius = dp(28).toFloat() } }
        for (index in 0..1) nav.addView(button(if (index == 0) "▦   课表" else "◎   我的") { tab = index; render() }.apply {
            setTextColor(if (tab == index) 0xff357e84.toInt() else if (dark) 0xffb0c0cf.toInt() else 0xff8a969f.toInt())
            background = GradientDrawable().apply { setColor(if (tab == index) if (dark) 0xff2d4858.toInt() else 0xffe7f0ec.toInt() else Color.TRANSPARENT); cornerRadius = dp(22).toFloat() }
            setTypeface(null, if (tab == index) Typeface.BOLD else Typeface.NORMAL)
        }, LinearLayout.LayoutParams(0, dp(46), 1f))
        page.addView(nav, LinearLayout.LayoutParams(-1, -2).apply { setMargins(dp(36), dp(8), dp(36), dp(14)) })
    }

    private fun renderTimetable() {
        val top = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(5), dp(5), dp(5), dp(10)) }
        val title = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL }
        title.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(label("GMPluse  /  每周计划", 10f, true).apply { letterSpacing = .12f; setTextColor(if (dark) 0xff8fbac3.toInt() else 0xff739895.toInt()); setPadding(0, 0, 0, dp(5)) })
            addView(label("把今天安排好", 27f, true))
        }, LinearLayout.LayoutParams(0, -2, 1f))
        title.addView(button("↗") { share() }.apply { textSize = 22f; contentDescription = "分享课表" }, LinearLayout.LayoutParams(dp(43), dp(43)))
        title.addView(button("↻") { load() }.apply { textSize = 23f; contentDescription = "刷新课表" }, LinearLayout.LayoutParams(dp(43), dp(43)).apply { leftMargin = dp(7) })
        top.addView(title)
        val monday = store.firstMonday.plusWeeks((week - 1).toLong())
        top.addView(label("${monday.format(DateTimeFormatter.ofPattern("M月d日"))} — ${monday.plusDays(6).format(DateTimeFormatter.ofPattern("M月d日"))}  ▾", 12f).apply { alpha = .6f; setPadding(0, dp(10), 0, dp(17)); setOnClickListener { chooseDate() }; contentDescription = "按日期跳转周次" })
        val controls = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL; setPadding(dp(5), dp(5), dp(5), dp(5)); background = GradientDrawable().apply { setColor(if (dark) 0xff21364b.toInt() else 0xffe8eeeb.toInt()); cornerRadius = dp(21).toFloat() } }
        controls.addView(button("‹") { changeWeek(week - 1) }.apply { background = null; textSize = 23f }, LinearLayout.LayoutParams(dp(40), dp(40)))
        controls.addView(button("第 $week 周  ▾") { chooseWeek() }.apply { background = null; textSize = 16f; setTypeface(null, Typeface.BOLD) }, LinearLayout.LayoutParams(0, dp(40), 1f))
        controls.addView(button("›") { changeWeek(week + 1) }.apply { background = null; textSize = 23f }, LinearLayout.LayoutParams(dp(40), dp(40)))
        controls.addView(button("回本周") { changeWeek(store.currentWeek()) }.apply { textSize = 11f; setTextColor(if (dark) 0xffc8e3df.toInt() else 0xff467f7a.toInt()); background = GradientDrawable().apply { setColor(if (dark) 0xff345062.toInt() else Color.WHITE); cornerRadius = dp(16).toFloat() } }, LinearLayout.LayoutParams(dp(72), dp(36)).apply { leftMargin = dp(5) })
        top.addView(controls)
        val nowCard = LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL; setPadding(dp(14), dp(13), dp(14), dp(13))
            background = GradientDrawable(GradientDrawable.Orientation.LEFT_RIGHT, if (dark) intArrayOf(0xff234357.toInt(), 0xff24473f.toInt()) else intArrayOf(0xffe0eef0.toInt(), 0xffe5eee5.toInt())).apply { cornerRadius = dp(19).toFloat() }
        }
        nowCard.addView(label("◷", 28f).apply { setTextColor(if (dark) 0xff9fc7c6.toInt() else 0xff578a8c.toInt()); gravity = Gravity.CENTER }, LinearLayout.LayoutParams(dp(37), dp(40)))
        status = label("", 12f, true).apply { setPadding(dp(11), 0, 0, 0); setLineSpacing(dp(4).toFloat(), 1f) }
        nowCard.addView(status, LinearLayout.LayoutParams(0, -2, 1f)); updateNow()
        top.addView(nowCard, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(13) })
        top.addView(label("●  $message", 10f).apply { alpha = .55f; setPadding(dp(3), dp(10), 0, 0); setOnClickListener { if (store.username.isBlank() || sessionExpired) credentials() else load() } })
        page.addView(top)
        val scroll = ScrollView(this).apply { isFillViewport = true; clipToPadding = false; setPadding(0, dp(10), 0, dp(8)) }
        val body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        if (schedule == null) {
            body.addView(card().apply {
                addView(label("▦", 52f).apply { gravity = Gravity.CENTER; setTextColor(0xff7ba6a3.toInt()); setPadding(0, dp(30), 0, dp(20)) })
                addView(label("课程，从这里开始", 21f, true))
                addView(label("使用学校统一认证登录。课表、学籍与备注保存在本机，离线也能查看已缓存课表。", 14f).apply { setPadding(0, dp(12), 0, dp(16)) })
                addView(button("登录教务系统") { credentials() })
            })
        } else {
            body.addView(grid(dark))
            if (schedule!!.courses.isEmpty()) body.addView(label("本周暂无课程", 16f).apply { gravity = Gravity.CENTER; setPadding(0, dp(16), 0, dp(16)) })
            if (schedule!!.remark.isNotBlank()) body.addView(card().apply { addView(label("课表备注", 15f, true)); addView(label(schedule!!.remark, 13f)) })
        }
        scroll.addView(body); page.addView(scroll, LinearLayout.LayoutParams(-1, 0, 1f))
    }
    private fun grid(exportDark: Boolean) = TimetableView(this, schedule?.courses.orEmpty(), week, store.firstMonday.plusWeeks((week - 1).toLong()), store.campus ?: SchoolConfig.campuses.keys.first(), exportDark, { name -> if (previewScreen == null) store.note(name) else "" }, store::courseColorIndex, ::courseDetails, ::editNote)

    private fun updateNow() {
        if (tab != 0 || status == null) return
        if (week != store.currentWeek()) { status?.text = "浏览其他周 · 长按课程添加备注"; return }
        val now = LocalTime.now(); val times = SchoolConfig.periodTimes(store.campus ?: SchoolConfig.campuses.keys.first())
        val today = schedule?.courses.orEmpty().filter { it.day == LocalDate.now().dayOfWeek.value }.sortedBy { it.period }
        val current = today.firstOrNull { c -> val t = times[c.period - 1]; t.first.isNotBlank() && now >= LocalTime.parse(t.first) && now < LocalTime.parse(t.second) }
        val next = today.firstOrNull { c -> times[c.period - 1].first.let { it.isNotBlank() && now < LocalTime.parse(it) } }
        status?.text = when {
            current != null -> "正在上课 · ${current.name}\n${current.room}  ·  还有 ${java.time.Duration.between(now, LocalTime.parse(times[current.period - 1].second)).toMinutes() + 1} 分钟下课"
            next != null -> "下一节 ${times[next.period - 1].first} · ${next.name}\n${next.room}  ·  ${java.time.Duration.between(now, LocalTime.parse(times[next.period - 1].first)).toMinutes() + 1} 分钟后上课"
            today.isNotEmpty() -> "今天的课程已结束，辛苦了"
            else -> "今天没有课程 · 长按课程添加备注"
        }
    }
    private fun changeWeek(value: Int) {
        if (previewScreen != null) { week = value.coerceIn(1, store.totalWeeks); schedule = schedule?.copy(selectedWeek = week.toString()); render(); return }
        week = value.coerceIn(1, store.totalWeeks); schedule = store.readSchedule(week)
        message = if (schedule != null) "已载入缓存课表" else "此周尚未缓存"
        render(); if (store.username.isNotBlank()) load()
    }
    private fun chooseWeek() {
        AlertDialog.Builder(this).setTitle("选择周次").setItems((1..store.totalWeeks).map { "第 $it 周" }.toTypedArray()) { _, index -> changeWeek(index + 1) }.setNegativeButton("按日期选择") { _, _ -> chooseDate() }.show()
    }
    private fun chooseDate() {
        val date = store.firstMonday.plusWeeks((week - 1).toLong())
        DatePickerDialog(this, { _, y, m, d -> changeWeek(SchoolConfig.weekOfDate(LocalDate.of(y, m + 1, d), store.firstMonday, store.totalWeeks)) }, date.year, date.monthValue - 1, date.dayOfMonth).show()
    }
    private fun courseDetails(c: Course) {
        val time = SchoolConfig.periodTimes(store.campus ?: SchoolConfig.campuses.keys.first())[c.period - 1]
        val content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(24), dp(8), dp(24), dp(14)) }
        content.addView(label("教师：${c.teacher}\n教室：${c.room}\n教学班：${c.teachingClass}\n周次：${c.rawWeeks}\n节次：${c.sectionRange.ifBlank { "第 ${c.period} 大节" }}\n时间：${time.first}–${time.second}\n\n备注：${store.note(c.name).ifBlank { "暂无" }}", 14f).apply { setLineSpacing(dp(4).toFloat(), 1f) })
        content.addView(label("课程颜色", 12f, true).apply { setPadding(0, dp(22), 0, dp(10)) })
        val colors = LinearLayout(this)
        TimetableView.palette.forEachIndexed { index, color ->
            colors.addView(label(if (store.courseColorIndex(c.name) == index) "✓" else "", 14f, true).apply {
                gravity = Gravity.CENTER; setTextColor(0xff47676d.toInt()); contentDescription = "课程颜色 ${index + 1}"
                background = GradientDrawable().apply { setColor(color); cornerRadius = dp(30).toFloat() }
                setOnClickListener { store.setCourseColor(c.name, index); for (i in 0 until colors.childCount) (colors.getChildAt(i) as TextView).text = if (i == index) "✓" else ""; render() }
            }, LinearLayout.LayoutParams(0, dp(30), 1f).apply { setMargins(dp(3), 0, dp(3), 0) })
        }
        content.addView(colors)
        AlertDialog.Builder(this).setTitle(c.name).setView(content)
            .setPositiveButton("编辑备注") { _, _ -> editNote(c) }.setNegativeButton("关闭", null).show()
    }
    private fun editNote(c: Course) {
        val field = EditText(this).apply { setText(store.note(c.name)); hint = "这门课的个人备注"; minLines = 3; gravity = Gravity.TOP; setPadding(dp(20), dp(12), dp(20), dp(12)) }
        AlertDialog.Builder(this).setTitle(c.name).setView(field).setPositiveButton("保存") { _, _ -> store.setNote(c.name, field.text.toString().trim()); render() }.setNeutralButton("删除") { _, _ -> store.setNote(c.name, ""); render() }.setNegativeButton("取消", null).show()
    }

    private fun load() {
        if (previewScreen != null) { toast("界面预览不会连接学校"); return }
        if (busy) return
        if (sessionExpired) { credentials(); return }
        if (store.username.isBlank()) { credentials(); return }
        busy = true; message = "正在更新课表…"; render()
        val requestedWeek = week; val requestedTerm = store.term; val requestedCampus = store.campus
        val followedCurrentWeek = week == store.currentWeek()
        executor.execute {
            val result = runCatching {
                val fresh = client.fetch(requestedTerm, requestedWeek, requestedCampus)
                // 校历是补充信息；其独立请求失败时仍使用已验证成功的课表。
                val calendar = runCatching { client.fetchCalendar() }.getOrNull()
                fresh to calendar
            }
            runOnUiThread {
                busy = false
                result.onSuccess { (fresh, calendar) ->
                    sessionExpired = false
                    calendar?.let { store.firstMonday = it.firstMonday; store.totalWeeks = it.totalWeeks }
                    val old = store.readSchedule(requestedWeek)
                    store.writeSchedule(requestedWeek, fresh)
                    if (week == requestedWeek) schedule = fresh
                    if (calendar != null && followedCurrentWeek && week == requestedWeek && store.currentWeek() != week) {
                        week = store.currentWeek()
                        schedule = store.readSchedule(week)
                    }
                    message = "刚刚更新 · ${fresh.courses.size} 门课程"
                    if (store.prefs.getBoolean("reminders", false)) store.scheduleReminders(fresh, store.prefs.getInt("reminder_minutes", 10))
                    render()
                    scheduleDiff(old ?: fresh, fresh)?.let { AlertDialog.Builder(this).setTitle("课表有变化").setMessage(it).setPositiveButton("知道了", null).show() }
                }.onFailure { error ->
                    sessionExpired = SchoolClient.isSessionExpired(error)
                    message = if (SchoolClient.isSessionExpired(error)) "登录已失效 · 已保留离线课表，点此重试" else "更新失败 · ${error.message ?: "请检查网络"} · 显示缓存"
                    render()
                    if (SchoolClient.isSessionExpired(error) && !authSuppressed && !autoAttempted && store.prefs.getBoolean("auto_login", false) && !store.savedPassword().isNullOrEmpty()) {
                        autoAttempted = true; authenticate(store.username, store.savedPassword().orEmpty(), true, true, true)
                    }
                }
                if (week != requestedWeek && !sessionExpired) load()
            }
        }
    }

    private fun renderMine() {
        page.addView(label("个人空间", 28f, true).apply { setPadding(dp(6), dp(9), 0, dp(5)) })
        page.addView(label("每一项偏好，都刚刚好。", 12f).apply { alpha = .6f; setPadding(dp(6), 0, 0, dp(21)) })
        val scroll = ScrollView(this)
        val body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val account = card()
        account.addView(label("◎", 31f).apply { setTextColor(if (dark) 0xffb1d1cc.toInt() else 0xff548e88.toInt()); gravity = Gravity.CENTER; background = GradientDrawable().apply { setColor(if (dark) 0xff314d5b.toInt() else 0xffe3efea.toInt()); cornerRadius = dp(19).toFloat() } }, LinearLayout.LayoutParams(dp(58), dp(58)).apply { bottomMargin = dp(15) })
        account.addView(label(if (previewScreen != null) "演示同学" else profile?.name ?: store.username.ifBlank { "欢迎使用 GMPluse" }, 22f, true))
        account.addView(label(if (previewScreen != null) "虚构账号 · 仅供界面预览" else if (store.username.isBlank()) "登录学校账号，同步个人课表" else "学号 ${store.username}", 12f).apply { alpha = .6f; setPadding(0, dp(7), 0, dp(18)) })
        account.addView(button(if (store.username.isBlank()) "登录" else "查看学籍信息") { if (store.username.isBlank()) credentials() else showProfile() }, LinearLayout.LayoutParams(-1, dp(43)))
        if (store.username.isNotBlank()) account.addView(button("重新登录 / 切换账号") { credentials() }.apply { background = null; textSize = 11f; alpha = .7f }, LinearLayout.LayoutParams(-1, dp(39)).apply { topMargin = dp(4) })
        body.addView(account)
        var group = card()
        fun section(title: String) {
            body.addView(label(title, 11f, true).apply { setTextColor(if (dark) 0xff8aadb8.toInt() else 0xff7a9693.toInt()); letterSpacing = .12f; setPadding(dp(10), dp(25), 0, dp(10)) })
            group = card().apply { setPadding(dp(4), dp(3), dp(4), dp(3)) }
            body.addView(group)
        }
        fun row(title: String, subtitle: String = "", action: () -> Unit) {
            val view = LinearLayout(this).apply {
                gravity = Gravity.CENTER_VERTICAL; setPadding(dp(15), dp(16), dp(15), dp(16))
                addView(LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.VERTICAL; addView(label(title, 14f, true))
                    if (subtitle.isNotBlank()) addView(label(subtitle, 11f).apply { alpha = .55f; setPadding(0, dp(5), 0, 0) })
                }, LinearLayout.LayoutParams(0, -2, 1f))
                addView(label("›", 22f).apply { alpha = .3f })
                setOnClickListener { action() }
            }
            group.addView(view)
        }
        section("学习偏好")
        row("学期", schedule?.terms?.firstOrNull { it.value == store.term }?.label ?: schedule?.selectedTerm ?: "教务默认") {
            if (busy) { toast("请等待本次同步完成"); return@row }
            val options = schedule?.terms.orEmpty()
            if (options.isEmpty()) { toast("请先登录并刷新课表"); return@row }
            choose("学期", options.map { it.label }) { store.term = options[it].value; schedule = store.readSchedule(week); render(); load() }
        }
        row("校区", schedule?.campuses?.firstOrNull { it.value == store.campus }?.label ?: SchoolConfig.campuses[store.campus] ?: "教务默认") {
            if (busy) { toast("请等待本次同步完成"); return@row }
            val options = schedule?.campuses?.takeIf { it.isNotEmpty() } ?: SchoolConfig.campuses.map { SelectOption(it.key, it.value) }
            choose("校区", options.map { it.label }) { store.campus = options[it].value; schedule = store.readSchedule(week); render(); load() }
        }
        section("外观与体验")
        row("深浅色", mapOf("system" to "跟随系统", "light" to "浅色", "dark" to "深色")[store.prefs.getString("theme", "system")] ?: "跟随系统") {
            choose("深浅色", listOf("跟随系统", "浅色", "深色")) { store.prefs.edit().putString("theme", listOf("system", "light", "dark")[it]).apply(); render() }
        }
        row("背景与模糊", if (store.backgroundFile.exists()) "自定义照片" else "渐变背景") { backgroundSettings() }
        section("账号与提醒")
        fun toggle(title: String, key: String, action: (Boolean) -> Unit) {
            group.addView(Switch(this).apply {
                text = title; textSize = 14f; setTextColor(ink); setPadding(dp(15), dp(17), dp(15), dp(17)); isChecked = store.prefs.getBoolean(key, false)
                thumbTintList = android.content.res.ColorStateList.valueOf(if (dark) 0xffacd0cc.toInt() else 0xff5b9690.toInt())
                setOnCheckedChangeListener { _, enabled -> action(enabled) }
            })
        }
        toggle("保存密码", "remember_password") { enabled ->
            if (!enabled) { store.saveCredentials(null, false); store.prefs.edit().putBoolean("auto_login", false).apply(); render() }
            else if (store.savedPassword().isNullOrEmpty()) credentials(true) else store.prefs.edit().putBoolean("remember_password", true).apply()
        }
        toggle("自动登录", "auto_login") { enabled ->
            if (enabled && store.savedPassword().isNullOrEmpty()) { credentials(true, true); render() }
            else store.prefs.edit().putBoolean("auto_login", enabled).apply()
        }
        toggle("课前本地提醒", "reminders") { enabled ->
            store.prefs.edit().putBoolean("reminders", enabled).apply()
            if (enabled) {
                if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 51)
                else schedule?.let { store.scheduleReminders(it, store.prefs.getInt("reminder_minutes", 10)) }
            } else store.cancelReminders()
        }
        row("提醒时间", "提前 ${store.prefs.getInt("reminder_minutes", 10)} 分钟") {
            val mins = listOf(5, 10, 15, 20, 30)
            choose("提前提醒", mins.map { "$it 分钟" }) { store.prefs.edit().putInt("reminder_minutes", mins[it]).apply(); if (store.prefs.getBoolean("reminders", false)) schedule?.let { s -> store.scheduleReminders(s, mins[it]) }; render() }
        }
        group.addView(label("提醒由此设备发出。未允许精确闹钟时，系统会使用非精确提醒；省电和通知设置也可能造成延迟。", 10f).apply { alpha = .5f; setPadding(dp(15), 0, dp(15), dp(14)) })
        section("支持与关于")
        row("检查更新", "当前版本 3.0.1 (21)") { checkUpdate() }
        row("关于", "GMPluse · 原生 Android") { about() }
        if (store.username.isNotBlank()) row("退出登录") {
            if (busy) { toast("请等待本次同步完成"); return@row }
            AlertDialog.Builder(this).setTitle("退出登录？").setMessage("清除登录会话和课表缓存，保留此账号的课程备注。").setPositiveButton("退出") { _, _ ->
                store.logout(); authSuppressed = true; sessionExpired = false; profile = null; schedule = null; message = "已退出登录"; render()
            }.setNegativeButton("取消", null).show()
        }
        body.addView(label("课表与学籍直连学校，仅保存在此设备", 11f).apply { gravity = Gravity.CENTER; alpha = .6f; setPadding(0, dp(16), 0, dp(20)) })
        scroll.addView(body); page.addView(scroll, LinearLayout.LayoutParams(-1, 0, 1f))
    }
    private fun choose(title: String, values: List<String>, selected: (Int) -> Unit) {
        AlertDialog.Builder(this).setTitle(title).setItems(values.toTypedArray()) { _, i -> selected(i) }.setNegativeButton("取消", null).show()
    }
    private fun showProfile() {
        if (previewScreen != null) { toast("界面预览不读取真实学籍"); return }
        if (busy) { toast("请等待本次同步完成"); return }
        busy = true
        toast("正在读取学籍…")
        executor.execute {
            val result = runCatching { client.fetchProfile() }
            runOnUiThread { busy = false; result.onSuccess { p -> profile = p; render(); AlertDialog.Builder(this).setTitle("学籍信息 · ${p.name}").setMessage((listOf("学号" to p.studentId) + p.fields).joinToString("\n\n") { "${it.first}：${it.second}" }).setPositiveButton("关闭", null).show() }.onFailure { toast(it.message ?: "学籍读取失败，请重新登录") } }
        }
    }

    private fun backgroundSettings() {
        val content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(20), 0, dp(20), dp(16)) }
        content.addView(button("从相册选择背景") { startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply { type = "image/*"; addCategory(Intent.CATEGORY_OPENABLE) }, 40) })
        val names = listOf("柔雾", "默认", "青竹", "暖霞", "冷岩")
        names.forEachIndexed { i, title -> content.addView(button(title) { store.backgroundFile.delete(); store.prefs.edit().putInt("bg_style", i).apply(); render() }) }
        val value = label("模糊：${store.prefs.getFloat("bg_blur", 0f).toInt()}", 13f)
        content.addView(value)
        content.addView(SeekBar(this).apply {
            max = 40; progress = store.prefs.getFloat("bg_blur", 0f).toInt()
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(bar: SeekBar?, p: Int, fromUser: Boolean) { value.text = "模糊：$p" }
                override fun onStartTrackingTouch(bar: SeekBar?) {}
                override fun onStopTrackingTouch(bar: SeekBar) { store.prefs.edit().putFloat("bg_blur", bar.progress.toFloat()).apply(); render() }
            })
        })
        AlertDialog.Builder(this).setTitle("背景").setView(content).setPositiveButton("完成", null).show()
    }
    @Deprecated("Platform activity result API")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 40 && resultCode == RESULT_OK) data?.data?.let { uri ->
            executor.execute { val result = runCatching { store.saveBackground(uri) }; runOnUiThread { result.onSuccess { render() }.onFailure { toast("图片无法读取：${it.message}") } } }
        }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 51) {
            val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
            if (granted) schedule?.let { store.scheduleReminders(it, store.prefs.getInt("reminder_minutes", 10)) }
            else { store.prefs.edit().putBoolean("reminders", false).apply(); toast("未授予通知权限，提醒已关闭"); render() }
        }
    }

    private fun credentials(rememberDefault: Boolean = store.prefs.getBoolean("remember_password", false), autoDefault: Boolean = store.prefs.getBoolean("auto_login", false)) {
        if (busy) { toast("请等待本次同步完成"); return }
        loginFormUser = if (previewScreen == null) store.username else ""; loginFormPassword = if (previewScreen == null) store.savedPassword().orEmpty() else ""
        loginFormRemember = rememberDefault; loginFormAuto = autoDefault; loginError = ""; loginScreen = true; render()
    }
    private fun renderLogin() {
        val scroll = ScrollView(this).apply { isFillViewport = true; clipToPadding = false }
        val content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(10), dp(4), dp(10), dp(24)) }
        content.addView(button("‹  返回") { if (busy) toast("正在登录，请稍候") else { loginScreen = false; loginFormPassword = ""; render() } }.apply { background = null; gravity = Gravity.START }, LinearLayout.LayoutParams(-1, dp(44)))
        val brand = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL; setPadding(0, dp(16), 0, dp(26)) }
        brand.addView(label("G", 29f, true).apply {
            setTextColor(Color.WHITE); gravity = Gravity.CENTER; elevation = dp(5).toFloat()
            background = GradientDrawable(GradientDrawable.Orientation.TL_BR, intArrayOf(0xff367eae.toInt(), 0xff4d9a84.toInt())).apply { cornerRadius = dp(19).toFloat() }
        }, LinearLayout.LayoutParams(dp(58), dp(58)))
        brand.addView(LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(14), 0, 0, 0); addView(label("GMPluse", 23f, true)); addView(label("让校园生活，从容一点", 11f).apply { alpha = .6f; setPadding(0, dp(4), 0, 0) }) })
        content.addView(brand)
        content.addView(label("YOUR CAMPUS, YOUR RHYTHM", 10f, true).apply { letterSpacing = .16f; setTextColor(if (dark) 0xff80b9bf.toInt() else 0xff4d8d91.toInt()) })
        content.addView(label("把校园日常，\n安排得刚刚好。", 31f, true).apply { setLineSpacing(dp(5).toFloat(), 1f); setPadding(0, dp(12), 0, dp(12)) })
        content.addView(label("一张课表，连接每一天的小目标。", 13f).apply { alpha = .65f; setPadding(0, 0, 0, dp(28)) })
        val form = card().apply { setPadding(dp(22), dp(24), dp(22), dp(24)); elevation = dp(3).toFloat() }
        form.addView(label("欢迎回来", 22f, true))
        form.addView(label("使用学校统一认证账号登录", 12f).apply { alpha = .6f; setPadding(0, dp(7), 0, dp(22)) })
        val user = EditText(this).apply { setText(loginFormUser); hint = "请输入学号"; inputType = InputType.TYPE_CLASS_TEXT; setAutofillHints(View.AUTOFILL_HINT_USERNAME); isSingleLine = true }
        val pass = EditText(this).apply { setText(loginFormPassword); hint = "请输入密码"; inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD; setAutofillHints(View.AUTOFILL_HINT_PASSWORD); isSingleLine = true }
        listOf(Triple("◎", "学号", user), Triple("⌑", "密码", pass)).forEach { (icon, title, field) ->
            form.addView(label(title, 12f, true).apply { alpha = .75f; setPadding(dp(1), 0, 0, dp(8)) })
            val row = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL; setPadding(dp(14), 0, dp(8), 0) }
            fun appearance(focus: Boolean) { row.background = GradientDrawable().apply { setColor(if (dark) 0xff14273a.toInt() else if (focus) 0xfff4f9f7.toInt() else 0xfff2f5f3.toInt()); cornerRadius = dp(15).toFloat(); setStroke(dp(1), if (focus) 0xff7ab4aa.toInt() else if (dark) 0xff294052.toInt() else 0xffe7ede9.toInt()) } }
            appearance(false)
            row.addView(label(icon, 21f).apply { setTextColor(0xff6e9c9b.toInt()); gravity = Gravity.CENTER }, LinearLayout.LayoutParams(dp(28), -1))
            field.apply { background = null; textSize = 14f; setTextColor(ink); setHintTextColor(if (dark) 0xff7e94a6.toInt() else 0xff9ba8aa.toInt()); setPadding(dp(9), 0, 0, 0); isEnabled = !busy; setOnFocusChangeListener { _, focus -> appearance(focus) } }
            row.addView(field, LinearLayout.LayoutParams(0, -1, 1f))
            if (field === pass) row.addView(button("显示") {
                val visible = pass.transformationMethod is android.text.method.PasswordTransformationMethod
                pass.transformationMethod = if (visible) android.text.method.HideReturnsTransformationMethod.getInstance() else android.text.method.PasswordTransformationMethod.getInstance()
                pass.setSelection(pass.text.length)
                (row.getChildAt(2) as Button).text = if (visible) "隐藏" else "显示"
            }.apply { background = null; textSize = 11f; setTextColor(0xff659394.toInt()) }, LinearLayout.LayoutParams(dp(48), -1))
            form.addView(row, LinearLayout.LayoutParams(-1, dp(56)).apply { bottomMargin = dp(17) })
        }
        val options = LinearLayout(this)
        val remember = CheckBox(this).apply { text = "保存密码"; textSize = 11f; setTextColor(ink); buttonTintList = android.content.res.ColorStateList.valueOf(0xff4d9290.toInt()); isChecked = loginFormRemember; isEnabled = !busy }
        val automatic = CheckBox(this).apply { text = "自动登录"; textSize = 11f; setTextColor(ink); buttonTintList = android.content.res.ColorStateList.valueOf(0xff4d9290.toInt()); isChecked = loginFormAuto; isEnabled = !busy }
        remember.setOnCheckedChangeListener { _, checked -> if (!checked) automatic.isChecked = false }
        automatic.setOnCheckedChangeListener { _, checked -> if (checked) remember.isChecked = true }
        options.addView(remember, LinearLayout.LayoutParams(0, dp(40), 1f)); options.addView(automatic, LinearLayout.LayoutParams(0, dp(40), 1f)); form.addView(options)
        if (loginError.isNotBlank()) form.addView(label(loginError, 12f).apply { setTextColor(if (dark) 0xffffb5a9.toInt() else 0xffad5d50.toInt()); setPadding(dp(10), dp(10), dp(10), dp(10)); background = GradientDrawable().apply { setColor(if (dark) 0xff48343c.toInt() else 0xfffff0e9.toInt()); cornerRadius = dp(12).toFloat() } }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(10) })
        form.addView(button(if (busy) "正在连接学校…" else "登录，开启今天  →") {
            loginFormUser = user.text.toString().trim(); loginFormPassword = pass.text.toString(); loginFormRemember = remember.isChecked; loginFormAuto = automatic.isChecked
            if (previewScreen != null) { loginError = "这是界面预览，不会提交账号或连接学校。"; render() }
            else if (loginFormUser.isBlank() || loginFormPassword.isBlank()) { loginError = "请填写学号和密码"; render() }
            else authenticate(loginFormUser, loginFormPassword, loginFormRemember, loginFormAuto)
        }.apply { isEnabled = !busy; textSize = 15f; setTypeface(null, Typeface.BOLD); setTextColor(Color.WHITE); background = GradientDrawable(GradientDrawable.Orientation.LEFT_RIGHT, intArrayOf(0xff367ca9.toInt(), 0xff4c9588.toInt())).apply { cornerRadius = dp(17).toFloat() } }, LinearLayout.LayoutParams(-1, dp(56)).apply { topMargin = dp(16) })
        form.addView(button("▣  使用学校扫码登录") {
            if (previewScreen == null) { loginFormUser = user.text.toString().trim(); loginFormPassword = pass.text.toString(); openLogin(loginFormUser, "", false, true, false) }
        }.apply { isEnabled = !busy; background = null; setTextColor(if (dark) 0xffa1c6cd.toInt() else 0xff5c7b85.toInt()); textSize = 12f }, LinearLayout.LayoutParams(-1, dp(47)).apply { topMargin = dp(8) })
        content.addView(form)
        content.addView(label("◇  直连学校认证 · 数据留在本机", 11f).apply { gravity = Gravity.CENTER; alpha = .65f; setPadding(0, dp(24), 0, dp(6)) })
        content.addView(label("广东工贸职业技术学院 · 个人课表助手", 10f).apply { gravity = Gravity.CENTER; alpha = .4f })
        scroll.addView(content); page.addView(scroll, LinearLayout.LayoutParams(-1, -1))
    }
    private fun authenticate(username: String, password: String, remember: Boolean, automatic: Boolean, silent: Boolean = false) {
        if (busy) return
        busy = true; authSuppressed = false; loginFormAuto = automatic; loginError = ""; message = "正在重新连接学校…"; render()
        val sameAccount = username == store.username
        executor.execute {
            val result = runCatching { HttpLogin().login(username, password, if (sameAccount) store.term else null, store.currentWeek(), if (sameAccount) store.campus else null) }
            runOnUiThread { result.onSuccess { value ->
                installHttpCookies(value.cookies) {
                    val id = value.profile.studentId.ifBlank { username }
                    if (store.username != id) { store.term = null; store.campus = null }
                    store.username = id; profile = value.profile
                    value.calendar?.let { store.firstMonday = it.firstMonday; store.totalWeeks = it.totalWeeks }
                    store.saveCredentials(password, remember); store.prefs.edit().putBoolean("auto_login", automatic && remember).apply()
                    week = value.week; store.writeSchedule(week, value.schedule); schedule = value.schedule
                    busy = false; sessionExpired = false; loginScreen = false; loginFormPassword = ""; message = "已同步 · 课表与你一起出发"
                    if (store.prefs.getBoolean("reminders", false)) store.scheduleReminders(value.schedule, store.prefs.getInt("reminder_minutes", 10))
                    render()
                }
            }.onFailure { error ->
                busy = false
                if (error is HttpCaptchaRequired) {
                    message = "学校需要验证码，请完成验证"
                    openLogin(username, password, remember, false, false, error.url, error.cookies)
                } else {
                    val detail = error.message ?: "连接失败，请稍后重试"
                    if (silent) message = "自动登录失败 · $detail" else loginError = detail
                    render()
                }
            } }
        }
    }
    private fun openLogin(username: String, password: String, remember: Boolean, qr: Boolean, auto: Boolean, initialUrl: String? = null, sessionCookies: List<HttpCookie>? = null) {
        if (loginDialog != null) return
        // 浏览器在验证完成前可能已切换账户；取消时保留缓存，但不再用旧身份发业务请求。
        sessionExpired = true
        loginUsername = username; loginPassword = password; loginRemember = remember; loginQr = qr; loginVerified = false
        var submitted = false
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val hint = TextView(this).apply { text = "请在学校网页完成登录；验证码需要手动输入。"; setPadding(dp(16), dp(10), dp(16), dp(10)) }
        layout.addView(hint)
        val web = WebView(this)
        loginWeb = web
        web.settings.javaScriptEnabled = true; web.settings.domStorageEnabled = true; web.settings.userAgentString = SchoolConfig.userAgent
        CookieManager.getInstance().setAcceptCookie(true); CookieManager.getInstance().setAcceptThirdPartyCookies(web, true)
        web.webChromeClient = WebChromeClient()
        web.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String) {
                val location = Uri.parse(url)
                if (location.host == "eportal.gdgm.cn" && (location.path.orEmpty().startsWith("/new/index") || location.path.orEmpty() == "/index.html")) { view.loadUrl(SchoolConfig.entryUrl); return }
                if (location.host == Uri.parse(SchoolConfig.jwHost).host && location.path.orEmpty().contains("/framework/xsMain")) { verifyLogin(hint); return }
                if (location.host == "sfrz.gdgm.cn" && location.path.orEmpty().contains("/authserver/login") && !qr && !submitted) {
                    submitted = true
                    val js = """
                        (function(){
                          var u=${JSONObject.quote(username)},p=${JSONObject.quote(password)};
                          function fill(selector,value){var e=Array.from(document.querySelectorAll(selector)).find(function(e){return e.offsetParent!==null;});if(!e)return;e.focus();e.value=value;e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));e.dispatchEvent(new Event('keyup',{bubbles:true}));e.blur();}
                          fill('input[name="username"],#mobileUsername',u);fill('#mobilePassword,input[type="password"]',p);
                          ${if (auto) "setTimeout(function(){var captcha=typeof needCaptcha==='boolean'?needCaptcha:Array.from(document.querySelectorAll('input')).some(function(e){return /captcha|verify|code/i.test(e.name+' '+e.id)&&e.offsetParent!==null;});if(!captcha){var b=document.querySelector('#loginButton,#submitBtn,#load,#mobileLoginSubmit,#login_submit,#loginSubmit,button[type=submit],input[type=submit]');if(b)b.click();}},700);" else ""}
                          return 'filled';
                        })();
                    """.trimIndent()
                    view.evaluateJavascript(js, null)
                }
            }
        }
        layout.addView(web, LinearLayout.LayoutParams(-1, 0, 1f))
        layout.addView(button("已完成登录，验证并返回") { verifyLogin(hint) })
        val dialog = AlertDialog.Builder(this).setTitle(if (qr) "学校扫码登录" else "学校账号登录").setView(layout).setNegativeButton("取消", null).create()
        loginDialog = dialog
        dialog.setOnDismissListener { web.stopLoading(); web.destroy(); loginWeb = null; loginDialog = null; loginPassword = ""; if (!loginVerified) toast("已保留现有离线课表") }
        dialog.show(); dialog.window?.setLayout(-1, (resources.displayMetrics.heightPixels * .94).toInt()); dialog.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        val destination = initialUrl ?: if (qr) SchoolConfig.qrUrl else SchoolConfig.loginUrl
        if (sessionCookies != null) {
            installHttpCookies(sessionCookies) { if (loginWeb === web) web.loadUrl(destination) }
        } else if (qr || username != store.username) {
            CookieManager.getInstance().removeAllCookies {
                CookieManager.getInstance().flush()
                if (loginWeb === web) web.loadUrl(destination)
            }
        } else web.loadUrl(destination)
    }
    private fun verifyLogin(hint: TextView) {
        if (verifying) return
        verifying = true; busy = true; hint.text = "正在验证教务会话…"
        CookieManager.getInstance().flush()
        executor.execute {
            val result = runCatching {
                val p = client.fetchProfile()
                val id = p.studentId.ifBlank { loginUsername }
                require(id.isNotBlank()) { "无法识别学号，请先填写学号后重试" }
                val sameAccount = id == store.username
                val calendar = runCatching { client.fetchCalendar() }.getOrNull()
                val target = calendar?.currentWeek ?: store.currentWeek()
                val fresh = client.fetch(if (sameAccount) store.term else null, target, if (sameAccount) store.campus else null)
                Triple(fresh, calendar, p)
            }
            runOnUiThread {
                verifying = false; busy = false
                if (loginDialog == null) return@runOnUiThread
                result.onSuccess { (fresh, calendar, p) ->
                    val id = p.studentId.ifBlank { loginUsername }
                    val changedAccount = store.username != id
                    if (changedAccount) { store.term = null; store.campus = null }
                    store.username = id; profile = p
                    if (!loginQr || changedAccount) {
                        store.saveCredentials(loginPassword.takeIf { it.isNotBlank() }, loginRemember)
                        store.prefs.edit().putBoolean("auto_login", !loginQr && loginFormAuto && loginRemember).apply()
                    }
                    calendar?.let { store.firstMonday = it.firstMonday; store.totalWeeks = it.totalWeeks }
                    week = calendar?.currentWeek ?: store.currentWeek(); store.writeSchedule(week, fresh); schedule = fresh
                    loginVerified = true; authSuppressed = false; sessionExpired = false; loginScreen = false; loginFormPassword = ""; message = "登录成功 · 已同步课表"
                    if (store.prefs.getBoolean("reminders", false)) store.scheduleReminders(fresh, store.prefs.getInt("reminder_minutes", 10))
                    loginDialog?.dismiss(); render()
                }.onFailure { hint.text = "尚未完成教务登录：${it.message ?: "请继续在网页中操作"}" }
            }
        }
    }

    private fun share() {
        if (schedule == null) { toast("请先载入课表"); return }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; setPadding(dp(18), dp(18), dp(18), dp(18)); setBackgroundColor(Color.WHITE)
            addView(TextView(this@MainActivity).apply { text = "GMPluse · 第 $week 周课表"; textSize = 24f; setTextColor(0xff252c42.toInt()); setTypeface(null, Typeface.BOLD); setPadding(dp(36), 0, 0, dp(15)) })
            addView(grid(false))
            addView(TextView(this@MainActivity).apply { text = "${store.firstMonday.plusWeeks((week - 1).toLong())} · ${SchoolConfig.campuses[store.campus] ?: ""}"; textSize = 12f; setTextColor(Color.DKGRAY); gravity = Gravity.CENTER; setPadding(0, dp(12), 0, 0) })
        }
        content.measure(View.MeasureSpec.makeMeasureSpec(dp(560), View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
        content.layout(0, 0, content.measuredWidth, content.measuredHeight)
        val bitmap = Bitmap.createBitmap(content.measuredWidth, content.measuredHeight, Bitmap.Config.ARGB_8888)
        content.draw(Canvas(bitmap))
        executor.execute {
            val result = runCatching {
                val folder = File(cacheDir, "shared").apply { mkdirs() }
                File(folder, "timetable.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
            }
            runOnUiThread { result.onSuccess {
                val uri = Uri.parse("content://$packageName.share/timetable.png")
                startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply { type = "image/png"; putExtra(Intent.EXTRA_STREAM, uri); clipData = android.content.ClipData.newRawUri("课表", uri); addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION) }, "分享浅色课表图片"))
            }.onFailure { toast("导出失败：${it.message}") } }
        }
    }
    private fun checkUpdate() {
        toast("正在检查更新…")
        executor.execute {
            val result = runCatching {
                val connection = URL("https://github.com/qiu7c/GMPluse-Release/releases/latest/download/latest.json").openConnection() as HttpURLConnection
                connection.connectTimeout = 8000; connection.readTimeout = 20000
                try { connection.inputStream.bufferedReader().use { JSONObject(it.readText()) } } finally { connection.disconnect() }
            }
            runOnUiThread { result.onSuccess { data ->
                val code = data.optInt("versionCode", 0); val version = data.optString("version"); val apk = data.optString("apk")
                if (code <= 21) toast("当前已是最新版本 3.0.1")
                else AlertDialog.Builder(this).setTitle("发现新版本 $version").setMessage(data.optString("notes", "可前往官方发布页面下载更新。")).setPositiveButton("前往下载") { _, _ ->
                    val url = Uri.parse(apk)
                    if (url.scheme == "https" && url.host == "github.com") startActivity(Intent(Intent.ACTION_VIEW, url)) else startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/qiu7c/GMPluse-Release/releases/latest")))
                }.setNegativeButton("稍后", null).show()
            }.onFailure { toast("检查更新失败：${it.message}") } }
        }
    }
    private fun about() {
        AlertDialog.Builder(this).setTitle("GMPluse 3.0.1 (21)")
            .setMessage("Android 原生版 · Kotlin\n作者：cc\n邮箱：xcc575838@gmail.com\nQQ：921569084\n\n更新日志\n3.0.1：Android / iOS 原生迁移，直连学校教务，离线课表、课程备注、图片分享及本地课前提醒。\n\n本应用仅供个人查看课表，不用于商业用途。课表与学籍来自广东工贸职业技术学院教务系统，仅在本机展示，不上传第三方服务器。")
            .setPositiveButton("关闭", null).setNeutralButton("反馈") { _, _ -> startActivity(Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:xcc575838@gmail.com")).apply { putExtra(Intent.EXTRA_SUBJECT, "GMPluse Android 3.0.1 反馈") }) }.show()
    }
    private fun toast(text: String) { Toast.makeText(this, text, Toast.LENGTH_LONG).show() }
}
