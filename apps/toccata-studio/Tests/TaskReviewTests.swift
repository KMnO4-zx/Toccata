import Foundation
import XCTest
@testable import toccata_studio

final class TaskReviewTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 1
        return calendar
    }

    private func date(_ day: Int, month: Int = 10, hour: Int = 12, minute: Int = 0,
                      calendar suppliedCalendar: Calendar? = nil) -> Date {
        (suppliedCalendar ?? calendar).date(from: DateComponents(
            year: 2026, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func task(_ id: String, title: String? = nil, parent: String? = nil, details: String = "",
                      created: Date? = nil, planned: Date? = nil, completed: Date? = nil) -> TodoTask {
        let createdAt = created ?? date(1)
        return TodoTask(id: id, parentID: parent, title: title ?? id, details: details,
                        plannedDate: planned, createdAt: createdAt, updatedAt: completed ?? createdAt,
                        completedAt: completed)
    }

    private func snapshot(_ tasks: [TodoTask], period: TaskReviewPeriod = .thisWeek,
                          now: Date? = nil, query: String = "") -> TaskReviewSnapshot {
        TaskReviewSnapshot(tasks: tasks, period: period, referenceDate: now ?? date(21),
                           calendar: calendar, query: query)
    }

    func testPendingKeepsCarryoverAndIgnoresPlannedDatesButExcludesFutureTasks() {
        let tasks = [
            task("old-undated"), task("planned-past", planned: date(2)),
            task("planned-future", planned: date(30)), task("new", created: date(21)),
            task("future-created", created: date(22)),
            task("future-created-done", created: date(22), completed: date(20)),
            task("done-last-week", completed: date(18)),
            task("done-future", completed: date(22)), task("done-now", completed: date(21))
        ]
        let review = snapshot(tasks)
        XCTAssertEqual(review.pending.map(\.id), ["new", "old-undated", "planned-future", "planned-past"])
        XCTAssertEqual(review.completed.map(\.id), ["done-now"])
        XCTAssertEqual(Set(review.tasks.map(\.id)), Set(review.pending.map(\.id) + ["done-now"]))
    }

    func testCompletedBoundariesIncludeMondayMidnightAndNow() {
        let monday = date(19, hour: 0)
        let now = date(21, hour: 15)
        let review = snapshot([
            task("before", completed: monday.addingTimeInterval(-1)),
            task("start", completed: monday), task("now", completed: now),
            task("after", completed: now.addingTimeInterval(1))
        ], now: now)
        XCTAssertEqual(review.completed.map(\.id), ["now", "start"])
        XCTAssertEqual(review.dateLabel, "2026-10-19 — 2026-10-21")
    }

    func testSundayAndMondayWindowsKeepPendingAndUseActualCompletion() {
        let tasks = [task("carryover"), task("monday-19", completed: date(19, hour: 0)),
                     task("tuesday-20", completed: date(20, hour: 0)),
                     task("sunday-25", completed: date(25)), task("monday-26", completed: date(26, hour: 0))]
        let sunday = snapshot(tasks, now: date(25, hour: 23))
        XCTAssertEqual(sunday.completed.map(\.id), ["sunday-25", "tuesday-20", "monday-19"])
        XCTAssertEqual(sunday.pending.map(\.id), ["carryover"])
        let monday = snapshot(tasks, now: date(26, hour: 0))
        XCTAssertEqual(monday.completed.map(\.id), ["monday-26"])
        XCTAssertEqual(monday.pending.map(\.id), ["carryover"])
        let lastSeven = snapshot(tasks, period: .lastSevenDays, now: date(26, hour: 0))
        XCTAssertEqual(lastSeven.completed.map(\.id), ["monday-26", "sunday-25", "tuesday-20"])
        XCTAssertEqual(lastSeven.dateLabel, "2026-10-20 — 2026-10-26")
        XCTAssertEqual(lastSeven.title, "最近 7 天任务回顾")
    }

    func testSortIsDeterministicForEqualDatesAndNewestFirst() {
        let tasks = [task("z", created: date(20)), task("old"), task("a", created: date(20)),
                     task("done-z", completed: date(20)), task("done-old", completed: date(19)),
                     task("done-a", completed: date(20))]
        for input in [tasks, tasks.reversed().map { $0 }] {
            let review = snapshot(input)
            XCTAssertEqual(review.pending.map(\.id), ["a", "z", "old"])
            XCTAssertEqual(review.completed.map(\.id), ["done-a", "done-z", "done-old"])
        }
    }

    func testLocalMidnightAndDSTAreRespectedBySelectionAndExport() {
        var losAngeles = calendar
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = date(26, hour: 0, calendar: losAngeles)
        let now = date(1, month: 11, hour: 12, calendar: losAngeles)
        let review = TaskReviewSnapshot(tasks: [
            task("before", completed: start.addingTimeInterval(-1)),
            task("start", completed: start), task("now", completed: now)
        ], period: .lastSevenDays, referenceDate: now, calendar: losAngeles)
        XCTAssertEqual(review.completed.map(\.id), ["now", "start"])
        XCTAssertEqual(review.dateLabel, "2026-10-26 — 2026-11-01")
        XCTAssertTrue(review.markdown.contains("完成于 2026-10-26 00:00"))
        XCTAssertTrue(review.markdown.contains("完成于 2026-11-01 12:00"))
    }

    func testUndoCompletionMovesTaskToPendingWithoutLosingItsDetails() {
        let original = task("retained", details: "下次接着做\n保留上下文", completed: date(20))
        let before = snapshot([original])
        XCTAssertEqual(before.completed.map(\.id), [original.id])
        let reopened = task(original.id, details: original.details, created: original.createdAt)
        let after = snapshot([reopened])
        XCTAssertTrue(after.completed.isEmpty)
        XCTAssertEqual(after.pending.map(\.id), [original.id])
        XCTAssertTrue(after.markdown.contains("- [ ] retained"))
        XCTAssertTrue(after.markdown.contains("  下次接着做\n  保留上下文"))
    }

    func testExportIncludesEachVisibleTaskOnceWithParentContextAndMultilineDetails() {
        let parent = task("parent", title: "实验项目", details: "父任务说明", planned: date(30))
        let child = task("child", title: "整理结果", parent: parent.id,
                         details: "## 观察\n\n- **结果 A**\n```swift\nlet n = 2\n```", completed: date(20))
        let review = snapshot([child, parent])
        let entries = review.markdown.components(separatedBy: "\n").filter { $0.hasPrefix("- [") }
        XCTAssertEqual(entries.count, review.tasks.count)
        XCTAssertEqual(entries.filter { $0.contains("整理结果") }.count, 1)
        XCTAssertTrue(review.markdown.hasPrefix("# 本周任务回顾\n\n2026-10-19 — 2026-10-21"))
        XCTAssertTrue(review.markdown.contains("已完成 1 项 · 未完成 1 项（含子任务）"))
        XCTAssertTrue(review.markdown.contains("- [x] 实验项目 / 整理结果（完成于 2026-10-20 12:00）"))
        XCTAssertTrue(review.markdown.contains("- [ ] 实验项目（创建于 2026-10-01 12:00 · 计划 2026-10-30）"))
        XCTAssertTrue(review.markdown.contains("  ## 观察\n  \n  - **结果 A**\n  ```swift\n  let n = 2\n  ```"))
        XCTAssertEqual(review.parentTitle(for: child), "实验项目")
        XCTAssertNil(review.parentTitle(for: parent))
    }

    func testSearchFindsParentContextAndMatchingChildWithoutUnrelatedSiblings() {
        let tasks = [task("parent", title: "Project Alpha"),
                     task("match", title: "资料", parent: "parent", details: "需要对照 TOKEN 统计", completed: date(20)),
                     task("sibling", title: "部署", parent: "parent"),
                     task("unrelated", title: "Project Beta")]
        let childSearch = snapshot(tasks, query: " token ")
        XCTAssertEqual(Set(childSearch.tasks.map(\.id)), ["parent", "match"])
        XCTAssertFalse(childSearch.markdown.contains("部署"))
        XCTAssertFalse(childSearch.markdown.contains("Project Beta"))
        XCTAssertEqual(childSearch.markdown.components(separatedBy: "\n").filter { $0.hasPrefix("- [") }.count, 2)
        let parentSearch = snapshot(tasks, query: "alpha")
        XCTAssertEqual(Set(parentSearch.tasks.map(\.id)), ["parent", "match", "sibling"])
    }

    func testOldCompletedChildCannotPullParentIntoSearchButParentContextRemainsAvailable() {
        let tasks = [task("pending-parent", title: "当前项目"),
                     task("old-child", title: "ARCHIVED", parent: "pending-parent", completed: date(1)),
                     task("old-parent", title: "历史项目", completed: date(1)),
                     task("current-child", title: "修订", parent: "old-parent", completed: date(20))]
        XCTAssertTrue(snapshot(tasks, query: "archived").tasks.isEmpty)
        let review = snapshot(tasks, query: "历史项目")
        XCTAssertEqual(review.tasks.map(\.id), ["current-child"])
        XCTAssertTrue(review.markdown.contains("历史项目 / 修订"))
        XCTAssertEqual(review.markdown.components(separatedBy: "\n").filter { $0.hasPrefix("- [") }.count, 1)
    }

    func testEmptyAndUnmatchedExportKeepBothSectionsAndAccurateCounts() {
        for review in [snapshot([]), snapshot([task("only")], query: "missing")] {
            XCTAssertTrue(review.tasks.isEmpty)
            XCTAssertTrue(review.markdown.contains("已完成 0 项 · 未完成 0 项（含子任务）"))
            XCTAssertTrue(review.markdown.contains("## 已完成\n\n暂无已完成任务。"))
            XCTAssertTrue(review.markdown.contains("## 未完成\n\n暂无未完成任务。"))
            XCTAssertFalse(review.markdown.contains("- ["))
        }
    }

    func testTitlesStayLiteralOneLineWhileDetailsRemainMarkdown() {
        let review = snapshot([task("literal", title: "[标题]\n# 第二行", details: "**保留格式**")])
        XCTAssertTrue(review.markdown.contains("- [ ] \\[标题\\] \\# 第二行"))
        XCTAssertTrue(review.markdown.contains("  **保留格式**"))
        XCTAssertEqual(review.markdown.components(separatedBy: "\n").filter { $0.hasPrefix("- [") }.count, 1)
    }

    func testCustomSingleDayIncludesItsLastMillisecondButNotTheNextMidnight() {
        let start = date(20, hour: 0)
        let nextDay = date(21, hour: 0)
        let selected = CalendarDateRange(start: date(20, hour: 10), end: date(20, hour: 16), calendar: calendar)
        let review = TaskReviewSnapshot(tasks: [
            task("before", completed: start.addingTimeInterval(-0.001)),
            task("start", completed: start),
            task("last", completed: nextDay.addingTimeInterval(-0.001)),
            task("next", completed: nextDay)
        ], range: .custom(selected), referenceDate: date(26), calendar: calendar)

        XCTAssertEqual(review.completed.map(\.id), ["last", "start"])
        XCTAssertEqual(review.dateLabel, "2026-10-20 — 2026-10-20")
        XCTAssertEqual(review.title, "自定义时段任务回顾")
        XCTAssertTrue(review.markdown.contains("完成于 2026-10-20 23:59"))
        XCTAssertFalse(review.markdown.contains("- [x] next"))
    }

    func testCustomReversedCrossYearRangeAndExportAgree() {
        let first = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31))!
        let nextDay = calendar.date(from: DateComponents(year: 2027, month: 1, day: 3))!
        let selectedEnd = calendar.date(from: DateComponents(year: 2027, month: 1, day: 2, hour: 18))!
        let review = TaskReviewSnapshot(tasks: [
            task("before", completed: first.addingTimeInterval(-1)),
            task("start", completed: first),
            task("last", completed: nextDay.addingTimeInterval(-0.001)),
            task("after", completed: nextDay)
        ], range: .custom(CalendarDateRange(start: selectedEnd, end: first, calendar: calendar)),
            referenceDate: nextDay.addingTimeInterval(3600), calendar: calendar)

        XCTAssertEqual(review.completed.map(\.id), ["last", "start"])
        XCTAssertEqual(review.dateLabel, "2026-12-31 — 2027-01-02")
        XCTAssertTrue(review.markdown.hasPrefix("# 自定义时段任务回顾\n\n2026-12-31 — 2027-01-02"))
        XCTAssertTrue(review.markdown.contains("已完成 2 项 · 未完成 0 项"))
    }

    func testCustomPastRangeStillIncludesCurrentPendingAndExcludesOutsideCompletions() {
        let selected = CalendarDateRange(start: date(10), end: date(12), calendar: calendar)
        let review = TaskReviewSnapshot(tasks: [
            task("carryover"), task("planned-future", planned: date(30)),
            task("created-after-range", created: date(25)),
            task("created-in-future", created: date(27)),
            task("done-in-range", completed: date(11)),
            task("done-after-range", completed: date(20)), task("done-before-range", completed: date(9))
        ], range: .custom(selected), referenceDate: date(26), calendar: calendar)

        XCTAssertEqual(review.pending.map(\.id), ["created-after-range", "carryover", "planned-future"])
        XCTAssertEqual(review.completed.map(\.id), ["done-in-range"])
        XCTAssertEqual(review.tasks.count, 4)
        XCTAssertTrue(review.markdown.contains("已完成 1 项 · 未完成 3 项"))
    }

    func testCustomRangeNeverIncludesFutureCompletionsEvenIfTheSelectedEndIsFuture() {
        let now = date(21, hour: 15)
        let selected = CalendarDateRange(start: date(19), end: date(25), calendar: calendar)
        let review = TaskReviewSnapshot(tasks: [
            task("now", completed: now), task("future", completed: now.addingTimeInterval(0.001))
        ], range: .custom(selected), referenceDate: now, calendar: calendar)

        XCTAssertEqual(review.completed.map(\.id), ["now"])
        XCTAssertEqual(review.dateLabel, "2026-10-19 — 2026-10-25")
    }

    func testCustomDSTEndDatesDoNotLoseOrAddAnHourOfCompletions() {
        var local = calendar
        local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for (month, day) in [(3, 8), (11, 1)] {
            let start = date(day, month: month, hour: 0, calendar: local)
            let nextDay = date(day + 1, month: month, hour: 0, calendar: local)
            let review = TaskReviewSnapshot(tasks: [
                task("start", created: start, completed: start),
                task("last", created: start, completed: nextDay.addingTimeInterval(-0.001)),
                task("next", created: start, completed: nextDay),
                task("next-half-hour", created: start, completed: nextDay.addingTimeInterval(1800))
            ], range: .custom(CalendarDateRange(start: start, end: start, calendar: local)),
                referenceDate: nextDay.addingTimeInterval(3600), calendar: local)

            XCTAssertEqual(review.completed.map(\.id), ["last", "start"])
            XCTAssertEqual(review.dateLabel, month == 3 ? "2026-03-08 — 2026-03-08" : "2026-11-01 — 2026-11-01")
        }
    }

    func testCustomSearchAndExportKeepParentContextOutsideTheSelectedRange() {
        let selected = CalendarDateRange(start: date(20), end: date(20), calendar: calendar)
        let review = TaskReviewSnapshot(tasks: [
            task("parent", title: "Project Alpha", completed: date(5)),
            task("matching-child", title: "整理资料", parent: "parent", details: "**结论**\n保留说明", completed: date(20)),
            task("outside-child", title: "部署", parent: "parent", completed: date(22)),
            task("unrelated", title: "Project Beta")
        ], range: .custom(selected), referenceDate: date(26), calendar: calendar, query: "alpha")

        XCTAssertEqual(review.tasks.map(\.id), ["matching-child"])
        XCTAssertTrue(review.markdown.contains("- [x] Project Alpha / 整理资料"))
        XCTAssertTrue(review.markdown.contains("  **结论**\n  保留说明"))
        XCTAssertFalse(review.markdown.contains("部署"))
        XCTAssertFalse(review.markdown.contains("Project Beta"))
        XCTAssertEqual(review.markdown.components(separatedBy: "\n").filter { $0.hasPrefix("- [") }.count, 1)
    }

    func testReviewNestsEachChildUnderItsParentWithoutChangingActualCounts() {
        let all = [
            task("first", created: date(19)),
            task("first-child-a", parent: "first", created: date(20)),
            task("first-child-b", parent: "first", created: date(21)),
            task("second", created: date(20)),
            task("second-child-a", parent: "second", created: date(20)),
            task("second-child-b", parent: "second", created: date(21))
        ]
        let review = snapshot(all)
        let rows = WorkspaceTaskListSnapshot.rows(from: review.pendingRoots)

        XCTAssertEqual(rows.map(\.id), ["second", "second-child-b", "second-child-a",
                                       "first", "first-child-b", "first-child-a"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 0, 1, 1])
        XCTAssertEqual(review.pending.count, 6)
        XCTAssertEqual(review.pendingRoots.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)).count, 6)
    }

    func testCompletedChildStaysWithPendingParentAndKeepsItsActualStatus() {
        let review = snapshot([
            task("parent"), task("pending-child", parent: "parent"),
            task("completed-child", parent: "parent", completed: date(20)),
            task("completed-root", completed: date(21))
        ])
        let pendingRows = WorkspaceTaskListSnapshot.rows(from: review.pendingRoots)

        XCTAssertEqual(pendingRows.map(\.id), ["parent", "pending-child", "completed-child"])
        XCTAssertTrue(pendingRows.last!.task.isCompleted)
        XCTAssertEqual(review.completedRoots.map(\.id), ["completed-root"])
        XCTAssertEqual(review.completed.count, 2)
        XCTAssertEqual(review.pending.count, 2)
        let allRows = pendingRows + WorkspaceTaskListSnapshot.rows(from: review.completedRoots)
        XCTAssertEqual(Set(allRows.map(\.id)), Set(review.tasks.map(\.id)))
    }

    func testOldParentIsContextOnlyAndDoesNotPullOutOfRangeSiblingIntoReview() {
        let review = snapshot([
            task("old-parent", completed: date(1)),
            task("current-child", parent: "old-parent", completed: date(20)),
            task("old-sibling", parent: "old-parent", completed: date(2))
        ])
        let rows = WorkspaceTaskListSnapshot.rows(from: review.completedRoots)

        XCTAssertEqual(rows.map(\.id), ["old-parent", "current-child"])
        XCTAssertTrue(rows[0].node.isContextOnly)
        XCTAssertFalse(rows[1].node.isContextOnly)
        XCTAssertEqual(review.tasks.map(\.id), ["current-child"])
        XCTAssertTrue(review.pendingRoots.isEmpty)
        XCTAssertFalse(review.markdown.contains("old-sibling"))
    }

    func testReviewSearchAndCollapseKeepMembershipAndExportStable() {
        let review = snapshot([
            task("parent", title: "科研项目"),
            task("match", title: "制作 PPT", parent: "parent", details: "说明核心结论"),
            task("sibling", title: "无关资料", parent: "parent")
        ], query: "核心结论")
        let before = review.markdown
        let roots = review.pendingRoots

        XCTAssertEqual(WorkspaceTaskListSnapshot.rows(from: roots).map(\.id), ["parent", "match"])
        XCTAssertEqual(WorkspaceTaskListSnapshot.rows(from: roots, collapsedIDs: ["parent"]).map(\.id), ["parent"])
        XCTAssertEqual(Set(review.tasks.map(\.id)), ["parent", "match"])
        XCTAssertEqual(review.markdown, before)
        XCTAssertFalse(review.markdown.contains("无关资料"))
    }

    func testFutureAncestorCannotBeReintroducedAsReviewContext() {
        let review = snapshot([
            task("future-parent", created: date(22)),
            task("current-child", parent: "future-parent", completed: date(20))
        ])

        XCTAssertEqual(WorkspaceTaskListSnapshot.rows(from: review.completedRoots).map(\.id), ["current-child"])
        XCTAssertEqual(review.tasks.map(\.id), ["current-child"])
    }

    func testCompletedGroupsSortByTheirLatestMatchingCompletion() {
        let review = snapshot([
            task("old-parent", completed: date(1)),
            task("recent-child", parent: "old-parent", completed: date(21, hour: 20)),
            task("other-parent", completed: date(21, hour: 12))
        ], now: date(21, hour: 23))

        XCTAssertEqual(review.completedRoots.map(\.id), ["old-parent", "other-parent"])
        XCTAssertEqual(review.completed.count, 2)
    }
}
