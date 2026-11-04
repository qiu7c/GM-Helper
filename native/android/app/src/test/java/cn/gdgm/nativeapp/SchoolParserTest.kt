package cn.gdgm.nativeapp

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

class SchoolParserTest {
    private fun fixture(name: String): String =
        javaClass.getResource("/$name")!!.readText(Charsets.UTF_8)

    @Test
    fun scheduleFixtureMatchesExpectedCourseFieldsAndSelections() {
        val expected = JSONObject(fixture("schedule_expected.json"))
        val actual = SchoolParser.schedule(fixture("schedule.html"))
        val courses = expected.getJSONArray("courses")

        assertEquals(courses.length(), actual.courses.size)
        for (i in 0 until courses.length()) {
            val e = courses.getJSONObject(i)
            val a = actual.courses[i]
            assertEquals(e.getString("name"), a.name)
            assertEquals(e.getString("teacher"), a.teacher)
            assertEquals(e.getString("room"), a.room)
            assertEquals(e.getString("teachingClass"), a.teachingClass)
            assertEquals(e.getString("rawWeeks"), a.rawWeeks)
            assertEquals((0 until e.getJSONArray("weeks").length()).map { e.getJSONArray("weeks").getInt(it) }, a.weeks)
            assertEquals(e.getInt("day"), a.day)
            assertEquals(e.getInt("period"), a.period)
            assertEquals(e.getString("sectionRange"), a.sectionRange)
        }
        assertEquals(expected.getString("selectedTerm"), actual.selectedTerm)
        assertEquals(expected.getString("selectedWeek"), actual.selectedWeek)
        assertEquals(expected.getString("selectedCampus"), actual.selectedCampus)
        assertEquals(expected.getString("remark"), actual.remark)
        assertEquals(2, actual.courses.count { it.day == 1 && it.period == 1 })
    }

    @Test
    fun validEmptyWeekIsDistinctFromMissingOrIncompleteTable() {
        val empty = SchoolParser.schedule(fixture("empty_week.html"))
        assertTrue(empty.courses.isEmpty())
        assertEquals("8", empty.selectedWeek)

        assertThrows(SchoolResponseError::class.java) {
            SchoolParser.schedule(fixture("maintenance.html"))
        }
        assertThrows(SchoolResponseError::class.java) {
            SchoolParser.schedule("<table id='kbtable'><tr><th>节次</th></tr></table>")
        }
    }

    @Test
    fun calendarFixtureComputesFirstMonday() {
        val calendar = SchoolParser.calendar(fixture("calendar.html"))!!
        assertEquals(10, calendar.currentWeek)
        assertEquals(20, calendar.totalWeeks)
        assertEquals(LocalDate.parse("2026-11-04"), calendar.date)
        assertEquals(LocalDate.parse("2026-08-31"), calendar.firstMonday)
    }

    @Test
    fun profileParsesSyntheticDesktopFields() {
        val html = """
            <div class="middletopttxlr">
              <span><span class="middletopdwxxtit">学生姓名：</span><span class="middletopdwxxcont">虚构同学</span></span>
              <span><span class="middletopdwxxtit">学生编号：</span><span class="middletopdwxxcont">TEST000001</span></span>
              <span><span class="middletopdwxxtit">所属院系：</span><span class="middletopdwxxcont">虚构设计系</span></span>
            </div>
        """.trimIndent()
        val profile = SchoolParser.profile(html)
        assertEquals("虚构同学", profile.name)
        assertEquals("TEST000001", profile.studentId)
        assertEquals(listOf("所属院系" to "虚构设计系"), profile.fields)
    }

    @Test
    fun responseCheckSeparatesExpiredSessionFromSchoolFailure() {
        assertThrows(SessionExpired::class.java) {
            SchoolParser.checkResponse(200, fixture("login_expired.html"))
        }
        assertThrows(SessionExpired::class.java) { SchoolParser.checkResponse(302, "redirect") }
        assertThrows(SchoolResponseError::class.java) {
            SchoolParser.checkResponse(503, fixture("maintenance.html"))
        }
    }

    @Test
    fun sameWeekDiffReportsRoomChangeButIgnoresWeekOrdering() {
        val old = schedule("7", listOf(Course("绘图", teacher = "林老师", room = "A", weeks = listOf(1, 2, 3), day = 1, period = 1)))
        val reorderedSameData = schedule("7", listOf(Course("绘图", teacher = "林老师", room = "A", weeks = listOf(3, 1, 2), day = 1, period = 1)))
        assertNull(scheduleDiff(old, reorderedSameData))

        val movedRoom = schedule("7", listOf(Course("绘图", teacher = "林老师", room = "B", weeks = listOf(1, 2, 3), day = 1, period = 1)))
        assertEquals("调整 1 处", scheduleDiff(old, movedRoom))
    }

    @Test
    fun diffDoesNotCompareAcrossWeeks() {
        val old = schedule("7", listOf(Course("绘图", room = "A", day = 1, period = 1)))
        val new = schedule("8", listOf(Course("编程", room = "B", day = 2, period = 2)))
        assertNull(scheduleDiff(old, new))
    }

    @Test
    fun liwanHasNoSixthPeriodAndWeekCalculationClampsAtTermEdges() {
        val liwan = SchoolConfig.periodTimes("0A10E5C18E814AEAA9456E91A7092394")
        assertEquals(6, liwan.size)
        assertEquals("" to "", liwan[5])

        val firstMonday = LocalDate.parse("2026-08-31")
        assertEquals(1, SchoolConfig.weekOfDate(firstMonday.minusDays(1), firstMonday, 20))
        assertEquals(1, SchoolConfig.weekOfDate(firstMonday, firstMonday, 20))
        assertEquals(2, SchoolConfig.weekOfDate(firstMonday.plusDays(7), firstMonday, 20))
        assertEquals(20, SchoolConfig.weekOfDate(firstMonday.plusWeeks(25), firstMonday, 20))
    }

    private fun schedule(week: String, courses: List<Course>) = Schedule(
        courses = courses,
        terms = emptyList(),
        weeks = emptyList(),
        campuses = emptyList(),
        selectedTerm = "2026-2027-1",
        selectedWeek = week,
        selectedCampus = "3589FB3E8AD246BCBAD7BB5C8710D078",
    )
}
