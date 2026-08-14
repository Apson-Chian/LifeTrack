import Darwin
import Foundation
import OSLog
import UIKit

/// 崩溃捕获、事件日志与诊断包导出。
///
/// 不上架 App Store 时没有崩溃日志渠道，这里把崩溃与关键事件落到本地文件，
/// 用户可从设置页导出一份诊断报告发给开发者定位问题。
enum DiagnosticsService {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LifeTrack",
                                       category: "Diagnostics")

    private static let diagnosticsDirectoryName = "LifeTrackDiagnostics"
    private static let crashDirectoryName = "Crashes"
    private static let eventLogFileName = "events.log"
    private static let maximumCrashReports = 20
    private static let maximumEventLogBytes = 256 * 1024

    // MARK: - 崩溃捕获

    /// 在 App 启动最早期调用一次。
    static func installCrashHandlers() {
        // 标记已经安装，避免重复注册。
        guard !Self.handlersInstalled else { return }
        Self.handlersInstalled = true

        NSSetUncaughtExceptionHandler { exception in
            Self.recordException(exception)
        }

        install(signal: SIGABRT)
        install(signal: SIGILL)
        install(signal: SIGSEGV)
        install(signal: SIGFPE)
        install(signal: SIGBUS)
        install(signal: SIGTRAP)
    }

    // MARK: - 事件日志

    static func logEvent(_ message: String, category: String = "info") {
        let line = "[\(Self.timestamp())] [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = eventLogURL
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url)
            } else {
                let handle = try FileHandle(forWritingTo: url)
                handle.seekToEndOfFile()
                handle.write(data)
                try handle.close()
            }
            trimEventLogIfNeeded(at: url)
        } catch {
            logger.error("Event log write failed: \(String(reflecting: error), privacy: .public)")
        }
    }

    // MARK: - 诊断报告

    /// 生成一份可分享的纯文本诊断报告，返回其临时文件 URL。
    static func buildDiagnosticsReport(health: DataHealthSnapshot) throws -> URL {
        var lines: [String] = []
        lines.append("LifeTrack 诊断报告")
        lines.append("==============================")
        lines.append("生成时间: \(Self.timestamp())")
        lines.append("App 版本: \(appVersion) (build \(buildNumber))")
        lines.append("系统版本: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        lines.append("设备型号: \(UIDevice.current.model) · \(UIDevice.current.name)")
        lines.append("")

        lines.append("【数据健康】")
        lines.append("活跃会话数: \(health.activeSessionCount)")
        if let oldest = health.oldestActiveSessionStart {
            lines.append("最早活跃会话开始: \(Self.timestamp(of: oldest))")
        }
        lines.append("数据库大小: \(ByteCountFormatter.string(fromByteCount: health.databaseSize, countStyle: .file))")
        lines.append("最近备份: \(health.lastBackupDate.map(Self.timestamp(of:)) ?? "从未备份")")
        for record in health.recordCounts {
            lines.append("- \(record.name): \(record.count)")
        }
        lines.append("")

        lines.append("【事件日志】（最多显示最近 400 条）")
        let events = recentEventLog()
        lines.append(contentsOf: events.isEmpty ? ["（无）"] : events)
        lines.append("")

        lines.append("【崩溃报告】")
        let reports = pendingCrashReports()
        if reports.isEmpty {
            lines.append("（无已记录的崩溃）")
        } else {
            for url in reports {
                lines.append("---- \(url.lastPathComponent) ----")
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    lines.append(content.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                lines.append("")
            }
        }

        let content = lines.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeTrack-诊断报告-\(Self.fileDate(Date.now)).txt")
        try Data(content.utf8).write(to: url, options: .atomic)
        return url
    }

    /// 清除已记录的崩溃报告（例如用户主动清理时）。
    static func clearCrashReports() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: crashDirectory, includingPropertiesForKeys: nil) else { return }
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - 私有

    private static var handlersInstalled = false

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    private static func install(signal value: Int32) {
        Darwin.signal(value, signalHandler)
    }

    /// 无捕获的 C 函数指针，用于 signal() 注册（捕获局部变量会无法编译）。
    private static let signalHandler: @convention(c) (Int32) -> Void = { value in
        // 信号处理器里只做最小化、尽量安全的文件写入。
        DiagnosticsService.writeSignalReport(value, name: signalName(for: value))
    }

    private static func signalName(for value: Int32) -> String {
        switch value {
        case SIGABRT: return "SIGABRT"
        case SIGILL: return "SIGILL"
        case SIGSEGV: return "SIGSEGV"
        case SIGFPE: return "SIGFPE"
        case SIGBUS: return "SIGBUS"
        case SIGTRAP: return "SIGTRAP"
        default: return "SIG\(value)"
        }
    }

    private static func recordException(_ exception: NSException) {
        var lines: [String] = []
        lines.append("时间: \(Self.timestamp())")
        lines.append("类型: NSException · \(exception.name.rawValue)")
        lines.append("原因: \(exception.reason ?? "未知")")
        lines.append("调用栈:")
        lines.append(contentsOf: exception.callStackSymbols)
        let content = lines.joined(separator: "\n") + "\n"
        try? content.write(to: crashFileURL(kind: "exception"), atomically: true, encoding: .utf8)
        trimCrashReports()
    }

    private static func writeSignalReport(_ signalNumber: Int32, name: String) {
        let content = "时间: \(Self.timestamp())\n类型: 信号 \(name) (\(signalNumber))\n"
        // 用 write(2) 直接落盘，避免信号上下文里的对象分配问题。
        let url = crashFileURL(kind: name.lowercased())
        content.withCString { cString in
            url.path.withCString { path in
                let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
                guard fd >= 0 else { return }
                _ = Darwin.write(fd, cString, strlen(cString))
                _ = Darwin.close(fd)
            }
        }
    }

    private static func pendingCrashReports() -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: crashDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return urls.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    private static func crashFileURL(kind: String) -> URL {
        crashDirectory.appendingPathComponent("\(fileDate(Date.now))-\(kind)-\(UUID().uuidString.prefix(6)).txt")
    }

    private static func trimCrashReports() {
        let urls = pendingCrashReports()
        guard urls.count > maximumCrashReports else { return }
        for url in urls.dropFirst(maximumCrashReports) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func recentEventLog() -> [String] {
        guard let data = FileManager.default.contents(atPath: eventLogURL.path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        return Array(lines.suffix(400))
    }

    private static func trimEventLogIfNeeded(at url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > maximumEventLogBytes else { return }
        // 简单截断：只保留后半段（最新事件），避免日志无限增长。
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else { return }
        let half = maximumEventLogBytes / 2
        let suffix = text.suffix(half)
        try? Data(String(suffix).utf8).write(to: url, options: .atomic)
    }

    private static var diagnosticsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent(diagnosticsDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var crashDirectory: URL {
        let dir = diagnosticsDirectory.appendingPathComponent(crashDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var eventLogURL: URL {
        diagnosticsDirectory.appendingPathComponent(eventLogFileName)
    }

    private static func timestamp(of date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func fileDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
