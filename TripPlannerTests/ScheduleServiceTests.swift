import XCTest
@testable import TripPlanner

final class ScheduleServiceTests: XCTestCase {
    private func date(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: hour, minute: minute))!
    }

    func testOnTimeHasNoLateness() {
        let items = [ScheduleItem(planned: date(10, 0), durationMinutes: 60)]
        XCTAssertNil(ScheduleService.lateness(items: items, now: date(9, 30)))
    }

    func testLatenessUsesFirstPlannedStop() {
        let items = [
            ScheduleItem(planned: nil, durationMinutes: 30),
            ScheduleItem(planned: date(10, 0), durationMinutes: 60),
        ]
        XCTAssertEqual(ScheduleService.lateness(items: items, now: date(10, 40)), 40 * 60)
    }

    func testReflowShiftsOverlappingStops() {
        let items = [
            ScheduleItem(planned: date(10, 0), durationMinutes: 60),
            ScheduleItem(planned: date(11, 30), durationMinutes: 30),
        ]
        let proposals = ScheduleService.reflow(items: items, now: date(10, 40))
        XCTAssertEqual(proposals, [
            ScheduleProposal(index: 0, newTime: date(10, 40)),
            ScheduleProposal(index: 1, newTime: date(11, 50)),
        ])
    }

    func testReflowKeepsStopsThatStillFit() {
        let items = [
            ScheduleItem(planned: date(10, 0), durationMinutes: 30),
            ScheduleItem(planned: date(14, 0), durationMinutes: 60),
        ]
        let proposals = ScheduleService.reflow(items: items, now: date(10, 20))
        XCTAssertEqual(proposals, [ScheduleProposal(index: 0, newTime: date(10, 20))])
    }

    func testStopsWithoutTimeStillTakeUpTime() {
        let items = [
            ScheduleItem(planned: nil, durationMinutes: 60),
            ScheduleItem(planned: date(10, 30), durationMinutes: 30),
        ]
        // Cursor after the first stop: 10:00 + 60 + 10 = 11:10, so the second stop must move.
        let proposals = ScheduleService.reflow(items: items, now: date(10, 0))
        XCTAssertEqual(proposals, [ScheduleProposal(index: 1, newTime: date(11, 10))])
    }

    func testRoundUp() {
        let rounded = ScheduleService.roundUp(date(10, 41))
        XCTAssertEqual(rounded, date(10, 45))
    }

    func testAutoScheduleAddsTravelAndSlack() {
        let items = [
            ScheduleService.AutoItem(durationMinutes: 60, travelMinutes: 0),
            ScheduleService.AutoItem(durationMinutes: 30, travelMinutes: 12),
            ScheduleService.AutoItem(durationMinutes: 45, travelMinutes: 20),
        ]
        let times = ScheduleService.autoSchedule(items: items, start: date(9, 0))
        // 9:00 + 60 = 10:00; + 12 travel + 5 slack = 10:17 -> 10:20; + 30 = 10:50; + 25 = 11:15.
        XCTAssertEqual(times, [date(9, 0), date(10, 20), date(11, 15)])
    }

    func testAutoScheduleEmpty() {
        XCTAssertEqual(ScheduleService.autoSchedule(items: [], start: date(9, 0)), [])
    }
}
