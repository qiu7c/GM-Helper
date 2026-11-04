package cn.gdgm.nativeapp

import org.json.JSONArray
import org.json.JSONObject
import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.nodes.TextNode
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.temporal.TemporalAdjusters

data class Course(
    val name: String, val teacher: String = "", val room: String = "",
    val teachingClass: String = "", val rawWeeks: String = "", val weeks: List<Int> = emptyList(),
    val day: Int, val period: Int, val sectionRange: String = ""
) {
    fun toJson() = JSONObject().put("name", name).put("teacher", teacher).put("room", room)
        .put("teachingClass", teachingClass).put("rawWeeks", rawWeeks).put("weeks", JSONArray(weeks))
        .put("day", day).put("period", period).put("sectionRange", sectionRange)
    companion object {
        fun fromJson(o: JSONObject): Course {
            val weeks = o.getJSONArray("weeks")
            return Course(o.getString("name"), o.optString("teacher"), o.optString("room"),
                o.optString("teachingClass"), o.optString("rawWeeks"),
                (0 until weeks.length()).map { weeks.getInt(it) }, o.getInt("day"), o.getInt("period"), o.optString("sectionRange"))
        }
    }
}

data class SelectOption(val value: String, val label: String)
data class Schedule(
    val courses: List<Course>, val terms: List<SelectOption>, val weeks: List<SelectOption>,
    val campuses: List<SelectOption>, val selectedTerm: String?, val selectedWeek: String?,
    val selectedCampus: String?, val remark: String = "", val fetchedAt: Long = System.currentTimeMillis()
) {
    fun toJson(): JSONObject {
        val o = JSONObject().put("courses", JSONArray(courses.map { it.toJson() }))
            .put("selectedTerm", selectedTerm).put("selectedWeek", selectedWeek).put("selectedCampus", selectedCampus)
            .put("remark", remark).put("fetchedAt", fetchedAt).put("tableFound", true)
        listOf("terms" to terms, "weeks" to weeks, "campuses" to campuses).forEach { (key, options) ->
            o.put(key, JSONArray(options.map { JSONObject().put("value", it.value).put("label", it.label) }))
        }
        return o
    }
    companion object {
        fun fromJson(o: JSONObject): Schedule {
            require(o.optBoolean("tableFound", true)) { "缓存不包含课表" }
            val array = o.getJSONArray("courses")
            val options = listOf("terms", "weeks", "campuses").map { key ->
                val a = o.optJSONArray(key) ?: JSONArray()
                (0 until a.length()).map { a.getJSONObject(it) }.map { SelectOption(it.getString("value"), it.getString("label")) }
            }
            fun selected(key: String): String? = if (o.has(key) && !o.isNull(key)) o.getString(key) else null
            return Schedule((0 until array.length()).map { Course.fromJson(array.getJSONObject(it)) },
                options[0], options[1], options[2], selected("selectedTerm"), selected("selectedWeek"),
                selected("selectedCampus"), o.optString("remark"), o.optLong("fetchedAt", System.currentTimeMillis()))
        }
    }
}
data class StudentProfile(val name: String, val studentId: String, val fields: List<Pair<String, String>>)
data class TermCalendar(val currentWeek: Int, val totalWeeks: Int, val date: LocalDate) {
    val firstMonday: LocalDate get() = date.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY)).minusWeeks((currentWeek - 1).toLong())
}

object SchoolConfig {
    const val jwHost = "https://jw.gdgm.cn"
    const val portal = "https://eportal.gdgm.cn"
    const val loginUrl = "https://sfrz.gdgm.cn/authserver/login?service=https%3A%2F%2Feportal.gdgm.cn%2Flogin%3Fservice%3Dhttps%3A%2F%2Feportal.gdgm.cn%2Fnew%2Findex.html%3Fbrowser%3Dno"
    const val qrUrl = "$loginUrl&display=qrLogin"
    const val entryUrl = "$portal/appShow?appId=5759540940956162"
    const val mainUrl = "$jwHost/jsxsd/framework/xsMain.jsp"
    const val scheduleUrl = "$jwHost/jsxsd/xskb/xskb_list.do"
    const val desktopUrl = "$jwHost/jsxsd/framework/xsMain_new.jsp"
    const val userAgent = "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Mobile Safari/537.36"
    val campuses = linkedMapOf(
        "3589FB3E8AD246BCBAD7BB5C8710D078" to "天河校区",
        "29637FA5710B46F3B01242A09D7E9CCD" to "白云校区",
        "0A10E5C18E814AEAA9456E91A7092394" to "荔湾校区"
    )
    fun periodTimes(campus: String): List<Pair<String, String>> = when (campus) {
        campuses.keys.elementAt(1) -> listOf("08:30" to "10:05", "10:25" to "12:00", "14:00" to "15:35", "15:55" to "17:30", "19:00" to "20:35", "20:40" to "21:25")
        campuses.keys.elementAt(2) -> listOf("08:30" to "10:05", "10:25" to "12:00", "14:00" to "15:35", "15:55" to "17:30", "19:00" to "20:35", "" to "")
        else -> listOf("08:00" to "09:40", "10:00" to "11:40", "14:00" to "15:35", "15:55" to "17:30", "18:50" to "20:30", "20:40" to "21:25")
    }
    fun weekOfDate(date: LocalDate, firstMonday: LocalDate, totalWeeks: Int): Int =
        ((java.time.temporal.ChronoUnit.DAYS.between(firstMonday, date).coerceAtLeast(0) / 7).toInt() + 1).coerceAtMost(totalWeeks)
}

class SessionExpired : Exception("登录已过期，缓存课表仍可查看，请重新登录")
class SchoolResponseError(message: String) : Exception(message)

object SchoolParser {
    fun checkResponse(status: Int, body: String) {
        if (status >= 500) throw SchoolResponseError("教务系统暂时不可用（HTTP $status），保留离线课表")
        if (status in 300..399 || (status == 200 && listOf("casLoginForm", "pwdDefaultEncryptSalt", "请先登录系统").any { body.contains(it) })) throw SessionExpired()
        if (status != 200) throw SchoolResponseError("教务返回 HTTP $status，保留离线课表")
    }
    fun parseWeeks(raw: String): List<Int> {
        val result = mutableSetOf<Int>()
        raw.replace(Regex("\\([^)]*\\)|\\[[^]]*]"), "").split(',').forEach { part ->
            val m = Regex("\\s*(\\d+)(?:\\s*-\\s*(\\d+))?\\s*").matchEntire(part) ?: return@forEach
            val start = m.groupValues[1].toInt()
            val end = m.groupValues[2].toIntOrNull() ?: start
            for (week in start..end) {
                if (raw.contains("单") && week % 2 == 0) continue
                if (raw.contains("双") && week % 2 != 0) continue
                result.add(week)
            }
        }
        return result.sorted()
    }
    fun schedule(body: String): Schedule {
        val doc = Jsoup.parse(body)
        val table = doc.selectFirst("#kbtable") ?: throw SchoolResponseError("未识别到课表，保留上次数据")
        val courses = mutableListOf<Course>()
        var remark = ""
        var period = 0
        for (row in table.select("tr").drop(1)) {
            val cells = row.children().filter { it.tagName() == "td" }
            if (row.selectFirst("th")?.text()?.contains("备注") == true) {
                remark = cells.firstOrNull()?.text().orEmpty()
                continue
            }
            if (cells.size < 7) continue
            period++
            cells.take(7).forEachIndexed { day, cell ->
                for (div in cell.select("div.kbcontent").filterNot { it.hasClass("sykb2") }) {
                    val blocks = mutableListOf(mutableListOf<org.jsoup.nodes.Node>())
                    var hasFont = false
                    for (node in div.childNodes()) {
                        val text = (node as? TextNode)?.text()?.trim().orEmpty()
                        if (text.isNotEmpty() && !(text.startsWith("(") && text.endsWith(")")) && hasFont) {
                            blocks.add(mutableListOf()); hasFont = false
                        }
                        blocks.last().add(node)
                        if (node is Element && node.tagName() == "font") hasFont = true
                    }
                    for (block in blocks) {
                        var name = ""; var teacher = ""; var room = ""; var teachingClass = ""; var raw = ""
                        for (node in block) {
                            if (node is TextNode) {
                                val text = node.text().trim()
                                if (text.startsWith("(") && text.endsWith(")")) teachingClass = text.substring(1, text.length - 1)
                                else if (text.isNotEmpty() && name.isEmpty()) name = text
                            } else if (node is Element && node.tagName() == "font") {
                                val value = node.text().trim()
                                when (node.attr("title")) {
                                    "老师" -> teacher = value
                                    "教室" -> room = value
                                    "周次(节次)" -> raw = value
                                    "" -> if (teachingClass.isEmpty() && value.startsWith("(")) teachingClass = value.trim('(', ')')
                                }
                            }
                        }
                        if (name.isNotEmpty()) courses.add(Course(name, teacher, room, teachingClass, raw, parseWeeks(raw), day + 1, period, Regex("\\[([^]]+)]").find(raw)?.groupValues?.get(1).orEmpty()))
                    }
                }
            }
        }
        if (period == 0) throw SchoolResponseError("课表结构不完整，保留上次数据")
        val selects = listOf("#xnxq01id", "#zc", "#kbjcmsid").map { selector ->
            val select = doc.selectFirst(selector)
            val options = select?.select("option").orEmpty()
            val selected = options.firstOrNull { it.hasAttr("selected") } ?: options.firstOrNull()
            options.filter { it.attr("value").isNotEmpty() }.map { SelectOption(it.attr("value"), it.text()) } to selected?.attr("value")
        }
        return Schedule(courses, selects[0].first, selects[1].first, selects[2].first,
            selects[0].second, selects[1].second, selects[2].second, remark)
    }
    fun calendar(body: String): TermCalendar? {
        val doc = Jsoup.parse(body)
        val week = doc.selectFirst("#li_showWeek")?.text() ?: return null
        val current = Regex("第\\s*(\\d+)\\s*周").find(week)?.groupValues?.get(1)?.toIntOrNull() ?: return null
        val total = Regex("/\\s*(\\d+)\\s*周").find(week)?.groupValues?.get(1)?.toIntOrNull() ?: return null
        val date = doc.selectFirst("#rq")?.attr("value") ?: return null
        return TermCalendar(current, total, LocalDate.parse(date))
    }
    fun profile(body: String): StudentProfile {
        val doc = Jsoup.parse(body)
        var name = ""; var id = ""
        val fields = mutableListOf<Pair<String, String>>()
        for (label in doc.select(".middletopttxlr .middletopdwxxtit")) {
            val key = label.text().trim().trimEnd(':', '：')
            val value = label.parent()?.selectFirst(".middletopdwxxcont")?.text().orEmpty()
            if (value.isEmpty()) continue
            when (key) {
                "学生姓名", "姓名" -> name = value
                "学生编号", "学号" -> id = value
                else -> fields.add(key to value)
            }
        }
        if (name.isEmpty()) name = doc.selectFirst(".ckgrxx")?.text().orEmpty()
        if (id.isEmpty()) id = Regex("var\\s+userid\\s*=\\s*['\"]([^'\"]+)['\"]").find(body)?.groupValues?.get(1).orEmpty()
        if (name.isEmpty() && id.isEmpty() && fields.isEmpty()) throw SchoolResponseError("未识别到学籍信息，请稍后刷新")
        return StudentProfile(name, id, fields)
    }
}

fun scheduleDiff(before: Schedule, after: Schedule): String? {
    if (before.selectedWeek == null || before.selectedWeek != after.selectedWeek || before.selectedTerm != after.selectedTerm || before.selectedCampus != after.selectedCampus) return null
    val old = before.courses.associateBy { Triple(it.name, it.day, it.period) }
    val new = after.courses.associateBy { Triple(it.name, it.day, it.period) }
    val added = new.keys.count { it !in old }
    val removed = old.keys.count { it !in new }
    val changed = new.count { (key, course) -> old[key]?.let { it.teacher != course.teacher || it.room != course.room || it.weeks.toSet() != course.weeks.toSet() } == true }
    return listOfNotNull(if (added > 0) "新增 $added 门" else null, if (removed > 0) "取消 $removed 门" else null,
        if (changed > 0) "调整 $changed 处" else null).takeIf { it.isNotEmpty() }?.joinToString("、")
}
