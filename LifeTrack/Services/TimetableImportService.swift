import Foundation
import CoreFoundation
import SwiftData

/// 从 CSV 或 iCal（.ics 日历）导入课表。
///
/// - CSV：支持常见的“长表”格式（每行一门课），自动识别表头列名与编码（UTF-8 / GB18030）。
/// - iCal：解析教务系统“日历订阅/导出”得到的 VEVENT（FREQ=WEEKLY + BYDAY）。
///
/// 说明：教务系统千差万别，无法通用登录抓取；推荐从教务「导出课表 CSV」或「导出日历(.ics)」后在这里导入。
struct TimetableImportItem: Identifiable, Equatable {
    let id: UUID
    var name: String
    var weekday: Int          // 1=周一 … 7=周日
    var startMinutes: Int
    var endMinutes: Int
    var location: String
    var weekParity: Int       // 0=每周 1=单周 2=双周

    init(name: String,
         weekday: Int,
         startMinutes: Int,
         endMinutes: Int,
         location: String = "",
         weekParity: Int = 0) {
        self.id = UUID()
        self.name = name
        self.weekday = weekday
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.location = location
        self.weekParity = weekParity
    }

    func makeCourse() -> CourseEvent {
        CourseEvent(weekday: weekday,
                    startMinutes: startMinutes,
                    endMinutes: endMinutes,
                    name: name,
                    locationName: location,
                    weekParity: weekParity)
    }
}

enum TimetableImportError: LocalizedError {
    case unreadable
    case unsupportedEncoding
    case noHeader
    case noCourses

    var errorDescription: String? {
        switch self {
        case .unreadable: "无法读取所选文件。"
        case .unsupportedEncoding: "无法识别文件编码，请另存为 UTF-8 或 GBK 的 CSV。"
        case .noHeader: "没有识别到表头，请确认 CSV 第一行包含“课程名称、星期、时间/节次”等列。"
        case .noCourses: "没有解析到任何课程。请确认列内容格式，或尝试从教务导出日历(.ics)再导入。"
        }
    }
}

enum TimetableImportService {
    // MARK: - 入口

    static func importFile(at url: URL) throws -> [TimetableImportItem] {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        guard let text = decode(data) else { throw TimetableImportError.unsupportedEncoding }
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}\n\r "))

        if url.pathExtension.lowercased() == "ics" || trimmed.contains("BEGIN:VCALENDAR") {
            let items = parseICS(trimmed)
            guard !items.isEmpty else { throw TimetableImportError.noCourses }
            return items
        }

        let items = parseCSV(trimmed)
        guard !items.isEmpty else {
            throw csvRows(trimmed).isEmpty ? TimetableImportError.noCourses : TimetableImportError.noHeader
        }
        return items
    }

    // MARK: - 编码

    private static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        let cfEncoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let encoding = String.Encoding(rawValue: cfEncoding)
        return String(data: data, encoding: encoding)
    }

    // MARK: - CSV 解析

    private static func csvRows(_ text: String) -> [[String]] {
        text.components(separatedBy: .newlines).compactMap { line -> [String]? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return splitCSVLine(trimmed)
        }
    }

    private static func splitCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        for char in line {
            if inQuotes {
                if char == "\"" { inQuotes = false } else { field.append(char) }
            } else {
                if char == "\"" { inQuotes = true }
                else if char == "," { fields.append(field); field = "" }
                else { field.append(char) }
            }
        }
        fields.append(field)
        return fields
    }

    private static func parseCSV(_ text: String) -> [TimetableImportItem] {
        let rows = csvRows(text)
        guard rows.count >= 2 else { return [] }
        let map = detectColumns(rows[0])
        guard map.name != nil, map.weekday != nil else { return [] }

        var items: [TimetableImportItem] = []
        for row in rows.dropFirst() {
            guard let name = map.name.flatMap({ cell(row, $0) })?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { continue }
            guard let weekday = map.weekday.flatMap({ cell(row, $0) }).flatMap(parseWeekday) else { continue }

            let range: (Int, Int)
            if let s = map.startTime.flatMap({ cell(row, $0) }).flatMap(parseTime),
               let e = map.endTime.flatMap({ cell(row, $0) }).flatMap(parseTime) {
                range = (s, e)
            } else if let r = map.timeRange.flatMap({ cell(row, $0) }).flatMap(parseTimeRange) {
                range = r
            } else if let s = map.startPeriod.flatMap({ cell(row, $0) }).flatMap(parsePeriod),
                      let e = map.endPeriod.flatMap({ cell(row, $0) }).flatMap(parsePeriod),
                      let r = periodRange(from: s, to: e) {
                range = r
            } else if let r = map.periodRange.flatMap({ cell(row, $0) }).flatMap(parsePeriodRange) {
                range = r
            } else {
                continue
            }

            let location = map.location.flatMap({ cell(row, $0) })?.trimmingCharacters(in: .whitespaces) ?? ""
            let parity = map.parity.flatMap({ cell(row, $0) }).flatMap(parseParity) ?? 0
            items.append(TimetableImportItem(name: name,
                                             weekday: weekday,
                                             startMinutes: range.0,
                                             endMinutes: range.1,
                                             location: location,
                                             weekParity: parity))
        }
        return items
    }

    private struct ColumnMap {
        var name: Int?
        var weekday: Int?
        var startTime: Int?
        var endTime: Int?
        var timeRange: Int?
        var startPeriod: Int?
        var endPeriod: Int?
        var periodRange: Int?
        var location: Int?
        var parity: Int?
    }

    private static func detectColumns(_ header: [String]) -> ColumnMap {
        var map = ColumnMap()
        for (index, raw) in header.enumerated() {
            let column = normalized(raw)
            if map.name == nil && (column.contains("课程名") || column == "课程" || column == "name" || column == "course") {
                map.name = index
            } else if map.weekday == nil && (column.contains("星期") || column == "周" || column == "weekday" || column == "day") {
                map.weekday = index
            } else if map.startTime == nil && (column.contains("开始时间") || column == "starttime") {
                map.startTime = index
            } else if map.endTime == nil && (column.contains("结束时间") || column == "endtime") {
                map.endTime = index
            } else if map.timeRange == nil && (column == "时间" || column == "time" || column.contains("上课时间")) {
                map.timeRange = index
            } else if map.startPeriod == nil && (column.contains("开始节") || column.contains("起始节") || column == "start") {
                map.startPeriod = index
            } else if map.endPeriod == nil && (column.contains("结束节") || column.contains("终止节") || column == "end") {
                map.endPeriod = index
            } else if map.periodRange == nil && (column.contains("节次") || column == "period" || column == "节") {
                map.periodRange = index
            } else if map.location == nil && (column.contains("地点") || column.contains("教室") || column == "location" || column == "room") {
                map.location = index
            } else if map.parity == nil && (column.contains("周次") || column.contains("单双周") || column.contains("周数") || column == "weeks") {
                map.parity = index
            }
        }
        return map
    }

    private static func cell(_ row: [String], _ index: Int) -> String? {
        guard index >= 0, index < row.count else { return nil }
        return row[index]
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - 字段解析

    static func parseWeekday(_ value: String) -> Int? {
        let v = normalized(value).replacingOccurrences(of: "星期", with: "")
            .replacingOccurrences(of: "周", with: "")
        switch v {
        case "一", "1", "mon", "monday": return 1
        case "二", "2", "tue", "tuesday": return 2
        case "三", "3", "wed", "wednesday": return 3
        case "四", "4", "thu", "thursday": return 4
        case "五", "5", "fri", "friday": return 5
        case "六", "6", "sat", "saturday": return 6
        case "日", "天", "7", "sun", "sunday": return 7
        default: return nil
        }
    }

    static func parseTime(_ value: String) -> Int? {
        let v = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "：", with: ":")
        let parts = v.split(separator: ":").map(String.init)
        if parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]) {
            return hour * 60 + minute
        }
        let digits = v.filter(\.isNumber)
        if digits.count == 3 || digits.count == 4 {
            let padded = String(repeating: "0", count: max(0, 4 - digits.count)) + digits
            if let hour = Int(padded.prefix(2)), let minute = Int(padded.suffix(2)) {
                return hour * 60 + minute
            }
        }
        return nil
    }

    static func parseTimeRange(_ value: String) -> (Int, Int)? {
        let parts = value.replacingOccurrences(of: "：", with: ":").split(separator: "-").map(String.init)
        guard parts.count >= 2, let start = parseTime(parts[0]), let end = parseTime(parts[1]) else { return nil }
        return (start, end)
    }

    static func parsePeriod(_ value: String) -> Int? {
        let digits = value.filter(\.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    static func parsePeriodRange(_ value: String) -> (Int, Int)? {
        let parts = value.split(separator: "-").map(String.init)
        if parts.count >= 2, let s = parsePeriod(parts[0]), let e = parsePeriod(parts[1]) {
            return periodRange(from: s, to: e)
        }
        if let single = parsePeriod(value) { return periodRange(from: single, to: single) }
        return nil
    }

    static func parseParity(_ value: String) -> Int? {
        let v = normalized(value)
        if v.contains("单") { return 1 }
        if v.contains("双") { return 2 }
        return 0
    }

    /// 默认“节次→时间”表（常见高校作息，可在导入后按学校实际调整）。
    private static let periodTimes: [(start: Int, end: Int)] = [
        (8 * 60, 8 * 60 + 45),
        (8 * 60 + 50, 9 * 60 + 35),
        (9 * 60 + 50, 10 * 60 + 35),
        (10 * 60 + 40, 11 * 60 + 25),
        (11 * 60 + 30, 12 * 60 + 15),
        (14 * 60, 14 * 60 + 45),
        (14 * 60 + 50, 15 * 60 + 35),
        (15 * 60 + 50, 16 * 60 + 35),
        (16 * 60 + 40, 17 * 60 + 25),
        (19 * 60, 19 * 60 + 45),
        (19 * 60 + 50, 20 * 60 + 35),
        (20 * 60 + 40, 21 * 60 + 25)
    ]

    static func periodRange(from start: Int, to end: Int) -> (Int, Int)? {
        guard start >= 1, end >= start, end <= periodTimes.count else { return nil }
        return (periodTimes[start - 1].start, periodTimes[end - 1].end)
    }

    // MARK: - iCal (.ics) 解析

    private static func parseICS(_ text: String) -> [TimetableImportItem] {
        let unfolded = unfoldLines(text)
        var items: [TimetableImportItem] = []
        for event in splitEvents(unfolded) {
            guard let summary = eventValue(event, key: "SUMMARY")?.trimmingCharacters(in: .whitespaces),
                  !summary.isEmpty else { continue }
            let location = eventValue(event, key: "LOCATION")?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let start = eventTimeMinutes(event, key: "DTSTART"),
                  let end = eventTimeMinutes(event, key: "DTEND") else { continue }
            for weekday in eventWeekdays(event) {
                items.append(TimetableImportItem(name: summary,
                                                 weekday: weekday,
                                                 startMinutes: start,
                                                 endMinutes: end,
                                                 location: location))
            }
        }
        return items
    }

    private static func unfoldLines(_ text: String) -> String {
        var result: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix(" ") || line.hasPrefix("\t"), !result.isEmpty {
                result[result.count - 1] += line.dropFirst()
            } else {
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }

    private static func splitEvents(_ text: String) -> [String] {
        text.components(separatedBy: "BEGIN:VEVENT").dropFirst().compactMap { block in
            guard let end = block.range(of: "END:VEVENT") else { return nil }
            return String(block[..<end.lowerBound])
        }
    }

    private static func eventValue(_ event: String, key: String) -> String? {
        for line in event.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(key + ";") || trimmed.hasPrefix(key + ":") {
                if let colon = trimmed.firstIndex(of: ":") {
                    return String(trimmed[trimmed.index(after: colon)...])
                }
            }
        }
        return nil
    }

    private static func eventTimeMinutes(_ event: String, key: String) -> Int? {
        guard let value = eventValue(event, key: key), let t = value.firstIndex(of: "T") else { return nil }
        let digits = value[value.index(after: t)...].prefix(6)
        guard digits.count == 6,
              let hour = Int(digits.prefix(2)),
              let minute = Int(digits.dropFirst(2).prefix(2)) else { return nil }
        return hour * 60 + minute
    }

    private static func eventWeekdays(_ event: String) -> [Int] {
        if let rrule = eventValue(event, key: "RRULE") {
            for part in rrule.components(separatedBy: ";") where part.uppercased().hasPrefix("BYDAY=") {
                let days = part.dropFirst("BYDAY=".count).uppercased().components(separatedBy: ",")
                let mapped = days.compactMap { day -> Int? in
                    switch String(day.trimmingCharacters(in: .whitespaces).prefix(2)) {
                    case "MO": return 1
                    case "TU": return 2
                    case "WE": return 3
                    case "TH": return 4
                    case "FR": return 5
                    case "SA": return 6
                    case "SU": return 7
                    default: return nil
                    }
                }
                if !mapped.isEmpty { return mapped }
            }
        }

        if let dtstart = eventValue(event, key: "DTSTART"),
           let datePart = dtstart.components(separatedBy: "T").first,
           datePart.count == 8 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd"
            if let date = formatter.date(from: datePart) {
                let iso = Calendar.current.component(.weekday, from: date) // 1=周日 … 7=周六
                return [((iso + 5) % 7) + 1]
            }
        }
        return []
    }
}
