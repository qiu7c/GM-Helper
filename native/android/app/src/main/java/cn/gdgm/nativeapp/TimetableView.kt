package cn.gdgm.nativeapp

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.TextView
import java.time.LocalDate

/** The same complete grid is used on screen and in the shared image. */
class TimetableView(
    context: Context,
    courses: List<Course>,
    week: Int,
    monday: LocalDate,
    campus: String,
    dark: Boolean,
    note: (String) -> String,
    onCourse: (Course) -> Unit,
    onNote: (Course) -> Unit
) : LinearLayout(context) {
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    init {
        orientation = VERTICAL
        val ink = if (dark) Color.WHITE else Color.rgb(38, 45, 62)
        val muted = if (dark) 0xffb8bed0.toInt() else 0xff677187.toInt()
        val days = listOf("一", "二", "三", "四", "五", "六", "日")
        val header = LinearLayout(context)
        header.addView(TextView(context), LayoutParams(dp(37), dp(52)))
        for (day in 1..7) {
            val date = monday.plusDays((day - 1).toLong())
            val today = date == LocalDate.now()
            val label = TextView(context).apply {
                text = "周${days[day - 1]}\n${date.monthValue}/${date.dayOfMonth}"
                textSize = 11f; gravity = Gravity.CENTER; setTextColor(if (today) 0xff45232b.toInt() else ink)
                if (today) { background = GradientDrawable().apply { setColor(0xffffa9b5.toInt()); cornerRadius = dp(10).toFloat() }; setTypeface(null, Typeface.BOLD) }
            }
            header.addView(label, LayoutParams(0, dp(52), 1f).apply { setMargins(dp(1), 0, dp(1), dp(4)) })
        }
        addView(header)
        val times = SchoolConfig.periodTimes(campus)
        val palette = intArrayOf(0xff547ad4.toInt(), 0xff288879.toInt(), 0xff98712a.toInt(), 0xffb46c38.toInt(), 0xff7c61c4.toInt(), 0xff347f9f.toInt(), 0xff9866a6.toInt(), 0xffa75c79.toInt())
        for (period in 1..6) {
            val row = LinearLayout(context)
            row.gravity = Gravity.TOP
            val count = (1..7).maxOf { d -> courses.count { it.day == d && it.period == period } }.coerceAtLeast(1)
            val rowHeight = dp(if (count > 1) count * 85 else 116)
            row.addView(TextView(context).apply {
                val time = times[period - 1]
                text = "$period\n${time.first}\n${time.second}"; textSize = 9f
                gravity = Gravity.CENTER; setTextColor(muted)
                contentDescription = "第${period}大节 ${time.first}至${time.second}"
            }, LayoutParams(dp(37), rowHeight))
            for (day in 1..7) {
                val cell = LinearLayout(context).apply { orientation = VERTICAL }
                for (course in courses.filter { it.day == day && it.period == period }) {
                    val memo = note(course.name)
                    val color = palette[(course.name.hashCode() and Int.MAX_VALUE) % palette.size]
                    val block = TextView(context).apply {
                        text = listOf(course.name, course.room.takeIf { it.isNotBlank() }?.let { "@$it" }, course.teacher.takeIf { it.isNotBlank() }, memo.takeIf { it.isNotBlank() }?.let { "✎ $it" }).filterNotNull().joinToString("\n")
                        setTextColor(Color.WHITE); textSize = 10f; setPadding(dp(4), dp(7), dp(3), dp(4))
                        background = GradientDrawable().apply { setColor(color); cornerRadius = dp(9).toFloat() }
                        setOnClickListener { onCourse(course) }; setOnLongClickListener { onNote(course); true }
                        contentDescription = "${course.name}，${course.room}，${course.teacher}。点按详情，长按备注"
                    }
                    cell.addView(block, LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f).apply { setMargins(dp(1), dp(2), dp(1), dp(2)) })
                }
                row.addView(cell, LayoutParams(0, rowHeight, 1f))
            }
            addView(row)
        }
        contentDescription = "第 $week 周课表"
    }
}
