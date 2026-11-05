package cn.gdgm.nativeapp

import android.webkit.CookieManager
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

class SchoolClient {
    private fun request(url: String, form: Map<String, String>? = null): String {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = false
        connection.connectTimeout = 8000
        connection.readTimeout = 20000
        connection.setRequestProperty("User-Agent", SchoolConfig.userAgent)
        connection.setRequestProperty("Referer", SchoolConfig.mainUrl)
        CookieManager.getInstance().getCookie(url)?.let { connection.setRequestProperty("Cookie", it) }
        try {
            if (form != null) {
                connection.requestMethod = "POST"
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
                val body = form.entries.joinToString("&") { "${URLEncoder.encode(it.key, "UTF-8")}=${URLEncoder.encode(it.value, "UTF-8")}" }
                connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            }
            val status = connection.responseCode
            connection.headerFields.filterKeys { it?.equals("Set-Cookie", true) == true }.values.flatten().forEach {
                CookieManager.getInstance().setCookie(url, it)
            }
            val charset = Regex("charset=([^;\\s]+)", RegexOption.IGNORE_CASE).find(connection.contentType.orEmpty())
                ?.groupValues?.get(1)?.trim('"', '\'')?.let { charset(it) } ?: Charsets.UTF_8
            val body = (if (status >= 400) connection.errorStream else connection.inputStream)
                ?.bufferedReader(charset)?.use { it.readText() }.orEmpty()
            SchoolParser.checkResponse(status, body)
            return body
        } finally { connection.disconnect() }
    }
    fun fetch(term: String?, week: Int, campus: String?): Schedule {
        val form = linkedMapOf("zc" to week.toString())
        if (term != null) form["xnxq01id"] = term
        if (campus != null) form["kbjcmsid"] = campus
        val schedule = SchoolParser.schedule(request(SchoolConfig.scheduleUrl, form))
        if (schedule.selectedWeek != week.toString() || (term != null && schedule.selectedTerm != term) || (campus != null && schedule.selectedCampus != campus))
            throw SchoolResponseError("教务返回的学期、周次或校区与查询不符，保留上次课表")
        return schedule
    }
    fun fetchCalendar(): TermCalendar? = SchoolParser.calendar(request(SchoolConfig.desktopUrl))
    fun fetchProfile(): StudentProfile = SchoolParser.profile(request(SchoolConfig.desktopUrl))
    companion object {
        fun isSessionExpired(error: Throwable): Boolean = error is SessionExpired
    }
}
