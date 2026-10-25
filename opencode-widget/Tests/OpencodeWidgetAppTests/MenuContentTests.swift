import XCTest
@testable import OpencodeWidgetApp
@testable import OpencodeWidgetShared

@MainActor
final class MenuContentTests: XCTestCase {
    func testDualRowsAreIndependentAndFiveHourComesFirst() {
        let weekReset = Date(timeIntervalSince1970: 1_800_000_000)
        let fiveReset = weekReset.addingTimeInterval(-100_000)
        let quota = OpenAIQuota(remainingPercent: 25, resetDate: weekReset, fiveHourRemainingPercent: 80, fiveHourResetDate: fiveReset)
        let rows = MenuContent.quotaRows(quota)
        XCTAssertEqual(rows.map(\.label), ["5h", "Weekly"])
        XCTAssertEqual(rows.map(\.cycleHours), [5, 168])
        XCTAssertEqual(rows.map(\.remainingPercent), [80, 25])
        XCTAssertEqual(rows.map(\.resetDate), [fiveReset, weekReset])
        let missing = MenuContent.quotaRows(OpenAIQuota(remainingPercent: 25))
        XCTAssertNil(missing[0].remainingPercent)
        XCTAssertEqual(missing[1].remainingPercent, 25)
    }

    func testFiveHourResetNeverChangesWeeklyEstimateAnchor() {
        var anchors: [Date] = []
        let state = MenuBarState(estimatedCost: { anchors.append($0); return 12 })
        let week = Date(timeIntervalSince1970: 1_800_000_000)
        for reset in [week.addingTimeInterval(-18000), week.addingTimeInterval(-9000)] {
            let quota = OpenAIQuota(remainingPercent: 40, resetDate: week, fiveHourRemainingPercent: 60, fiveHourResetDate: reset)
            state.update(with: WidgetCache(openAIQuota: quota))
            XCTAssertEqual(state.openAIQuota, quota)
            XCTAssertEqual(state.openAIEstimatedCost, 12)
        }
        state.update(with: WidgetCache(openAIQuota: OpenAIQuota(fiveHourRemainingPercent: 90, fiveHourResetDate: week)))
        XCTAssertEqual(anchors, [week, week])
        XCTAssertNil(state.openAIEstimatedCost)
    }

    func testUnavailableBarHasNeitherUsageFillNorInventedMarker() {
        let bar = QuotaResetBar(remainingPercent: nil, resetDate: nil, cycleHours: 5)
        XCTAssertNil(bar.usedFraction)
        XCTAssertNil(bar.markerFraction(at: Date()))
        XCTAssertEqual(QuotaResetBar(remainingPercent: 100, resetDate: nil).usedFraction, 0)
        XCTAssertNil(QuotaResetBar(remainingPercent: .nan, resetDate: nil).usedFraction)
    }
    func testQuotaTextShowsRemainingPercentage() {
        XCTAssertEqual(MenuContent.quotaText(OpenAIQuota(remainingPercent: 97)), "97% remaining")
    }

    func testQuotaTextShowsUnavailableWhenMissing() {
        XCTAssertEqual(MenuContent.quotaText(nil), "Quota unavailable")
    }

    func testResetTextShowsMonthAndDay() {
        let date = Date(timeIntervalSince1970: 1_784_764_800)
        let localDate = date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        XCTAssertEqual(MenuContent.resetText(date), "Resets " + localDate)
    }

    func testResetTextIsEmptyWhenMissing() {
        XCTAssertEqual(MenuContent.resetText(nil), "")
    }

    func testEstimatedCostTextUsesEstimateLabel() {
        XCTAssertEqual(MenuContent.estimatedCostText(12.345), "Est. $12.35")
        XCTAssertEqual(MenuContent.estimatedCostText(0), "Est. $0.00")
        XCTAssertEqual(MenuContent.estimatedCostText(nil), "Est. unavailable")
    }

    func testMenuBarStateClearsUnanchoredEstimateWhenResetDateMissing() {
        let state = MenuBarState(estimatedCost: { _ in 42.0 })
        state.update(with: WidgetCache(openAIQuota: OpenAIQuota(remainingPercent: 50, resetDate: Date(timeIntervalSince1970: 2_000_000_000))))
        XCTAssertEqual(state.openAIEstimatedCost, 42.0)

        state.update(with: WidgetCache(openAIQuota: OpenAIQuota(remainingPercent: 50, resetDate: nil)))
        XCTAssertNil(state.openAIEstimatedCost)
    }

    func testMenuBarStateShowsUnavailableEstimateWhenNeverComputed() {
        let state = MenuBarState()
        state.update(with: WidgetCache(openAIQuota: OpenAIQuota(remainingPercent: 50, resetDate: nil)))
        XCTAssertNil(state.openAIEstimatedCost)
        XCTAssertEqual(MenuContent.estimatedCostText(state.openAIEstimatedCost), "Est. unavailable")
    }

    func testMenuBarStateUpdateKeepsDeepSeekBalanceHistory() {
        let state = MenuBarState()
        let history = [DeepSeekBalanceSnapshot(hour: Date(timeIntervalSince1970: 3_600), remainingRM: 45)]

        state.update(with: WidgetCache(deepseekBalanceHistory: history))

        XCTAssertEqual(state.deepseekBalanceHistory, history)
    }

    func testPreviousOffsetMovesBackOneDayWithoutExceedingHistory() {
        XCTAssertEqual(MenuContent.previousOffset(current: 0, historyCount: 720), 24)
        XCTAssertEqual(MenuContent.previousOffset(current: 552, historyCount: 720), 552)
    }

    func testNextOffsetMovesTowardLiveWindow() {
        XCTAssertEqual(MenuContent.nextOffset(current: 24), 0)
        XCTAssertEqual(MenuContent.nextOffset(current: 0), 0)
    }
}
