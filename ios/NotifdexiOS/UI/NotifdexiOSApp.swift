import NotifdexCore
import SwiftUI
import UIKit

final class NotifdexiOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        #if canImport(CloudKit)
        if CloudKitSyncTransport().hasCloudKitEntitlement() {
            application.registerForRemoteNotifications()
        }
        #endif
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        #if canImport(CloudKit)
        guard CloudKitSyncTransport.isSyncRemoteNotification(userInfo) else {
            completionHandler(.noData)
            return
        }
        Task.detached(priority: .utility) {
            let service = CaptureService.shared
            do {
                let paired = try service.isSyncPaired()
                let autoEnabled = try service.isAutoSyncEnabled()
                guard paired && autoEnabled else {
                    await MainActor.run { completionHandler(.noData) }
                    return
                }
                let result = try await service.runSync(using: CloudKitSyncTransport())
                let outcome: UIBackgroundFetchResult = result.applied.hasChanges ? .newData : .noData
                await MainActor.run { completionHandler(outcome) }
            } catch {
                await MainActor.run { completionHandler(.failed) }
            }
        }
        #else
        completionHandler(.noData)
        #endif
    }
}

@main
struct NotifdexiOSApp: App {
    @UIApplicationDelegateAdaptor(NotifdexiOSAppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AppViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView(viewModel: viewModel)
                .onChange(of: scenePhase) { _, newPhase in
                    viewModel.handleScenePhase(newPhase)
                }
        }
    }
}
