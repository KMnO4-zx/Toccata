import AppKit
import Combine
import Foundation
import SQLite3

/// The task database is independent of the keyboard daemon's statistics database.
/// All mutations are transactions; published state changes only after commit succeeds.
@MainActor
final class TaskStore: ObservableObject {
    nonisolated static let defaultURL = AppPaths.supportDirectory.appendingPathComponent("tasks.sqlite", isDirectory: false)

    @Published private(set) var tasks: [TodoTask] = []
    @Published var errorMessage: String?

    private var database: TaskDatabase?
    private let calendar: Calendar
    private let now: () -> Date
    private let completionFeedback: @MainActor () -> Void

    init(databaseURL: URL = TaskStore.defaultURL,
         calendar: Calendar = .current,
         now: @escaping () -> Date = Date.init,
         completionFeedback: @escaping @MainActor () -> Void = {
             TaskCompletionSound.play()
         }) {
        self.calendar = calendar
        self.now = now
        self.completionFeedback = completionFeedback
        do {
            database = try TaskDatabase(url: databaseURL)
            _ = reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func reload() -> Bool {
        do {
            guard let database else { throw TaskStoreError.unavailable }
            tasks = try database.snapshot()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func task(id: String) -> TodoTask? {
        tasks.first { $0.id == id }
    }

    func children(of parentID: String?) -> [TodoTask] {
        let children = tasks.filter { $0.parentID == parentID }
        return parentID == nil ? children : children.sorted(by: SubtaskOrder.precedes)
    }

    /// A move never changes the parent, completion state, or task dates.
    @discardableResult
    func moveSubtask(id: String, relativeTo targetID: String, placement: SubtaskPlacement) -> Bool {
        guard let ids = SubtaskOrder.reorderedIDs(in: tasks, moving: id,
                                                 relativeTo: targetID, placement: placement),
              let source = task(id: id) else { return false }
        let currentIDs = children(of: source.parentID).filter {
            $0.isCompleted == source.isCompleted
        }.map(\.id)
        if currentIDs == ids { return true }
        return write { database in
            // Validate again inside the transaction, against the latest persisted state.
            guard let orderedIDs = SubtaskOrder.reorderedIDs(in: try database.snapshot(), moving: id,
                relativeTo: targetID, placement: placement) else { throw TaskStoreError.invalidSubtaskMove }
            for (position, childID) in orderedIDs.enumerated() {
                try database.run("UPDATE tasks SET subtask_order = ? WHERE id = ?",
                                 [.integer(Int64(position)), .text(childID)])
            }
        }
    }

    func completedTasks(in period: TaskReviewPeriod, relativeTo referenceDate: Date? = nil) -> [TodoTask] {
        let interval = period.interval(relativeTo: referenceDate ?? now(), calendar: calendar)
        return tasks.filter { task in
            guard let completedAt = task.completedAt else { return false }
            return completedAt >= interval.start && completedAt <= interval.end
        }.sorted {
            if $0.completedAt != $1.completedAt { return $0.completedAt! > $1.completedAt! }
            return $0.id < $1.id
        }
    }

    @discardableResult
    func addTask(title: String, details: String = "", plannedDate: Date? = nil,
                 parentID: String? = nil) -> String? {
        guard let title = validatedText(title, error: L10n.tr("请先填写任务名称。")) else { return nil }
        let id = UUID().uuidString
        let timestamp = now()
        let succeeded = write { database in
            if let parentID {
                guard try database.taskExists(id: parentID) else { throw TaskStoreError.taskMissing }
                guard try database.parentID(of: parentID) == nil else { throw TaskStoreError.nestedSubtask }
                // A new unfinished child reopens a completed parent and all its ancestors.
                try database.reopenAncestors(of: parentID, at: timestamp)
            }
            try database.run("""
                INSERT INTO tasks (id, parent_id, title, details, planned_at, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, [.text(id), .optionalText(parentID), .text(title), .text(details),
                       .optionalDate(plannedDate), .date(timestamp), .date(timestamp)])
        }
        return succeeded ? id : nil
    }

    @discardableResult
    func updateTask(id: String, title: String, details: String, plannedDate: Date?) -> Bool {
        guard let title = validatedText(title, error: L10n.tr("任务名称不能为空。")) else { return false }
        let timestamp = now()
        return write { database in
            guard try database.taskExists(id: id) else { throw TaskStoreError.taskMissing }
            try database.run("""
                UPDATE tasks SET title = ?, details = ?, planned_at = ?, updated_at = ? WHERE id = ?
                """, [.text(title), .text(details), .optionalDate(plannedDate), .date(timestamp), .text(id)])
        }
    }

    @discardableResult
    func setPriority(id: String, priority: TaskPriority) -> Bool {
        let timestamp = now()
        return write { database in
            guard try database.taskExists(id: id) else { throw TaskStoreError.taskMissing }
            try database.run("UPDATE tasks SET priority = ?, updated_at = ? WHERE id = ?",
                             [.integer(Int64(priority.rawValue)), .date(timestamp), .text(id)])
        }
    }

    /// Completing a parent completes every unfinished descendant at the same actual time.
    /// Existing descendant completion times remain intact. Reopening a task reopens its
    /// completed ancestors, while leaving its completed descendants unchanged.
    @discardableResult
    func setCompleted(id: String, completed: Bool) -> Bool {
        let shouldPlayCompletionFeedback = completed && task(id: id)?.isCompleted == false
        let timestamp = now()
        let succeeded = write { database in
            guard try database.taskExists(id: id) else { throw TaskStoreError.taskMissing }
            if completed {
                try database.run("""
                    WITH RECURSIVE descendants(id) AS (
                        SELECT id FROM tasks WHERE id = ?
                        UNION ALL
                        SELECT tasks.id FROM tasks JOIN descendants ON tasks.parent_id = descendants.id
                    )
                    UPDATE tasks SET completed_at = ?, updated_at = ?
                    WHERE id IN (SELECT id FROM descendants) AND completed_at IS NULL
                    """, [.text(id), .date(timestamp), .date(timestamp)])
            } else {
                try database.reopenAncestors(of: id, at: timestamp)
            }
        }
        if succeeded && shouldPlayCompletionFeedback { completionFeedback() }
        return succeeded
    }

    /// Deleting a parent also deletes descendants and their progress entries atomically.
    @discardableResult
    func deleteTask(id: String) -> Bool {
        write { database in
            guard try database.taskExists(id: id) else { throw TaskStoreError.taskMissing }
            try database.run("DELETE FROM tasks WHERE id = ?", [.text(id)])
        }
    }

    private func validatedText(_ text: String, error: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = error
            return nil
        }
        return trimmed
    }

    private func write(_ operation: (TaskDatabase) throws -> Void) -> Bool {
        do {
            guard let database else { throw TaskStoreError.unavailable }
            let tasks = try database.transaction {
                try operation(database)
                return try database.snapshot()
            }
            self.tasks = tasks
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

private enum TaskStoreError: LocalizedError {
    case unavailable
    case taskMissing
    case nestedSubtask
    case invalidSubtaskMove
    case database(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return L10n.tr("任务数据库暂不可用，请检查存储位置后重新打开应用。")
        case .taskMissing: return L10n.tr("任务不存在，可能已被删除。")
        case .nestedSubtask: return L10n.tr("子任务下不能再创建子任务。")
        case .invalidSubtaskMove: return L10n.tr("只能在同一主任务、同一完成状态的子任务之间排序。")
        case .database(let message): return L10n.tr("任务保存失败：\(message)")
        }
    }
}

private enum TaskSQLValue {
    case text(String)
    case number(Double)
    case integer(Int64)
    case null

    static func optionalText(_ value: String?) -> TaskSQLValue { value.map(Self.text) ?? .null }
    static func date(_ value: Date) -> TaskSQLValue { .number(value.timeIntervalSince1970) }
    static func optionalDate(_ value: Date?) -> TaskSQLValue { value.map(Self.date) ?? .null }
}

private final class TaskDatabase {
    private let handle: OpaquePointer

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? L10n.tr("无法创建任务数据库")
            if let opened { sqlite3_close(opened) }
            throw TaskStoreError.database(message)
        }
        handle = opened
        sqlite3_busy_timeout(opened, 1_000)
        do {
            try run("PRAGMA foreign_keys = ON")
            try run("PRAGMA journal_mode = WAL")
            try run("""
                CREATE TABLE IF NOT EXISTS tasks (
                    id TEXT PRIMARY KEY NOT NULL,
                    parent_id TEXT REFERENCES tasks(id) ON DELETE CASCADE,
                    title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                    details TEXT NOT NULL DEFAULT '',
                    planned_at REAL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    completed_at REAL,
                    priority INTEGER NOT NULL DEFAULT 0,
                    subtask_order INTEGER
                )
                """)
            // Serialize the schema check and ALTER so repeated opens also migrate safely.
            try transaction {
                let columns = try query("PRAGMA table_info(tasks)") { self.text($0, 1) }
                if !columns.contains("priority") {
                    try run("ALTER TABLE tasks ADD COLUMN priority INTEGER NOT NULL DEFAULT 0")
                }
                if !columns.contains("subtask_order") {
                    try run("ALTER TABLE tasks ADD COLUMN subtask_order INTEGER")
                }
            }
            try run("CREATE INDEX IF NOT EXISTS task_parent ON tasks(parent_id)")
            try run("CREATE INDEX IF NOT EXISTS task_completed ON tasks(completed_at)")
            // Legacy progress rows stay on disk; task details are the only notes interface.
            try run("""
                CREATE TABLE IF NOT EXISTS task_progress (
                    id TEXT PRIMARY KEY NOT NULL,
                    task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                    text TEXT NOT NULL CHECK(length(trim(text)) > 0),
                    created_at REAL NOT NULL
                )
                """)
            try run("CREATE INDEX IF NOT EXISTS progress_task ON task_progress(task_id, created_at)")
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE TRANSACTION")
        do {
            let value = try body()
            try run("COMMIT")
            return value
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    func taskExists(id: String) throws -> Bool {
        try query("SELECT id FROM tasks WHERE id = ?", [.text(id)]) { _ in true }.first ?? false
    }

    func parentID(of id: String) throws -> String? {
        try query("SELECT parent_id FROM tasks WHERE id = ?", [.text(id)]) {
            self.optionalText($0, 0)
        }.first ?? nil
    }

    func reopenAncestors(of id: String, at timestamp: Date) throws {
        try run("""
            WITH RECURSIVE ancestors(id, parent_id) AS (
                SELECT id, parent_id FROM tasks WHERE id = ?
                UNION ALL
                SELECT tasks.id, tasks.parent_id FROM tasks JOIN ancestors ON tasks.id = ancestors.parent_id
            )
            UPDATE tasks SET completed_at = NULL, updated_at = ?
            WHERE id IN (SELECT id FROM ancestors) AND completed_at IS NOT NULL
            """, [.text(id), .date(timestamp)])
    }

    func snapshot() throws -> [TodoTask] {
        try query("""
            SELECT id, parent_id, title, details, planned_at, created_at, updated_at, completed_at, priority, subtask_order
            FROM tasks ORDER BY created_at ASC, rowid ASC
            """) { statement in
            TodoTask(id: self.text(statement, 0), parentID: self.optionalText(statement, 1),
                     title: self.text(statement, 2), details: self.text(statement, 3),
                     plannedDate: self.optionalDate(statement, 4),
                     createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                     updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                     completedAt: self.optionalDate(statement, 7),
                     priority: TaskPriority(rawValue: Int(sqlite3_column_int64(statement, 8))) ?? .none,
                     subtaskOrder: sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 9)))
        }
    }

    func run(_ sql: String, _ values: [TaskSQLValue] = []) throws {
        _ = try query(sql, values) { _ in () }
    }

    private func query<T>(_ sql: String, _ values: [TaskSQLValue] = [], row: (OpaquePointer) -> T) throws -> [T] {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
            throw TaskStoreError.database(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(prepared) }
        for (index, value) in values.enumerated() {
            let parameter = Int32(index + 1)
            let result: Int32
            switch value {
            case .text(let text):
                result = sqlite3_bind_text(prepared, parameter, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .number(let number): result = sqlite3_bind_double(prepared, parameter, number)
            case .integer(let integer): result = sqlite3_bind_int64(prepared, parameter, integer)
            case .null: result = sqlite3_bind_null(prepared, parameter)
            }
            guard result == SQLITE_OK else { throw TaskStoreError.database(String(cString: sqlite3_errmsg(handle))) }
        }
        var rows: [T] = []
        while true {
            switch sqlite3_step(prepared) {
            case SQLITE_ROW: rows.append(row(prepared))
            case SQLITE_DONE: return rows
            default: throw TaskStoreError.database(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }

    private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(statement, index)
    }

    private func optionalDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }
}
