import SwiftUI

@MainActor
struct LCResourceCompactionView: View {
    @ObservedObject var app: LCAppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = Set<String>()
    @State private var plan: LCResourceCompactionPlan?
    @State private var result: LCResourceCompactionResult?
    @State private var progress: Progress?
    @State private var progressFraction = 0.0
    @State private var progressRefresh: Task<Void, Never>?
    @State private var isApplying = false
    @State private var operation: Task<Void, Never>?
    @State private var errorInfo: String?
    @State private var availableBytes: Int64?
    @State private var isRefreshingSpace = false

    private var containers: [LCContainer] {
        app.uiContainers.filter { $0.storageBookMark == nil }
    }

    var body: some View {
        Form {
            Section {
                ForEach(containers, id: \.folderName) { container in
                    Button {
                        if !selection.insert(container.folderName).inserted {
                            selection.remove(container.folderName)
                        }
                        plan = nil
                        result = nil
                        errorInfo = nil
                    } label: {
                        HStack {
                            Text(container.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selection.contains(container.folderName) {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .disabled(progress != nil)
                    .accessibilityAddTraits(selection.contains(container.folderName) ? .isSelected : [])
                }
            } header: {
                Text("lc.resourceCompaction.selectContainers".loc)
            } footer: {
                Text("lc.resourceCompaction.instructions".loc)
            }

            Section {
                if let progress {
                    ProgressView(value: progressFraction) {
                        Text((isApplying ? "lc.resourceCompaction.applying" : "lc.resourceCompaction.analyzing").loc)
                    }
                    Button("lc.common.cancel".loc) { progress.cancel() }
                } else {
                    Button("lc.resourceCompaction.analyze".loc) { analyze() }
                        .disabled(selection.count < 2)
                    if let plan {
                        valueRow("lc.resourceCompaction.matching", String(plan.matchingFileCount))
                        valueRow("lc.resourceCompaction.candidateSize", byteSize(plan.candidateBytes))
                        valueRow("lc.resourceCompaction.alreadyCompacted", String(plan.alreadyCompactedFileCount))
                        valueRow("lc.resourceCompaction.independent", String(plan.independentFileCount))
                        valueRow("lc.resourceCompaction.verifiedSharedFiles", String(plan.verifiedSharedFileCount))
                        valueRow("lc.resourceCompaction.verifiedSharedSize", byteSize(plan.verifiedSharedBytes))
                        if plan.sharingUnavailableFileCount > 0 {
                            valueRow("lc.resourceCompaction.sharingUnavailableFiles", String(plan.sharingUnavailableFileCount))
                            Text("lc.resourceCompaction.sharingUnavailableNote".loc)
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if plan.matchingFileCount > 0 {
                            Button("lc.resourceCompaction.apply".loc) { apply(plan) }
                        }
                    }
                }
            } footer: {
                Text("lc.resourceCompaction.estimateNote".loc)
            }

            if let result {
                Section {
                    valueRow("lc.resourceCompaction.compacted", String(result.compactedFileCount))
                    valueRow("lc.resourceCompaction.sharedSize", byteSize(result.processedBytes))
                    valueRow("lc.resourceCompaction.verifiedSharedFiles", String(result.verifiedSharedFileCount))
                    if result.sharingUnavailableFileCount > 0 {
                        valueRow("lc.resourceCompaction.sharingUnavailableFiles", String(result.sharingUnavailableFileCount))
                        Text("lc.resourceCompaction.sharingUnavailableNote".loc)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    valueRow("lc.resourceCompaction.completedAt", result.completedAt.formatted(date: .abbreviated, time: .shortened))
                    if let before = result.availableBytesBefore?.int64Value {
                        valueRow("lc.resourceCompaction.availableBefore", byteSize(before))
                    }
                    if let after = result.availableBytesAfter?.int64Value {
                        valueRow("lc.resourceCompaction.availableAfter", byteSize(after))
                    }
                    if let before = result.availableBytesBefore?.int64Value,
                       let after = result.availableBytesAfter?.int64Value {
                        valueRow("lc.resourceCompaction.availableChange", signedByteSize(after - before))
                    } else {
                        Text("lc.resourceCompaction.spaceUnavailable".loc)
                    }
                    if let stoppedError = result.stoppedError {
                        Text(localizedError(stoppedError)).foregroundStyle(.red)
                    } else {
                        Text("lc.resourceCompaction.finished".loc)
                    }
                } footer: {
                    Text("lc.resourceCompaction.spaceNote".loc)
                }
            }

            Section {
                if let availableBytes {
                    valueRow("lc.resourceCompaction.availableNow", byteSize(availableBytes))
                    if let before = result?.availableBytesBefore?.int64Value {
                        valueRow("lc.resourceCompaction.changeSinceBefore", signedByteSize(availableBytes - before))
                    }
                } else {
                    Text("lc.resourceCompaction.spaceUnavailable".loc).foregroundStyle(.secondary)
                }
                Button("lc.storage.refresh".loc) { Task { await refreshSpace() } }
                    .disabled(progress != nil || isRefreshingSpace)
            } footer: {
                Text("lc.storage.cloneSizeNote".loc)
            }

            if let errorInfo {
                Section {
                    Text(errorInfo).foregroundStyle(.red)
                }
            }

            Section {
                Text("lc.resourceCompaction.updates".loc)
            } header: {
                Text("lc.resourceCompaction.updateTitle".loc)
            }
        }
        .navigationTitle("lc.resourceCompaction.title".loc)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if selection.isEmpty { selection = Set(containers.map(\.folderName)) }
        }
        .task(id: selection) { await refreshSpace() }
        .onDisappear {
            progress?.cancel()
            operation?.cancel()
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { progress?.cancel() }
        }
    }

    private func valueRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key.loc)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func byteSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func signedByteSize(_ bytes: Int64) -> String {
        if bytes == 0 { return byteSize(0) }
        return (bytes > 0 ? "+" : "−") + byteSize(abs(bytes))
    }

    private func refreshSpace() async {
        guard progress == nil else { return }
        let selected = selection
        let urls = containers.filter { selected.contains($0.folderName) }.map(\.containerURL)
        guard !urls.isEmpty else { availableBytes = nil; return }
        isRefreshingSpace = true
        defer { isRefreshingSpace = false }
        let measurements = await Task.detached(priority: .utility) {
            (LCResourceCompactor.availableBytes(containers: urls), LCResourceCompactor.lastResult(containers: urls))
        }.value
        guard !Task.isCancelled, selection == selected, progress == nil else { return }
        availableBytes = measurements.0?.int64Value
        if result == nil { result = measurements.1 }
    }

    private func selectedContainersAreIdle() -> Bool {
        for container in containers where selection.contains(container.folderName) {
            if MultitaskManager.isUsing(container: container.folderName) ||
                LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) != nil {
                errorInfo = "lc.resourceCompaction.closeWindows".loc
                return false
            }
        }
        return true
    }

    private func startProgress(applying: Bool) -> Progress {
        errorInfo = nil
        result = nil
        isApplying = applying
        progressFraction = 0
        let next = Progress(totalUnitCount: 0)
        progress = next
        progressRefresh = Task {
            while !Task.isCancelled {
                progressFraction = next.fractionCompleted
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    break
                }
            }
        }
        return next
    }

    private func finishProgress() {
        progressRefresh?.cancel()
        progressRefresh = nil
        progress = nil
        operation = nil
    }

    private func analyze() {
        guard progress == nil, selectedContainersAreIdle() else { return }
        let urls = containers.filter { selection.contains($0.folderName) }.map(\.containerURL)
        let bundleIdentifier = app.appInfo.bundleIdentifier() ?? ""
        plan = nil
        let next = startProgress(applying: false)
        operation = Task {
            do {
                let scanned = try await Task.detached(priority: .utility) {
                    try LCResourceCompactor.scan(containers: urls, bundleIdentifier: bundleIdentifier, progress: next)
                }.value
                if !Task.isCancelled { plan = scanned }
            } catch {
                if !Task.isCancelled { errorInfo = localizedError(error) }
            }
            finishProgress()
            await refreshSpace()
        }
    }

    private func apply(_ currentPlan: LCResourceCompactionPlan) {
        guard progress == nil, selectedContainersAreIdle() else { return }
        plan = nil
        let next = startProgress(applying: true)
        operation = Task {
            do {
                let applied = try await Task.detached(priority: .utility) {
                    try LCResourceCompactor.apply(plan: currentPlan, progress: next)
                }.value
                if !Task.isCancelled {
                    result = applied
                    availableBytes = applied.availableBytesAfter?.int64Value
                }
            } catch {
                if !Task.isCancelled { errorInfo = localizedError(error) }
            }
            finishProgress()
            await refreshSpace()
        }
    }

    private func localizedError(_ error: Error) -> String {
        let code = (error as NSError).code
        guard (error as NSError).domain == LCResourceCompactionErrorDomain else { return error.localizedDescription }
        let key: String
        switch code {
        case 1: key = "lc.resourceCompaction.unsupportedApp"
        case 2: key = "lc.resourceCompaction.closeWindows"
        case 3: key = "lc.resourceCompaction.invalidContainer"
        case 4: key = "lc.resourceCompaction.changed"
        case 5: key = "lc.resourceCompaction.unsupportedVolume"
        case 6: key = "lc.resourceCompaction.cancelled"
        case 8: key = "lc.resourceCompaction.sharingNotRetained"
        default: key = "lc.resourceCompaction.failed"
        }
        return key.loc
    }
}
