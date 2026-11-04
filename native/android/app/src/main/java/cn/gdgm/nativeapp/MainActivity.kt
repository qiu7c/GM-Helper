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
        week = store.currentWeek()
        schedule = store.readSchedule(week)
        if (schedule != null) message = "已载入离线课表"
        render()
        clock.post(tick)
        if (store.username.isNotBlank()) load()
    }
    override fun onDestroy() {
        clock.removeCallbacks(tick); loginWeb?.destroy(); executor.shutdown(); super.onDestroy()
    }
    override fun onConfigurationChanged(newConfig: Configuration) { super.onConfigurationChanged(newConfig); render() }

    private fun label(text: String, size: Float = 15f, bold: Boolean = false) = TextView(this).apply {
        this.text = text; textSize = size; setTextColor(ink)
        if (bold) setTypeface(null, Typeface.BOLD)
    }
    private fun button(title: String, action: () -> Unit) = Button(this).apply {
        text = title; isAllCaps = false; textSize = 13f; setTextColor(ink)
        backgroundTintList = android.content.res.ColorStateList.valueOf(if (dark) 0xcc35394d.toInt() else 0xccffffff.toInt())
        setOnClickListener { action() }
    }
    private fun card(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL; setPadding(dp(16), dp(12), dp(16), dp(12))
        background = GradientDrawable().apply { setColor(if (dark) 0xd024293a.toInt() else 0xe6ffffff.toInt()); cornerRadius = dp(20).toFloat(); setStroke(dp(1), if (dark) 0x335c6586 else 0x66ffffff) }
    }
    private fun render() {
        setTheme(if (dark) android.R.style.Theme_Material_NoActionBar else android.R.style.Theme_Material_Light_NoActionBar)
        window.statusBarColor = if (dark) 0xff202434.toInt() else 0xffedf1fc.toInt()
        window.navigationBarColor = window.statusBarColor
        window.decorView.systemUiVisibility = if (dark) 0 else View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
        root = FrameLayout(this)
        root.setOnApplyWindowInsetsListener { view, insets ->
            view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop, insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
            insets
        }
        val styles = arrayOf(intArrayOf(0xffe8edf9.toInt(), 0xfff4e8ed.toInt()), intArrayOf(0xffe4edfa.toInt(), 0xffeee5f5.toInt()), intArrayOf(0xffd9f0e9.toInt(), 0xffedf1e3.toInt()), intArrayOf(0xfff9e7d9.toInt(), 0xfff3e2eb.toInt()), intArrayOf(0xffdce5ec.toInt(), 0xffe9edf0.toInt()))
        root.background = GradientDrawable(GradientDrawable.Orientation.TL_BR, if (dark) intArrayOf(0xff182131.toInt(), 0xff30283f.toInt()) else styles[store.prefs.getInt("bg_style", 1).coerceIn(0, 4)])
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
        page = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(12), dp(8), dp(12), 0) }
        root.addView(page, FrameLayout.LayoutParams(-1, -1))
        setContentView(root)
        if (tab == 0) renderTimetable() else renderMine()
        val nav = LinearLayout(this).apply { gravity = Gravity.CENTER; setPadding(dp(22), dp(5), dp(22), dp(6)) }
        nav.addView(button(if (tab == 0) "▦  课表" else "课表") { tab = 0; render() }, LinearLayout.LayoutParams(0, dp(52), 1f))
        nav.addView(button(if (tab == 1) "●  我的" else "我的") { tab = 1; render() }, LinearLayout.LayoutParams(0, dp(52), 1f))
        page.addView(nav)
    }

    private fun renderTimetable() {
        val top = card()
        val title = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL }
        title.addView(label("我的课表", 25f, true), LinearLayout.LayoutParams(0, -2, 1f))
        title.addView(button("分享") { share() }); title.addView(button("刷新") { load() })
        top.addView(title)
        val controls = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL }
        controls.addView(button("‹") { changeWeek(week - 1) }, LinearLayout.LayoutParams(dp(48), dp(48)))
        controls.addView(button("第 $week 周 ▾") { chooseWeek() }, LinearLayout.LayoutParams(0, dp(48), 1f))
        controls.addView(button("›") { changeWeek(week + 1) }, LinearLayout.LayoutParams(dp(48), dp(48)))
        controls.addView(button("本周") { changeWeek(store.currentWeek()) })
        top.addView(controls)
        val monday = store.firstMonday.plusWeeks((week - 1).toLong())
        top.addView(label("${monday.format(DateTimeFormatter.ofPattern("M月d日"))} — ${monday.plusDays(6).format(DateTimeFormatter.ofPattern("M月d日"))}  ·  点击日期跳周", 12f).apply { setPadding(0, dp(4), 0, dp(8)); setOnClickListener { chooseDate() } })
        status = label("", 13f).apply { setPadding(0, dp(4), 0, dp(8)) }
        top.addView(status); updateNow()
        top.addView(label(message, 11f).apply { alpha = .72f; setOnClickListener { if (store.username.isBlank() || sessionExpired) credentials() else load() } })
        page.addView(top)
        val scroll = ScrollView(this).apply { isFillViewport = true; clipToPadding = false; setPadding(0, dp(10), 0, dp(8)) }
        val body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        if (schedule == null) {
            body.addView(card().apply {
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
    private fun grid(exportDark: Boolean) = TimetableView(this, schedule?.courses.orEmpty(), week, store.firstMonday.plusWeeks((week - 1).toLong()), store.campus ?: SchoolConfig.campuses.keys.first(), exportDark, store::note, ::courseDetails, ::editNote)

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
        AlertDialog.Builder(this).setTitle(c.name).setMessage("教师：${c.teacher}\n教室：${c.room}\n教学班：${c.teachingClass}\n周次：${c.rawWeeks}\n节次：${c.sectionRange.ifBlank { "第 ${c.period} 大节" }}\n时间：${time.first}–${time.second}\n\n备注：${store.note(c.name).ifBlank { "暂无" }}")
            .setPositiveButton("编辑备注") { _, _ -> editNote(c) }.setNegativeButton("关闭", null).show()
    }
    private fun editNote(c: Course) {
        val field = EditText(this).apply { setText(store.note(c.name)); hint = "这门课的个人备注"; minLines = 3; gravity = Gravity.TOP; setPadding(dp(20), dp(12), dp(20), dp(12)) }
        AlertDialog.Builder(this).setTitle(c.name).setView(field).setPositiveButton("保存") { _, _ -> store.setNote(c.name, field.text.toString().trim()); render() }.setNeutralButton("删除") { _, _ -> store.setNote(c.name, ""); render() }.setNegativeButton("取消", null).show()
    }

    private fun load() {
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
                        autoAttempted = true; openLogin(store.username, store.savedPassword().orEmpty(), true, false, true)
                    }
                }
                if (week != requestedWeek && !sessionExpired) load()
            }
        }
    }

    private fun renderMine() {
        page.addView(label("我的", 28f, true).apply { setPadding(dp(6), dp(9), 0, dp(16)) })
        val scroll = ScrollView(this)
        val body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val account = card()
        account.addView(label(profile?.name ?: store.username.ifBlank { "欢迎使用 GMPluse" }, 22f, true))
        account.addView(label(if (store.username.isBlank()) "登录学校账号，同步个人课表" else "学号 ${store.username}", 13f))
        account.addView(button(if (store.username.isBlank()) "登录" else "查看学籍信息") { if (store.username.isBlank()) credentials() else showProfile() })
        if (store.username.isNotBlank()) account.addView(button("重新登录 / 切换账号") { credentials() })
        body.addView(account)
        fun row(title: String, subtitle: String = "", action: () -> Unit) {
            val view = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL; setPadding(dp(16), dp(16), dp(16), dp(16)); addView(label("$title  ›", 15f, true))
                if (subtitle.isNotBlank()) addView(label(subtitle, 12f).apply { alpha = .72f; setPadding(0, dp(5), 0, 0) })
                setOnClickListener { action() }
            }
            body.addView(view)
        }
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
        row("深浅色", mapOf("system" to "跟随系统", "light" to "浅色", "dark" to "深色")[store.prefs.getString("theme", "system")] ?: "跟随系统") {
            choose("深浅色", listOf("跟随系统", "浅色", "深色")) { store.prefs.edit().putString("theme", listOf("system", "light", "dark")[it]).apply(); render() }
        }
        row("背景与模糊", if (store.backgroundFile.exists()) "自定义照片" else "渐变背景") { backgroundSettings() }
        fun toggle(title: String, key: String, action: (Boolean) -> Unit) {
            body.addView(Switch(this).apply {
                text = title; textSize = 15f; setTextColor(ink); setPadding(dp(16), dp(12), dp(16), dp(12)); isChecked = store.prefs.getBoolean(key, false)
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
        body.addView(label("提醒由此设备发出。未允许精确闹钟时，系统会使用非精确提醒；省电和通知设置也可能造成延迟。", 11f).apply { alpha = .7f; setPadding(dp(16), 0, dp(16), dp(12)) })
        row("检查更新", "当前版本 3.0.0 (20)") { checkUpdate() }
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
        val content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(24), dp(8), dp(24), 0) }
        val user = EditText(this).apply { hint = "学号"; setText(store.username); inputType = InputType.TYPE_CLASS_TEXT; setAutofillHints(View.AUTOFILL_HINT_USERNAME) }
        val pass = EditText(this).apply { hint = "密码（可在学校网页中填写）"; inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD; setText(store.savedPassword().orEmpty()); setAutofillHints(View.AUTOFILL_HINT_PASSWORD) }
        val remember = CheckBox(this).apply { text = "在此设备保存密码"; isChecked = rememberDefault }
        val automatic = CheckBox(this).apply { text = "会话失效时自动登录"; isChecked = autoDefault }
        content.addView(user); content.addView(pass); content.addView(remember); content.addView(automatic)
        content.addView(TextView(this).apply { text = "统一认证由学校页面处理；如出现验证码，请直接在网页中完成。"; setPadding(0, dp(10), 0, dp(10)) })
        AlertDialog.Builder(this).setTitle("登录学校统一认证").setView(content)
            .setPositiveButton("账号登录") { _, _ ->
                authSuppressed = false; store.prefs.edit().putBoolean("auto_login", automatic.isChecked && remember.isChecked).apply()
                openLogin(user.text.toString().trim(), pass.text.toString(), remember.isChecked, false, pass.text.isNotEmpty())
            }.setNeutralButton("扫码登录") { _, _ -> authSuppressed = false; openLogin(user.text.toString().trim(), "", false, true, false) }.setNegativeButton("取消", null).show()
    }
    private fun openLogin(username: String, password: String, remember: Boolean, qr: Boolean, auto: Boolean) {
        if (loginDialog != null) return
        loginUsername = username; loginPassword = password; loginRemember = remember; loginQr = qr; loginVerified = false
        if (qr || username != store.username) store.clearSession()
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
                          function fill(selector,value){var e=Array.from(document.querySelectorAll(selector)).find(function(e){return e.offsetParent!==null;});if(!e)return;e.focus();e.value=value;e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));e.dispatchEvent(new Event('keyup',{bubbles:true}));}
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
        web.loadUrl(if (qr) SchoolConfig.qrUrl else SchoolConfig.loginUrl)
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
                        if (!loginRemember) store.prefs.edit().putBoolean("auto_login", false).apply()
                    }
                    calendar?.let { store.firstMonday = it.firstMonday; store.totalWeeks = it.totalWeeks }
                    week = calendar?.currentWeek ?: store.currentWeek(); store.writeSchedule(week, fresh); schedule = fresh
                    loginVerified = true; authSuppressed = false; sessionExpired = false; message = "登录成功 · 已同步课表"
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
                if (code <= 20) toast("当前已是最新版本 3.0.0")
                else AlertDialog.Builder(this).setTitle("发现新版本 $version").setMessage(data.optString("notes", "可前往官方发布页面下载更新。")).setPositiveButton("前往下载") { _, _ ->
                    val url = Uri.parse(apk)
                    if (url.scheme == "https" && url.host == "github.com") startActivity(Intent(Intent.ACTION_VIEW, url)) else startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/qiu7c/GMPluse-Release/releases/latest")))
                }.setNegativeButton("稍后", null).show()
            }.onFailure { toast("检查更新失败：${it.message}") } }
        }
    }
    private fun about() {
        AlertDialog.Builder(this).setTitle("GMPluse 3.0.0 (20)")
            .setMessage("Android 原生版 · Kotlin\n作者：cc\n邮箱：xcc575838@gmail.com\nQQ：921569084\n\n更新日志\n3.0.0：Android / iOS 原生迁移，直连学校教务，离线课表、课程备注、图片分享及本地课前提醒。\n\n本应用仅供个人查看课表，不用于商业用途。课表与学籍来自广东工贸职业技术学院教务系统，仅在本机展示，不上传第三方服务器。")
            .setPositiveButton("关闭", null).setNeutralButton("反馈") { _, _ -> startActivity(Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:xcc575838@gmail.com")).apply { putExtra(Intent.EXTRA_SUBJECT, "GMPluse Android 3.0.0 反馈") }) }.show()
    }
    private fun toast(text: String) { Toast.makeText(this, text, Toast.LENGTH_LONG).show() }
}
