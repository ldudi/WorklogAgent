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

struct ScreenshotSelector {
    func select(_ candidates: [ScreenshotEvidence], limit: Int = 6) -> [ScreenshotEvidence] {
        guard limit > 0 else { return [] }
        var previousByDisplay: [String: Data] = [:]
        var unique: [ScreenshotEvidence] = []
        for candidate in candidates.sorted(by: { $0.startedAt < $1.startedAt }) {
            if let previous = previousByDisplay[candidate.displayName],
               previous.count == 8, candidate.perceptualHash.count == 8,
               zip(previous, candidate.perceptualHash).reduce(0, { $0 + ($1.0 ^ $1.1).nonzeroBitCount }) <= 6 {
                continue
            }
            unique.append(candidate)
            previousByDisplay[candidate.displayName] = candidate.perceptualHash
        }
        let groups = Dictionary(grouping: unique, by: \.displayName)
        let displays = Array(groups.keys.sorted().prefix(limit))
        var allocations = Dictionary(uniqueKeysWithValues: displays.map { ($0, 1) })
        while allocations.values.reduce(0, +) < min(limit, unique.count) {
            let eligible = displays.filter { (allocations[$0] ?? 0) < (groups[$0]?.count ?? 0) }
            guard let key = eligible.max(by: {
                Double(groups[$0]?.count ?? 0) / Double((allocations[$0] ?? 0) + 1) <
                Double(groups[$1]?.count ?? 0) / Double((allocations[$1] ?? 0) + 1)
            }) else { break }
            allocations[key, default: 0] += 1
        }
        return displays.flatMap { evenlySpaced(groups[$0] ?? [], limit: allocations[$0] ?? 0) }
            .sorted { $0.startedAt < $1.startedAt }
    }
}

extension JustNowReader {
    public func representativeScreenshots(from start: Date, to end: Date, limit: Int = 6) throws -> [ScreenshotEvidence] {
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
                  seen.insert(id).inserted else { continue }
            let url = root.appendingPathComponent(filename).resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: url.path) else { continue }
            let bytes = sqlite3_column_bytes(statement, 3)
            let hash = sqlite3_column_blob(statement, 3).map { Data(bytes: $0, count: Int(bytes)) } ?? Data()
            candidates.append(ScreenshotEvidence(id: id,
                startedAt: max(start, Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))),
                displayName: sqliteText(statement, 4) ?? "Unknown display", url: url, perceptualHash: hash))
        }
        return ScreenshotSelector().select(candidates, limit: min(6, max(0, limit)))
    }
}
