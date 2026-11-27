import NotifdexCore
import SwiftUI

struct TodayView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.followUps.isEmpty {
                    ContentUnavailableView(
                        "No Open Follow-ups",
                        systemImage: "checkmark.circle",
                        description: Text("Open any alert in Inbox and schedule a follow-up to track it here.")
                    )
                } else {
                    List {
                        ForEach(viewModel.followUps) { entry in
                            HStack(alignment: .top, spacing: 12) {
                                Button {
                                    viewModel.completeFollowUp(entry)
                                } label: {
                                    Image(systemName: "circle")
                                        .font(.title3)
                                        .foregroundStyle(NotifdexTheme.prussian)
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(entry.app)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(NotifdexTheme.color(for: entry.app))
                                        if !entry.personName.isEmpty {
                                            Text("· \(entry.personName)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if let dueAt = entry.dueAt {
                                            Text(Date(timeIntervalSince1970: dueAt).formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(dueAt < Date().timeIntervalSince1970 ? NotifdexTheme.vermilion : NotifdexTheme.sienna)
                                        }
                                    }

                                    Text(entry.title.isEmpty ? entry.app : entry.title)
                                        .font(.subheadline.weight(.semibold))
                                    Text(entry.body)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 4)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    viewModel.completeFollowUp(entry)
                                } label: {
                                    Label("Done", systemImage: "checkmark")
                                }
                                .tint(NotifdexTheme.celadon)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { viewModel.reload() }
                }
            }
            .navigationTitle("Today")
        }
    }
}
