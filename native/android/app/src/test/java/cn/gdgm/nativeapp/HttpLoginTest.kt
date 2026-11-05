package cn.gdgm.nativeapp

import org.junit.Assert.*
import org.junit.Test
import java.net.URI
import java.net.URLDecoder
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

class HttpLoginTest {
    private val form = """<form id="casLoginForm" action="/authserver/login"><input name="execution" value="nonce-7"><input name="lt" value="dynamic-token"></form><script>pwdDefaultEncryptSalt="0123456789abcdef";</script>"""
    private fun fixture(name: String) = javaClass.getResource("/$name")!!.readText()
    @Test fun aesMatchesIndependentKnownVector() {
        assertEquals("C5sV2ktEoPUVHc/EwB811XB+8Q2GjXiGjtyRUKn0tZBPMOykE8qp5hBRsHxL1HNb9wqYtOXhfT0V4GBzEezbbwEeg0s5xeVEJS/+jm+qwYI=",
            CasProtocol.encrypt("test-password", "0123456789abcdef", "A".repeat(64), "A".repeat(16)))
    }
    @Test fun captchaPreservesSessionAndDoesNotSubmitPassword() {
        var posts = 0
        val client = HttpLogin { method, url, _, _ ->
            if (method == "POST") posts++
            if (URI(url).path.endsWith("needCaptcha.html")) LoginReply(200, emptyMap(), "true::::fedcba9876543210")
            else LoginReply(200, mapOf("Set-Cookie" to listOf("CASID=synthetic; Path=/authserver; Secure")), form)
        }
        val error = assertThrows(HttpCaptchaRequired::class.java) { client.login("synthetic-user", "fake-password", null, 7, null) }
        assertEquals(0, posts)
        assertTrue(error.cookies.any { it.name == "CASID" && it.value == "synthetic" })
        assertTrue(error.url.startsWith("https://sfrz.gdgm.cn/authserver/login"))
    }
    @Test fun invalidCaptchaResponseStopsWithoutOpeningOrPosting() {
        var posts = 0
        val client = HttpLogin { method, url, _, _ ->
            if (method == "POST") posts++
            LoginReply(200, emptyMap(), if (URI(url).path.endsWith("needCaptcha.html")) "maintenance" else form)
        }
        assertThrows(HttpLoginFailure::class.java) { client.login("synthetic-user", "fake-password", null, 7, null) }
        assertEquals(0, posts)
    }
    @Test fun wrongPasswordIsReportedOnceWithCredentialsRedacted() {
        var posts = 0
        val client = HttpLogin { method, url, _, _ ->
            when {
                method == "POST" -> { posts++; LoginReply(200, emptyMap(), "<form id=casLoginForm></form><div id=msg>synthetic-user 的 fake-password 有误</div>") }
                URI(url).path.endsWith("needCaptcha.html") -> LoginReply(200, emptyMap(), "false")
                else -> LoginReply(200, emptyMap(), form)
            }
        }
        val error = assertThrows(HttpLoginFailure::class.java) { client.login("synthetic-user", "fake-password", null, 7, null) }
        assertEquals(1, posts)
        assertTrue(error.message!!.contains("有误"))
        assertFalse(error.message!!.contains("fake-password"))
        assertFalse(error.message!!.contains("synthetic-user"))
    }
    @Test fun fullHttpLoginRefreshesSaltFollowsBothSsoStagesAndGetsSchedule() {
        var submitted = 0
        var authorizedForJw = false
        val salt = "fedcba9876543210"
        val client = HttpLogin { method, url, body, headers ->
            val uri = URI(url)
            when {
                uri.host == "sfrz.gdgm.cn" && uri.path.endsWith("needCaptcha.html") -> {
                    assertTrue(uri.query.contains("pwdEncrypt2=pwdEncryptSalt"))
                    assertTrue(headers["Cookie"].orEmpty().contains("CASID=synthetic"))
                    LoginReply(200, emptyMap(), "false::::$salt")
                }
                uri.host == "sfrz.gdgm.cn" && method == "POST" -> {
                    submitted++
                    val fields = body!!.split('&').associate { val parts = it.split('=', limit = 2); URLDecoder.decode(parts[0], "UTF-8") to URLDecoder.decode(parts[1], "UTF-8") }
                    assertEquals("dynamic-token", fields["lt"])
                    assertEquals("nonce-7", fields["execution"])
                    assertNotEquals("fake-password", fields["password"])
                    val decryptor = Cipher.getInstance("AES/CBC/PKCS5Padding")
                    decryptor.init(Cipher.DECRYPT_MODE, SecretKeySpec(salt.toByteArray(), "AES"), IvParameterSpec(ByteArray(16)))
                    val decrypted = decryptor.doFinal(Base64.getDecoder().decode(fields["password"]))
                    assertEquals("fake-password", String(decrypted.copyOfRange(64, decrypted.size)))
                    LoginReply(302, mapOf("Location" to listOf(SchoolConfig.portal + "/new/index.html"), "Set-Cookie" to listOf("TGC=synthetic-tgc; Path=/authserver; Secure")), "")
                }
                uri.host == "sfrz.gdgm.cn" && uri.query.orEmpty().contains("jw.gdgm.cn") -> {
                    assertTrue(headers["Cookie"].orEmpty().contains("TGC=synthetic-tgc"))
                    authorizedForJw = true
                    LoginReply(302, mapOf("Location" to listOf(SchoolConfig.jwHost + "/jsxsd/sso.jsp?ticket=synthetic-ticket")), "")
                }
                uri.host == "sfrz.gdgm.cn" -> LoginReply(200, mapOf("Set-Cookie" to listOf("CASID=synthetic; Path=/authserver; Secure")), form)
                uri.path == "/new/index.html" -> LoginReply(200, emptyMap(), "portal")
                uri.path == "/appShow" -> LoginReply(302, mapOf("Location" to listOf(SchoolConfig.jwHost + "/jsxsd/sso.jsp")), "")
                uri.path == "/jsxsd/sso.jsp" && authorizedForJw -> LoginReply(302, mapOf("Location" to listOf(SchoolConfig.mainUrl), "Set-Cookie" to listOf("JSESSIONID=synthetic-jw; Path=/jsxsd; Secure")), "")
                uri.path == "/jsxsd/sso.jsp" -> LoginReply(200, emptyMap(), "<script>window.location.href='https://sfrz.gdgm.cn/authserver/login?service=school'</script>")
                uri.path.endsWith("xsMain.jsp") -> { assertTrue(authorizedForJw); LoginReply(200, emptyMap(), "<a href='/jsxsd/'>教务</a>") }
                uri.path.endsWith("xsMain_new.jsp") -> LoginReply(200, emptyMap(), fixture("profile.html") + "<div id=li_showWeek>第7周/20周</div><input id=rq value='2026-10-21'>")
                uri.path.endsWith("xskb_list.do") -> {
                    assertTrue(headers["Cookie"].orEmpty().contains("JSESSIONID=synthetic-jw"))
                    assertFalse(headers["Cookie"].orEmpty().contains("TGC="))
                    LoginReply(200, emptyMap(), fixture("schedule.html"))
                }
                else -> throw AssertionError("Unexpected request: $method ${uri.host}${uri.path}")
            }
        }
        val result = client.login("synthetic-user", "fake-password", null, 7, null)
        assertEquals(1, submitted)
        assertTrue(authorizedForJw)
        assertEquals(7, result.week)
        assertEquals(6, result.schedule.courses.size)
        assertFalse(result.profile.studentId.isBlank())
    }
}
