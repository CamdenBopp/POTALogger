import SwiftUI
import MapKit

// MARK: - Camera Command

struct CameraCommand {
    let id = UUID()
    let region: MKCoordinateRegion?
    let animated: Bool
}

struct POTAClusterParkListRequest: Identifiable {
    let id = UUID()
    let parks: [ParkRecord]
    let anchor: CGPoint
}

// MARK: - Annotations

final class ParkAnnotation: NSObject, MKAnnotation {
    let reference: String
    let name: String
    let coordinate: CLLocationCoordinate2D

    var title: String? { nil }
    var subtitle: String? { nil }

    init(reference: String, name: String, coordinate: CLLocationCoordinate2D) {
        self.reference = reference
        self.name = name
        self.coordinate = coordinate
        super.init()
    }
}

final class PinnedParkAnnotation: NSObject, MKAnnotation {
    let reference: String
    let coordinate: CLLocationCoordinate2D
    private let name: String
    var title: String? { nil }
    var subtitle: String? { nil }

    init(park: POTAPark) {
        self.reference = park.reference
        self.name = park.name
        self.coordinate = park.coordinate
        super.init()
    }
}

final class POTAAnnotationView: MKMarkerAnnotationView {
    override var accessibilityFrame: CGRect {
        get {
            let raw = UIAccessibility.convertToScreenCoordinates(bounds, in: self)
            guard let window else { return raw }
            let windowFrame = UIAccessibility.convertToScreenCoordinates(window.bounds, in: window)
            let clipped = raw.intersection(windowFrame)
            return clipped.isNull ? .zero : clipped
        }
        set { }
    }

    override var accessibilityPath: UIBezierPath? {
        get {
            let frame = accessibilityFrame
            guard !frame.isEmpty else { return nil }
            return UIBezierPath(
                roundedRect: frame,
                cornerRadius: min(frame.width, frame.height) / 2
            )
        }
        set { }
    }

    override var accessibilityActivationPoint: CGPoint {
        get {
            let frame = accessibilityFrame
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        set { }
    }

    override var annotation: MKAnnotation? {
        didSet { collapseAccessibilityChildren() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        collapseAccessibilityChildren()
    }

    private func collapseAccessibilityChildren() {
        isAccessibilityElement = false
        for subview in subviews {
            subview.isAccessibilityElement = false
            subview.accessibilityElementsHidden = true
        }
    }
}

protocol POTAAccessibleMapViewDataSource: AnyObject {
    func accessibilityElements(for mapView: POTAAccessibleMapView) -> [Any]
}

final class POTAAccessibleMapView: MKMapView {
    weak var potaAccessibilityDataSource: POTAAccessibleMapViewDataSource?
    private var cachedAccessibilityElements: [Any]?

    /// Insets carving the occluded chrome out of the map's bounds. Only pins
    /// inside `accessibleContentRect` are exposed to VoiceOver.
    var accessibleContentInset: UIEdgeInsets = .zero

    var accessibleContentRect: CGRect {
        bounds.inset(by: accessibleContentInset)
    }

    override var isAccessibilityElement: Bool {
        get { false }
        set { }
    }

    override var accessibilityElements: [Any]? {
        get {
            if cachedAccessibilityElements == nil {
                reloadPOTAAccessibilityElements()
            }
            return cachedAccessibilityElements
        }
        set { }
    }

    func reloadPOTAAccessibilityElements() {
        let elements = potaAccessibilityDataSource?.accessibilityElements(for: self) ?? []
        if !elements.isEmpty || cachedAccessibilityElements == nil {
            cachedAccessibilityElements = elements
        }
    }

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        suppressNativeAccessibility(in: subview)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for subview in subviews {
            suppressNativeAccessibility(in: subview)
        }
    }

    private func suppressNativeAccessibility(in view: UIView) {
        guard view !== self else { return }
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        for subview in view.subviews {
            suppressNativeAccessibility(in: subview)
        }
    }
}

final class POTAMapAccessibilityElement: UIAccessibilityElement {
    weak var mapView: MKMapView?
    private let annotation: MKAnnotation
    private let activate: (() -> Bool)?

    init(
        container: Any,
        mapView: MKMapView,
        annotation: MKAnnotation,
        label: String,
        customActions: [UIAccessibilityCustomAction] = [],
        activate: (() -> Bool)? = nil
    ) {
        self.mapView = mapView
        self.annotation = annotation
        self.activate = activate
        super.init(accessibilityContainer: container)
        accessibilityLabel = label
        accessibilityHint = customActions.isEmpty ? nil : "Actions available"
        accessibilityTraits = [.button]
        accessibilityCustomActions = customActions
    }

    override var accessibilityFrame: CGRect {
        get {
            guard let mapView else { return .zero }
            return UIAccessibility.convertToScreenCoordinates(accessibilityFrameInContainerSpace, in: mapView)
        }
        set { }
    }

    override var accessibilityFrameInContainerSpace: CGRect {
        get { currentFrameInContainerSpace ?? .zero }
        set { }
    }

    override var accessibilityPath: UIBezierPath? {
        get {
            guard let mapView, let frame = currentFrameInContainerSpace else { return nil }
            let screenFrame = UIAccessibility.convertToScreenCoordinates(frame, in: mapView)
            return UIBezierPath(
                roundedRect: screenFrame,
                cornerRadius: min(screenFrame.width, screenFrame.height) / 2
            )
        }
        set { }
    }

    override func accessibilityActivate() -> Bool {
        if let activate {
            return activate()
        }
        guard let mapView else { return false }
        mapView.selectAnnotation(annotation, animated: true)
        return true
    }

    var sortFrame: CGRect {
        currentFrameInContainerSpace ?? .zero
    }

    var isVisibleInContainer: Bool {
        currentFrameInContainerSpace != nil
    }

    private var currentFrameInContainerSpace: CGRect? {
        guard let mapView, mapView.window != nil else { return nil }

        // Only surface a pin that has a real, on-screen marker view. Annotations
        // absorbed into a cluster (or scrolled past the edge) have no view; planting
        // a frame at their raw coordinate creates "ghost" elements off to the side of
        // the cluster pin that VoiceOver can land on.
        guard let view = mapView.view(for: annotation) as? POTAAnnotationView,
              !view.isHidden,
              view.alpha > 0.01,
              view.window != nil
        else { return nil }

        // Inflate the marker to at least a 44pt hit target, then gate it against the
        // unoccluded content rect (bounds minus chrome like the top toolbar). The pure
        // geometry lives in POTAMapAccessibilityGeometry so it can be unit-tested
        // without a live MKMapView.
        let rawFrame = view.convert(
            POTAMapAccessibilityGeometry.hitTargetBounds(view.bounds), to: mapView
        )
        let contentRect = (mapView as? POTAAccessibleMapView)?.accessibleContentRect ?? mapView.bounds
        let anchor = mapView.convert(annotation.coordinate, toPointTo: mapView)
        return POTAMapAccessibilityGeometry.resolvedFrame(
            markerFrame: rawFrame, anchor: anchor, contentRect: contentRect
        )
    }
}

// MARK: - Map accessibility geometry (pure / testable)

/// The pure geometry behind the map's VoiceOver element frames, factored out of
/// `POTAMapAccessibilityElement` so it can be unit-tested without a live MKMapView.
enum POTAMapAccessibilityGeometry {
    /// Minimum VoiceOver hit-target edge length — Apple's HIG touch-target floor.
    static let minimumHitTarget: CGFloat = 44

    /// Minimum visible (post-clip) edge length below which a pin isn't worth surfacing.
    static let minimumVisible: CGFloat = 12

    /// Inflates a marker's bounds so each edge is at least `minimum`, keeping the pin
    /// centered. Markers already larger than `minimum` are returned unchanged.
    static func hitTargetBounds(_ bounds: CGRect, minimum: CGFloat = minimumHitTarget) -> CGRect {
        let dx = max((minimum - bounds.width) / 2, 0)
        let dy = max((minimum - bounds.height) / 2, 0)
        return bounds.insetBy(dx: -dx, dy: -dy)
    }

    /// Resolves a pin's accessibility frame, or nil if it should not be exposed.
    /// - Parameters:
    ///   - markerFrame: the (hit-target-inflated) marker frame in map space.
    ///   - anchor: the pin's true projected on-screen point.
    ///   - contentRect: the unoccluded region of the map (bounds minus chrome).
    /// Returns nil when the anchor is occluded, or the visible clip is too small.
    static func resolvedFrame(
        markerFrame: CGRect,
        anchor: CGPoint,
        contentRect: CGRect,
        minimumVisible: CGFloat = minimumVisible
    ) -> CGRect? {
        // The pin's true location is occluded by chrome — drop it rather than expose a
        // sliver poking out below the toolbar.
        guard contentRect.contains(anchor) else { return nil }
        let clipped = markerFrame.intersection(contentRect)
        guard !clipped.isNull,
              clipped.width >= minimumVisible,
              clipped.height >= minimumVisible
        else { return nil }
        return clipped
    }
}

// MARK: - POTAMKMapView

struct POTAMKMapView: UIViewRepresentable {
    let parks: [ParkRecord]
    let geodesicOrigin: CLLocationCoordinate2D?
    let geodesicEndpoints: [CLLocationCoordinate2D]
    let pinnedPark: POTAPark?
    let markerTint: UIColor
    @Binding var selectedParkReference: String?
    var cameraCommand: CameraCommand?
    var onClusterListRequested: (POTAClusterParkListRequest) -> Void = { _ in }
    let onRegionChanged: (MKCoordinateRegion) -> Void
    let onTapped: () -> Void
    /// Top chrome (toolbar) height to exclude from the accessibility tree so
    /// VoiceOver never lands on pins hidden behind the overlay controls.
    var accessibilityTopInset: CGFloat = 0
    /// Bottom overlay height (the debug badge) to lift MapKit's legal/logo
    /// ornaments above, via the map's `layoutMargins`, so they aren't covered.
    var legalBottomInset: CGFloat = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = POTAAccessibleMapView()
        map.delegate = context.coordinator
        map.potaAccessibilityDataSource = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.shouldGroupAccessibilityChildren = true
        map.accessibilityContainerType = .list
        map.accessibilityNavigationStyle = .separate

        map.register(POTAAnnotationView.self, forAnnotationViewWithReuseIdentifier: Coordinator.parkId)
        map.register(POTAAnnotationView.self, forAnnotationViewWithReuseIdentifier: Coordinator.pinnedId)
        map.register(
            POTAAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier
        )

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.mapTapped))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.mapLongPressed(_:))
        )
        longPress.delegate = context.coordinator
        map.addGestureRecognizer(longPress)

        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.diffAnnotations(on: map)
        c.diffPinnedPark(on: map)
        c.diffOverlays(on: map)
        c.applyCamera(on: map)
        c.syncSelection(on: map)
        c.syncMarkerTint(on: map)
        c.syncAccessibilityContentInset(on: map)
        c.syncLegalInset(on: map)
        c.scheduleAccessibilityRefresh(on: map)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate, POTAAccessibleMapViewDataSource {
        static let parkId = "park"
        static let pinnedId = "pinned"

        var parent: POTAMKMapView
        var lastCommandId: UUID?
        private var parkRefs = Set<String>()
        private var pinnedRef: String?
        private var overlayKey = ""
        private var appliedTint: UIColor?
        private var accessibilityRefreshWorkItem: DispatchWorkItem?
        private var suppressNextTap = false

        init(parent: POTAMKMapView) {
            self.parent = parent
            super.init()
        }

        // MARK: Diffing

        func diffAnnotations(on map: MKMapView) {
            var newRefs = Set(parent.parks.map(\.reference))
            if let pinnedRef = parent.pinnedPark?.reference {
                newRefs.remove(pinnedRef)
            }
            guard newRefs != parkRefs else { return }

            let existing = map.annotations.compactMap { $0 as? ParkAnnotation }
            let existingRefs = Set(existing.map(\.reference))

            let toRemove = existing.filter { !newRefs.contains($0.reference) }
            let refsToAdd = newRefs.subtracting(existingRefs)
            let toAdd = parent.parks.filter {
                refsToAdd.contains($0.reference) && $0.reference != parent.pinnedPark?.reference
            }

            if !toRemove.isEmpty { map.removeAnnotations(toRemove) }
            if !toAdd.isEmpty {
                map.addAnnotations(toAdd.map {
                    ParkAnnotation(reference: $0.reference, name: $0.name, coordinate: $0.coordinate)
                })
            }
            parkRefs = newRefs
        }

        func diffPinnedPark(on map: MKMapView) {
            let newRef = parent.pinnedPark?.reference
            guard newRef != pinnedRef else { return }

            let old = map.annotations.compactMap { $0 as? PinnedParkAnnotation }
            if !old.isEmpty { map.removeAnnotations(old) }

            if let park = parent.pinnedPark {
                map.addAnnotation(PinnedParkAnnotation(park: park))
            }
            pinnedRef = newRef
        }

        func diffOverlays(on map: MKMapView) {
            let key: String
            if let o = parent.geodesicOrigin, !parent.geodesicEndpoints.isEmpty {
                key = "\(o.latitude),\(o.longitude)|\(parent.geodesicEndpoints.count)"
            } else {
                key = ""
            }
            guard key != overlayKey else { return }
            overlayKey = key

            map.removeOverlays(map.overlays)
            guard let origin = parent.geodesicOrigin else { return }
            for dest in parent.geodesicEndpoints {
                var coords = [origin, dest]
                let polyline = MKGeodesicPolyline(coordinates: &coords, count: 2)
                map.addOverlay(polyline)
            }
        }

        func applyCamera(on map: MKMapView) {
            guard let cmd = parent.cameraCommand, cmd.id != lastCommandId else { return }
            lastCommandId = cmd.id
            if let region = cmd.region {
                map.setRegion(region, animated: cmd.animated)
            } else {
                map.userTrackingMode = .follow
            }
        }

        func syncSelection(on map: MKMapView) {
            let target = parent.selectedParkReference
            let current = map.selectedAnnotations.first.flatMap(Self.reference(for:))
            guard target != current else { return }

            if let ref = target,
               let ann = map.annotations.first(where: { Self.reference(for: $0) == ref }) {
                map.selectAnnotation(ann, animated: true)
            } else if let sel = map.selectedAnnotations.first, Self.reference(for: sel) != nil {
                map.deselectAnnotation(sel, animated: true)
            }
        }

        func syncMarkerTint(on map: MKMapView) {
            guard parent.markerTint != appliedTint else { return }
            appliedTint = parent.markerTint
            for ann in map.annotations where ann is ParkAnnotation {
                if let view = map.view(for: ann) as? MKMarkerAnnotationView {
                    view.markerTintColor = parent.markerTint
                }
            }
        }

        /// Lift MapKit's legal/logo ornaments above a bottom overlay (the debug
        /// badge) by widening the map's bottom layout margin. MapKit positions its
        /// ornaments inside `layoutMargins`, so this keeps the "Legal" link and
        /// Apple logo visible instead of hidden behind the badge.
        func syncLegalInset(on map: MKMapView) {
            let bottom = max(0, parent.legalBottomInset)
            guard map.layoutMargins.bottom != bottom else { return }
            var margins = map.layoutMargins
            margins.bottom = bottom
            map.layoutMargins = margins
        }

        func syncAccessibilityContentInset(on map: MKMapView) {
            guard let map = map as? POTAAccessibleMapView else { return }
            let newInset = UIEdgeInsets(top: max(0, parent.accessibilityTopInset), left: 0, bottom: 0, right: 0)
            guard newInset != map.accessibleContentInset else { return }
            map.accessibleContentInset = newInset
            map.reloadPOTAAccessibilityElements()
        }

        func scheduleAccessibilityRefresh(on map: MKMapView) {
            guard let map = map as? POTAAccessibleMapView else { return }
            accessibilityRefreshWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak map] in
                map?.reloadPOTAAccessibilityElements()
            }
            accessibilityRefreshWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            if annotation is PinnedParkAnnotation {
                let v = mapView.dequeueReusableAnnotationView(
                    withIdentifier: Self.pinnedId, for: annotation
                ) as! POTAAnnotationView
                v.glyphImage = UIImage(systemName: "tree.fill")
                v.markerTintColor = parent.markerTint
                v.displayPriority = .required
                v.clusteringIdentifier = nil
                v.canShowCallout = false
                if let pinned = annotation as? PinnedParkAnnotation {
                    Self.configureAccessibility(v, label: Self.accessibleReference(pinned.reference))
                }
                return v
            }

            if let cluster = annotation as? MKClusterAnnotation {
                let v = mapView.dequeueReusableAnnotationView(
                    withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier,
                    for: annotation
                ) as! POTAAnnotationView
                v.markerTintColor = parent.markerTint
                Self.configureAccessibility(v, label: "\(cluster.memberAnnotations.count) parks")
                return v
            }

            if let park = annotation as? ParkAnnotation {
                let v = mapView.dequeueReusableAnnotationView(
                    withIdentifier: Self.parkId, for: annotation
                ) as! POTAAnnotationView
                v.glyphImage = UIImage(systemName: "tree.fill")
                v.markerTintColor = parent.markerTint
                v.clusteringIdentifier = "park"
                v.titleVisibility = .hidden
                v.subtitleVisibility = .hidden
                v.canShowCallout = false
                Self.configureAccessibility(v, label: Self.accessibleReference(park.reference))
                return v
            }

            return nil
        }

        func accessibilityElements(for mapView: POTAAccessibleMapView) -> [Any] {
            mapView.annotations
                .compactMap { annotation -> POTAMapAccessibilityElement? in
                    guard !(annotation is MKUserLocation),
                          let label = Self.accessibilityLabel(for: annotation)
                    else { return nil }

                    let customActions = clusterActions(for: annotation, on: mapView)
                    let element = POTAMapAccessibilityElement(
                        container: mapView,
                        mapView: mapView,
                        annotation: annotation,
                        label: label,
                        customActions: customActions,
                        activate: customActions.isEmpty ? nil : { [weak mapView, weak self] in
                            guard let mapView, let self else { return false }
                            return self.zoomIntoCluster(annotation, on: mapView)
                        }
                    )
                    return element.isVisibleInContainer ? element : nil
                }
                .sorted { lhs, rhs in
                    let left = lhs.sortFrame
                    let right = rhs.sortFrame
                    if abs(left.midY - right.midY) > 24 {
                        return left.midY < right.midY
                    }
                    return left.midX < right.midX
                }
        }

        private func clusterActions(for annotation: MKAnnotation, on mapView: POTAAccessibleMapView) -> [UIAccessibilityCustomAction] {
            guard let cluster = annotation as? MKClusterAnnotation,
                  cluster.memberAnnotations.count > 1
            else { return [] }

            return [
                UIAccessibilityCustomAction(name: "List Parks") { [weak self, weak mapView] _ in
                    guard let self, let mapView else { return false }
                    return self.showClusterParkList(cluster, on: mapView)
                },
                UIAccessibilityCustomAction(name: "Increase Zoom Level") { [weak self, weak mapView] _ in
                    guard let self, let mapView else { return false }
                    return self.zoomIntoCluster(cluster, on: mapView)
                }
            ]
        }

        private func showClusterParkList(_ cluster: MKClusterAnnotation, on mapView: MKMapView) -> Bool {
            let parks = parks(in: cluster)
            guard parks.count > 1 else { return false }

            let anchor = clusterAnchor(for: cluster, on: mapView)
            let request = POTAClusterParkListRequest(parks: parks, anchor: anchor)

            // Defer the SwiftUI state change to the next runloop tick. When this
            // runs from a VoiceOver custom action, mutating state here would post
            // a .screenChanged that makes VoiceOver synchronously rebuild the map's
            // accessibility elements — freeing the element whose action closure is
            // still on the stack (a use-after-free that traps). Returning first and
            // applying the change afterward keeps the action closure self-contained.
            DispatchQueue.main.async { [weak self] in
                self?.parent.onClusterListRequested(request)
            }
            return true
        }

        private func zoomIntoCluster(_ annotation: MKAnnotation, on mapView: MKMapView) -> Bool {
            guard let cluster = annotation as? MKClusterAnnotation,
                  cluster.memberAnnotations.count > 1
            else { return false }

            let current = mapView.region.span
            let region = MKCoordinateRegion(
                center: cluster.coordinate,
                span: MKCoordinateSpan(
                    latitudeDelta: max(current.latitudeDelta * 0.45, 0.01),
                    longitudeDelta: max(current.longitudeDelta * 0.45, 0.01)
                )
            )
            mapView.setRegion(region, animated: true)
            parent.onRegionChanged(region)
            parent.onClusterListRequested(POTAClusterParkListRequest(parks: [], anchor: .zero))
            return true
        }

        private func parks(in cluster: MKClusterAnnotation) -> [ParkRecord] {
            let refs = cluster.memberAnnotations.compactMap(Self.reference(for:))
            return refs
                .compactMap { ref in
                    parent.parks.first(where: { $0.reference == ref }) ??
                    ParkIndex.shared.park(reference: ref)
                }
                .sorted { $0.reference < $1.reference }
        }

        private func clusterAnchor(for cluster: MKClusterAnnotation, on mapView: MKMapView) -> CGPoint {
            if let view = mapView.view(for: cluster) {
                let frame = view.convert(view.bounds, to: mapView)
                return CGPoint(x: frame.midX, y: frame.midY)
            }
            return mapView.convert(cluster.coordinate, toPointTo: mapView)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: polyline)
                r.strokeColor = UIColor.systemBlue.withAlphaComponent(0.5)
                r.lineWidth = 2
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            parent.onRegionChanged(mapView.region)
            scheduleAccessibilityRefresh(on: mapView)
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let park = view.annotation as? ParkAnnotation {
                parent.selectedParkReference = park.reference
            } else if let park = view.annotation as? PinnedParkAnnotation {
                parent.selectedParkReference = park.reference
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            if Self.reference(for: view.annotation) != nil,
               mapView.selectedAnnotations.compactMap(Self.reference(for:)).isEmpty {
                parent.selectedParkReference = nil
            }
        }

        // MARK: Tap Gesture

        @objc func mapTapped() {
            // A long press that opened the cluster list also ends with a touch-up
            // that the tap recognizer sees — ignore that one tap so the popup stays.
            if suppressNextTap {
                suppressNextTap = false
                return
            }
            parent.onTapped()
        }

        @objc func mapLongPressed(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let mapView = gesture.view as? MKMapView else { return }

            let point = gesture.location(in: mapView)
            guard let cluster = clusterAnnotation(at: point, on: mapView),
                  cluster.memberAnnotations.count > 1 else { return }

            suppressNextTap = true
            _ = showClusterParkList(cluster, on: mapView)
        }

        /// Returns the multi-park cluster whose marker contains `point`, if any.
        private func clusterAnnotation(at point: CGPoint, on mapView: MKMapView) -> MKClusterAnnotation? {
            for annotation in mapView.annotations {
                guard let cluster = annotation as? MKClusterAnnotation,
                      cluster.memberAnnotations.count > 1,
                      let view = mapView.view(for: cluster),
                      !view.isHidden, view.alpha > 0.01
                else { continue }

                let frame = view.convert(view.bounds, to: mapView).insetBy(dx: -8, dy: -8)
                if frame.contains(point) { return cluster }
            }
            return nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        // MARK: Accessibility

        static func reference(for annotation: MKAnnotation?) -> String? {
            if let park = annotation as? ParkAnnotation {
                return park.reference
            }
            if let park = annotation as? PinnedParkAnnotation {
                return park.reference
            }
            return nil
        }

        static func accessibilityLabel(for annotation: MKAnnotation) -> String? {
            if let cluster = annotation as? MKClusterAnnotation {
                return "\(cluster.memberAnnotations.count) parks"
            }
            if let reference = reference(for: annotation) {
                return accessibleReference(reference)
            }
            return nil
        }

        static func configureAccessibility(_ view: POTAAnnotationView, label: String) {
            view.isAccessibilityElement = false
            view.accessibilityLabel = label
            view.accessibilityValue = nil
            view.accessibilityHint = nil
            view.accessibilityTraits = [.button]
        }

        static func accessibleReference(_ ref: String) -> String {
            ref.split(separator: "-").map { segment in
                if segment.allSatisfy(\.isLetter) {
                    return segment.map(String.init).joined(separator: " ")
                }
                return String(segment)
            }.joined(separator: " ")
        }
    }
}
