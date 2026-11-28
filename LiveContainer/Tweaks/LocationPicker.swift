import SwiftUI
import MapKit

struct LCLocationPoint: Equatable {
    var latitude: Double
    var longitude: Double
    var name: String = ""
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var text: String { String(format: "%.6f, %.6f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude) }

    init(latitude: Double, longitude: Double, name: String = "") {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
    }

    init?(_ settings: [AnyHashable: Any]) {
        guard let lat = settings["latitude"] as? Double, let lon = settings["longitude"] as? Double,
              LCAppLocationCoordinateIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon)) else { return nil }
        self.init(latitude: lat, longitude: lon, name: settings["name"] as? String ?? "")
    }

    func settings(enabled: Bool) -> [AnyHashable: Any] {
        ["enabled": enabled, "latitude": latitude, "longitude": longitude, "name": name]
    }
}

private enum LCLocationMarkerRole: Equatable {
    case current, saved, pending

    var title: String {
        switch self {
        case .current: return "lc.location.current".lcLocationText
        case .saved: return "lc.location.saved".lcLocationText
        case .pending: return "lc.location.pending".lcLocationText
        }
    }

    var symbol: String {
        switch self {
        case .current: return "checkmark"
        case .saved: return "bookmark.fill"
        case .pending: return "pencil"
        }
    }

    var tint: UIColor { self == .pending ? .systemOrange : .systemBlue }
}

@MainActor
final class LCLocationSearch: ObservableObject {
    @Published var results: [MKMapItem] = []
    @Published var busy = false
    @Published var message: String?
    private var search: MKLocalSearch?
    private var revision = 0

    func cancel() {
        revision += 1
        search?.cancel()
        search = nil
        busy = false
        results = []
        message = nil
    }

    func find(_ query: String, near region: MKCoordinateRegion?) {
        cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let region { request.region = region }
        let operation = MKLocalSearch(request: request)
        search = operation
        busy = true
        let capturedRevision = revision
        operation.start { [weak self] response, error in
            Task { @MainActor in
                guard let self, self.revision == capturedRevision else { return }
                self.busy = false
                self.search = nil
                self.results = response?.mapItems ?? []
                self.message = error != nil ? "lc.location.searchFailed" :
                    (self.results.isEmpty ? "lc.location.noResults" : nil)
            }
        }
    }
}

struct LCLocationPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var search = LCLocationSearch()
    // Capture the app's custom point once, separately from every draft edit.
    @State private var baseline: LCLocationPoint?
    @State private var baselineRole: LCLocationMarkerRole
    @State private var point: LCLocationPoint?
    @State private var cameraPoint: LCLocationPoint?
    @State private var cameraRevision = 0
    @State private var centerSelection = 0
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var query = ""
    @State private var enteringCoordinates = false
    @FocusState private var searching: Bool
    let save: (LCLocationPoint) -> Void
    let close: (() -> Void)?

    init(initial: LCLocationPoint?, initialEnabled: Bool = false, close: (() -> Void)? = nil,
         save: @escaping (LCLocationPoint) -> Void) {
        _baseline = State(initialValue: initial)
        _baselineRole = State(initialValue: initialEnabled ? .current : .saved)
        _point = State(initialValue: initial)
        _cameraPoint = State(initialValue: initial)
        self.save = save
        self.close = close
    }

    private func select(_ newPoint: LCLocationPoint, moveCamera: Bool) {
        point = newPoint
        search.cancel()
        searching = false
        if moveCamera { cameraPoint = newPoint; cameraRevision += 1 }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("lc.location.searchPlaceholder".lcLocationText, text: $query)
                        .accessibilityIdentifier("location.search")
                        .submitLabel(.search).focused($searching)
                        .onSubmit { search.find(query, near: visibleRegion); searching = false }
                        .onChange(of: query) { _ in search.cancel() }
                    if search.busy { ProgressView() }
                    Button("lc.location.search".lcLocationText) {
                        search.find(query, near: visibleRegion)
                        searching = false
                    }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || search.busy)
                }
                .padding()
                if let message = search.message {
                    Text(message.lcLocationText).font(.callout).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 8)
                }
                if !search.results.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(search.results.enumerated()), id: \.offset) { _, item in
                                Button {
                                    let coordinate = item.placemark.coordinate
                                    select(LCLocationPoint(latitude: coordinate.latitude, longitude: coordinate.longitude,
                                                           name: item.name ?? ""), moveCamera: true)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name ?? "").foregroundStyle(.primary)
                                        Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).padding()
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
                ZStack {
                    LCLocationMap(baseline: baseline, baselineRole: baselineRole, point: point,
                                  cameraPoint: cameraPoint, cameraRevision: cameraRevision,
                                  centerSelection: centerSelection, regionChanged: { visibleRegion = $0 },
                                  selected: { select($0, moveCamera: false) })
                    Image(systemName: "plus").font(.title2.weight(.light))
                        .foregroundStyle(.primary).opacity(0.6)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                .frame(minHeight: 160)
                .overlay(alignment: .topTrailing) {
                    if let baseline {
                        Button {
                            cameraPoint = baseline
                            cameraRevision += 1
                            searching = false
                        } label: {
                            Label((baselineRole == .current ? "lc.location.returnCurrent" : "lc.location.returnSaved").lcLocationText,
                                  systemImage: "arrow.uturn.backward")
                                .labelStyle(.iconOnly)
                                .frame(minWidth: 44, minHeight: 44)
                                .background(.regularMaterial, in: Circle())
                        }
                        .accessibilityIdentifier("location.returnBaseline")
                        .padding(12)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    if let baseline {
                        pointSummary(baseline, role: baselineRole, roleID: "location.baselineRole",
                                     coordinateID: "location.baselineCoordinate")
                    }
                    if let point {
                        pointSummary(point, role: .pending, roleID: "location.pendingRole",
                                     coordinateID: "location.selectedCoordinate")
                    } else {
                        Text("lc.location.mapHint".lcLocationText).font(.callout).foregroundStyle(.secondary)
                    }
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading) { selectionButtons }
                    } else {
                        HStack { selectionButtons }
                    }
                    Button {
                        if let point { save(point); if let close { close() } else { dismiss() } }
                    } label: {
                        Text("lc.location.useLocation".lcLocationText).frame(maxWidth: .infinity).padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent).disabled(point == nil)
                    .accessibilityIdentifier("location.save")
                }
                .padding().background(.regularMaterial)
            }
            .navigationTitle("lc.location.choose".lcLocationText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".lcLocationText) { if let close { close() } else { dismiss() } }.accessibilityIdentifier("location.cancel")
                }
            }
            .sheet(isPresented: $enteringCoordinates) {
                LCLocationCoordinateEditor(initial: point) { select($0, moveCamera: true) }
            }
            .onDisappear { search.cancel() }
        }
        .navigationViewStyle(.stack)
    }

    private func pointSummary(_ point: LCLocationPoint, role: LCLocationMarkerRole,
                              roleID: String, coordinateID: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: role.symbol).foregroundStyle(Color(role.tint)).accessibilityHidden(true)
                Text(role.title).font(.headline).accessibilityIdentifier(roleID)
            }
            if !point.name.isEmpty { Text(point.name).font(.subheadline).foregroundStyle(.secondary) }
            Text(point.text).font(.callout).monospacedDigit().textSelection(.enabled).foregroundStyle(.secondary)
                .accessibilityIdentifier(coordinateID)
        }
    }

    @ViewBuilder private var selectionButtons: some View {
        Button { centerSelection += 1 } label: {
            Label("lc.location.useCenter".lcLocationText, systemImage: "plus.viewfinder")
        }
        .buttonStyle(.bordered).accessibilityIdentifier("location.center")
        Button { enteringCoordinates = true } label: {
            Label("lc.location.coordinates".lcLocationText, systemImage: "number")
        }
        .buttonStyle(.bordered).accessibilityIdentifier("location.coordinates")
    }
}

private struct LCLocationCoordinateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var latitude: String
    @State private var longitude: String
    @State private var pair = ""
    @FocusState private var focusedField: String?
    let select: (LCLocationPoint) -> Void

    init(initial: LCLocationPoint?, select: @escaping (LCLocationPoint) -> Void) {
        _latitude = State(initialValue: initial.map { String($0.latitude) } ?? "")
        _longitude = State(initialValue: initial.map { String($0.longitude) } ?? "")
        self.select = select
    }

    private var point: LCLocationPoint? {
        if !pair.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return parsedPair }
        func number(_ input: String) -> Double? {
            Double(input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "−", with: "-")
                .replacingOccurrences(of: ",", with: "."))
        }
        guard let lat = number(latitude), let lon = number(longitude),
              LCAppLocationCoordinateIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon)) else { return nil }
        return LCLocationPoint(latitude: lat, longitude: lon)
    }

    private var parsedPair: LCLocationPoint? {
        let parts = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "−", with: "-")
            .components(separatedBy: CharacterSet(charactersIn: ",; \t\n")).filter { !$0.isEmpty }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              LCAppLocationCoordinateIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon)) else { return nil }
        return LCLocationPoint(latitude: lat, longitude: lon)
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    coordinateField("lc.location.latitude", text: $latitude)
                    coordinateField("lc.location.longitude", text: $longitude)
                } footer: {
                    Text("lc.location.coordinateHelp".lcLocationText)
                }
                Section {
                    TextField("lc.location.pastePair".lcLocationText, text: $pair)
                        .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).disableAutocorrection(true)
                        .focused($focusedField, equals: "pair")
                        .accessibilityIdentifier("location.coordinatePair")
                        .onChange(of: pair) { _ in
                            if let parsedPair { latitude = String(parsedPair.latitude); longitude = String(parsedPair.longitude) }
                        }
                } footer: { Text("lc.location.pastePairHelp".lcLocationText) }
                if point == nil && (!latitude.isEmpty || !longitude.isEmpty || !pair.isEmpty) {
                    Text("lc.location.invalidCoordinate".lcLocationText).foregroundStyle(.red)
                        .accessibilityIdentifier("location.invalid")
                }
            }
            .navigationTitle("lc.location.coordinates".lcLocationText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if focusedField == "pair" {
                        Spacer()
                        Button("lc.common.done".lcLocationText) { focusedField = nil }
                            .accessibilityIdentifier("location.keyboardDone")
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("lc.common.cancel".lcLocationText) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("lc.location.showOnMap".lcLocationText) { if let point { select(point); dismiss() } }
                        .disabled(point == nil)
                        .accessibilityIdentifier("location.showOnMap")
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func coordinateField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading) {
            Text(title.lcLocationText).font(.caption).foregroundStyle(.secondary)
            LCLocationNumberField(title: title, text: Binding(get: { text.wrappedValue }, set: {
                text.wrappedValue = $0; pair = ""
            }))
            .frame(minHeight: 44)
        }
    }
}

// Keep the sign control inside the native text field. A separate SwiftUI Form
// button can resign the iPad keyboard on touch-down and move the sheet before
// touch-up, cancelling the sign change.
private struct LCLocationNumberField: UIViewRepresentable {
    let title: String
    @Binding var text: String

    final class Coordinator: NSObject {
        var parent: LCLocationNumberField
        weak var field: UITextField?
        init(_ parent: LCLocationNumberField) { self.parent = parent }
        @objc func edited(_ field: UITextField) { parent.text = field.text ?? "" }
        @objc func changeSign() {
            guard let field else { return }
            field.becomeFirstResponder()
            let value = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            field.text = value.hasPrefix("-") || value.hasPrefix("−") ? String(value.dropFirst()) : "-" + value
            edited(field)
        }
        @objc func done() { field?.resignFirstResponder() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        context.coordinator.field = field
        field.placeholder = title.lcLocationText
        field.accessibilityIdentifier = title
        field.accessibilityLabel = title.lcLocationText
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.keyboardType = .decimalPad
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.edited(_:)), for: .editingChanged)

        let sign = UIButton(type: .system)
        sign.setTitle("±", for: .normal)
        sign.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        // UITextField sizes its accessory with Auto Layout, ignoring the frame
        // when UIButton's smaller intrinsic content size is available.
        NSLayoutConstraint.activate([
            sign.widthAnchor.constraint(equalToConstant: 44),
            sign.heightAnchor.constraint(equalToConstant: 44)
        ])
        sign.backgroundColor = .tertiarySystemFill
        sign.layer.cornerRadius = 10
        sign.accessibilityLabel = "lc.location.changeSign".lcLocationText + ": " + title.lcLocationText
        sign.accessibilityIdentifier = title + ".sign"
        sign.addTarget(context.coordinator, action: #selector(Coordinator.changeSign), for: .touchUpInside)
        field.rightView = sign
        field.rightViewMode = .always

        let toolbar = UIToolbar()
        let done = UIBarButtonItem(title: "lc.common.done".lcLocationText, style: .done,
                                  target: context.coordinator, action: #selector(Coordinator.done))
        done.accessibilityIdentifier = "location.keyboardDone"
        toolbar.items = [UIBarButtonItem(systemItem: .flexibleSpace), done]
        toolbar.sizeToFit()
        field.inputAccessoryView = toolbar
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
    }
    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width,
               height: max(44, uiView.intrinsicContentSize.height))
    }
}

private struct LCLocationMap: UIViewRepresentable {
    let baseline: LCLocationPoint?
    let baselineRole: LCLocationMarkerRole
    let point: LCLocationPoint?
    let cameraPoint: LCLocationPoint?
    let cameraRevision: Int
    let centerSelection: Int
    let regionChanged: (MKCoordinateRegion) -> Void
    let selected: (LCLocationPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = false
        map.isPitchEnabled = false
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "location")
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPress(_:)))
        longPress.delegate = context.coordinator
        map.addGestureRecognizer(longPress)
        if cameraPoint == nil {
            map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                            span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 180)), animated: false)
        }
        return map
    }
    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.updateAnnotations(map, point: point)
        if coordinator.cameraRevision != cameraRevision {
            coordinator.cameraRevision = cameraRevision
            if let cameraPoint {
                map.setRegion(MKCoordinateRegion(center: cameraPoint.coordinate,
                                                latitudinalMeters: 2000, longitudinalMeters: 2000), animated: false)
            }
        }
        if coordinator.centerSelection != centerSelection {
            coordinator.centerSelection = centerSelection
            let center = map.centerCoordinate
            DispatchQueue.main.async { coordinator.pick(center, on: map) }
        }
    }
    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) { map.delegate = nil }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: LCLocationMap
        let baselinePin = MKPointAnnotation()
        let pendingPin = MKPointAnnotation()
        var cameraRevision = -1
        var centerSelection = 0
        var baselinePoint: LCLocationPoint?
        var selectedPoint: LCLocationPoint?
        var draggingSelection = false
        init(_ parent: LCLocationMap) { self.parent = parent }

        func updateAnnotations(_ map: MKMapView, point: LCLocationPoint?) {
            if let baseline = parent.baseline, baselinePoint != baseline {
                baselinePin.coordinate = baseline.coordinate
            }
            baselinePoint = parent.baseline
            if !draggingSelection {
                if let point, selectedPoint != point { pendingPin.coordinate = point.coordinate }
                selectedPoint = point
            }

            // Names do not determine whether two points coincide. At a shared
            // coordinate one draggable marker carries both roles; the fixed
            // baseline reappears as soon as the pending marker starts moving.
            let coincident: Bool
            if let baseline = parent.baseline, let point = selectedPoint {
                coincident = !draggingSelection && baseline.latitude == point.latitude && baseline.longitude == point.longitude
            } else {
                coincident = false
            }
            baselinePin.title = parent.baselineRole.title
            baselinePin.subtitle = parent.baseline?.name
            pendingPin.title = coincident ? parent.baselineRole.title + " · " + LCLocationMarkerRole.pending.title : LCLocationMarkerRole.pending.title
            var names = [selectedPoint?.name ?? ""]
            if coincident, let name = parent.baseline?.name, !names.contains(name) { names.append(name) }
            pendingPin.subtitle = names.filter { !$0.isEmpty }.joined(separator: " · ")

            setVisible(parent.baseline != nil && !coincident, pin: baselinePin, on: map)
            setVisible(selectedPoint != nil, pin: pendingPin, on: map)
            for pin in [baselinePin, pendingPin] {
                if let view = map.view(for: pin) as? MKMarkerAnnotationView { configure(view, for: pin) }
            }
        }

        private func setVisible(_ visible: Bool, pin: MKPointAnnotation, on map: MKMapView) {
            let present = map.annotations.contains { $0 === pin }
            if visible && !present { map.addAnnotation(pin) }
            if !visible && present { map.removeAnnotation(pin) }
        }

        private func configure(_ view: MKMarkerAnnotationView, for annotation: MKPointAnnotation) {
            let pending = annotation === pendingPin
            let role: LCLocationMarkerRole = pending ? .pending : parent.baselineRole
            view.isDraggable = pending
            view.canShowCallout = true
            view.markerTintColor = role.tint
            view.glyphTintColor = .white
            view.glyphImage = UIImage(systemName: role.symbol)
            view.titleVisibility = .visible
            view.subtitleVisibility = .adaptive
            view.displayPriority = .required
            view.isAccessibilityElement = true
            view.accessibilityIdentifier = pending ? "location.pendingMarker" : "location.baselineMarker"
            view.accessibilityLabel = [annotation.title, annotation.subtitle]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            view.accessibilityValue = (pending ? selectedPoint : parent.baseline)?.text
        }

        func pick(_ coordinate: CLLocationCoordinate2D, on map: MKMapView) {
            guard LCAppLocationCoordinateIsValid(coordinate) else {
                selectedPoint = nil
                updateAnnotations(map, point: parent.point)
                return
            }
            let point = LCLocationPoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
            parent.selected(point)
            // A drop at the unchanged point may not trigger a SwiftUI update.
            // Refresh now so coincident markers always recombine after dragging.
            updateAnnotations(map, point: point)
        }
        @objc func longPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let map = gesture.view as? MKMapView else { return }
            pick(map.convert(gesture.location(in: map), toCoordinateFrom: map), on: map)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Let MapKit handle marker dragging and callouts without the map's
            // long-press selection also creating a draft beneath the finger.
            var view = touch.view
            while let current = view {
                if current is MKAnnotationView { return false }
                view = current.superview
            }
            return true
        }
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            DispatchQueue.main.async { [weak self] in self?.parent.regionChanged(region) }
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let pin = annotation as? MKPointAnnotation, pin === baselinePin || pin === pendingPin,
                  let view = mapView.dequeueReusableAnnotationView(withIdentifier: "location", for: annotation) as? MKMarkerAnnotationView else { return nil }
            configure(view, for: pin)
            return view
        }
        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                     didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            guard view.annotation === pendingPin else { return }
            if newState == .starting {
                draggingSelection = true
                updateAnnotations(mapView, point: parent.point)
            }
            if newState == .ending || newState == .canceling {
                let coordinate = pendingPin.coordinate
                view.dragState = .none
                draggingSelection = false
                if newState == .ending { pick(coordinate, on: mapView) }
                // A cancelled drag must restore the draft, including its name.
                if newState == .canceling {
                    selectedPoint = nil
                    updateAnnotations(mapView, point: parent.point)
                }
            }
        }
    }
}

extension String {
    var lcLocationText: String { LCLocationLocalized(self) }
}
