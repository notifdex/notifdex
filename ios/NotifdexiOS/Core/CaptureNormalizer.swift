import CryptoKit
import Foundation

/// Normalizes notification payloads from iOS 27 Shortcuts and computes deterministic dedup keys.
public enum CaptureNormalizer {
    public static let directionMarks = CharacterSet(charactersIn: "\u{061C}\u{200E}\u{200F}")
    /// Deduplication bucket in seconds so rapid duplicate triggers collapse while distinct later messages stay separate.
    public static let dedupBucketSeconds: Double = 60.0

    public static func normalizeAppLabel(_ raw: String) -> String {
        let trimSet = CharacterSet.whitespacesAndNewlines.union(directionMarks)
        let trimmed = raw.trimmingCharacters(in: trimSet)
        return trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func normalizeField(_ raw: String?) -> String {
        guard let raw else { return "" }
        let trimSet = CharacterSet.whitespacesAndNewlines.union(directionMarks)
        return raw.trimmingCharacters(in: trimSet)
    }

    public static func normalize(_ payload: IncomingNotificationPayload) -> NormalizedNotification? {
        let appLabel = normalizeAppLabel(payload.app)
        guard !appLabel.isEmpty else { return nil }

        let title = normalizeField(payload.title)
        let subtitle = normalizeField(payload.subtitle)
        let body = normalizeField(payload.body)
        let timestamp = payload.receivedAt.timeIntervalSince1970
        let safeTimestamp = timestamp.isFinite ? timestamp : Date().timeIntervalSince1970

        let dedupKey = makeDedupKey(
            appLabel: appLabel,
            title: title,
            subtitle: subtitle,
            body: body,
            capturedAt: safeTimestamp
        )

        let metadataJSON = encodeMetadata(payload.sourceMetadata)
        let origin: NotificationOrigin = .iphone

        return NormalizedNotification(
            appLabel: appLabel,
            title: title,
            subtitle: subtitle,
            body: body,
            dedupKey: dedupKey,
            capturedAt: safeTimestamp,
            channel: payload.channel,
            origin: origin,
            metadataJSON: metadataJSON
        )
    }

    public static func makeDedupKey(
        appLabel: String,
        title: String,
        subtitle: String,
        body: String,
        capturedAt: Double,
        bucketSeconds: Double = dedupBucketSeconds
    ) -> String {
        let safeBucketSeconds = bucketSeconds > 0 ? bucketSeconds : dedupBucketSeconds
        let bucket = Int64(floor(capturedAt / safeBucketSeconds))
        let canonical = [
            normalizeAppLabel(appLabel).lowercased(),
            normalizeField(title),
            normalizeField(subtitle),
            normalizeField(body),
            String(bucket)
        ].joined(separator: "\u{001F}")

        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func encodeMetadata(_ metadata: [String: String]) -> String {
        guard !metadata.isEmpty else { return "{}" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(metadata),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
