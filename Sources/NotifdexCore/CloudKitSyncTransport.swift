import Foundation

#if canImport(CloudKit)
import CloudKit
#if os(macOS)
import Security
#endif

/// Opt-in Apple CloudKit Private Database sync transport (`iCloud.com.notifdex.shared`).
/// Guards missing entitlements cleanly at runtime so unentitled/ad-hoc builds return a
/// descriptive `StoreError` instead of crashing inside `CKContainer`.
public final class CloudKitSyncTransport: SyncTransport, @unchecked Sendable {
    public static let defaultContainerIdentifier = "iCloud.com.notifdex.shared"
    public static let zoneName = "NotifdexSyncZone"
    public static let recordType = "NotifdexSyncBatch"
    public static let databaseSubscriptionID = "notifdex-private-db-changes"

    /// Identifies whether an incoming APNs remote notification payload belongs to Notifdex's
    /// private CloudKit sync subscription so macOS/iOS app delegates can trigger an immediate pull.
    public static func isSyncRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        if let ckNotification = CKNotification(fromRemoteNotificationDictionary: userInfo) {
            if ckNotification.subscriptionID == Self.databaseSubscriptionID {
                return true
            }
            if ckNotification.notificationType == .database || ckNotification.notificationType == .recordZone {
                return true
            }
        }
        // Fallback inspection for synthetic test payloads containing the CloudKit `"ck"` dictionary.
        if let ck = userInfo["ck"] as? [AnyHashable: Any] {
            if let qry = ck["qry"] as? [AnyHashable: Any],
               let sid = qry["sid"] as? String,
               sid == Self.databaseSubscriptionID {
                return true
            }
            if let met = ck["met"] as? [AnyHashable: Any],
               let sid = met["sid"] as? String,
               sid == Self.databaseSubscriptionID {
                return true
            }
            if ck["fet"] != nil {
                return true
            }
        }
        return false
    }

    public let containerIdentifier: String
    private let zoneID: CKRecordZone.ID

    public init(containerIdentifier: String = CloudKitSyncTransport.defaultContainerIdentifier) {
        self.containerIdentifier = containerIdentifier
        self.zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// Checks whether the running binary carries the CloudKit entitlement for `containerIdentifier`.
    public func hasCloudKitEntitlement() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let appID = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.application-identifier" as CFString,
            nil
        ) as? String
        guard let appID, !appID.isEmpty else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-container-identifiers" as CFString,
            nil
        )
        if let containers = value as? [String] {
            return containers.contains(containerIdentifier)
        }
        return false
        #elseif os(iOS)
        // On physical iOS devices, embedded.mobileprovision declares the authorized iCloud containers.
        if let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: profileURL),
           let ascii = String(data: data, encoding: .isoLatin1) {
            return ascii.contains(containerIdentifier)
        }
        // On iOS Simulator, fall back to whether an iCloud ubiquity token is present.
        return FileManager.default.ubiquityIdentityToken != nil
        #else
        return false
        #endif
    }

    public func checkAccountAvailable() async throws -> Bool {
        try requireEntitlement()
        let container = CKContainer(identifier: containerIdentifier)
        let status = try await container.accountStatus()
        return status == .available
    }

    /// Registers an idempotent silent-push subscription on the private CloudKit database
    /// so paired devices can be nudged when remote changes arrive.
    public func ensureDatabaseSubscription() async throws {
        try requireEntitlement()
        let container = CKContainer(identifier: containerIdentifier)
        let status = try await container.accountStatus()
        guard status == .available else { return }

        let database = container.privateCloudDatabase
        try await ensureZoneExists(in: database)

        let subscription = CKDatabaseSubscription(subscriptionID: Self.databaseSubscriptionID)
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
    }

    public func push(_ batch: SyncBatch) async throws {
        try requireEntitlement()
        let container = CKContainer(identifier: containerIdentifier)
        let status = try await container.accountStatus()
        guard status == .available else {
            throw StoreError(description: "Sign in to iCloud in Settings to enable Notifdex CloudKit sync.")
        }

        let database = container.privateCloudDatabase
        try await ensureZoneExists(in: database)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rawPayload = try encoder.encode(batch)
        let payloadData = Self.encodePayloadForCloudKit(rawPayload)

        // One deterministic snapshot record per paired device prevents unbounded CloudKit record buildup.
        let recordID = CKRecord.ID(
            recordName: "device-snapshot-\(batch.senderDeviceID)",
            zoneID: zoneID
        )
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["schemaVersion"] = NSNumber(value: batch.schemaVersion)
        record["senderDeviceID"] = batch.senderDeviceID as CKRecordValue
        record["exportedAt"] = NSNumber(value: batch.exportedAt)
        record["payloadJSON"] = payloadData as CKRecordValue

        let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        if case .failure(let saveError) = result.saveResults[recordID] {
            throw saveError
        }
    }

    private static let compressedMagic = Data("NFZ1".utf8)

    internal static func encodePayloadForCloudKit(_ rawJSON: Data) -> Data {
        // Compress snapshots approaching CloudKit's 1 MB CKRecord limit while keeping smaller batches plain JSON.
        guard rawJSON.count >= 850_000,
              let compressed = try? (rawJSON as NSData).compressed(using: .zlib) as Data,
              compressed.count + compressedMagic.count < rawJSON.count else {
            return rawJSON
        }
        var out = Data(capacity: compressedMagic.count + compressed.count)
        out.append(compressedMagic)
        out.append(compressed)
        return out
    }

    internal static func decodePayloadFromCloudKit(_ data: Data) throws -> Data {
        if data.starts(with: compressedMagic) {
            let body = data.dropFirst(compressedMagic.count)
            return try (Data(body) as NSData).decompressed(using: .zlib) as Data
        }
        return data
    }

    public func pull(since token: Data?) async throws -> SyncPullResult {
        try requireEntitlement()
        let container = CKContainer(identifier: containerIdentifier)
        let status = try await container.accountStatus()
        guard status == .available else {
            throw StoreError(description: "Sign in to iCloud in Settings to enable Notifdex CloudKit sync.")
        }

        let database = container.privateCloudDatabase
        try await ensureZoneExists(in: database)

        let previousToken: CKServerChangeToken?
        if let token {
            previousToken = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: token)
        } else {
            previousToken = nil
        }

        do {
            return try await fetchZoneChanges(in: database, since: previousToken)
        } catch let ckError as CKError where ckError.code == .changeTokenExpired {
            // Reset expired token cleanly and perform a full zone pull.
            return try await fetchZoneChanges(in: database, since: nil)
        }
    }

    private func fetchZoneChanges(in database: CKDatabase, since previousToken: CKServerChangeToken?) async throws -> SyncPullResult {
        var batches: [SyncBatch] = []
        let decoder = JSONDecoder()
        var cursor = previousToken
        var decodeError: Error?

        while true {
            let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: cursor)
            for modification in changes.modificationResultsByID.values {
                if case .success(let entry) = modification,
                   let rawData = entry.record["payloadJSON"] as? Data {
                    do {
                        let jsonData = try Self.decodePayloadFromCloudKit(rawData)
                        let decoded = try decoder.decode(SyncBatch.self, from: jsonData)
                        batches.append(decoded)
                    } catch {
                        decodeError = error
                    }
                }
            }
            cursor = changes.changeToken
            if !changes.moreComing {
                break
            }
        }

        if batches.isEmpty, let decodeError {
            throw StoreError(description: "Failed to decode remote sync snapshot: \(decodeError.localizedDescription)")
        }

        batches.sort { $0.exportedAt < $1.exportedAt }
        let archivedToken = cursor.flatMap {
            try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
        }
        return SyncPullResult(batches: batches, nextToken: archivedToken)
    }

    private func requireEntitlement() throws {
        guard hasCloudKitEntitlement() else {
            throw StoreError(
                description: "This build does not carry the iCloud CloudKit entitlement (\(containerIdentifier)). Sign with a CloudKit provisioning profile for Team HNH4DY9A2T to enable live iCloud sync."
            )
        }
    }

    private func ensureZoneExists(in database: CKDatabase) async throws {
        do {
            _ = try await database.recordZone(for: zoneID)
        } catch {
            let zone = CKRecordZone(zoneID: zoneID)
            _ = try await database.save(zone)
        }
    }
}
#endif
