import Foundation
import Compression

/// 无依赖的表格文件读取器，支持旧版 `.xls`（OLE2 / BIFF8）与新版 `.xlsx`（OOXML / ZIP+XML）。
///
/// 设计目标：不引入任何第三方库与 SwiftPM 依赖，纯 Swift 实现，且对国内高校教务系统
/// 导出的 WPS `.xls`（codepage=1200，UTF-16LE）友好。
enum SpreadsheetError: LocalizedError {
    case notSupported
    case corrupt
    case empty

    var errorDescription: String? {
        switch self {
        case .notSupported: "不支持的文件格式，请导出为 .xls / .xlsx / .csv。"
        case .corrupt: "文件无法解析，可能已损坏或不是标准表格。"
        case .empty: "没有解析到任何内容。"
        }
    }
}

struct SpreadsheetSheet {
    let name: String
    /// 矩形网格，行优先；空白单元格为空字符串。
    let grid: [[String]]
}

struct SpreadsheetReader {
    /// 读取表格文件，返回所有工作表（通常课表只有第一个）。
    static func read(data: Data) throws -> [SpreadsheetSheet] {
        // .xls: OLE2 复合文档
        if data.count >= 8, data.subdata(in: 0..<8) == Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            return try readXLS(data)
        }
        // .xlsx: ZIP 容器（PK\x03\x04 ...）
        if data.count >= 4, data.subdata(in: 0..<4) == Data([0x50, 0x4B, 0x03, 0x04]) {
            return try readXLSX(data)
        }
        throw SpreadsheetError.notSupported
    }

    // MARK: - .xls (OLE2 + BIFF8)

    private static func readXLS(_ data: Data) throws -> [SpreadsheetSheet] {
        guard data.count >= 512 else { throw SpreadsheetError.corrupt }
        let sectorShift = Int(data.u16(at: 0x1E))
        let miniSectorShift = Int(data.u16(at: 0x20))
        guard (9...12).contains(sectorShift), (3...9).contains(miniSectorShift) else {
            throw SpreadsheetError.corrupt
        }
        let sectorSize = 1 << sectorShift
        let miniSectorSize = 1 << miniSectorShift
        let sectorCount = (data.count - 512) / sectorSize
        guard sectorCount > 0 else { throw SpreadsheetError.corrupt }

        func sector(_ index: Int) -> Data? {
            guard index >= 0, index < sectorCount else { return nil }
            let start = 512 + index * sectorSize
            let end = start + sectorSize
            guard end <= data.count else { return nil }
            return data.subdata(in: start..<end)
        }

        let fatSectorCount = Int(data.u32(at: 0x2C))
        let firstDirectorySector = Int(data.u32(at: 0x30))
        let miniStreamCutoff = Int(data.u32(at: 0x38))
        let firstMiniFatSector = Int(data.u32(at: 0x3C))
        let miniFatSectorCount = Int(data.u32(at: 0x40))

        // DIFAT：先读取头部的 109 项，再按需跟随扩展 DIFAT 扇区。
        var difat: [Int] = []
        for index in 0..<109 {
            let value = Int(data.u32(at: 0x4C + index * 4))
            if value < 0xFFFF_FFFA { difat.append(value) }
        }
        var nextDifat = Int(data.u32(at: 0x44))
        var remainingDifatSectors = Int(data.u32(at: 0x48))
        var visitedDifat: Set<Int> = []
        while difat.count < fatSectorCount,
              remainingDifatSectors > 0,
              nextDifat < 0xFFFF_FFFA,
              visitedDifat.insert(nextDifat).inserted,
              let bytes = sector(nextDifat) {
            let entryCount = sectorSize / 4 - 1
            for index in 0..<entryCount {
                let value = Int(bytes.u32(at: index * 4))
                if value < 0xFFFF_FFFA { difat.append(value) }
            }
            nextDifat = Int(bytes.u32(at: entryCount * 4))
            remainingDifatSectors -= 1
        }
        if fatSectorCount > 0 { difat = Array(difat.prefix(fatSectorCount)) }

        func buildFat(from sectors: [Int]) -> [UInt32] {
            var result: [UInt32] = []
            for index in sectors {
                guard let bytes = sector(index) else { continue }
                for offset in stride(from: 0, to: bytes.count, by: 4) {
                    result.append(bytes.u32(at: offset))
                }
            }
            return result
        }

        func chain(in table: [UInt32], startingAt start: Int, maximumIndex: Int) -> [Int] {
            var result: [Int] = []
            var current = start
            var visited: Set<Int> = []
            while current >= 0,
                  current < 0xFFFF_FFFA,
                  current < maximumIndex,
                  current < table.count,
                  visited.insert(current).inserted {
                result.append(current)
                current = Int(table[current])
            }
            return result
        }

        func regularStream(start: Int, size: Int?, fat: [UInt32]) -> Data? {
            let sectors = chain(in: fat, startingAt: start, maximumIndex: sectorCount)
            guard !sectors.isEmpty else { return nil }
            var result = Data()
            for index in sectors {
                guard let bytes = sector(index) else { return nil }
                result.append(bytes)
            }
            if let size {
                guard size >= 0, size <= result.count else { return nil }
                result = result.prefix(size)
            }
            return result
        }

        struct DirectoryEntry {
            let name: String
            let type: UInt8
            let start: Int
            let size: Int
        }

        func directoryEntries(using fat: [UInt32]) -> [DirectoryEntry]? {
            guard let raw = regularStream(start: firstDirectorySector, size: nil, fat: fat) else { return nil }
            var result: [DirectoryEntry] = []
            for offset in stride(from: 0, to: raw.count, by: 128) {
                guard offset + 128 <= raw.count else { break }
                let rawNameLength = Int(raw.u16(at: offset + 0x40))
                guard rawNameLength >= 2, rawNameLength <= 64 else { continue }
                let nameData = raw.subdata(in: offset..<(offset + rawNameLength - 2))
                guard let name = String(data: nameData, encoding: .utf16LittleEndian) else { continue }
                let lowSize = UInt64(raw.u32(at: offset + 0x78))
                let highSize = sectorShift == 12 ? UInt64(raw.u32(at: offset + 0x7C)) : 0
                let fullSize = lowSize | (highSize << 32)
                guard fullSize <= UInt64(Int.max) else { continue }
                result.append(DirectoryEntry(name: name,
                                             type: raw[offset + 0x42],
                                             start: Int(raw.u32(at: offset + 0x74)),
                                             size: Int(fullSize)))
            }
            return result
        }

        var fat = buildFat(from: difat)
        var entries = directoryEntries(using: fat)
        if entries?.contains(where: { $0.name == "Workbook" || $0.name == "Book" }) != true {
            // 少数 WPS 文件的 DIFAT 不规范；尝试把每个扇区作为单 FAT 扇区恢复。
            for candidate in 0..<sectorCount {
                let candidateFat = buildFat(from: [candidate])
                if let candidateEntries = directoryEntries(using: candidateFat),
                   candidateEntries.contains(where: { $0.name == "Workbook" || $0.name == "Book" }) {
                    fat = candidateFat
                    entries = candidateEntries
                    break
                }
            }
        }
        guard let entries,
              let workbook = entries.first(where: { $0.name == "Workbook" || $0.name == "Book" }) else {
            throw SpreadsheetError.corrupt
        }

        let workbookData: Data?
        if workbook.size < miniStreamCutoff,
           let root = entries.first(where: { $0.type == 5 }),
           let rootStream = regularStream(start: root.start, size: root.size, fat: fat),
           let miniFatBytes = regularStream(start: firstMiniFatSector,
                                            size: miniFatSectorCount * sectorSize,
                                            fat: fat) {
            var miniFat: [UInt32] = []
            for offset in stride(from: 0, to: miniFatBytes.count, by: 4) {
                miniFat.append(miniFatBytes.u32(at: offset))
            }
            let miniChain = chain(in: miniFat,
                                  startingAt: workbook.start,
                                  maximumIndex: rootStream.count / miniSectorSize)
            var result = Data()
            for index in miniChain {
                let start = index * miniSectorSize
                let end = start + miniSectorSize
                guard end <= rootStream.count else { throw SpreadsheetError.corrupt }
                result.append(rootStream.subdata(in: start..<end))
            }
            guard workbook.size <= result.count else { throw SpreadsheetError.corrupt }
            workbookData = result.prefix(workbook.size)
        } else {
            workbookData = regularStream(start: workbook.start, size: workbook.size, fat: fat)
        }
        guard let wbRaw = workbookData, !wbRaw.isEmpty else { throw SpreadsheetError.corrupt }

        // BIFF 解析
        var codepage = 0
        var sst: [String] = []
        var grid: [Int: [Int: String]] = [:]
        var pos = wbRaw.range(of: Data([0x09, 0x08]))?.lowerBound ?? 0
        let n = wbRaw.count
        while pos + 4 <= n {
            let op = Int(wbRaw.u16(at: pos))
            let len = Int(wbRaw.u16(at: pos + 2))
            let p = pos + 4
            guard p + len <= n else { break }
            if op == 0x0042 { // CODEPAGE
                codepage = Int(wbRaw.u16(at: p))
            } else if op == 0x00FC, len >= 8 { // SST
                let uniqueCount = Int(wbRaw.u32(at: p + 4))
                var payload = Data(wbRaw[(p + 8)..<(p + len)])
                var cpos = pos + 4 + len
                while cpos + 4 <= n, Int(wbRaw.u16(at: cpos)) == 0x003C {
                    let continueLength = Int(wbRaw.u16(at: cpos + 2))
                    guard cpos + 4 + continueLength <= n else { break }
                    payload.append(wbRaw[(cpos + 4)..<(cpos + 4 + continueLength)])
                    cpos += 4 + continueLength
                }
                sst = readSSTStrings(payload, total: uniqueCount, codepage: codepage)
                pos = cpos
                continue
            } else if op == 0x00FD, len >= 10 { // LABELSST
                let r = Int(wbRaw.u16(at: p))
                let c = Int(wbRaw.u16(at: p + 2))
                let ix = Int(wbRaw.u32(at: p + 6))
                var rowDict = grid[r] ?? [:]
                rowDict[c] = ix < sst.count ? sst[ix] : ""
                grid[r] = rowDict
            } else if op == 0x0204, len >= 9 { // LABEL
                let r = Int(wbRaw.u16(at: p))
                let c = Int(wbRaw.u16(at: p + 2))
                var o = p + 6 // 跳过 row(2) col(2) ixf(2)
                let slen = Int(wbRaw.u16(at: o)); o += 2
                let flags = wbRaw[o]; o += 1
                if let value = readLabelString(wbRaw, start: o, length: slen, flags: flags, codepage: codepage, end: p + len) {
                    var rowDict = grid[r] ?? [:]
                    rowDict[c] = value
                    grid[r] = rowDict
                }
            }
            pos = pos + 4 + len
        }

        guard !grid.isEmpty else { throw SpreadsheetError.empty }
        let maxR = grid.keys.max() ?? 0
        let maxC = grid.values.map { $0.keys.max() ?? 0 }.max() ?? 0
        var rows: [[String]] = []
        for r in 0...maxR {
            var row: [String] = []
            for c in 0...maxC { row.append(grid[r]?[c] ?? "") }
            rows.append(row)
        }
        return [SpreadsheetSheet(name: workbook.name, grid: rows)]
    }

    /// 读取 SST 字符串块，处理富文本/ phonetic 头部与尾部。
    /// - Parameters:
    ///   - buf: 合并后的 SST payload（含 CONTINUE 续接）
    ///   - total: SST header 中声明的唯一字符串总数
    ///   - codepage: BIFF CODEPAGE 记录值；1200 表示 UTF-16LE（需忽略 compressed 标志强制按 UTF-16 解码）
    private static func readSSTStrings(_ buf: Data, total: Int, codepage: Int = 0) -> [String] {
        let forceUTF16 = (codepage == 1200)
        var res: [String] = []
        var off = 0
        while res.count < total, off + 3 <= buf.count {
            let slen = Int(buf.u16(at: off)); off += 2
            let flags = buf[off]; off += 1
            var rt = 0, ph = 0
            if flags & 0x08 != 0 {
                guard off + 2 <= buf.count else { break }
                rt = Int(buf.u16(at: off)); off += 2
            }
            if flags & 0x04 != 0 {
                guard off + 4 <= buf.count else { break }
                ph = Int(buf.u32(at: off)); off += 4
            }
            let compressed = (flags & 0x01) != 0
            // WPS/国内教务系统常在 codepage=1200 时仍将字符串标记为 compressed，
            // 实际内容却是 UTF-16LE 编码。必须按 codepage 强制选择解码方式。
            let actuallyCompressed = compressed && !forceUTF16
            let byteCount = actuallyCompressed ? slen : slen * 2
            let trailingCount = rt * 4 + ph
            guard off + byteCount + trailingCount <= buf.count else { break }
            let bytes = buf.subdata(in: off..<(off + byteCount))
            let encoding: String.Encoding = actuallyCompressed ? .isoLatin1 : .utf16LittleEndian
            res.append(String(data: bytes, encoding: encoding) ?? "")
            off += byteCount + trailingCount
        }
        return res
    }

    private static func readLabelString(_ buf: Data,
                                        start: Int,
                                        length: Int,
                                        flags: UInt8,
                                        codepage: Int,
                                        end: Int) -> String? {
        let compressed = (flags & 0x01) != 0
        let forceUTF16 = (codepage == 1200)
        let actuallyCompressed = compressed && !forceUTF16
        let byteCount = actuallyCompressed ? length : length * 2
        guard start >= 0, start + byteCount <= end, end <= buf.count else { return nil }
        let bytes = buf.subdata(in: start..<(start + byteCount))
        return String(data: bytes, encoding: actuallyCompressed ? .isoLatin1 : .utf16LittleEndian)
    }

    // MARK: - .xlsx (OOXML / ZIP + XML)

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 { data.u16(at: offset) }
    private static func u32(_ data: Data, _ offset: Int) -> UInt32 { data.u32(at: offset) }

    private static func readXLSX(_ data: Data) throws -> [SpreadsheetSheet] {
        // 1) 解析 ZIP 中央目录（从文件尾部向前搜索 EOCD 记录 PK\x05\x06）
        guard data.count >= 22 else { throw SpreadsheetError.corrupt }
        let sig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        var eocd: Int?
        for i in stride(from: data.count - 22, through: 0, by: -1) {
            if data[i] == sig[0], data[i + 1] == sig[1], data[i + 2] == sig[2], data[i + 3] == sig[3] {
                eocd = i
                break
            }
        }
        guard let eocd else { throw SpreadsheetError.corrupt }
        let cdCount = Int(u16(data, eocd + 10))
        let cdOffset = Int(u32(data, eocd + 16))
        var entries: [(name: String,
                       flags: UInt16,
                       method: Int,
                       compressedSize: Int,
                       uncompressedSize: Int,
                       localOffset: Int)] = []
        var off = cdOffset
        for _ in 0..<cdCount {
            guard off >= 0, data.count >= off + 46 else { throw SpreadsheetError.corrupt }
            let sig = u32(data, off)
            guard sig == 0x0201_4B50 else { throw SpreadsheetError.corrupt }
            let flags = u16(data, off + 8)
            let method = Int(u16(data, off + 10))
            let compressedSize = Int(u32(data, off + 20))
            let uncompressedSize = Int(u32(data, off + 24))
            let nameLen = Int(u16(data, off + 28))
            let extraLen = Int(u16(data, off + 30))
            let commentLen = Int(u16(data, off + 32))
            let localOffset = Int(u32(data, off + 42))
            guard compressedSize != 0xFFFF_FFFF,
                  uncompressedSize != 0xFFFF_FFFF,
                  off + 46 + nameLen + extraLen + commentLen <= data.count else {
                throw SpreadsheetError.notSupported
            }
            let name = String(data: data.subdata(in: off + 46..<off + 46 + nameLen), encoding: .utf8) ?? ""
            entries.append((name, flags, method, compressedSize, uncompressedSize, localOffset))
            off += 46 + nameLen + extraLen + commentLen
        }

        func localData(_ name: String) -> Data? {
            guard let entry = entries.first(where: { $0.name == name }) else { return nil }
            let lo = entry.localOffset
            guard entry.flags & 0x0001 == 0,
                  lo >= 0,
                  data.count >= lo + 30,
                  u32(data, lo) == 0x0403_4B50 else { return nil }
            let nameLen = Int(u16(data, lo + 26))
            let extraLen = Int(u16(data, lo + 28))
            let start = lo + 30 + nameLen + extraLen
            let end = start + entry.compressedSize
            guard start >= 0, end >= start, end <= data.count else { return nil }
            let raw = data.subdata(in: start..<end)
            if entry.method == 0 { return raw }
            if entry.method == 8 { return inflate(raw, expectedSize: entry.uncompressedSize) }
            return nil
        }

        // 2) 共享字符串
        var shared: [String] = []
        if let ssData = localData("xl/sharedStrings.xml"),
           let xml = String(data: ssData, encoding: .utf8) {
            shared = parseSharedStrings(xml)
        }

        // 3) 工作表（取第一个 worksheet）
        guard let sheetEntry = entries.first(where: { $0.name.hasPrefix("xl/worksheets/sheet") && $0.name.hasSuffix(".xml") }),
              let sheetData = localData(sheetEntry.name),
              let sheetXML = String(data: sheetData, encoding: .utf8) else {
            throw SpreadsheetError.empty
        }
        let grid = parseSheet(sheetXML, sharedStrings: shared)
        return [SpreadsheetSheet(name: "Sheet1", grid: grid)]
    }

    private static func parseSharedStrings(_ xml: String) -> [String] {
        var result: [String] = []
        // <si>...</si>，内部可能有多个 <t>
        let siPattern = try? NSRegularExpression(pattern: "<si>(.*?)</si>", options: [.dotMatchesLineSeparators])
        let tPattern = try? NSRegularExpression(pattern: "<t[^>]*>(.*?)</t>", options: [.dotMatchesLineSeparators])
        guard let siPattern, let tPattern else { return result }
        let siRange = NSRange(xml.startIndex..., in: xml)
        siPattern.enumerateMatches(in: xml, range: siRange) { match, _, _ in
            guard let m = match, let inner = Range(m.range(at: 1), in: xml) else { return }
            let innerStr = String(xml[inner])
            var text = ""
            tPattern.enumerateMatches(in: innerStr, range: NSRange(innerStr.startIndex..., in: innerStr)) { tm, _, _ in
                if let tm, let r = Range(tm.range(at: 1), in: innerStr) {
                    text += String(innerStr[r])
                }
            }
            result.append(decodeXMLEntities(text))
        }
        return result
    }

    private static func parseSheet(_ xml: String, sharedStrings: [String]) -> [[String]] {
        var grid: [Int: [Int: String]] = [:]
        let rowPattern = try? NSRegularExpression(pattern: "<row[^>]*r=\"(\\d+)\"[^>]*>(.*?)</row>", options: [.dotMatchesLineSeparators])
        let cellPattern = try? NSRegularExpression(pattern: "<c[^>]*r=\"([A-Z]+)(\\d+)\"((?:[^>]*t=\"([^\"]*)\")?[^>]*)>(.*?)</c>", options: [.dotMatchesLineSeparators])
        guard let rowPattern, let cellPattern else { return [] }
        rowPattern.enumerateMatches(in: xml, range: NSRange(xml.startIndex..., in: xml)) { rmatch, _, _ in
            guard let rm = rmatch,
                  let rstr = Range(rm.range(at: 1), in: xml),
                  let bodyRange = Range(rm.range(at: 2), in: xml) else { return }
            let rowIndex = Int(xml[rstr]) ?? 0
            let body = String(xml[bodyRange])
            cellPattern.enumerateMatches(in: body, range: NSRange(body.startIndex..., in: body)) { cm, _, _ in
                guard let cm,
                      let colRange = Range(cm.range(at: 1), in: body),
                      Range(cm.range(at: 2), in: body) != nil else { return }
                let colLetters = String(body[colRange])
                let t = cm.range(at: 4).location != NSNotFound ? String(body[Range(cm.range(at: 4), in: body)!]) : nil
                let inner = cm.range(at: 5).location != NSNotFound ? String(body[Range(cm.range(at: 5), in: body)!]) : ""
                let colIndex = colLetters.reduce(0) { $0 * 26 + (Int($1.asciiValue! - 64)) }
                var value = ""
                if t == "s" {
                    if let vm = inner.range(of: #"<v>([^<]*)</v>"#, options: .regularExpression),
                       let idx = Int(inner[vm].replacingOccurrences(of: "<v>", with: "").replacingOccurrences(of: "</v>", with: "")) {
                        value = idx < sharedStrings.count ? sharedStrings[idx] : ""
                    }
                } else if t == "inlineStr" {
                    let tPat = try? NSRegularExpression(pattern: "<t[^>]*>(.*?)</t>", options: [.dotMatchesLineSeparators])
                    if let tPat {
                        let matches = tPat.matches(in: inner, range: NSRange(inner.startIndex..., in: inner))
                        var text = ""
                        for m in matches {
                            if let r = Range(m.range(at: 1), in: inner) { text += String(inner[r]) }
                        }
                        value = decodeXMLEntities(text)
                    }
                } else {
                    if let vm = inner.range(of: #"<v>([^<]*)</v>"#, options: .regularExpression) {
                        value = String(inner[vm]).replacingOccurrences(of: "<v>", with: "").replacingOccurrences(of: "</v>", with: "")
                    }
                }
                var rowDict = grid[rowIndex] ?? [:]
                rowDict[colIndex] = value
                grid[rowIndex] = rowDict
            }
        }
        let maxR = grid.keys.max() ?? 0
        let maxC = grid.values.map { $0.keys.max() ?? 0 }.max() ?? 0
        var rows: [[String]] = []
        for r in 1...maxR {
            var row: [String] = []
            for c in 1...maxC { row.append(grid[r]?[c] ?? "") }
            rows.append(row)
        }
        return rows
    }

    private static func decodeXMLEntities(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        let maximumEntrySize = 64 * 1024 * 1024
        guard expectedSize >= 0, expectedSize <= maximumEntrySize else { return nil }
        if expectedSize == 0 { return Data() }

        var destination = [UInt8](repeating: 0, count: expectedSize)
        let src = [UInt8](data)
        let rc = src.withUnsafeBytes { srcPtr in
            destination.withUnsafeMutableBytes { dstPtr in
                compression_decode_buffer(dstPtr.bindMemory(to: UInt8.self).baseAddress!,
                                          dstPtr.count,
                                          srcPtr.bindMemory(to: UInt8.self).baseAddress!,
                                          src.count,
                                          nil,
                                          COMPRESSION_ZLIB)
            }
        }
        guard rc == expectedSize else { return nil }
        return Data(destination)
    }
}

private extension Data {
    func u32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8) | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
    func u16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }
}
