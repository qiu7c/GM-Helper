package cn.gdgm.nativeapp

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.webkit.CookieManager
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class NativeStore(private val context: Context) {
    val prefs = context.getSharedPreferences("gm_native", Context.MODE_PRIVATE)
    private val cacheFile = File(context.filesDir, "schedule_cache.json")
    val backgroundFile = File(context.filesDir, "background.jpg")
    var username: String
        get() = prefs.getString("username", "").orEmpty()
        set(value) { prefs.edit().putString("username", value).apply() }
    var term: String?
        get() = prefs.getString("term", null)
        set(value) { prefs.edit().putString("term", value).apply() }
    var campus: String?
        get() = prefs.getString("campus", null)
        set(value) { prefs.edit().putString("campus", value).apply() }
    var firstMonday: LocalDate
        get() = LocalDate.parse(prefs.getString("first_monday", "2026-08-31"))
        set(value) { prefs.edit().putString("first_monday", value.toString()).apply() }
    var totalWeeks: Int
        get() = prefs.getInt("total_weeks", 20)
        set(value) { prefs.edit().putInt("total_weeks", value).apply() }

    init { migrateFlutter() }
    fun currentWeek() = SchoolConfig.weekOfDate(LocalDate.now(ZoneId.of("Asia/Shanghai")), firstMonday, totalWeeks)
    private fun scope(week: Int) = "$username|${term.orEmpty()}|${campus.orEmpty()}|$week"
    private fun readCache(): JSONObject {
        if (!cacheFile.exists()) return JSONObject()
        return try { JSONObject(cacheFile.readText()) } catch (_: JSONException) { JSONObject() }
    }
    fun readSchedule(week: Int): Schedule? {
        val value = readCache().optJSONObject(scope(week)) ?: return null
        return try { Schedule.fromJson(value) } catch (_: JSONException) { null } catch (_: IllegalArgumentException) { null }
    }
    fun writeSchedule(week: Int, schedule: Schedule) {
        // 服务端已确认选中项；首次默认查询后使用真实 scope 保存和查找。
        term = schedule.selectedTerm ?: term
        campus = schedule.selectedCampus ?: campus
        val all = readCache()
        all.put(scope(week), schedule.toJson())
        val oldest = all.keys().asSequence().toList().sortedBy { all.getJSONObject(it).optLong("fetchedAt") }
        oldest.dropLast(6).forEach { all.remove(it) }
        cacheFile.writeText(all.toString())
    }
    fun clearSession() {
        CookieManager.getInstance().removeAllCookies(null)
        CookieManager.getInstance().flush()
    }
    fun logout() {
        clearSession()
        cacheFile.delete()
        cancelReminders()
        // 保留账号以回填，但清除凭据和自动重登开关，重启也不会自行登录。
        saveCredentials(null, false)
        prefs.edit().putString("username", "").putBoolean("auto_login", false).apply()
    }
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("gmpluse-password", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("gmpluse-password", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    fun saveCredentials(password: String?, remember: Boolean) {
        val edit = prefs.edit().putBoolean("remember_password", remember)
        if (!remember || password.isNullOrEmpty()) edit.remove("password")
        else {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
            val encrypted = cipher.doFinal(password.toByteArray(Charsets.UTF_8))
            edit.putString("password", Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(encrypted, Base64.NO_WRAP))
        }
        edit.apply()
    }
    fun savedPassword(): String? {
        val raw = prefs.getString("password", null) ?: return null
        // 这里只处理持久化凭据损坏或系统密钥失效；不把异常分散到调用链。
        return try {
            val parts = raw.split(":", limit = 2)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)))
            }
            String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), Charsets.UTF_8)
        } catch (_: java.security.GeneralSecurityException) { null }
        catch (_: IllegalArgumentException) { null }
        catch (_: IndexOutOfBoundsException) { null }
    }
    fun note(courseName: String): String = JSONObject(prefs.getString("notes.$username", "{}").orEmpty()).optString(courseName)
    fun setNote(courseName: String, note: String) {
        val notes = JSONObject(prefs.getString("notes.$username", "{}").orEmpty())
        if (note.isBlank()) notes.remove(courseName) else notes.put(courseName, note.trim())
        prefs.edit().putString("notes.$username", notes.toString()).apply()
    }
    fun courseColorIndex(courseName: String): Int {
        val colors = JSONObject(prefs.getString("course_colors.$username", "{}").orEmpty())
        if (colors.has(courseName)) return colors.getInt(courseName)
        val index = colors.length() % 8
        colors.put(courseName, index)
        prefs.edit().putString("course_colors.$username", colors.toString()).apply()
        return index
    }
    fun setCourseColor(courseName: String, index: Int) {
        val colors = JSONObject(prefs.getString("course_colors.$username", "{}").orEmpty())
        colors.put(courseName, index)
        prefs.edit().putString("course_colors.$username", colors.toString()).apply()
    }
    fun saveBackground(uri: Uri) {
        context.contentResolver.openInputStream(uri).use { source ->
            requireNotNull(source) { "图片无法读取" }
            backgroundFile.outputStream().use { source.copyTo(it) }
        }
    }
    fun cancelReminders() {
        val alarm = context.getSystemService(AlarmManager::class.java)
        for (id in 0 until 60) alarm.cancel(PendingIntent.getBroadcast(context, id, Intent(context, ReminderReceiver::class.java), PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE) ?: continue)
        prefs.edit().remove("reminder_plan").apply()
    }
    fun scheduleReminders(schedule: Schedule, minutes: Int) {
        // 汇总同账号/学期/校区的缓存周，翻到空周不会取消本周已知的课程提醒。
        val all = readCache()
        val prefix = "$username|${term.orEmpty()}|${campus.orEmpty()}|"
        val plans = mutableListOf<JSONObject>()
        for (cacheKey in all.keys()) {
            if (!cacheKey.startsWith(prefix)) continue
            val entry = all.getJSONObject(cacheKey)
            val week = entry.optString("selectedWeek").toIntOrNull() ?: continue
            val cached = Schedule.fromJson(entry)
            val times = SchoolConfig.periodTimes(campus.orEmpty())
            for (course in cached.courses) {
                if (course.weeks.isNotEmpty() && week !in course.weeks) continue
                val start = times.getOrNull(course.period - 1)?.first.orEmpty()
                if (start.isEmpty()) continue
                val date = firstMonday.plusWeeks((week - 1).toLong()).plusDays((course.day - 1).toLong())
                val at = date.atTime(LocalTime.parse(start)).atZone(ZoneId.of("Asia/Shanghai")).toInstant().toEpochMilli() - minutes * 60000L
                if (at <= System.currentTimeMillis()) continue
                plans.add(JSONObject().put("at", at).put("title", "${course.name} · $minutes 分钟后上课")
                    .put("body", "$start · ${course.room.ifBlank { "教室待定" }} · ${course.teacher}"))
            }
        }
        cancelReminders()
        val sorted = plans.distinctBy { "${it.getLong("at")}|${it.getString("title")}|${it.getString("body")}" }.sortedBy { it.getLong("at") }.take(60)
        prefs.edit().putString("reminder_plan", JSONArray(sorted).toString()).apply()
        restoreReminders()
    }
    fun restoreReminders() {
        if (!prefs.getBoolean("reminders", false)) return
        val plan = JSONArray(prefs.getString("reminder_plan", "[]"))
        val alarm = context.getSystemService(AlarmManager::class.java)
        for (id in 0 until plan.length()) {
            val item = plan.getJSONObject(id)
            val at = item.getLong("at")
            if (at <= System.currentTimeMillis()) continue
            val intent = Intent(context, ReminderReceiver::class.java).putExtra("title", item.getString("title")).putExtra("body", item.getString("body")).putExtra("notificationId", id)
            val pending = PendingIntent.getBroadcast(context, id, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            if (android.os.Build.VERSION.SDK_INT < 31 || alarm.canScheduleExactAlarms()) alarm.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
            else alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
        }
    }
    private fun migrateFlutter() {
        if (prefs.getBoolean("flutter_migrated", false)) return
        val old = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val oldUser = old.getString("flutter.saved_username", "").orEmpty()
        if (oldUser.isNotEmpty()) {
            username = oldUser
            term = old.getString("flutter.last_term", null)
            campus = old.getString("flutter.last_campus", null)
            val edit = prefs.edit()
            old.getString("flutter.term_first_monday", null)?.let { edit.putString("first_monday", it.take(10)) }
            if (old.contains("flutter.term_total_weeks")) edit.putInt("total_weeks", old.getLong("flutter.term_total_weeks", 20).toInt())
            if (old.contains("flutter.bg_style")) edit.putInt("bg_style", old.getLong("flutter.bg_style", 1).toInt())
            val theme = old.getLong("flutter.theme_mode", 0).toInt()
            edit.putString("theme", listOf("system", "light", "dark").getOrElse(theme) { "system" })
            edit.putString("notes.$oldUser", old.getString("flutter.course_notes", "{}"))
            edit.putBoolean("auto_login", old.getBoolean("flutter.auto_login", false)).apply()
            if (old.getBoolean("flutter.save_password", false)) {
                saveCredentials(old.getString("flutter.saved_password", null), true)
                old.edit().remove("flutter.saved_password").apply()
            }
            old.getString("flutter.jw_cookie", null)?.split(';')?.forEach { CookieManager.getInstance().setCookie(SchoolConfig.jwHost + "/jsxsd/", it.trim() + "; Path=/jsxsd; Secure") }
            val image = old.getString("flutter.bg_image", null)?.let { File(it) }
            if (image?.isFile == true && image.canonicalPath.startsWith(context.dataDir.canonicalPath + File.separator)) image.copyTo(backgroundFile, overwrite = true)
            val cache = old.getString("flutter.schedule_cache_v1", null)
            if (cache != null) {
                val imported = try {
                    val source = JSONObject(cache)
                    val entries = JSONObject()
                    source.keys().forEach { cacheKey ->
                        val entry = source.getJSONObject(cacheKey)
                        if (entry.optBoolean("tableFound", true)) entries.put(cacheKey, Schedule.fromJson(entry).toJson())
                    }
                    entries
                } catch (_: JSONException) { JSONObject() } catch (_: IllegalArgumentException) { JSONObject() }
                cacheFile.writeText(imported.toString())
            }
        }
        prefs.edit().putBoolean("flutter_migrated", true).apply()
    }
}
