package cn.gdgm.nativeapp

import android.content.Context
import android.app.AlertDialog
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
    colorIndex: (String) -> Int,
    onCourse: (Course) -> Unit,
    onNote: (Course) -> Unit,
    fitHeight: Boolean = false
) : LinearLayout(context) {
    companion object {
        val palette = intArrayOf(0xffd8e8fa.toInt(), 0xffd9eee4.toInt(), 0xfff4e9ce.toInt(), 0xfff4dfd4.toInt(), 0xffe6dff5.toInt(), 0xffd6eced.toInt(), 0xffeddfeb.toInt(), 0xffe6e8d6.toInt())
    }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    init {
        orientation = VERTICAL
        val ink = if (dark) Color.WHITE else Color.rgb(38, 45, 62)
        val muted = if (dark) 0xffb8bed0.toInt() else 0xff677187.toInt()
        val compact = resources.configuration.screenWidthDp < 360
        val timeWidth = dp(if (compact) 29 else 34)
        val days = listOf("一", "二", "三", "四", "五", "六", "日")
        val header = LinearLayout(context)
        val headerHeight = dp(if (fitHeight) 38 else 46)
        header.addView(TextView(context).apply { text = "节次"; textSize = 8f; gravity = Gravity.CENTER; setTextColor(muted) }, LayoutParams(timeWidth, headerHeight))
        for (day in 1..7) {
            val date = monday.plusDays((day - 1).toLong())
            val today = date == LocalDate.now()
            val label = TextView(context).apply {
                text = "周${days[day - 1]}\n${date.monthValue}/${date.dayOfMonth}"
                textSize = 11f; gravity = Gravity.CENTER; setTextColor(if (today) Color.WHITE else muted)
                if (today) { background = GradientDrawable(GradientDrawable.Orientation.TL_BR, intArrayOf(0xff367ba2.toInt(), 0xff438d82.toInt())).apply { cornerRadius = dp(14).toFloat() }; setTypeface(null, Typeface.BOLD) }
            }
            header.addView(label, LayoutParams(0, headerHeight, 1f).apply { setMargins(dp(1), 0, dp(1), dp(2)) })
        }
        addView(header)
        val times = SchoolConfig.periodTimes(campus)
        for (period in 1..times.count { it.first.isNotBlank() }) {
            val row = LinearLayout(context)
            row.gravity = Gravity.TOP
            val rowHeight = if (fitHeight) LayoutParams.MATCH_PARENT else dp(maxOf(120, (1..7).maxOf { d -> courses.count { it.day == d && it.period == period } } * 88))
            row.addView(TextView(context).apply {
                val time = times[period - 1]
                text = "$period\n${time.first}\n${time.second}"; textSize = if (compact) 8f else 9f
                gravity = Gravity.CENTER; setTextColor(muted)
                contentDescription = "第${period}大节 ${time.first}至${time.second}"
            }, LayoutParams(timeWidth, rowHeight))
            for (day in 1..7) {
                val cell = LinearLayout(context).apply {
                    orientation = VERTICAL
                    background = GradientDrawable().apply {
                        setColor(if (monday.plusDays((day - 1).toLong()) == LocalDate.now()) if (dark) 0x183f998f else 0x12448f85 else Color.TRANSPARENT)
                        setStroke(dp(1), if (dark) 0x0c99bbcc else 0x08708b83); cornerRadius = dp(9).toFloat()
                    }
                }
                val lessons = courses.filter { it.day == day && it.period == period }
                for (course in if (fitHeight) lessons.take(1) else lessons) {
                    val memo = note(course.name)
                    val color = palette[colorIndex(course.name)]
                    val fill = if (dark) Color.rgb(Color.red(color) * 30 / 100, Color.green(color) * 30 / 100, Color.blue(color) * 30 / 100) else color
                    val block = LinearLayout(context).apply {
                        orientation = VERTICAL; setPadding(dp(3), dp(if (fitHeight) 3 else 6), dp(3), dp(if (fitHeight) 2 else 4))
                        background = GradientDrawable().apply { setColor(fill); cornerRadius = dp(12).toFloat() }
                        addView(TextView(context).apply { text = course.name; textSize = if (compact) 10f else 10.5f; maxLines = if (fitHeight) 2 else 3; ellipsize = android.text.TextUtils.TruncateAt.END; includeFontPadding = false; setTypeface(null, Typeface.BOLD); setTextColor(if (dark) 0xfff1f4fa.toInt() else 0xff34495c.toInt()) })
                        if (course.room.isNotBlank() || fitHeight && lessons.size > 1) addView(TextView(context).apply { text = if (fitHeight && lessons.size > 1) "共${lessons.size}门 · 点选" else course.room; textSize = 9f; maxLines = 1; includeFontPadding = false; ellipsize = android.text.TextUtils.TruncateAt.END; setTextColor(if (dark) 0xffd3dce7.toInt() else 0xff566a78.toInt()); setPadding(0, dp(2), 0, 0) })
                        if (!fitHeight && course.teacher.isNotBlank()) addView(TextView(context).apply { text = course.teacher; textSize = 9f; maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END; setTextColor(if (dark) 0xffbec9d5.toInt() else 0xff687884.toInt()); setPadding(0, dp(2), 0, 0) })
                        if (!fitHeight && memo.isNotBlank()) addView(TextView(context).apply { text = "✎ $memo"; textSize = 8f; maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END; setTextColor(if (dark) Color.WHITE else 0xff405b6a.toInt()); setPadding(0, dp(4), 0, 0) })
                        setOnClickListener {
                            if (fitHeight && lessons.size > 1) AlertDialog.Builder(context).setTitle("选择课程").setItems(lessons.map { "${it.name} · ${it.room}" }.toTypedArray()) { _, index -> onCourse(lessons[index]) }.setNegativeButton("取消", null).show()
                            else onCourse(course)
                        }
                        setOnLongClickListener {
                            if (fitHeight && lessons.size > 1) AlertDialog.Builder(context).setTitle("选择课程备注").setItems(lessons.map { it.name }.toTypedArray()) { _, index -> onNote(lessons[index]) }.setNegativeButton("取消", null).show()
                            else onNote(course)
                            true
                        }
                        contentDescription = "${course.name}，${course.room}，${course.teacher}。点按详情，长按备注"
                    }
                    cell.addView(block, LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f).apply { setMargins(dp(1), dp(2), dp(1), dp(2)) })
                }
                row.addView(cell, LayoutParams(0, rowHeight, 1f))
            }
            addView(row, if (fitHeight) LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f) else LayoutParams(LayoutParams.MATCH_PARENT, rowHeight))
        }
        contentDescription = "第 $week 周课表"
    }
}
