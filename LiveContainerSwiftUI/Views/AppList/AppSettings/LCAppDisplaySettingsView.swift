import SwiftUI

private enum AppAspectRatioChoice: String, CaseIterable, Identifiable {
    case fill, portraitPhone, landscapePhone, portraitTablet, landscapeTablet, custom

    var id: Self { self }
    var title: String {
        switch self {
        case .fill: return "lc.appSettings.aspectRatio.fill".loc
        case .portraitPhone: return "9:16"
        case .landscapePhone: return "16:9"
        case .portraitTablet: return "3:4"
        case .landscapeTablet: return "4:3"
        case .custom: return "lc.appSettings.aspectRatio.custom".loc
        }
    }
    var size: CGSize? {
        switch self {
        case .fill: return .zero
        case .portraitPhone: return CGSize(width: 9, height: 16)
        case .landscapePhone: return CGSize(width: 16, height: 9)
        case .portraitTablet: return CGSize(width: 3, height: 4)
        case .landscapeTablet: return CGSize(width: 4, height: 3)
        case .custom: return nil
        }
    }
    static func matching(_ size: CGSize) -> Self {
        guard LCAppAspectRatioIsValid(size) else { return .fill }
        return allCases.first { choice in
            guard let preset = choice.size, preset.height > 0 else { return false }
            return abs(preset.width / preset.height - size.width / size.height) < 0.000001
        } ?? .custom
    }
}

@available(iOS 16.0, *)
struct LCAppDisplaySettingsView: View {
    @ObservedObject var model: LCAppModel
    @State private var editingCustomRatio = false

    private var ratioChoice: Binding<AppAspectRatioChoice> {
        Binding(get: { AppAspectRatioChoice.matching(model.uiWindowAspectRatio) }, set: { choice in
            if let size = choice.size { model.uiWindowAspectRatio = size }
            else { editingCustomRatio = true }
        })
    }

    var body: some View {
        Form {
            Section {
                Picker("lc.appSettings.interfaceMode".loc, selection: $model.uiInterfaceMode) {
                    Text("lc.common.auto".loc).tag(LCAppInterfaceMode.automatic)
                    Text("iPhone").tag(LCAppInterfaceMode.phone)
                    Text("iPad").tag(LCAppInterfaceMode.pad)
                }
                .disabled(model.uiDontInjectTweakLoader)
            } footer: {
                Text("lc.appSettings.interfaceMode.help".loc)
            }
            Section {
                Picker("lc.appSettings.aspectRatio".loc, selection: ratioChoice) {
                    ForEach(AppAspectRatioChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                if AppAspectRatioChoice.matching(model.uiWindowAspectRatio) == .custom {
                    Button {
                        editingCustomRatio = true
                    } label: {
                        HStack {
                            Text("lc.appSettings.aspectRatio.custom".loc)
                            Spacer()
                            Text("\(model.uiWindowAspectRatio.width.formatted()):\(model.uiWindowAspectRatio.height.formatted())")
                        }
                    }
                }
            } footer: {
                Text("lc.appSettings.aspectRatio.help".loc)
            }
            .disabled(model.uiDontInjectTweakLoader)
            Section {
                Text("lc.appSettings.displaySettings.help".loc)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("lc.appSettings.displaySettings".loc)
        .sheet(isPresented: $editingCustomRatio) {
            LCAppCustomAspectRatioView(initial: model.uiWindowAspectRatio) { ratio in
                model.uiWindowAspectRatio = ratio
            }
        }
    }
}

@available(iOS 16.0, *)
private struct LCAppCustomAspectRatioView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var width: String
    @State private var height: String
    let save: (CGSize) -> Void

    init(initial: CGSize, save: @escaping (CGSize) -> Void) {
        let value = LCAppAspectRatioIsValid(initial) ? initial : CGSize(width: 9, height: 16)
        _width = State(initialValue: String(Double(value.width)))
        _height = State(initialValue: String(Double(value.height)))
        self.save = save
    }

    private var ratio: CGSize? {
        // Accept decimal commas as well as decimal points, without accepting
        // a partially parsed value such as "9abc" or thousands separators.
        guard let w = Double(width.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              let h = Double(height.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) else { return nil }
        let size = CGSize(width: w, height: h)
        return LCAppAspectRatioIsValid(size) ? size : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("lc.appSettings.aspectRatio.width".loc) {
                        TextField("lc.appSettings.aspectRatio.width".loc, text: $width)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("lc.appSettings.aspectRatio.height".loc) {
                        TextField("lc.appSettings.aspectRatio.height".loc, text: $height)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    Text("lc.appSettings.aspectRatio.customHelp".loc)
                }
            }
            .navigationTitle("lc.appSettings.aspectRatio.custom".loc)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".loc) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("lc.common.done".loc) {
                        if let ratio { save(ratio); dismiss() }
                    }
                    .disabled(ratio == nil)
                }
            }
        }
    }
}
