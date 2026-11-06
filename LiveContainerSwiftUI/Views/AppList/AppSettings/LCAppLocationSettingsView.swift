import SwiftUI
import MapKit

private struct LCSavedLocationPoint {
    let settings: [AnyHashable: Any]
    var name: String { settings["name"] as? String ?? "" }
    var text: String { String(format: "%.6f, %.6f", locale: Locale(identifier: "en_US_POSIX"), settings["latitude"] as? Double ?? 0, settings["longitude"] as? Double ?? 0) }
    init?(_ value: [AnyHashable: Any]) {
        guard !LCAppLocationSettings(value).isEmpty else { return nil }; settings = value
    }
    func settings(enabled: Bool) -> [AnyHashable: Any] { var value = settings; value["enabled"] = enabled; return value }
}

struct LCAppLocationSettingsView: View {
    @ObservedObject var model: LCAppModel
    @State private var editing = false
    @State private var enableAfterSelection = false
    @State private var requestedEnabled: Bool
    @State private var quickControl = false
    @State private var error: String?

    init(model: LCAppModel) {
        self.model = model
        _requestedEnabled = State(initialValue: model.uiCustomLocation["enabled"] as? Bool == true)
    }

    private var point: LCSavedLocationPoint? { LCSavedLocationPoint(model.uiCustomLocation) }
    private var enabled: Bool { model.uiCustomLocation["enabled"] as? Bool == true }
    private var unavailable: Bool { model.uiDontInjectTweakLoader || model.uiIs32bit }
    private var session: LCLocationSession { LCLocationSession.session(path: model.appInfo.bundlePath(), title: model.appInfo.displayName()) }

    private func save(_ value: [AnyHashable: Any]) {
        let session = session
        _ = session.select(point: value, enabled: value["enabled"] as? Bool == true)
        model.uiCustomLocation = session.settings
        requestedEnabled = enabled
        error = session.error
    }

    var body: some View {
        Form {
            Section {
                Toggle("lc.location.enable".loc, isOn: $requestedEnabled)
                .onChange(of: requestedEnabled) { value in
                    guard value != enabled else { return }
                    if let point { save(point.settings(enabled: value)) }
                    else if value { enableAfterSelection = true; editing = true }
                }
                .disabled(unavailable)
                .accessibilityIdentifier("location.enabled")
            } footer: {
                Text((unavailable ? "lc.location.unavailable" : "lc.location.scope").loc)
            }
            Section {
                if let point {
                    if !point.name.isEmpty { Text(point.name) }
                    Text(point.text).monospacedDigit().textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                Button {
                    enableAfterSelection = false
                    editing = true
                } label: {
                    Label((point == nil ? "lc.location.choose" : "lc.location.change").loc, systemImage: "map")
                }
                .disabled(unavailable)
                .accessibilityIdentifier("location.choose")
            } header: {
                Text("lc.location.saved".loc)
            } footer: {
                Text("lc.location.restart".loc)
            }
            Section {
                Toggle("lc.location.quickControl".loc, isOn: $quickControl)
                    .disabled(unavailable)
                    .onChange(of: quickControl) { value in
                        let info = NSDictionary(contentsOfFile: model.appInfo.bundlePath() + "/LCAppInfo.plist")
                        let saved = info?["LCLocationQuickControl"] as? Bool == true
                        if value != saved, !session.setQuickControl(value) { quickControl = saved; error = session.error }
                    }
                Button {
                    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else { return }
                    LCLocationUI.showControls(for: LCLocationSession.session(path: model.appInfo.bundlePath(), title: model.appInfo.displayName()), in: scene)
                } label: { Label("lc.location.openControls".loc, systemImage: "location.circle") }
                .disabled(unavailable).accessibilityIdentifier("location.openControls")
            } footer: { Text("lc.location.quickControlHelp".loc) }
            if let error { Section { Text(error.loc).foregroundStyle(.red) } }
            Section { Text("lc.location.coverage".loc).foregroundStyle(.secondary) }
        }
        .navigationTitle("lc.location.title".loc)
        .onAppear {
            model.uiCustomLocation = model.appInfo.customLocation
            requestedEnabled = enabled
            let info = NSDictionary(contentsOfFile: model.appInfo.bundlePath() + "/LCAppInfo.plist")
            quickControl = info?["LCLocationQuickControl"] as? Bool == true
        }
        .onReceive(NotificationCenter.default.publisher(for: .LCLocationSessionDidChange)) { notification in
            if let changed = notification.object as? LCLocationSession, changed === session {
                error = changed.error
                if !NSDictionary(dictionary: model.uiCustomLocation).isEqual(to: changed.settings) {
                    model.uiCustomLocation = changed.settings; requestedEnabled = enabled
                }
            }
        }
        .sheet(isPresented: $editing, onDismiss: { requestedEnabled = enabled }) {
            LCLocationPickerHost(initial: model.uiCustomLocation) { value in
                var value = value; value["enabled"] = enabled || enableAfterSelection
                save(value)
            }
        }
    }
}


private struct LCLocationPickerHost: UIViewControllerRepresentable {
    let initial: [AnyHashable: Any]
    let save: ([AnyHashable: Any]) -> Void
    func makeUIViewController(context: Context) -> UIViewController { LCLocationUI.picker(withInitial: initial, completion: save) }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
