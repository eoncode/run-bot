// RepoSelectorSheet.swift
// RunnerBar
import RunnerBarCore
import SwiftUI

// MARK: - RepoSelectorSheet
/// Sheet for selecting a repository before triggering a workflow dispatch.
struct RepoSelectorSheet: View {
    @ObservedObject var store: RunnerViewModel
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            sheetContent
        }
        .glassCard()
        .frame(width: 360, height: 440)
    }

    // MARK: - Header
    private var sheetHeader: some View {
        HStack {
            Text("Select Repository")
                .font(.headline)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassSection()
    }

    // MARK: - Content
    private var sheetContent: some View {
        VStack(spacing: 0) {
            SearchField(text: $searchText, placeholder: "Filter repositories\u2026")
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            List(filteredRepos, id: \.self, selection: .constant(nil as String?)) { repo in
                Button(action: {
                    onSelect(repo)
                    dismiss()
                }) {
                    HStack {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(repo)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .background(Color.clear)
        }
    }

    private var filteredRepos: [String] {
        let repos = store.knownRepos
        return searchText.isEmpty ? repos : repos.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }
}
