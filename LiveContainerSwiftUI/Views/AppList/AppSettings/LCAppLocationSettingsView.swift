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

struct LCAppLocationSettingsView: View {
    @ObservedObject var model: LCAppModel
    @State private var editing = false
    @State private var enableAfterSelection = false

    private var point: LCLocationPoint? { LCLocationPoint(model.uiCustomLocation) }
    private var enabled: Bool { model.uiCustomLocation["enabled"] as? Bool == true }
    private var unavailable: Bool { model.uiDontInjectTweakLoader || model.uiIs32bit }

    var body: some View {
        Form {
            Section {
                Toggle("lc.location.enable".loc, isOn: Binding(get: { enabled }, set: { value in
                    if let point { model.uiCustomLocation = point.settings(enabled: value) }
                    else if value { enableAfterSelection = true; editing = true }
                }))
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
                Text("lc.location.coverage".loc).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("lc.location.title".loc)
        .sheet(isPresented: $editing) {
            LCLocationPickerView(initial: point) { newPoint in
                model.uiCustomLocation = newPoint.settings(enabled: enabled || enableAfterSelection)
            }
        }
    }
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

private struct LCLocationPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var search = LCLocationSearch()
    @State private var point: LCLocationPoint?
    @State private var cameraPoint: LCLocationPoint?
    @State private var cameraRevision = 0
    @State private var centerSelection = 0
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var query = ""
    @State private var enteringCoordinates = false
    @FocusState private var searching: Bool
    let save: (LCLocationPoint) -> Void

    init(initial: LCLocationPoint?, save: @escaping (LCLocationPoint) -> Void) {
        _point = State(initialValue: initial)
        _cameraPoint = State(initialValue: initial)
        self.save = save
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
                    TextField("lc.location.searchPlaceholder".loc, text: $query)
                        .accessibilityIdentifier("location.search")
                        .submitLabel(.search).focused($searching)
                        .onSubmit { search.find(query, near: visibleRegion); searching = false }
                        .onChange(of: query) { _ in search.cancel() }
                    if search.busy { ProgressView() }
                    Button("lc.location.search".loc) {
                        search.find(query, near: visibleRegion)
                        searching = false
                    }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || search.busy)
                }
                .padding()
                if let message = search.message {
                    Text(message.loc).font(.callout).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 8)
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
                    LCLocationMap(point: point, cameraPoint: cameraPoint, cameraRevision: cameraRevision,
                                  centerSelection: centerSelection, regionChanged: { visibleRegion = $0 },
                                  selected: { select($0, moveCamera: false) })
                    Image(systemName: "plus").font(.title2.weight(.light))
                        .foregroundStyle(.primary).padding(7).background(.regularMaterial, in: Circle())
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                .frame(minHeight: 160)
                VStack(alignment: .leading, spacing: 10) {
                    if let point {
                        Text(point.name.isEmpty ? "lc.location.selected".loc : point.name).font(.headline)
                        Text(point.text).monospacedDigit().textSelection(.enabled).foregroundStyle(.secondary)
                            .accessibilityIdentifier("location.selectedCoordinate")
                    } else {
                        Text("lc.location.mapHint".loc).font(.callout).foregroundStyle(.secondary)
                    }
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading) { selectionButtons }
                    } else {
                        HStack { selectionButtons }
                    }
                    Button {
                        if let point { save(point); dismiss() }
                    } label: {
                        Text("lc.location.useLocation".loc).frame(maxWidth: .infinity).padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent).disabled(point == nil)
                    .accessibilityIdentifier("location.save")
                }
                .padding().background(.regularMaterial)
            }
            .navigationTitle("lc.location.choose".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".loc) { dismiss() }.accessibilityIdentifier("location.cancel")
                }
            }
            .sheet(isPresented: $enteringCoordinates) {
                LCLocationCoordinateEditor(initial: point) { select($0, moveCamera: true) }
            }
            .onDisappear { search.cancel() }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder private var selectionButtons: some View {
        Button { centerSelection += 1 } label: {
            Label("lc.location.useCenter".loc, systemImage: "plus.viewfinder")
        }
        .buttonStyle(.bordered).accessibilityIdentifier("location.center")
        Button { enteringCoordinates = true } label: {
            Label("lc.location.coordinates".loc, systemImage: "number")
        }
        .buttonStyle(.bordered).accessibilityIdentifier("location.coordinates")
    }
}

private struct LCLocationCoordinateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var latitude: String
    @State private var longitude: String
    let select: (LCLocationPoint) -> Void

    init(initial: LCLocationPoint?, select: @escaping (LCLocationPoint) -> Void) {
        _latitude = State(initialValue: initial.map { String($0.latitude) } ?? "")
        _longitude = State(initialValue: initial.map { String($0.longitude) } ?? "")
        self.select = select
    }

    private var point: LCLocationPoint? {
        func number(_ input: String) -> Double? {
            Double(input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "−", with: "-")
                .replacingOccurrences(of: ",", with: "."))
        }
        guard let lat = number(latitude), let lon = number(longitude),
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
                    Text("lc.location.coordinateHelp".loc)
                }
                if point == nil && (!latitude.isEmpty || !longitude.isEmpty) {
                    Text("lc.location.invalidCoordinate".loc).foregroundStyle(.red)
                        .accessibilityIdentifier("location.invalid")
                }
            }
            .navigationTitle("lc.location.coordinates".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("lc.common.cancel".loc) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("lc.location.showOnMap".loc) { if let point { select(point); dismiss() } }
                        .disabled(point == nil)
                        .accessibilityIdentifier("location.showOnMap")
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func coordinateField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading) {
            Text(title.loc).font(.caption).foregroundStyle(.secondary)
            // numbersAndPunctuation includes minus signs on iPhone.
            TextField(title.loc, text: text).keyboardType(.numbersAndPunctuation)
                .accessibilityIdentifier(title)
                .textInputAutocapitalization(.never).disableAutocorrection(true)
        }
    }
}

private struct LCLocationMap: UIViewRepresentable {
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
        map.addGestureRecognizer(UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPress(_:))))
        if cameraPoint == nil {
            map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                            span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 180)), animated: false)
        }
        return map
    }
    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if let point, coordinator.selectedPoint != point {
            coordinator.selectedPoint = point
            coordinator.pin.coordinate = point.coordinate
            coordinator.pin.title = point.name.isEmpty ? "lc.location.selected".loc : point.name
            if map.annotations.isEmpty { map.addAnnotation(coordinator.pin) }
        }
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
            DispatchQueue.main.async { coordinator.pick(center) }
        }
    }
    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) { map.delegate = nil }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: LCLocationMap
        let pin = MKPointAnnotation()
        var cameraRevision = -1
        var centerSelection = 0
        var selectedPoint: LCLocationPoint?
        init(_ parent: LCLocationMap) { self.parent = parent }
        func pick(_ coordinate: CLLocationCoordinate2D) {
            guard LCAppLocationCoordinateIsValid(coordinate) else { return }
            parent.selected(LCLocationPoint(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }
        @objc func longPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let map = gesture.view as? MKMapView else { return }
            pick(map.convert(gesture.location(in: map), toCoordinateFrom: map))
        }
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            DispatchQueue.main.async { [weak self] in self?.parent.regionChanged(region) }
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "location", for: annotation)
            view.isDraggable = true
            view.canShowCallout = true
            return view
        }
        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                     didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            if newState == .ending, let coordinate = view.annotation?.coordinate { pick(coordinate) }
            if newState == .ending || newState == .canceling { view.dragState = .none }
        }
    }
}
