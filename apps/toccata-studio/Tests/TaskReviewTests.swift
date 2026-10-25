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
}
