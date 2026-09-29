import Foundation
import CSQLite
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif

public struct ScreenshotEvidence: Sendable {
    public let id: String
    public let startedAt: Date
    public let displayName: String
    public let url: URL
    let perceptualHash: Data

    /// Downsample locally; the original JustNow file is never modified.
    func encodedImage() -> String? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1920,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data).base64EncodedString()
        #else
        return (try? Data(contentsOf: url))?.base64EncodedString()
        #endif
    }
}

extension JustNowReader {
    public func screenshotCandidates(from start: Date, to end: Date) throws -> [ScreenshotEvidence] {
        let db = try SQLiteReadConnection(url: framesDatabaseURL)
        let statement = try db.prepare("""
        SELECT f.id, s.started_at, f.filename, f.perceptual_hash, s.display_name
        FROM frame_spans s JOIN frames f ON f.id = s.frame_id
        WHERE s.observed_through_at >= ? AND s.started_at <= ?
        ORDER BY s.started_at ASC, s.sequence ASC;
        """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_double(statement, 1, start.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_double(statement, 2, end.timeIntervalSince1970) == SQLITE_OK else {
            throw WorklogError.sqlite(db.errorMessage())
        }
        let root = directory.appendingPathComponent("frames", isDirectory: true).resolvingSymlinksInPath()
        var seen = Set<String>()
        var candidates: [ScreenshotEvidence] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw WorklogError.sqlite(db.errorMessage()) }
            guard let id = sqliteText(statement, 0), let filename = sqliteText(statement, 2),
                  seen.insert("\(id):\(sqliteText(statement, 4) ?? "Unknown display")").inserted else { continue }
            let url = root.appendingPathComponent(filename).resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: url.path) else { continue }
            let bytes = sqlite3_column_bytes(statement, 3)
            let hash = sqlite3_column_blob(statement, 3).map { Data(bytes: $0, count: Int(bytes)) } ?? Data()
            candidates.append(ScreenshotEvidence(id: id,
                startedAt: max(start, Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))),
                displayName: sqliteText(statement, 4) ?? "Unknown display", url: url, perceptualHash: hash))
        }
        return candidates
    }
}

// Compatibility for callers that only need image references. The engine supplies OCR explicitly.
extension JustNowReader {
    public func representativeScreenshots(from start: Date, to end: Date, limit: Int = 12) throws -> [ScreenshotEvidence] {
        let raw = try observations(from: start, to: end)
        return VisualEvidenceSampler().select(images: try screenshotCandidates(from: start, to: end), observations: raw,
            start: start, end: end, settings: ScreenshotSelectionSettings(maximum: limit)).selected.map(\.image)
    }
}
