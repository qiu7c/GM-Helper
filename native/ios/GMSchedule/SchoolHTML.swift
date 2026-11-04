import Foundation
import SwiftSoup

enum SchoolHTML {
    static func check(_ html: String, status: Int, url: URL?) throws {
        if status >= 500 { throw SchoolError.unavailable }
        if (300..<400).contains(status) || url?.host == "sfrz.gdgm.cn" || ["casLoginForm", "pwdDefaultEncryptSalt", "请先登录系统"].contains(where: html.contains) {
            throw SchoolError.expired
        }
        if status != 200 { throw SchoolError.message("学校返回 HTTP \(status)，请稍后重试。") }
    }

    static func weeks(_ raw: String) -> [Int] {
        let clean = raw.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: "", options: .regularExpression)
        var result = Set<Int>()
        for part in clean.split(separator: ",") {
            let numbers = part.trimmingCharacters(in: .whitespaces).split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let start = numbers.first, numbers.count <= 2, (1...60).contains(start) else { continue }
            let end = numbers.last!
            guard end >= start && end <= 60 else { continue }
            for week in start...end {
                if raw.contains("单") && week % 2 == 0 { continue }
                if raw.contains("双") && week % 2 == 1 { continue }
                result.insert(week)
            }
        }
        return result.sorted()
    }

    static func schedule(_ html: String) throws -> Schedule {
        let doc = try SwiftSoup.parse(html)
        guard let table = try doc.select("#kbtable").first() else { throw SchoolError.unrecognized }
        var courses: [Course] = []
        var remark = ""
        var period = 0
        for row in try table.select("tr").array().dropFirst() {
            let cells = row.children().array().filter { $0.tagName() == "td" }
            if let heading = row.children().array().first(where: { $0.tagName() == "th" }), try heading.text().contains("备注") {
                remark = try cells.first?.text() ?? ""
                continue
            }
            if cells.count < 7 { continue }
            period += 1
            guard period <= 6 else { throw SchoolError.unrecognized }
            for (day, cell) in cells.prefix(7).enumerated() {
                for div in try cell.select("div.kbcontent") {
                    if div.hasClass("sykb2") { continue }
                    var blocks: [[Node]] = [[]]
                    var hasFont = false
                    for node in div.getChildNodes() {
                        let text = (node as? TextNode)?.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !text.isEmpty && !(text.hasPrefix("(") && text.hasSuffix(")")) && hasFont {
                            blocks.append([])
                            hasFont = false
                        }
                        blocks[blocks.count - 1].append(node)
                        if (node as? Element)?.tagName() == "font" { hasFont = true }
                    }
                    for block in blocks {
                        var course = Course(name: "", day: day + 1, period: period)
                        for node in block {
                            if let textNode = node as? TextNode {
                                let text = textNode.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines)
                                if text.hasPrefix("(") && text.hasSuffix(")") { course.teachingClass = String(text.dropFirst().dropLast()) }
                                else if course.name.isEmpty { course.name = text }
                            } else if let font = node as? Element, font.tagName() == "font" {
                                let title = try font.attr("title")
                                let value = try font.text()
                                switch title {
                                case "老师": course.teacher = value
                                case "教室": course.room = value
                                case "周次(节次)": course.rawWeeks = value
                                default:
                                    if title.isEmpty && value.hasPrefix("(") { course.teachingClass = value.trimmingCharacters(in: CharacterSet(charactersIn: "()")) }
                                }
                            }
                        }
                        if !course.name.isEmpty {
                            course.weeks = weeks(course.rawWeeks)
                            if let range = course.rawWeeks.range(of: #"(?<=\[)[^\]]+"#, options: .regularExpression) { course.section = String(course.rawWeeks[range]) }
                            courses.append(course)
                        }
                    }
                }
            }
        }
        // A real empty week still has period rows. A missing/incomplete table never replaces cache.
        guard period > 0 else { throw SchoolError.unrecognized }
        let term = try options(doc, "#xnxq01id")
        let week = try options(doc, "#zc")
        let campus = try options(doc, "#kbjcmsid")
        guard !term.selected.isEmpty, let number = Int(week.selected), (1...60).contains(number), let campusValue = Campus(rawValue: campus.selected) else {
            throw SchoolError.unrecognized
        }
        return Schedule(courses: courses, terms: term.items, weeks: week.items, campuses: campus.items, term: term.selected, week: number, campus: campusValue, remark: remark)
    }

    private static func options(_ doc: Document, _ selector: String) throws -> (items: [Choice], selected: String) {
        let options = try doc.select(selector + " option").array()
        let items = try options.compactMap { option -> Choice? in
            let value = try option.attr("value")
            return value.isEmpty ? nil : Choice(value: value, label: try option.text())
        }
        let selected = options.first(where: { $0.hasAttr("selected") }) ?? options.first
        return (items, try selected?.attr("value") ?? "")
    }

    static func calendar(_ html: String) throws -> TermCalendar? {
        let doc = try SwiftSoup.parse(html)
        let text = try doc.select("#li_showWeek").text()
        let numbers = text.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
        let raw = try doc.select("#rq").attr("value")
        let formatter = DateFormatter()
        formatter.calendar = SchoolClock.calendar
        formatter.timeZone = SchoolClock.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let week = numbers.first, (1...60).contains(week), let date = formatter.date(from: raw) else { return nil }
        let total = numbers.count > 1 ? numbers[1] : 20
        guard (week...60).contains(total) else { return nil }
        return TermCalendar(week: week, total: total, date: date)
    }

    static func profile(_ html: String) throws -> [ProfileField] {
        let doc = try SwiftSoup.parse(html)
        return try doc.select(".middletopttxlr .middletopdwxxtit").compactMap { title in
            let label = try title.text().trimmingCharacters(in: CharacterSet(charactersIn: "：: \n"))
            let value = try title.parent()?.select(".middletopdwxxcont").text() ?? ""
            return label.isEmpty || value.isEmpty ? nil : ProfileField(label: label, value: value)
        }
    }
    static func frameProfile(_ html: String) throws -> [ProfileField] {
        let doc = try SwiftSoup.parse(html)
        var fields: [ProfileField] = []
        let name = try doc.select(".ckgrxx").text()
        if !name.isEmpty { fields.append(ProfileField(label: "姓名", value: name)) }
        let regex = try NSRegularExpression(pattern: #"var\s+userid\s*=\s*['"]([^'"]+)['"]"#)
        if let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let range = Range(match.range(at: 1), in: html) {
            fields.append(ProfileField(label: "学号", value: String(html[range])))
        }
        return fields
    }
}
