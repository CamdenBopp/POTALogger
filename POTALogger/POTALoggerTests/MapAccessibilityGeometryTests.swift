//
//  MapAccessibilityGeometryTests.swift
//  POTALoggerTests
//
//  Deterministic coverage for the map's VoiceOver element geometry: the 44pt
//  hit-target inflation and the toolbar-occlusion gate. This is the logic behind
//  "pins hidden behind the top toolbar shouldn't be reachable" and "the VoiceOver
//  cursor shouldn't be a tiny speck" — verified here without a live MKMapView.
//

import XCTest
import UIKit
@testable import POTALogger

final class MapAccessibilityGeometryTests: XCTestCase {

    // A 390×844 map with a 90pt top toolbar carved out of the top.
    private let mapBounds = CGRect(x: 0, y: 0, width: 390, height: 844)
    private let topInset: CGFloat = 90
    private var contentRect: CGRect { mapBounds.inset(by: UIEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)) }

    private func assertRect(_ a: CGRect?, _ b: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("expected \(b), got nil", file: file, line: line) }
        XCTAssertEqual(a.minX, b.minX, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: 0.001, file: file, line: line)
    }

    // MARK: hit-target inflation

    func testSmallMarkerInflatedTo44() {
        // A 30×30 marker grows to 44×44, staying centered on (115, 115).
        let inflated = POTAMapAccessibilityGeometry.hitTargetBounds(CGRect(x: 100, y: 100, width: 30, height: 30))
        assertRect(inflated, CGRect(x: 93, y: 93, width: 44, height: 44))
    }

    func testLargeMarkerNotShrunk() {
        let big = CGRect(x: 100, y: 100, width: 60, height: 50)
        assertRect(POTAMapAccessibilityGeometry.hitTargetBounds(big), big)
    }

    // MARK: occlusion gate

    func testPinAboveToolbarBottomIsDropped() {
        // Anchor sits inside the top toolbar band → not exposed at all.
        let frame = POTAMapAccessibilityGeometry.resolvedFrame(
            markerFrame: CGRect(x: 178, y: 28, width: 44, height: 44),
            anchor: CGPoint(x: 200, y: 50),
            contentRect: contentRect
        )
        XCTAssertNil(frame)
    }

    func testPinBelowToolbarIsKeptWhole() {
        // Anchor well below the band, marker fully inside the content rect → unchanged.
        let marker = CGRect(x: 178, y: 198, width: 44, height: 44)
        let frame = POTAMapAccessibilityGeometry.resolvedFrame(
            markerFrame: marker, anchor: CGPoint(x: 200, y: 220), contentRect: contentRect
        )
        assertRect(frame, marker)
    }

    func testOccludedAnchorDroppedEvenIfMarkerOverlapsContent() {
        // The pin's true location is under the toolbar, but its inflated frame pokes
        // below the toolbar bottom. We must still drop it (no sliver poking out).
        let frame = POTAMapAccessibilityGeometry.resolvedFrame(
            markerFrame: CGRect(x: 178, y: 18, width: 44, height: 90), // extends to y=108, into content
            anchor: CGPoint(x: 200, y: 40),                            // but anchor is occluded
            contentRect: contentRect
        )
        XCTAssertNil(frame)
    }

    func testPartiallyVisibleMarkerIsClippedToContent() {
        // Anchor just below the toolbar; the inflated frame straddles the edge and is
        // clipped to the visible region.
        let frame = POTAMapAccessibilityGeometry.resolvedFrame(
            markerFrame: CGRect(x: 178, y: 73, width: 44, height: 44), // y 73..117
            anchor: CGPoint(x: 200, y: 95),                            // visible (>= 90)
            contentRect: contentRect
        )
        assertRect(frame, CGRect(x: 178, y: 90, width: 44, height: 27)) // top clipped to inset
    }

    func testTooSmallVisibleSliverIsDropped() {
        // Only a 5pt sliver of the marker is below the toolbar → below the 12pt floor.
        let frame = POTAMapAccessibilityGeometry.resolvedFrame(
            markerFrame: CGRect(x: 0, y: 85, width: 44, height: 10), // y 85..95, only 90..95 visible
            anchor: CGPoint(x: 20, y: 92),
            contentRect: contentRect
        )
        XCTAssertNil(frame)
    }

    func testNoOcclusionWhenContentRectIsFullBounds() {
        // With no inset (contentRect == bounds), a top-of-screen pin stays exposed.
        let marker = CGRect(x: 10, y: 4, width: 44, height: 44)
        let frame = POTAMapAccessibilityGeometry.resolvedFrame(
            markerFrame: marker, anchor: CGPoint(x: 32, y: 26), contentRect: mapBounds
        )
        assertRect(frame, marker)
    }
}
