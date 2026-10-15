//
//  POTALoggerTests.swift
//  POTALoggerTests
//
//  Created by Camden Bopp on 4/6/25.
//

import XCTest
@testable import POTALogger

// MARK: - FrequencyFormatter

final class FrequencyFormatterTests: XCTestCase {

    func testMHz_shownZeros_standard() {
        XCTAssertEqual(formatFrequency("14074", unit: .MHz, trailingZeros: .shown), "14.074 MHz")
    }

    func testMHz_shownZeros_roundNumber() {
        XCTAssertEqual(formatFrequency("7000", unit: .MHz, trailingZeros: .shown), "7.000 MHz")
    }

    func testMHz_trimmed_noTrailingZeros() {
        XCTAssertEqual(formatFrequency("14200", unit: .MHz, trailingZeros: .trimmed), "14.2 MHz")
    }

    func testMHz_trimmed_wholeNumber() {
        XCTAssertEqual(formatFrequency("7000", unit: .MHz, trailingZeros: .trimmed), "7 MHz")
    }

    func testMHz_trimmed_allDecimalsSignificant() {
        XCTAssertEqual(formatFrequency("7041", unit: .MHz, trailingZeros: .trimmed), "7.041 MHz")
    }

    func testMHz_VHF_144200() {
        XCTAssertEqual(formatFrequency("144200", unit: .MHz, trailingZeros: .trimmed), "144.2 MHz")
    }

    func testMHz_FT8_20M() {
        XCTAssertEqual(formatFrequency("14074", unit: .MHz, trailingZeros: .trimmed), "14.074 MHz")
    }

    func testKHz_shownZeros() {
        XCTAssertEqual(formatFrequency("14074", unit: .kHz, trailingZeros: .shown), "14074.000 kHz")
    }

    func testKHz_trimmed_keepOneDecimalMinimum() {
        XCTAssertEqual(formatFrequency("14074", unit: .kHz, trailingZeros: .trimmed), "14074.0 kHz")
    }

    func testKHz_trimmed_withSubKHzFraction() {
        XCTAssertEqual(formatFrequency("14074.1", unit: .kHz, trailingZeros: .trimmed), "14074.1 kHz")
    }

    func testInvalidInput_MHz_fallsThrough() {
        XCTAssertEqual(formatFrequency("abc", unit: .MHz, trailingZeros: .shown), "abc MHz")
    }

    func testInvalidInput_kHz_fallsThrough() {
        XCTAssertEqual(formatFrequency("--", unit: .kHz, trailingZeros: .trimmed), "-- kHz")
    }
}

// MARK: - Spot helpers

private func makeSpot(
    frequency: String = "14074",
    reference: String = "K-1234",
    spotTime: String = "2026-04-07T03:04:29",
    expire: Int? = 30
) -> Spot {
    Spot(
        spotId: 1,
        activator: "KF8CKX",
        frequency: frequency,
        mode: "FT8",
        reference: reference,
        name: nil,
        spotTime: spotTime,
        comments: nil,
        spotter: nil,
        source: nil,
        locationDesc: nil,
        grid4: nil,
        grid6: nil,
        latitude: nil,
        longitude: nil,
        count: nil,
        expire: expire
    )
}

// MARK: - Spot.band

final class SpotBandTests: XCTestCase {

    func testBand_160M()    { XCTAssertEqual(makeSpot(frequency: "1800").band,    "160M") }
    func testBand_80M()     { XCTAssertEqual(makeSpot(frequency: "3750").band,    "80M")  }
    func testBand_60M()     { XCTAssertEqual(makeSpot(frequency: "5370").band,    "60M")  }
    func testBand_40M()     { XCTAssertEqual(makeSpot(frequency: "7041").band,    "40M")  }
    func testBand_30M()     { XCTAssertEqual(makeSpot(frequency: "10125").band,   "30M")  }
    func testBand_20M()     { XCTAssertEqual(makeSpot(frequency: "14074").band,   "20M")  }
    func testBand_17M()     { XCTAssertEqual(makeSpot(frequency: "18100").band,   "17M")  }
    func testBand_15M()     { XCTAssertEqual(makeSpot(frequency: "21074").band,   "15M")  }
    func testBand_12M()     { XCTAssertEqual(makeSpot(frequency: "24915").band,   "12M")  }
    func testBand_10M()     { XCTAssertEqual(makeSpot(frequency: "28074").band,   "10M")  }
    func testBand_6M()      { XCTAssertEqual(makeSpot(frequency: "50313").band,   "6M")   }
    func testBand_2M()      { XCTAssertEqual(makeSpot(frequency: "144200").band,  "2M")   }
    func testBand_70CM()    { XCTAssertEqual(makeSpot(frequency: "432100").band,  "70CM") }
    func testBand_unknown() { XCTAssertEqual(makeSpot(frequency: "99999").band,   "?")    }
    func testBand_invalid() { XCTAssertEqual(makeSpot(frequency: "abc").band,     "?")    }
}

// MARK: - Spot.isQRT

final class SpotQRTTests: XCTestCase {

    func testIsQRT_nilExpire()      { XCTAssertTrue(makeSpot(expire: nil).isQRT)  }
    func testIsQRT_zeroExpire()     { XCTAssertTrue(makeSpot(expire: 0).isQRT)    }
    func testIsQRT_negativeExpire() { XCTAssertTrue(makeSpot(expire: -1).isQRT)   }
    func testIsNotQRT_positive()    { XCTAssertFalse(makeSpot(expire: 30).isQRT)  }
    func testIsNotQRT_one()         { XCTAssertFalse(makeSpot(expire: 1).isQRT)   }
}

// MARK: - Spot.program

final class SpotProgramTests: XCTestCase {

    func testProgram_K()  { XCTAssertEqual(makeSpot(reference: "K-1234").program,  "K")  }
    func testProgram_US() { XCTAssertEqual(makeSpot(reference: "US-1234").program, "US") }
    func testProgram_JP() { XCTAssertEqual(makeSpot(reference: "JP-1918").program, "JP") }
    func testProgram_VE() { XCTAssertEqual(makeSpot(reference: "VE-0123").program, "VE") }

    func testProgram_noHyphen_returnsWholeString() {
        XCTAssertEqual(makeSpot(reference: "NOHYPHEN").program, "NOHYPHEN")
    }
}

// MARK: - parseSpotTime

final class SpotTimeTests: XCTestCase {

    func testParseSpotTime_validBareUTC() {
        XCTAssertNotNil(parseSpotTime("2026-04-07T03:04:29"))
    }

    func testParseSpotTime_validISO8601WithZ() {
        XCTAssertNotNil(parseSpotTime("2026-04-07T03:04:29Z"))
    }

    func testParseSpotTime_invalid_returnsNil() {
        XCTAssertNil(parseSpotTime("not-a-date"))
    }

    func testParseSpotTime_empty_returnsNil() {
        XCTAssertNil(parseSpotTime(""))
    }

    func testParseSpotTime_correctComponents() throws {
        let date = try XCTUnwrap(parseSpotTime("2026-01-15T12:30:45"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(cal.component(.year,   from: date), 2026)
        XCTAssertEqual(cal.component(.month,  from: date), 1)
        XCTAssertEqual(cal.component(.day,    from: date), 15)
        XCTAssertEqual(cal.component(.hour,   from: date), 12)
        XCTAssertEqual(cal.component(.minute, from: date), 30)
        XCTAssertEqual(cal.component(.second, from: date), 45)
    }
}

// MARK: - POTAHTMLProbe

final class POTAHTMLProbeTests: XCTestCase {

    func testCallsignNotInHTML_returnsNotFound() {
        let result = POTAHTMLProbe.checkActivation(in: "<html><body>nothing here</body></html>",
                                                   callsign: "KF8CKX")
        XCTAssertEqual(result, .notFound)
    }

    func testEmptyCallsign_returnsParseError() {
        let result = POTAHTMLProbe.checkActivation(in: "<html>KF8CKX</html>", callsign: "")
        guard case .parseError = result else {
            XCTFail("Expected parseError, got \(result)")
            return
        }
    }

    func testWhitespaceOnlyCallsign_returnsParseError() {
        let result = POTAHTMLProbe.checkActivation(in: "<html>KF8CKX</html>", callsign: "   ")
        guard case .parseError = result else {
            XCTFail("Expected parseError, got \(result)")
            return
        }
    }

    func testCallsignFound_withLastHeard_returnsActive() {
        let html = """
        <html><body>
        <hr data-v-abc>
        KF8CKX is active
        <a href="#">K-4566</a>
        <div>7074 kHz</div>
        <div>Last heard 5 minutes ago</div>
        <hr data-v-def>
        </body></html>
        """
        let result = POTAHTMLProbe.checkActivation(in: html, callsign: "KF8CKX")
        XCTAssertTrue(result.isConfirmedActive)
        if case .active(let record) = result {
            XCTAssertEqual(record.callsign, "KF8CKX")
            XCTAssertEqual(record.frequency, "7074 kHz")
        }
    }

    func testCallsignFound_noLastHeard_returnsInactive() {
        let html = """
        <html><body>
        <hr data-v-abc>
        KF8CKX
        <div>Some content but no last-heard line</div>
        <hr data-v-def>
        </body></html>
        """
        let result = POTAHTMLProbe.checkActivation(in: html, callsign: "KF8CKX")
        guard case .inactive = result else {
            XCTFail("Expected inactive, got \(result)")
            return
        }
    }

    func testLowercaseCallsign_normalizedBeforeSearch() {
        // lowercase callsign is uppercased internally; HTML has no match → notFound
        let result = POTAHTMLProbe.checkActivation(in: "<html><body>nothing</body></html>",
                                                   callsign: "kf8ckx")
        XCTAssertEqual(result, .notFound)
    }

    func testHTMLEntities_decodedBeforeParsing() {
        // &amp; in the HTML should be decoded; callsign still found → not notFound
        let html = "<html><body>KF8CKX &amp; operating</body></html>"
        let result = POTAHTMLProbe.checkActivation(in: html, callsign: "KF8CKX")
        if case .notFound = result {
            XCTFail("Callsign should be found after HTML entity decoding")
        }
    }
}

// MARK: - APSpotSMS

final class APSpotSMSTests: XCTestCase {

    private func makeSMS(
        activator: String = "KF8CKX",
        reference: String = "K-4566",
        frequencyKHz: String = "14074",
        mode: String = "FT8",
        comment: String = ""
    ) -> APSpotSMS {
        APSpotSMS(activator: activator, reference: reference,
                  frequencyKHz: frequencyKHz, mode: mode, comment: comment)
    }

    func testBody_FT8_withComment() {
        XCTAssertEqual(makeSMS(comment: "CQ from summit").body,
                       "!KF8CKX POTA K-4566 14.074 FT8 CQ from summit")
    }

    func testBody_noComment_omitsTrailingPart() {
        XCTAssertEqual(makeSMS().body, "!KF8CKX POTA K-4566 14.074 FT8")
    }

    func testBody_whitespaceOnlyComment_omitted() {
        XCTAssertEqual(makeSMS(comment: "   ").body, "!KF8CKX POTA K-4566 14.074 FT8")
    }

    func testBody_longComment_truncatedTo60Chars() {
        let longComment = String(repeating: "A", count: 80)
        let sms = makeSMS(comment: longComment)
        let commentPart = sms.body.components(separatedBy: " FT8 ").last ?? ""
        XCTAssertEqual(commentPart.count, 60)
    }

    func testBody_exactly60CharComment_notTruncated() {
        let comment = String(repeating: "B", count: 60)
        XCTAssertTrue(makeSMS(comment: comment).body.hasSuffix(comment))
    }

    func testBody_digitalVoiceMode_mappedToFM() {
        XCTAssertTrue(makeSMS(mode: "DIGITALVOICE").body.contains(" FM ") ||
                      makeSMS(mode: "DIGITALVOICE").body.hasSuffix(" FM"))
    }

    func testBody_lowercaseActivator_uppercased() {
        XCTAssertTrue(makeSMS(activator: "kf8ckx").body.hasPrefix("!KF8CKX"))
    }

    func testBody_lowercaseReference_uppercased() {
        XCTAssertTrue(makeSMS(reference: "k-4566").body.contains(" K-4566 "))
    }

    func testFreqConversion_40M_CW() {
        XCTAssertTrue(makeSMS(frequencyKHz: "7032", mode: "CW").body.contains(" 7.032 "),
                      "7032 kHz should convert to 7.032 MHz")
    }

    func testFreqConversion_roundNumber_keepOneDecimal() {
        // 7000 kHz → 7.0 MHz (strips trailing zeros but keeps at least one decimal)
        XCTAssertTrue(makeSMS(frequencyKHz: "7000").body.contains(" 7.0 "),
                      "7000 kHz should format as 7.0 MHz")
    }

    func testFreqConversion_14200_trailingZeroStripped() {
        XCTAssertTrue(makeSMS(frequencyKHz: "14200").body.contains(" 14.2 "),
                      "14200 kHz should format as 14.2 MHz")
    }

    func testFreqConversion_invalid_passedThrough() {
        XCTAssertTrue(makeSMS(frequencyKHz: "abc").body.contains(" abc "))
    }
}

// MARK: - POTAUserInfo.initials

final class POTAUserInfoTests: XCTestCase {

    private func makeInfo(name: String?) -> POTAUserInfo {
        POTAUserInfo(sub: "test", name: name, email: nil, pictureURL: nil)
    }

    func testInitials_twoWordName() {
        XCTAssertEqual(makeInfo(name: "Camden Bopp").initials, "CB")
    }

    func testInitials_oneWordName() {
        XCTAssertEqual(makeInfo(name: "Camden").initials, "C")
    }

    func testInitials_threeWordName_onlyFirstTwo() {
        XCTAssertEqual(makeInfo(name: "John Jacob Smith").initials, "JJ")
    }

    func testInitials_nilName_returnsFallback() {
        XCTAssertEqual(makeInfo(name: nil).initials, "?")
    }

    func testInitials_emptyName_returnsFallback() {
        XCTAssertEqual(makeInfo(name: "").initials, "?")
    }

    func testInitials_lowercaseName_uppercased() {
        XCTAssertEqual(makeInfo(name: "john doe").initials, "JD")
    }

    func testInitials_singleCharName() {
        XCTAssertEqual(makeInfo(name: "X").initials, "X")
    }
}

// MARK: - Spot.ageInMinutes

final class SpotAgeTests: XCTestCase {

    func testAgeInMinutes_invalidDate_returnsZero() {
        XCTAssertEqual(makeSpot(spotTime: "not-a-date").ageInMinutes, 0)
    }

    func testAgeInMinutes_futureDate_clampsToZero() {
        XCTAssertEqual(makeSpot(spotTime: "2099-12-31T23:59:59").ageInMinutes, 0)
    }

    func testAgeInMinutes_recentSpot_correctMinutes() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")!
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let twoMinutesAgo = Date().addingTimeInterval(-125)
        let spot = makeSpot(spotTime: formatter.string(from: twoMinutesAgo))
        XCTAssertEqual(spot.ageInMinutes, 2)
    }
}

// MARK: - Spot JSON decoding

final class SpotJSONDecodingTests: XCTestCase {

    func testSpot_decodesFullJSON() throws {
        let json = """
        {
            "spotId": 12345, "activator": "KF8CKX", "frequency": "14074",
            "mode": "FT8", "reference": "K-4566", "name": "Hocking Hills State Park",
            "spotTime": "2026-04-07T03:04:29", "comments": "CQ POTA",
            "spotter": "W1AW", "source": "API", "locationDesc": "Ohio",
            "grid4": "EN80", "grid6": "EN80ab", "latitude": 39.4,
            "longitude": -82.5, "count": 5, "expire": 30
        }
        """.data(using: .utf8)!
        let spot = try JSONDecoder().decode(Spot.self, from: json)
        XCTAssertEqual(spot.spotId, 12345)
        XCTAssertEqual(spot.activator, "KF8CKX")
        XCTAssertEqual(spot.frequency, "14074")
        XCTAssertEqual(spot.reference, "K-4566")
        XCTAssertEqual(spot.expire, 30)
        XCTAssertEqual(spot.name, "Hocking Hills State Park")
    }

    func testSpot_decodesMinimalJSON_optionalsNil() throws {
        let json = """
        {"spotId":1,"activator":"KF8CKX","frequency":"14074","mode":"FT8",
         "reference":"K-1234","spotTime":"2026-04-07T03:04:29"}
        """.data(using: .utf8)!
        let spot = try JSONDecoder().decode(Spot.self, from: json)
        XCTAssertNil(spot.name)
        XCTAssertNil(spot.expire)
        XCTAssertNil(spot.comments)
        XCTAssertNil(spot.latitude)
    }

    func testSpot_decodesArray() throws {
        let json = """
        [
            {"spotId":1,"activator":"K1A","frequency":"7041","mode":"CW",
             "reference":"K-0001","spotTime":"2026-04-07T03:04:29"},
            {"spotId":2,"activator":"K2B","frequency":"14074","mode":"FT8",
             "reference":"K-0002","spotTime":"2026-04-07T04:00:00"}
        ]
        """.data(using: .utf8)!
        let spots = try JSONDecoder().decode([Spot].self, from: json)
        XCTAssertEqual(spots.count, 2)
        XCTAssertEqual(spots[0].mode, "CW")
        XCTAssertEqual(spots[1].activator, "K2B")
    }

    func testSpot_invalidJSON_throws() {
        let json = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(Spot.self, from: json))
    }
}

// MARK: - POTAStats JSON decoding

final class POTAStatsDecodingTests: XCTestCase {

    func testPOTAStats_decodesFullJSON() throws {
        let json = """
        {
            "callsign": "KF8CKX", "name": "Camden Bopp", "gravatar": "abc123hash",
            "activator": {"activations": 10, "parks": 8, "qsos": 250},
            "hunter": {"parks": 42, "qsos": 500},
            "awards": 3, "endorsements": 2
        }
        """.data(using: .utf8)!
        let stats = try JSONDecoder().decode(POTAStats.self, from: json)
        XCTAssertEqual(stats.callsign, "KF8CKX")
        XCTAssertEqual(stats.activator.activations, 10)
        XCTAssertEqual(stats.activator.parks, 8)
        XCTAssertEqual(stats.activator.qsos, 250)
        XCTAssertEqual(stats.hunter.parks, 42)
        XCTAssertEqual(stats.hunter.qsos, 500)
        XCTAssertEqual(stats.awards, 3)
        XCTAssertEqual(stats.gravatar, "abc123hash")
    }

    func testPOTAStats_nullGravatar_decodesAsNil() throws {
        let json = """
        {
            "callsign": "KF8CKX", "name": "X", "gravatar": null,
            "activator": {"activations": 0, "parks": 0, "qsos": 0},
            "hunter": {"parks": 0, "qsos": 0},
            "awards": 0, "endorsements": 0
        }
        """.data(using: .utf8)!
        let stats = try JSONDecoder().decode(POTAStats.self, from: json)
        XCTAssertNil(stats.gravatar)
    }
}

// MARK: - TokenResponse JSON decoding

final class TokenResponseDecodingTests: XCTestCase {

    func testTokenResponse_decodesSnakeCaseKeys() throws {
        let json = """
        {"access_token":"access123","id_token":"id456","refresh_token":"refresh789"}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(TokenResponse.self, from: json)
        XCTAssertEqual(response.accessToken, "access123")
        XCTAssertEqual(response.idToken, "id456")
        XCTAssertEqual(response.refreshToken, "refresh789")
    }

    func testTokenResponse_missingRefreshToken_decodesAsNil() throws {
        let json = """
        {"access_token":"a","id_token":"b"}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(TokenResponse.self, from: json)
        XCTAssertNil(response.refreshToken)
    }
}

// MARK: - POTAActivationState.displayMessage

final class ActivationStateDisplayTests: XCTestCase {

    func testDisplayMessage_active_allFields_joinedWithSeparator() {
        let record = ActivationRecord(callsign: "KF8CKX", park: "K-4566",
                                      frequency: "14074 kHz", lastHeard: "Last heard 5 min ago",
                                      comment: nil)
        let msg = POTAActivationState.active(record).displayMessage
        XCTAssertTrue(msg.contains("Confirmed on pota.app"))
        XCTAssertTrue(msg.contains("K-4566"))
        XCTAssertTrue(msg.contains("14074 kHz"))
        XCTAssertTrue(msg.contains("Last heard 5 min ago"))
        XCTAssertTrue(msg.contains(" · "), "Parts should be separated by ·")
    }

    func testDisplayMessage_active_nilOptionals_noSeparators() {
        let record = ActivationRecord(callsign: "KF8CKX", park: nil,
                                      frequency: nil, lastHeard: nil, comment: nil)
        XCTAssertEqual(POTAActivationState.active(record).displayMessage,
                       "Confirmed on pota.app")
    }

    func testDisplayMessage_inactive_includesReason() {
        let msg = POTAActivationState.inactive(reason: "not in list yet").displayMessage
        XCTAssertTrue(msg.contains("not in list yet"))
    }

    func testDisplayMessage_notFound_nonEmpty() {
        XCTAssertFalse(POTAActivationState.notFound.displayMessage.isEmpty)
    }

    func testDisplayMessage_parseError_nonEmpty() {
        XCTAssertFalse(POTAActivationState.parseError("network failure").displayMessage.isEmpty)
    }
}

// MARK: - POTAHunterLogScraper parsing

// @MainActor: POTAHunterLogScraper's parsers are main-actor-isolated under Xcode 27's
// Swift 6 checking, so the test case must be too.
@MainActor
final class HunterLogParsingTests: XCTestCase {

    func testExtractParkRef_simpleK() {
        XCTAssertEqual(POTAHunterLogScraper.extractParkRef(from: "K-1234"), "K-1234")
    }

    func testExtractParkRef_multiCharPrefix() {
        XCTAssertEqual(POTAHunterLogScraper.extractParkRef(from: "US-1234"), "US-1234")
        XCTAssertEqual(POTAHunterLogScraper.extractParkRef(from: "JP-1918"), "JP-1918")
        XCTAssertEqual(POTAHunterLogScraper.extractParkRef(from: "VE-BC-0001"), "VE-BC-0001")
    }

    func testExtractParkRef_embeddedInText() {
        XCTAssertEqual(POTAHunterLogScraper.extractParkRef(from: "Hunted at K-4566 last week"),
                       "K-4566")
    }

    func testExtractParkRef_lowercase_uppercased() {
        XCTAssertEqual(POTAHunterLogScraper.extractParkRef(from: "k-1234"), "K-1234")
    }

    func testExtractParkRef_nil_returnsNil() {
        XCTAssertNil(POTAHunterLogScraper.extractParkRef(from: nil))
    }

    func testExtractParkRef_noMatch_returnsNil() {
        XCTAssertNil(POTAHunterLogScraper.extractParkRef(from: "hello world"))
        XCTAssertNil(POTAHunterLogScraper.extractParkRef(from: ""))
    }

    func testParseLogbookRefs_typedResponse() {
        let json = """
        {"count":2,"entries":[{"reference":"K-1234"},{"reference":"K-5678"}]}
        """.data(using: .utf8)!
        let refs = POTAHunterLogScraper.parseLogbookRefs(from: json)
        XCTAssertEqual(Set(refs ?? []), ["K-1234", "K-5678"])
    }

    func testParseLogbookRefs_rawArrayFallback() {
        let json = """
        [{"reference":"K-1234"},{"parkRef":"US-5678"},{"park":"JP-1918"}]
        """.data(using: .utf8)!
        let refs = POTAHunterLogScraper.parseLogbookRefs(from: json)
        XCTAssertNotNil(refs)
        XCTAssertTrue(refs?.contains("K-1234") == true)
        XCTAssertTrue(refs?.contains("US-5678") == true)
        XCTAssertTrue(refs?.contains("JP-1918") == true)
    }

    func testParseLogbookRefs_emptyEntries_returnsEmptyArray() {
        let json = """
        {"count":0,"entries":[]}
        """.data(using: .utf8)!
        let refs = POTAHunterLogScraper.parseLogbookRefs(from: json)
        XCTAssertEqual(refs, [])
    }

    func testParseLogbookRefs_invalidJSON_returnsNil() {
        XCTAssertNil(POTAHunterLogScraper.parseLogbookRefs(from: "not json".data(using: .utf8)!))
    }
}

// MARK: - ParkIndex CSV parsing

final class ParkIndexParsingTests: XCTestCase {

    // MARK: parseRow

    func testParseRow_simpleFields() {
        let fields = ParkIndex.parseRow("K-1234,Hocking Hills,1,5,Ohio,39.4,-82.5,EN80")
        XCTAssertEqual(fields, ["K-1234", "Hocking Hills", "1", "5", "Ohio", "39.4", "-82.5", "EN80"])
    }

    func testParseRow_quotedFieldContainingComma() {
        let fields = ParkIndex.parseRow(#"K-1234,"Hocking Hills, State Park",1,5,Ohio,39.4,-82.5,EN80"#)
        XCTAssertEqual(fields[1], "Hocking Hills, State Park")
    }

    func testParseRow_escapedQuotesInsideField() {
        let fields = ParkIndex.parseRow(#"K-1234,"Park ""A"" Reserve",1,5,Ohio,39.4,-82.5,EN80"#)
        XCTAssertEqual(fields[1], #"Park "A" Reserve"#)
    }

    // MARK: parseCSV

    private func csv(_ body: String) -> Data {
        "reference,name,active,parkTypeId,locationDesc,latitude,longitude,grid\n\(body)"
            .data(using: .utf8)!
    }

    func testParseCSV_headerSkipped_oneRecord() {
        let records = ParkIndex.parseCSV(csv("K-1234,Hocking Hills,1,5,Ohio,39.4,-82.5,EN80"))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].reference, "K-1234")
        XCTAssertEqual(records[0].name, "Hocking Hills")
    }

    func testParseCSV_activeFlag_parsedCorrectly() {
        let records = ParkIndex.parseCSV(csv("""
        K-1234,Active Park,1,5,Ohio,39.4,-82.5,EN80
        K-5678,Inactive Park,0,5,Ohio,39.5,-82.5,EN80
        """))
        XCTAssertTrue(records[0].active)
        XCTAssertFalse(records[1].active)
    }

    func testParseCSV_invalidCoordinates_rowSkipped() {
        let records = ParkIndex.parseCSV(csv("""
        K-1234,Bad Coords,1,5,Ohio,not-a-number,-82.5,EN80
        K-5678,Good Coords,1,5,Ohio,39.4,-82.5,EN80
        """))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].reference, "K-5678")
    }

    func testParseCSV_coordinatesStoredCorrectly() {
        let records = ParkIndex.parseCSV(csv("K-1234,Park,1,5,Ohio,39.456,-82.123,EN80"))
        XCTAssertEqual(records[0].latitude, 39.456, accuracy: 0.001)
        XCTAssertEqual(records[0].longitude, -82.123, accuracy: 0.001)
    }

    func testParseCSV_emptyData_returnsEmpty() {
        XCTAssertTrue(ParkIndex.parseCSV(Data()).isEmpty)
    }

    // MARK: search

    private func park(_ ref: String, name: String) -> ParkRecord {
        ParkRecord(reference: ref, name: name, active: true,
                   locationDesc: "", latitude: 0, longitude: 0, grid: "")
    }

    func testSearch_matchesByName() {
        let parks = [park("K-1234", name: "Hocking Hills"), park("K-5678", name: "Blue Ridge")]
        let results = ParkIndex.search(parks, query: "hocking")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].reference, "K-1234")
    }

    func testSearch_matchesByReference() {
        let parks = [park("K-1234", name: "Alpha"), park("K-5678", name: "Beta")]
        let results = ParkIndex.search(parks, query: "K-5678")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].name, "Beta")
    }

    func testSearch_caseInsensitive() {
        let parks = [park("K-1234", name: "Hocking Hills")]
        XCTAssertEqual(ParkIndex.search(parks, query: "HOCKING").count, 1)
        XCTAssertEqual(ParkIndex.search(parks, query: "hOcKiNg").count, 1)
    }

    func testSearch_prefixMatchesRankedBeforeSubstringMatches() {
        let parks = [
            park("K-1", name: "Big Hocking Park"),   // substring match
            park("K-2", name: "Hocking Hills"),       // prefix match
            park("K-3", name: "Hocking Valley"),      // prefix match
        ]
        let results = ParkIndex.search(parks, query: "hocking")
        XCTAssertEqual(results[0].reference, "K-2", "Prefix match should rank first (alphabetical)")
        XCTAssertEqual(results[1].reference, "K-3")
        XCTAssertEqual(results[2].reference, "K-1", "Substring match should rank last")
    }

    func testSearch_prefixMatchesSortedAlphabetically() {
        let parks = [
            park("K-3", name: "Hocking Zoo"),
            park("K-1", name: "Hocking Hills"),
            park("K-2", name: "Hocking Meadows"),
        ]
        let results = ParkIndex.search(parks, query: "hocking")
        XCTAssertEqual(results.map(\.name), ["Hocking Hills", "Hocking Meadows", "Hocking Zoo"])
    }

    func testSearch_capsResultsAtEight() {
        let parks = (1...12).map { park("K-\($0)", name: "Park \($0)") }
        XCTAssertEqual(ParkIndex.search(parks, query: "park").count, 8)
    }

    func testSearch_noMatches_returnsEmpty() {
        let parks = [park("K-1234", name: "Hocking Hills")]
        XCTAssertTrue(ParkIndex.search(parks, query: "zzzz").isEmpty)
    }

    func testSearch_emptyQuery_matchesEverything() {
        let parks = (1...10).map { park("K-\($0)", name: "Park \($0)") }
        XCTAssertEqual(ParkIndex.search(parks, query: "").count, 8)
    }
}

// MARK: - APSpotSMS.phoneNumber

final class APSpotPhoneNumberTests: XCTestCase {

    func testPhoneNumber_returnsKnownNumber() {
        let known: Set<String> = ["+18668705797", "+18678772605", "+61489905884"]
        XCTAssertTrue(known.contains(APSpotSMS.phoneNumber),
                      "phoneNumber '\(APSpotSMS.phoneNumber)' is not in the known set")
    }
}
