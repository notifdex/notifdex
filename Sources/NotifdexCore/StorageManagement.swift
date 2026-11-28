import Foundation
import CSQLite

// MARK: - Storage Usage & Retention Cleanup (Shared macOS + iOS, Issue #110)
// Mirrors spec/StorageCleanup.tla: atomic FK-safe deletion, user-data preservation,
// protected-alert preservation for age-based retention, WAL checkpoint + VACUUM,
// integrity verification, and device-local prune watermark for CloudKit sync safety.

public enum StorageCleanupPeriod: String, CaseIterable, Identifiable, Codable, Sendable {
    case olderThan30Days = "30d"
    case olderThan90Days = "90d"
    case olderThan180Days = "180d"
    case olderThan1Year = "365d"
    case allHistory = "all"

    public var id: String { rawValue }

    public var retentionDays: Int? {
        switch self {
        case .olderThan30Days: 30
        case .olderThan90Days: 90
        case .olderThan180Days: 180
        case .olderThan1Year: 365
        case .allHistory: nil
        }
    }

    public var isClearAll: Bool {
        self == .allHistory
    }

    public static var ageRetentionOptions: [StorageCleanupPeriod] {
        [.olderThan30Days, .olderThan90Days, .olderThan180Days, .olderThan1Year]
    }

    public var title: String {
        switch self {
        case .olderThan30Days: "Older than 30 days"
        case .olderThan90Days: "Older than 90 days"
        case .olderThan180Days: "Older than 180 days"
        case .olderThan1Year: "Older than 1 year"
        case .allHistory: "All notification history"
        }
    }

    public var shortTitle: String {
        switch self {
        case .olderThan30Days: "30 days"
        case .olderThan90Days: "90 days"
        case .olderThan180Days: "180 days"
        case .olderThan1Year: "1 year"
        case .allHistory: "All history"
        }
    }

    public func cutoffTimestamp(now: Double) -> Double? {
        guard let days = retentionDays else { return nil }
        return now - Double(days) * 86_400.0
    }
}

public struct StorageUsageReport: Equatable, Sendable {
    public let totalBytes: Int64
    public let databaseFileBytes: Int64
    public let walBytes: Int64
    public let shmBytes: Int64
    public let auxiliaryDatabaseBytes: Int64
    public let attachmentsAndMediaBytes: Int64
    public let recordsAndMetadataBytes: Int64
    public let contentAndPayloadsBytes: Int64
    public let indexesAndOverheadBytes: Int64
    public let freelistBytes: Int64
    public let observationCount: Int
    public let protectedObservationCount: Int
    public let oldestObservationAt: Double?
    public let newestObservationAt: Double?
    public let calculatedAt: Double

    public var formattedTotalSize: String {
        Self.formatBytes(totalBytes)
    }

    public var formattedRecordsAndMetadata: String {
        Self.formatBytes(recordsAndMetadataBytes)
    }

    public var formattedContentAndPayloads: String {
        Self.formatBytes(contentAndPayloadsBytes)
    }

    public var formattedAttachmentsAndMedia: String {
        Self.formatBytes(attachmentsAndMediaBytes)
    }

    public var formattedIndexesAndOverhead: String {
        Self.formatBytes(indexesAndOverheadBytes)
    }

    public var formattedFreelistSize: String {
        Self.formatBytes(freelistBytes)
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}

public struct StorageCleanupPreview: Equatable, Sendable {
    public let period: StorageCleanupPeriod
    public let cutoffTimestamp: Double?
    public let removableObservationCount: Int
    public let preservedObservationCount: Int
    public let estimatedReclaimableBytes: Int64
    public let preservedPeopleCount: Int
    public let preservedNotesCount: Int
    public let preservedWorkspacesCount: Int
    public let preservedHideRulesCount: Int

    public var formattedEstimatedReclaim: String {
        StorageUsageReport.formatBytes(estimatedReclaimableBytes)
    }
}

public struct StorageCleanupResult: Equatable, Sendable {
    public let period: StorageCleanupPeriod
    public let removedObservations: Int
    public let preservedObservations: Int
    public let bytesBefore: Int64
    public let bytesAfter: Int64
    public let reclaimedBytes: Int64
    public let vacuumPerformed: Bool
    public let integrityOK: Bool
    public let completedAt: Double

    public var formattedReclaimedBytes: String {
        StorageUsageReport.formatBytes(reclaimedBytes)
    }
}

public extension CaptureStore {
    /// SQL predicate identifying user-curated or cross-referenced observations preserved by age-based cleanup.
    private static let protectedObservationClause = """
        (EXISTS (SELECT 1 FROM flagged_observations f WHERE f.observation_id = o.id)
         OR EXISTS (SELECT 1 FROM observation_work w WHERE w.observation_id = o.id AND (w.saved = 1 OR (w.due_at IS NOT NULL AND w.done = 0)))
         OR EXISTS (SELECT 1 FROM person_observations po WHERE po.observation_id = o.id)
         OR EXISTS (SELECT 1 FROM observation_workspaces ow WHERE ow.observation_id = o.id))
        """

    private static func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return max(0, size.int64Value)
    }

    private static func sqliteFileFootprint(for databaseURL: URL) -> (main: Int64, wal: Int64, shm: Int64) {
        let basePath = databaseURL.path
        let main = fileSize(at: databaseURL)
        let wal = fileSize(at: URL(fileURLWithPath: basePath + "-wal"))
        let shm = fileSize(at: URL(fileURLWithPath: basePath + "-shm"))
        return (main, wal, shm)
    }

    private func scalarInt64(_ sql: String, numbers: [Double] = []) throws -> Int64 {
        let statement = try prepare(sql, numbers: numbers)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int64(statement, 0)
    }

    private func scalarOptionalDouble(_ sql: String) throws -> Double? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 0)
    }

    /// Calculates local storage footprint including SQLite main DB, WAL/SHM sidecars,
    /// auxiliary databases (e.g., iOS telemetry DB), and stored media/attachments (e.g., custom backdrop).
    func storageUsageReport(
        databaseURL: URL,
        auxiliaryDatabaseURLs: [URL] = [],
        mediaFileURLs: [URL] = [],
        at calculatedAt: Double = Date().timeIntervalSince1970
    ) throws -> StorageUsageReport {
        let primaryFootprint = Self.sqliteFileFootprint(for: databaseURL)
        let auxBytes: Int64 = auxiliaryDatabaseURLs.reduce(0) { sum, url in
            let f = Self.sqliteFileFootprint(for: url)
            return sum + f.main + f.wal + f.shm
        }
        let mediaBytes: Int64 = mediaFileURLs.reduce(0) { $0 + Self.fileSize(at: $1) }
        let sqliteDiskBytes = primaryFootprint.main + primaryFootprint.wal + primaryFootprint.shm + auxBytes
        let totalBytes = sqliteDiskBytes + mediaBytes

        let pageSize = try scalarInt64("PRAGMA page_size")
        let freelistCount = try scalarInt64("PRAGMA freelist_count")
        let freelistBytes = max(0, pageSize * freelistCount)

        let obsCount = try scalar("SELECT count(*) FROM observations")
        let protectedCount = try scalar("SELECT count(*) FROM observations o WHERE \(Self.protectedObservationClause)")
        let oldest = try scalarOptionalDouble("SELECT min(captured_at) FROM observations")
        let newest = try scalarOptionalDouble("SELECT max(captured_at) FROM observations")

        // Measure logical payload bytes (captured notification content) vs. metadata/CRM records.
        let contentBytes = try scalarInt64("""
            SELECT coalesce(SUM(
                length(CAST(title AS BLOB))
                + length(CAST(subtitle AS BLOB))
                + length(CAST(body AS BLOB))
                + length(CAST(accessibility_description AS BLOB))
            ), 0) FROM observations
            """)

        let obsMetadataBytes = try scalarInt64("""
            SELECT coalesce(SUM(
                length(CAST(source_id AS BLOB))
                + length(CAST(source_event_id AS BLOB))
                + length(CAST(run_id AS BLOB))
                + length(CAST(origin AS BLOB))
                + length(CAST(coalesce(app_label, '') AS BLOB))
                + 32
            ), 0) FROM observations
            """)

        let notesAndCRMBytes = try scalarInt64("""
            SELECT
                coalesce((SELECT SUM(length(CAST(title AS BLOB)) + length(CAST(body AS BLOB)) + 48) FROM personal_notes), 0)
                + coalesce((SELECT SUM(length(CAST(title AS BLOB)) + length(CAST(body AS BLOB)) + 48) FROM person_notes), 0)
                + coalesce((SELECT SUM(length(CAST(display_name AS BLOB)) + 48) FROM people), 0)
                + coalesce((SELECT SUM(length(CAST(app AS BLOB)) + length(CAST(value AS BLOB)) + 32) FROM inbox_filters), 0)
                + coalesce((SELECT SUM(length(CAST(definition AS BLOB)) + 32) FROM relationship_templates), 0)
                + coalesce((SELECT count(*) * 64 FROM sync_observation_links), 0)
                + coalesce((SELECT count(*) * 48 FROM coverage_gaps), 0)
            """)

        let logicalRecordsBytes = max(0, obsMetadataBytes + notesAndCRMBytes)
        let logicalTotal = contentBytes + logicalRecordsBytes
        let indexesAndOverheadBytes: Int64
        if sqliteDiskBytes >= logicalTotal {
            indexesAndOverheadBytes = sqliteDiskBytes - logicalTotal
        } else {
            indexesAndOverheadBytes = freelistBytes + primaryFootprint.wal + primaryFootprint.shm
        }

        return StorageUsageReport(
            totalBytes: totalBytes,
            databaseFileBytes: primaryFootprint.main,
            walBytes: primaryFootprint.wal,
            shmBytes: primaryFootprint.shm,
            auxiliaryDatabaseBytes: auxBytes,
            attachmentsAndMediaBytes: mediaBytes,
            recordsAndMetadataBytes: logicalRecordsBytes,
            contentAndPayloadsBytes: contentBytes,
            indexesAndOverheadBytes: indexesAndOverheadBytes,
            freelistBytes: freelistBytes,
            observationCount: obsCount,
            protectedObservationCount: protectedCount,
            oldestObservationAt: oldest,
            newestObservationAt: newest,
            calculatedAt: calculatedAt
        )
    }

    /// Estimates how many observations will be removed vs. preserved and how much disk space can be reclaimed.
    func previewStorageCleanup(
        period: StorageCleanupPeriod,
        databaseURL: URL,
        auxiliaryDatabaseURLs: [URL] = [],
        mediaFileURLs: [URL] = [],
        now: Double = Date().timeIntervalSince1970
    ) throws -> StorageCleanupPreview {
        let report = try storageUsageReport(
            databaseURL: databaseURL,
            auxiliaryDatabaseURLs: auxiliaryDatabaseURLs,
            mediaFileURLs: mediaFileURLs,
            at: now
        )
        let cutoff = period.cutoffTimestamp(now: now)

        let removableCount: Int
        let preservedCount: Int
        let removableLogicalBytes: Int64

        if let cutoff {
            removableCount = Int(try scalarInt64("""
                SELECT count(*) FROM observations o
                WHERE o.captured_at < ? AND NOT \(Self.protectedObservationClause)
                """, numbers: [cutoff]))
            preservedCount = Int(try scalarInt64("""
                SELECT count(*) FROM observations o
                WHERE o.captured_at < ? AND \(Self.protectedObservationClause)
                """, numbers: [cutoff]))
            removableLogicalBytes = try scalarInt64("""
                SELECT coalesce(SUM(
                    length(CAST(source_id AS BLOB))
                    + length(CAST(source_event_id AS BLOB))
                    + length(CAST(run_id AS BLOB))
                    + length(CAST(origin AS BLOB))
                    + length(CAST(coalesce(app_label, '') AS BLOB))
                    + length(CAST(title AS BLOB))
                    + length(CAST(subtitle AS BLOB))
                    + length(CAST(body AS BLOB))
                    + length(CAST(accessibility_description AS BLOB))
                    + 96
                ), 0) FROM observations o
                WHERE o.captured_at < ? AND NOT \(Self.protectedObservationClause)
                """, numbers: [cutoff])
        } else {
            removableCount = report.observationCount
            preservedCount = 0
            removableLogicalBytes = try scalarInt64("""
                SELECT coalesce(SUM(
                    length(CAST(source_id AS BLOB))
                    + length(CAST(source_event_id AS BLOB))
                    + length(CAST(run_id AS BLOB))
                    + length(CAST(origin AS BLOB))
                    + length(CAST(coalesce(app_label, '') AS BLOB))
                    + length(CAST(title AS BLOB))
                    + length(CAST(subtitle AS BLOB))
                    + length(CAST(body AS BLOB))
                    + length(CAST(accessibility_description AS BLOB))
                    + 96
                ), 0) FROM observations
                """)
        }

        let peopleCount = try scalar("SELECT count(*) FROM people")
        let notesCount = try scalar("SELECT (SELECT count(*) FROM personal_notes) + (SELECT count(*) FROM person_notes)")
        let workspacesCount = try scalar("SELECT count(*) FROM workspaces")
        let rulesCount = try scalar("SELECT count(*) FROM inbox_filters")

        // Estimate disk savings from removable logical bytes (scaled for SQLite B-tree/index overhead)
        // plus existing reclaimable freelist + WAL overhead, bounded by actual primary DB footprint.
        let primarySQLiteBytes = report.databaseFileBytes + report.walBytes
        let estimatedReclaim: Int64
        if removableCount == 0 && report.freelistBytes == 0 {
            estimatedReclaim = 0
        } else if report.observationCount > 0 {
            let scaledContent = Int64((Double(removableLogicalBytes) * 1.25).rounded())
            let proportionEstimate = Int64((Double(primarySQLiteBytes) * (Double(removableCount) / Double(report.observationCount))).rounded())
            let rawEstimate = max(scaledContent, proportionEstimate) + report.freelistBytes
            // Leave room for minimum empty SQLite schema pages (~64 KB) when DB still holds user data.
            let minSchemaFootprint: Int64 = min(primarySQLiteBytes, 65_536)
            let maxPossible = max(0, primarySQLiteBytes - minSchemaFootprint)
            estimatedReclaim = min(maxPossible, max(0, rawEstimate))
        } else {
            estimatedReclaim = min(primarySQLiteBytes, report.freelistBytes)
        }

        return StorageCleanupPreview(
            period: period,
            cutoffTimestamp: cutoff,
            removableObservationCount: removableCount,
            preservedObservationCount: preservedCount,
            estimatedReclaimableBytes: estimatedReclaim,
            preservedPeopleCount: peopleCount,
            preservedNotesCount: notesCount,
            preservedWorkspacesCount: workspacesCount,
            preservedHideRulesCount: rulesCount
        )
    }

    /// Safely removes eligible notification history in an atomic FK-safe transaction while preserving
    /// people, notes, workspaces, hide rules, and (for age-based retention) saved/flagged/follow-up/linked alerts.
    /// Runs WAL checkpoint + VACUUM + PRAGMA quick_check afterwards to reclaim disk space safely.
    @discardableResult
    func performStorageCleanup(
        period: StorageCleanupPeriod,
        databaseURL: URL,
        auxiliaryDatabaseURLs: [URL] = [],
        mediaFileURLs: [URL] = [],
        now: Double = Date().timeIntervalSince1970
    ) throws -> StorageCleanupResult {
        let beforeReport = try storageUsageReport(
            databaseURL: databaseURL,
            auxiliaryDatabaseURLs: auxiliaryDatabaseURLs,
            mediaFileURLs: mediaFileURLs,
            at: now
        )
        let cutoff = period.cutoffTimestamp(now: now)

        let (removedCount, preservedCount): (Int, Int) = try transaction {
            try execute("CREATE TEMP TABLE IF NOT EXISTS _notifdex_cleanup_targets (id INTEGER PRIMARY KEY)")
            try execute("DELETE FROM _notifdex_cleanup_targets")

            let preserved: Int
            if let cutoff {
                try execute("""
                    INSERT INTO _notifdex_cleanup_targets (id)
                    SELECT o.id FROM observations o
                    WHERE o.captured_at < ? AND NOT \(Self.protectedObservationClause)
                    """, numbers: [cutoff])
                preserved = Int(try scalarInt64("""
                    SELECT count(*) FROM observations o
                    WHERE o.captured_at < ? AND \(Self.protectedObservationClause)
                    """, numbers: [cutoff]))
            } else {
                try execute("INSERT INTO _notifdex_cleanup_targets (id) SELECT id FROM observations")
                preserved = 0
            }

            let removed = try scalar("SELECT count(*) FROM _notifdex_cleanup_targets")
            if removed > 0 {
                // Explicitly delete observation-scoped child rows for FK safety (PRAGMA foreign_keys = ON).
                let childTables = [
                    "person_observations",
                    "observation_work",
                    "hidden_observations",
                    "read_observations",
                    "flagged_observations",
                    "person_match_exclusions",
                    "observation_workspaces",
                    "sync_observation_links"
                ]
                for table in childTables {
                    try execute("DELETE FROM \(table) WHERE observation_id IN (SELECT id FROM _notifdex_cleanup_targets)")
                }
                try execute("DELETE FROM observations WHERE id IN (SELECT id FROM _notifdex_cleanup_targets)")
                // Remove ended capture runs that no longer own any observations or coverage gaps.
                try execute("""
                    DELETE FROM capture_runs
                    WHERE ended_at IS NOT NULL
                      AND NOT EXISTS (SELECT 1 FROM observations o WHERE o.run_id = capture_runs.id)
                      AND NOT EXISTS (SELECT 1 FROM coverage_gaps g WHERE g.run_id = capture_runs.id)
                    """)
            }

            if removed > 0 || period.isClearAll {
                try setLocalPrunedBeforeTimestamp(cutoff ?? now)
            }
            try execute("DROP TABLE IF EXISTS _notifdex_cleanup_targets")
            return (removed, preserved)
        }

        let (vacuumed, integrityOK) = runMaintenanceAndIntegrityCheck()
        let afterReport = try storageUsageReport(
            databaseURL: databaseURL,
            auxiliaryDatabaseURLs: auxiliaryDatabaseURLs,
            mediaFileURLs: mediaFileURLs,
            at: now
        )
        let reclaimed = max(0, beforeReport.totalBytes - afterReport.totalBytes)

        return StorageCleanupResult(
            period: period,
            removedObservations: removedCount,
            preservedObservations: preservedCount,
            bytesBefore: beforeReport.totalBytes,
            bytesAfter: afterReport.totalBytes,
            reclaimedBytes: reclaimed,
            vacuumPerformed: vacuumed,
            integrityOK: integrityOK,
            completedAt: now
        )
    }

    /// Reclaims existing SQLite freelist and WAL space via checkpoint + VACUUM without deleting any alerts.
    @discardableResult
    func compactDatabase(
        databaseURL: URL,
        auxiliaryDatabaseURLs: [URL] = [],
        mediaFileURLs: [URL] = [],
        at now: Double = Date().timeIntervalSince1970
    ) throws -> StorageCleanupResult {
        let beforeReport = try storageUsageReport(
            databaseURL: databaseURL,
            auxiliaryDatabaseURLs: auxiliaryDatabaseURLs,
            mediaFileURLs: mediaFileURLs,
            at: now
        )
        let (vacuumed, integrityOK) = runMaintenanceAndIntegrityCheck()
        let afterReport = try storageUsageReport(
            databaseURL: databaseURL,
            auxiliaryDatabaseURLs: auxiliaryDatabaseURLs,
            mediaFileURLs: mediaFileURLs,
            at: now
        )
        return StorageCleanupResult(
            period: .olderThan30Days,
            removedObservations: 0,
            preservedObservations: afterReport.observationCount,
            bytesBefore: beforeReport.totalBytes,
            bytesAfter: afterReport.totalBytes,
            reclaimedBytes: max(0, beforeReport.totalBytes - afterReport.totalBytes),
            vacuumPerformed: vacuumed,
            integrityOK: integrityOK,
            completedAt: now
        )
    }

    private func runMaintenanceAndIntegrityCheck() -> (vacuumPerformed: Bool, integrityOK: Bool) {
        // 1. Flush WAL into main DB file before VACUUM.
        _ = try? readRows("PRAGMA wal_checkpoint(TRUNCATE)") { _ in 0 }

        // 2. Run VACUUM outside any transaction to rebuild compact pages.
        var vacuumed = false
        do {
            try execute("VACUUM")
            vacuumed = true
        } catch {
            // If another connection briefly holds a lock, committed deletes remain safe and intact.
            vacuumed = false
        }

        // 3. Truncate the WAL generated by VACUUM so disk space actually shrinks immediately.
        _ = try? readRows("PRAGMA wal_checkpoint(TRUNCATE)") { _ in 0 }

        // 4. Verify database structural integrity.
        let checkRows = (try? readRows("PRAGMA quick_check") { columnString($0, 0) }) ?? []
        let integrityOK = checkRows == ["ok"]
        return (vacuumed, integrityOK)
    }
}
