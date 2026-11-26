import AppIntents
import Foundation

public struct CaptureNotificationIntent: AppIntent {
    public static let title: LocalizedStringResource = "Capture Notification"
    public static let description = IntentDescription(
        "Saves an incoming iOS notification (App, Title, Subtitle, Body) into Notifdex.",
        categoryName: "Capture"
    )
    public static let supportedModes: IntentModes = .background
    public static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "App", description: "The source app name from the Notification trigger.")
    public var app: String

    @Parameter(title: "Title", description: "Optional notification title.")
    public var title: String?

    @Parameter(title: "Subtitle", description: "Optional notification subtitle.")
    public var subtitle: String?

    @Parameter(title: "Body", description: "Optional notification body text.")
    public var body: String?

    public static var parameterSummary: some ParameterSummary {
        Summary("Capture \(\.$app) alert · Title \(\.$title) · Subtitle \(\.$subtitle) · Body \(\.$body)")
    }

    public init() {}

    public init(app: String, title: String? = nil, subtitle: String? = nil, body: String? = nil) {
        self.app = app
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = try Self.execute(
            app: app,
            title: title,
            subtitle: subtitle,
            body: body,
            service: .shared
        )
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }

    public static func execute(
        app: String,
        title: String?,
        subtitle: String?,
        body: String?,
        receivedAt: Date = Date(),
        service: CaptureService
    ) throws -> String {
        let payload = IncomingNotificationPayload(
            app: app,
            title: title,
            subtitle: subtitle,
            body: body,
            receivedAt: receivedAt,
            channel: .iosShortcuts,
            sourceMetadata: ["intent": "CaptureNotificationIntent"]
        )
        let outcome = try service.ingest(payload)
        return outcome.summaryMessage
    }
}

public struct NotifdexAppShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureNotificationIntent(),
            phrases: [
                "Capture a notification in \(.applicationName)",
                "Log a notification with \(.applicationName)"
            ],
            shortTitle: "Capture Notification",
            systemImageName: "tray.and.arrow.down.fill"
        )
    }
}
