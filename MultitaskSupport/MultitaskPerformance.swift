import SwiftUI
import Combine

@available(iOS 16.0, *)
@MainActor
@objc final class MultitaskPerformanceManager: NSObject, ObservableObject {
    @objc static let shared = MultitaskPerformanceManager()
    let monitor = LCPerformanceMonitor.shared
    @Published private(set) var revision = 0
    private var subscription: AnyCancellable?
    private weak var panelController: UIViewController?

    private override init() {
        super.init()
        subscription = NotificationCenter.default.publisher(for: .LCPerformanceDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.revision &+= 1 }
    }

    var snapshot: [String: Any] { monitor.snapshot }
    var sync: [String: Any] { snapshot["sync"] as? [String: Any] ?? [:] }
    var processes: [PerformanceProcessSnapshot] {
        (snapshot["processes"] as? [[String: Any]] ?? []).map(PerformanceProcessSnapshot.init)
    }
    var thermalKey: String {
        guard let state = snapshot["thermalState"] as? Int, (0...3).contains(state) else { return "lc.performance.waiting" }
        return ["lc.performance.thermal.nominal", "lc.performance.thermal.fair", "lc.performance.thermal.serious", "lc.performance.thermal.critical"][state]
    }

    func setEnabled(_ enabled: Bool) {
        monitor.hostView = MultitaskDockManager.shared.windowHostingView
        monitor.isEnabled = enabled
    }

    @objc func presentPanel() {
        guard panelController == nil else { return }
        let host = MultitaskDockManager.shared.windowHostingView
        monitor.hostView = host
        guard let window = host.window ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first,
              var presenter = window.rootViewController else { return }
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        let controller = UIHostingController(rootView: MultitaskPerformancePanel())
        controller.modalPresentationStyle = .pageSheet
        controller.sheetPresentationController?.prefersGrabberVisible = true
        panelController = controller
        presenter.present(controller, animated: true)
    }

    func startMeasurement() {
        if monitor.isEnabled { monitor.resetMeasurements() }
        else { setEnabled(true) }
        if !MultitaskTapSyncManager.shared.dismissForMeasurement() { panelController?.dismiss(animated: true) }
    }
}

struct PerformanceProcessSnapshot: Identifiable {
    let id: Int
    let window: Int
    let role: String
    let cpu: Double?
    let memory: Double?
    init(_ value: [String: Any]) {
        id = value["number"] as? Int ?? 0
        window = value["window"] as? Int ?? 0
        role = value["role"] as? String ?? "other"
        cpu = value["cpu"] as? Double
        memory = value["memoryMiB"] as? Double
    }
    var title: String {
        if role == "host" { return "LiveContainer" }
        return (window > 0 ? "lc.performance.window" : "lc.performance.process").localizeWithFormat(window > 0 ? window : id)
    }
}

@available(iOS 16.0, *)
struct MultitaskPerformanceActions: View {
    @ObservedObject private var manager = MultitaskPerformanceManager.shared

    var body: some View {
        Toggle("lc.performance.showOverlay".loc, isOn: Binding(get: { manager.monitor.isEnabled }, set: { manager.setEnabled($0) }))
        Button { manager.presentPanel() } label: {
            Label("lc.performance.title".loc, systemImage: "gauge.with.dots.needle.33percent")
        }
    }
}

@available(iOS 16.0, *)
private struct MultitaskPerformancePanel: View {
    @ObservedObject private var manager = MultitaskPerformanceManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var exportURL: URL?
    @State private var exportDirectory: URL?
    @State private var showingExport = false
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("lc.performance.showOverlay".loc, isOn: Binding(get: { manager.monitor.isEnabled }, set: { manager.setEnabled($0) }))
                    Text((manager.monitor.isSampling ? "lc.performance.sampling" : manager.monitor.isEnabled ? "lc.performance.suspended" : "lc.performance.stopped").loc)
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { manager.startMeasurement() } label: {
                        Label("lc.performance.startMeasurement".loc, systemImage: "arrow.counterclockwise")
                    }
                } footer: {
                    Text("lc.performance.monitorHelp".loc)
                }
                Section {
                    metric("lc.performance.totalCPU", value: formatted(manager.snapshot["totalCPU"], unit: "%"))
                    metric("lc.performance.totalMemory", value: formatted(manager.snapshot["totalMemoryMiB"], unit: " MiB"))
                    metric("lc.performance.thermal", value: manager.thermalKey.loc)
                    if manager.snapshot["lowPowerMode"] as? Bool == true {
                        Label("lc.performance.lowPower".loc, systemImage: "battery.25percent").foregroundStyle(.secondary)
                    }
                    Text("lc.performance.coverage".localizeWithFormat(integer("cpuCoverage"), integer("memoryCoverage"), integer("processCount")))
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("lc.performance.current".loc)
                } footer: {
                    Text("lc.performance.scope".loc)
                }
                if !manager.processes.isEmpty {
                    Section {
                        ForEach(manager.processes) { process in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(process.title)
                                    Spacer()
                                    Text(formatted(process.cpu, unit: "%"))
                                }
                                HStack {
                                    if process.role == "source" || process.role == "follower" {
                                        Text((process.role == "source" ? "lc.tapSync.source" : "lc.tapSync.follower").loc)
                                    }
                                    Spacer()
                                    Text(formatted(process.memory, unit: " MiB"))
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            .monospacedDigit()
                        }
                    } header: {
                        Text("lc.performance.processes".loc)
                    }
                }
                Section {
                    Text("lc.performance.segmentSummary".localizeWithFormat(integer("segment"), manager.snapshot["segmentElapsed"] as? Double ?? 0))
                        .font(.footnote).foregroundStyle(.secondary)
                    metric("lc.performance.averageCPU", value: formatted(manager.snapshot["averageCPU"], unit: "%"))
                    metric("lc.performance.peakCPU", value: formatted(manager.snapshot["peakCPU"], unit: "%"))
                    metric("lc.performance.peakMemory", value: formatted(manager.snapshot["peakMemoryMiB"], unit: " MiB"))
                    Text("lc.performance.validSamples".localizeWithFormat(integer("cpuSamples"), manager.snapshot["measuredSeconds"] as? Double ?? 0))
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("lc.performance.sinceReset".loc)
                } footer: {
                    Text("lc.performance.segmentHelp".loc)
                }
                Section {
                    metric("lc.performance.responseMedian", value: formatted(manager.sync["responseP50Ms"], unit: " ms"))
                    metric("lc.performance.responseP95", value: formatted(manager.sync["responseP95Ms"], unit: " ms"))
                    metric("lc.performance.queue", value: "\(manager.sync["pending"] as? Int ?? 0) / 4")
                    metric("lc.performance.queuePeak", value: String(manager.sync["queuePeak"] as? Int ?? 0))
                    metric("lc.performance.coalesced", value: String(manager.sync["coalesced"] as? Int ?? 0))
                    Text("lc.performance.responseSamples".localizeWithFormat(manager.sync["responseSamples"] as? Int ?? 0))
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("lc.performance.sync".loc)
                } footer: {
                    Text("lc.performance.responseHelp".loc)
                }
                Section {
                    Button(action: exportReport) {
                        Label("lc.performance.export".loc, systemImage: "square.and.arrow.up")
                    }
                    .disabled(manager.monitor.reportSampleCount == 0)
                    Text("lc.performance.retainedSamples".localizeWithFormat(manager.monitor.reportSampleCount))
                        .font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup("lc.performance.testGuide".loc) {
                        Text("lc.performance.testProcedure".loc).font(.footnote)
                    }
                } footer: {
                    Text("lc.performance.exportHelp".loc)
                }
            }
            .navigationTitle("lc.performance.title".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("lc.common.done".loc) { dismiss() } }
            }
            .sheet(isPresented: $showingExport, onDismiss: removeExportFile) {
                if let exportURL {
                    ActivityViewController(activityItems: [exportURL])
                }
            }
            .alert("lc.performance.exportFailed".loc, isPresented: Binding(
                get: { exportError != nil }, set: { if !$0 { exportError = nil } }
            )) {
                Button("lc.common.ok".loc, role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
        }
    }

    private func exportReport() {
        guard manager.monitor.reportSampleCount > 0 else { return }
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("LCPerformance-\(UUID().uuidString)", isDirectory: true)
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let url = directory.appendingPathComponent("LiveContainer-performance-\(formatter.string(from: Date())).csv")
            // Snapshot only when requested. The shared file stays fixed while live sampling continues.
            try manager.monitor.csvReport.write(to: url, atomically: true, encoding: .utf8)
            exportDirectory = directory
            exportURL = url
            showingExport = true
        } catch {
            try? files.removeItem(at: directory)
            exportError = error.localizedDescription
        }
    }

    private func removeExportFile() {
        // This directory is created solely for this share sheet; never touch other temporary files.
        if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }
        exportURL = nil
        exportDirectory = nil
    }

    private func integer(_ key: String) -> Int { manager.snapshot[key] as? Int ?? 0 }
    private func formatted(_ value: Any?, unit: String) -> String {
        guard let value = value as? Double, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0...1))) + unit
    }
    private func metric(_ key: String, value: String) -> some View {
        HStack {
            Text(key.loc)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
