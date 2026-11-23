#if os(macOS)
import SwiftUI

@MainActor
struct UserGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notifdex guide")
                        .font(.largeTitle.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Find notifications your Mac has shown, keep track of people, and follow up.")
                        .foregroundStyle(.secondary)
                }

                topic("Get started", steps: [
                    "Open the Notifdex menu-bar menu and choose App Center.",
                    "Grant Notifdex Accessibility access in System Settings → Privacy & Security → Accessibility.",
                    "In Apps, enable the notification sources you want to collect. For a custom app, enter the label as it appears in macOS.",
                    "Send yourself a test notification and check Inbox. Closing App Center leaves collection running in the menu bar."
                ])

                topic("How capture works", paragraphs: [
                    "Notifdex reads notification previews that macOS makes available through Accessibility. This can include iPhone notifications forwarded to your Mac. Notifdex stores captured alerts and notes locally. Find the database through Appearance → Show data folder.",
                    "A scan can see the same banner more than once. Notifdex skips repeats of the same captured rendering and can keep a new revision when its visible content changes. The capture time is when Notifdex saw the alert. Redacted previews, missing alerts, and interruptions can leave gaps."
                ])

                topic("Inbox and follow-ups", steps: [
                    "Search captured alerts or filter by app and read status. Use Sort & group to arrange Inbox or Flagged. On a narrow window, use the View picker to switch destinations.",
                    "Open an alert to read its captured preview. Use Flag or Save for later to find it again. Hide individual alerts or matching alerts, then use Undo or manage rules from Hidden.",
                    "Set a due date and add a follow-up. In Today, you can reschedule, snooze, or mark a follow-up done. Open in app takes you to the source app or its inbox."
                ])

                topic("People and workspaces", paragraphs: [
                    "Link an alert to an existing person or create and link a new one. Open People to see that person's linked alerts, identities, and notes. After reading a linked alert, choose Back to person to return to their profile.",
                    "A person can belong to several workspaces. Person notes are shared across those workspaces. Assign an alert's workspace separately from the person's memberships. Use a relationship template if you want to track stages and milestones."
                ])

                topic("Notes", paragraphs: [
                    "My Notes is your personal notebook. Create folders to organize notes, or leave them in Unfiled. People Notes opens the same notes you see on person profiles, so saving an edit in either place updates the shared note."
                ])

                topic("Recovery and troubleshooting", paragraphs: [
                    "If Inbox is empty, check Accessibility access, the collection status, and whether the source is enabled in Apps. Confirm that macOS is showing a preview for that source.",
                    "In Recovery, use Recover now to scan alerts still visible in Notification Center. Check the recovery status for results and blockers. Cleared or unavailable alerts may remain missing after a scan. The collection status control shows recent scan details and lets you pause or resume."
                ])
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .notifdexSurface(.inboxList)
    }

    private func topic(_ title: String, paragraphs: [String] = [], steps: [String] = []) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            ForEach(paragraphs, id: \.self) { paragraph in
                Text(paragraph).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(steps.indices, id: \.self) { index in
                Text("\(index + 1). \(steps[index])")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
    }
}
#endif
