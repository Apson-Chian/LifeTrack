import CoreLocation
import CryptoKit
import Foundation
import SwiftData

enum GPXServiceError: LocalizedError {
    case emptyTrack
    case invalidFile(String)
    case fileTooLarge
    case tooManyPoints
    case duplicate
    case persistence

    var errorDescription: String? {
        switch self {
        case .emptyTrack: "GPX 文件中没有可导入的轨迹点。"
        case .invalidFile(let detail): "无法解析 GPX：\(detail)"
        case .fileTooLarge: "GPX 文件超过 50 MB，无法导入。"
        case .tooManyPoints: "GPX 轨迹点过多，无法导入。"
        case .duplicate: "这条 GPX 轨迹已经导入过，没有重复创建。"
        case .persistence: "GPX 轨迹已解析，但保存到本地数据库失败。"
        }
    }
}

enum GPXService {
    private static let maximumFileSize = 50 * 1024 * 1024
    private static let maximumTrackPointCount = 300_000

    static func export(session: ActivitySession) throws -> URL {
        let points = session.trackPoints.sorted { $0.timestamp < $1.timestamp }
        guard !points.isEmpty else { throw GPXServiceError.emptyTrack }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let name = "LifeTrack \(session.activityType.displayName)"
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<gpx version=\"1.1\" creator=\"LifeTrack\" xmlns=\"http://www.topografix.com/GPX/1/1\">",
            "  <metadata><time>\(formatter.string(from: session.startTime))</time></metadata>",
            "  <trk><name>\(xmlEscaped(name))</name><trkseg>"
        ]
        lines.reserveCapacity(points.count + 5)
        for point in points {
            lines.append("    <trkpt lat=\"\(point.latitude)\" lon=\"\(point.longitude)\"><ele>\(point.altitude)</ele><time>\(formatter.string(from: point.timestamp))</time></trkpt>")
        }
        lines.append("  </trkseg></trk>")
        lines.append("</gpx>")

        let filename = "LifeTrack-\(fileDate(session.startTime)).gpx"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try lines.joined(separator: "\n").data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    @MainActor
    static func importFile(at url: URL, into context: ModelContext) throws -> ActivitySession {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey,
                                                              .contentModificationDateKey])
        guard resourceValues.isRegularFile != false else {
            throw GPXServiceError.invalidFile("请选择普通 GPX 文件")
        }
        if let fileSize = resourceValues.fileSize, fileSize > maximumFileSize {
            throw GPXServiceError.fileTooLarge
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumFileSize else { throw GPXServiceError.fileTooLarge }
        let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .now
        let parserDelegate = GPXParserDelegate(fallbackDate: modificationDate,
                                               maximumPointCount: maximumTrackPointCount)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = parserDelegate
        guard parser.parse() else {
            if parserDelegate.didExceedPointLimit { throw GPXServiceError.tooManyPoints }
            throw GPXServiceError.invalidFile(parser.parserError?.localizedDescription ?? "文件格式不正确")
        }

        let points = parserDelegate.points.sorted { $0.timestamp < $1.timestamp }
        guard !points.isEmpty else { throw GPXServiceError.emptyTrack }
        let fingerprint = fingerprint(for: points)

        let importContext = ModelContext(context.container)
        importContext.autosaveEnabled = false
        let existing = try importContext.fetch(FetchDescriptor<ActivitySession>())
        if existing.contains(where: { session in
            if session.importFingerprint == fingerprint { return true }
            guard session.sourceRawValue == "imported_gpx",
                  session.trackPoints.count == points.count,
                  let first = session.trackPoints.min(by: { $0.timestamp < $1.timestamp }),
                  let last = session.trackPoints.max(by: { $0.timestamp < $1.timestamp }) else { return false }
            return abs(first.timestamp.timeIntervalSince(points[0].timestamp)) < 1 &&
                abs(last.timestamp.timeIntervalSince(points[points.count - 1].timestamp)) < 1
        }) {
            throw GPXServiceError.duplicate
        }

        let session = ActivitySession(activityType: .unknown,
                                      source: "imported_gpx",
                                      startTime: points[0].timestamp)
        session.importFingerprint = fingerprint
        session.endTime = points[points.count - 1].timestamp
        session.duration = max(0, session.endTime!.timeIntervalSince(session.startTime))
        session.isActive = false
        importContext.insert(session)

        var models: [TrackPoint] = []
        models.reserveCapacity(points.count)
        for point in points {
            let model = TrackPoint(latitude: point.latitude,
                                   longitude: point.longitude,
                                   altitude: point.elevation,
                                   speed: -1,
                                   course: -1,
                                   horizontalAccuracy: 25,
                                   timestamp: point.timestamp,
                                   activityType: .unknown,
                                   session: session)
            importContext.insert(model)
            models.append(model)
        }

        let analysis = TrajectoryAnalysisService.analyze(models)
        for point in models {
            point.anomalyReason = analysis.anomalyReasons[point.id]
        }
        session.distance = analysis.effectiveDistance

        let places = try importContext.fetch(FetchDescriptor<CustomPlace>())
        StayDetectionService.rebuildRecords(for: session, places: places, in: importContext)
        guard PersistenceService.save(importContext,
                                      operation: "导入 GPX 轨迹",
                                      failureRecovery: .rollback) else {
            throw GPXServiceError.persistence
        }
        JourneyGenerationService.refresh(in: importContext)
        return session
    }

    private static func fingerprint(for points: [GPXPoint]) -> String {
        var hasher = SHA256()
        for point in points {
            let normalized = String(format: "%.6f,%.6f,%.1f,%.3f|",
                                    point.latitude,
                                    point.longitude,
                                    point.elevation,
                                    point.timestamp.timeIntervalSince1970)
            hasher.update(data: Data(normalized.utf8))
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func fileDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

private struct GPXPoint {
    let latitude: Double
    let longitude: Double
    let elevation: Double
    let timestamp: Date
}

private final class GPXParserDelegate: NSObject, XMLParserDelegate {
    private struct PendingPoint {
        let latitude: Double
        let longitude: Double
        var elevation: Double = 0
        var timestamp: Date?
        var isInvalid = false
    }

    private let fallbackDate: Date
    private let maximumPointCount: Int
    private let formatter: ISO8601DateFormatter
    private var currentPoint: PendingPoint?
    private var currentElement = ""
    private var currentText = ""
    private(set) var points: [GPXPoint] = []
    private(set) var didExceedPointLimit = false

    init(fallbackDate: Date, maximumPointCount: Int) {
        let referenceTime = fallbackDate.timeIntervalSinceReferenceDate
        self.fallbackDate = referenceTime.isFinite ? fallbackDate : .now
        self.maximumPointCount = maximumPointCount
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName.lowercased()
        currentText = ""
        guard currentElement == "trkpt" || currentElement == "rtept" else { return }
        currentPoint = nil
        guard
              let latitudeText = attributeDict["lat"],
              let longitudeText = attributeDict["lon"],
              let latitude = Double(latitudeText),
              let longitude = Double(longitudeText),
              latitude.isFinite,
              longitude.isFinite,
              CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude,
                                                                   longitude: longitude)) else { return }
        currentPoint = PendingPoint(latitude: latitude, longitude: longitude)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let element = elementName.lowercased()
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if element == "ele" {
            if let elevation = Double(value), elevation.isFinite {
                currentPoint?.elevation = elevation
            } else {
                currentPoint?.isInvalid = true
            }
        } else if element == "time" {
            if let timestamp = parseDate(value), Self.isValid(timestamp) {
                currentPoint?.timestamp = timestamp
            } else {
                currentPoint?.isInvalid = true
            }
        } else if element == "trkpt" || element == "rtept" {
            if let point = currentPoint, !point.isInvalid {
                guard points.count < maximumPointCount else {
                    didExceedPointLimit = true
                    parser.abortParsing()
                    currentPoint = nil
                    return
                }
                let fallback = fallbackDate.addingTimeInterval(Double(points.count))
                let timestamp = point.timestamp ?? fallback
                if Self.isValid(timestamp) {
                    points.append(GPXPoint(latitude: point.latitude,
                                           longitude: point.longitude,
                                           elevation: point.elevation,
                                           timestamp: timestamp))
                }
            }
            currentPoint = nil
        }
        currentElement = ""
        currentText = ""
    }

    private func parseDate(_ value: String) -> Date? {
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        let date = formatter.date(from: value)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return date
    }

    private static func isValid(_ date: Date) -> Bool {
        let value = date.timeIntervalSinceReferenceDate
        let earliest = Date(timeIntervalSince1970: 0)
        let latest = Date.now.addingTimeInterval(7 * 24 * 60 * 60)
        return value.isFinite && date >= earliest && date <= latest
    }
}
