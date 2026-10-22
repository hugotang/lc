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
    @State private var progressObservation: NSKeyValueObservation?
    @State private var isApplying = false
    @State private var operation: Task<Void, Never>?
    @State private var errorInfo: String?

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
                    valueRow("lc.resourceCompaction.sharedSize", byteSize(result.sharedBytes))
                    if result.stoppedError == nil {
                        Text("lc.resourceCompaction.finished".loc)
                    }
                }
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
        progressObservation = next.observe(\.fractionCompleted, options: [.new]) { value, _ in
            Task { @MainActor in
                if progress === next { progressFraction = value.fractionCompleted }
            }
        }
        return next
    }

    private func finishProgress() {
        progressObservation = nil
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
                    if let stoppedError = applied.stoppedError { errorInfo = localizedError(stoppedError) }
                }
            } catch {
                if !Task.isCancelled { errorInfo = localizedError(error) }
            }
            finishProgress()
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
        default: key = "lc.resourceCompaction.failed"
        }
        return key.loc
    }
}
