package cn.gdgm.nativeapp

import android.webkit.CookieManager
import org.jsoup.Jsoup
import java.net.CookiePolicy
import java.net.HttpCookie
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLEncoder
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

data class HttpLoginResult(
    val profile: StudentProfile, val calendar: TermCalendar?, val schedule: Schedule,
    val cookies: List<HttpCookie>, val week: Int
)
class HttpCaptchaRequired(val cookies: List<HttpCookie>, val url: String) : Exception("学校要求验证码，请在认证页面完成验证")
class HttpLoginFailure(message: String) : Exception(message)
data class LoginReply(val status: Int, val headers: Map<String, List<String>>, val body: String)

object CasProtocol {
    private val random = SecureRandom()
    private fun randomText(length: Int): String {
        val chars = "ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678"
        return (1..length).map { chars[random.nextInt(chars.length)] }.joinToString("")
    }
    fun encrypt(password: String, salt: String, prefix: String = randomText(64), iv: String = randomText(16)): String {
        val key = salt.toByteArray(Charsets.UTF_8)
        if (key.size !in listOf(16, 24, 32)) throw HttpLoginFailure("学校登录页的加密参数已变化，请稍后重试")
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv.toByteArray(Charsets.UTF_8)))
        return Base64.getEncoder().encodeToString(cipher.doFinal((prefix + password).toByteArray(Charsets.UTF_8)))
    }
}

class HttpLogin(private val transport: (String, String, String?, Map<String, String>) -> LoginReply = ::network) {
    private val jar = java.net.CookieManager(null, CookiePolicy.ACCEPT_ALL)
    private fun cookies() = jar.cookieStore.cookies.map { it.clone() as HttpCookie }
    private fun follow(method: String, url: String, form: Map<String, String>? = null, referer: String = SchoolConfig.loginUrl): Pair<String, LoginReply> {
        var current = url
        var verb = method
        var body = form?.entries?.joinToString("&") { "${URLEncoder.encode(it.key, "UTF-8")}=${URLEncoder.encode(it.value, "UTF-8")}" }
        var previous = referer
        repeat(16) {
            val uri = URI(current)
            if (uri.scheme != "https" || uri.host !in setOf("sfrz.gdgm.cn", "eportal.gdgm.cn", "jw.gdgm.cn")) throw HttpLoginFailure("学校认证跳转地址发生变化，登录已停止")
            val headers = linkedMapOf("User-Agent" to SchoolConfig.userAgent, "Referer" to previous)
            jar.get(uri, emptyMap()).entries.firstOrNull { it.key.equals("Cookie", true) }?.value?.let { headers["Cookie"] = it.joinToString("; ") }
            if (verb == "POST") {
                headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
                if (uri.host == "sfrz.gdgm.cn") headers["Origin"] = "https://sfrz.gdgm.cn"
            }
            val reply = transport(verb, current, body, headers)
            jar.put(uri, reply.headers)
            if (reply.status >= 500) throw HttpLoginFailure("学校认证暂时不可用，请稍后再试")
            if (reply.status in listOf(301, 302, 303, 307, 308)) {
                val location = reply.headers.entries.firstOrNull { it.key.equals("Location", true) }?.value?.firstOrNull()
                    ?: throw HttpLoginFailure("学校认证跳转缺少地址")
                previous = current
                current = uri.resolve(location).toString()
                if (reply.status !in listOf(307, 308)) { verb = "GET"; body = null }
            } else return current to reply
        }
        throw HttpLoginFailure("学校认证跳转未完成，请稍后重试")
    }
    fun login(username: String, password: String, term: String?, week: Int, campus: String?): HttpLoginResult {
        require(username.isNotBlank() && password.isNotEmpty()) { "请输入学号和密码" }
        val (pageUrl, page) = follow("GET", SchoolConfig.loginUrl)
        if (page.status != 200) throw HttpLoginFailure("无法打开学校认证服务（HTTP ${page.status}）")
        val doc = Jsoup.parse(page.body)
        val form = doc.selectFirst("#casLoginForm") ?: throw HttpLoginFailure("学校登录页面已变化，暂时无法登录")
        val fields = form.select("input[name]").associate { it.attr("name") to it.attr("value") }.toMutableMap()
        var salt = Regex("pwdDefaultEncryptSalt\\s*=\\s*['\"]([^'\"]+)['\"]").find(page.body)?.groupValues?.get(1)
            ?: doc.selectFirst("#pwdEncryptSalt")?.attr("value")
            ?: throw HttpLoginFailure("学校登录页缺少加密参数")
        val (_, captcha) = follow("GET", "https://sfrz.gdgm.cn/authserver/needCaptcha.html?username=${URLEncoder.encode(username, "UTF-8")}&pwdEncrypt2=pwdEncryptSalt&_=${System.currentTimeMillis()}", referer = pageUrl)
        if (captcha.status != 200) throw HttpLoginFailure("暂时无法查询学校验证状态")
        val parts = captcha.body.trim().split("::::", limit = 2)
        when (parts[0].lowercase()) {
            "true" -> throw HttpCaptchaRequired(cookies(), pageUrl)
            "false" -> if (parts.size == 2) salt = parts[1].trim()
            else -> throw HttpLoginFailure("学校验证服务未返回有效结果，请稍后再试")
        }
        val action = URI(pageUrl).resolve(form.attr("action").ifBlank { pageUrl }).toString()
        if (URI(action).host != "sfrz.gdgm.cn") throw HttpLoginFailure("学校登录表单地址已变化")
        fields["username"] = username
        fields["password"] = CasProtocol.encrypt(password, salt)
        val (submittedUrl, submitted) = follow("POST", action, fields, pageUrl)
        if (URI(submittedUrl).host == "sfrz.gdgm.cn" || submitted.body.contains("casLoginForm")) {
            val failed = Jsoup.parse(submitted.body)
            val explicit = failed.selectFirst("#showErrorTip, #msg, .errors, .login-error")?.text()
                ?: Regex("showTips\\(\\s*['\"]([^'\"]+)['\"]\\s*\\)").find(submitted.body)?.groupValues?.get(1)
            val hint = (explicit ?: failed.body().text()).replace(username, "[账号]").replace(password, "[密码]").take(220)
            if (explicit?.contains("验证码") == true) throw HttpCaptchaRequired(cookies(), submittedUrl)
            throw HttpLoginFailure(if (hint.isBlank()) "学校认证未完成，请核对账号密码" else hint)
        }
        follow("GET", SchoolConfig.entryUrl, referer = SchoolConfig.portal)
        val service = URLEncoder.encode(SchoolConfig.jwHost + "/jsxsd/sso.jsp", "UTF-8")
        follow("GET", "https://sfrz.gdgm.cn/authserver/login?service=$service", referer = SchoolConfig.jwHost + "/jsxsd/sso.jsp")
        val (_, main) = follow("GET", SchoolConfig.mainUrl, referer = SchoolConfig.portal)
        SchoolParser.checkResponse(main.status, main.body)
        if (!listOf("/jsxsd/", "xsMain_new.jsp", "ckgrxx").any { main.body.contains(it) }) throw HttpLoginFailure("学校教务授权尚未完成")
        val (_, desktop) = follow("GET", SchoolConfig.desktopUrl, referer = SchoolConfig.mainUrl)
        SchoolParser.checkResponse(desktop.status, desktop.body)
        val profile = try { SchoolParser.profile(desktop.body) } catch (_: SchoolResponseError) { SchoolParser.profile(main.body) }
        if (profile.studentId.isBlank()) throw HttpLoginFailure("尚未取得学号，未保存登录状态")
        val calendar = SchoolParser.calendar(desktop.body)
        val targetWeek = calendar?.currentWeek ?: week
        val query = linkedMapOf("zc" to targetWeek.toString())
        if (term != null) query["xnxq01id"] = term
        if (campus != null) query["kbjcmsid"] = campus
        val (_, reply) = follow("POST", SchoolConfig.scheduleUrl, query, SchoolConfig.mainUrl)
        SchoolParser.checkResponse(reply.status, reply.body)
        val schedule = SchoolParser.schedule(reply.body)
        if (schedule.selectedWeek != targetWeek.toString() || (term != null && schedule.selectedTerm != term) || (campus != null && schedule.selectedCampus != campus)) throw HttpLoginFailure("学校返回的课表范围与请求不符，未保存登录状态")
        return HttpLoginResult(profile, calendar, schedule, cookies(), targetWeek)
    }
    companion object {
        private fun network(method: String, url: String, body: String?, headers: Map<String, String>): LoginReply {
            val connection = URL(url).openConnection() as HttpURLConnection
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 8000; connection.readTimeout = 20000
            connection.requestMethod = method
            headers.forEach { (key, value) -> connection.setRequestProperty(key, value) }
            try {
                if (body != null) {
                    connection.doOutput = true
                    connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                }
                val status = connection.responseCode
                val charset = Regex("charset=([^;\\s]+)", RegexOption.IGNORE_CASE).find(connection.contentType.orEmpty())
                    ?.groupValues?.get(1)?.trim('"', '\'')?.let { charset(it) } ?: Charsets.UTF_8
                val text = (if (status >= 400) connection.errorStream else connection.inputStream)?.bufferedReader(charset)?.use { it.readText() }.orEmpty()
                return LoginReply(status, connection.headerFields.filterKeys { it != null }, text)
            } finally { connection.disconnect() }
        }
    }
}

/** Only call on the UI thread: finish CookieManager callbacks before reading business pages. */
fun installHttpCookies(cookies: List<HttpCookie>, onComplete: () -> Unit) {
    val manager = CookieManager.getInstance()
    manager.removeAllCookies {
        if (cookies.isEmpty()) { manager.flush(); onComplete(); return@removeAllCookies }
        var remaining = cookies.size
        for (cookie in cookies) {
            val host = cookie.domain.trimStart('.')
            val path = cookie.path ?: "/"
            val value = buildString {
                append("${cookie.name}=${cookie.value}; Path=$path")
                append("; Domain=${cookie.domain}")
                if (cookie.secure) append("; Secure")
                if (cookie.isHttpOnly) append("; HttpOnly")
                if (cookie.maxAge >= 0) append("; Max-Age=${cookie.maxAge}")
            }
            manager.setCookie("https://$host$path", value) {
                remaining--
                if (remaining == 0) { manager.flush(); onComplete() }
            }
        }
    }
}
