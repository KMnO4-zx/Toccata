import Foundation
import SQLite3

enum DatabaseError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "无法打开数据库: \(message)"
        case .prepareFailed(let message): return "SQL 编译失败: \(message)"
        case .stepFailed(let code): return "SQL 执行失败(\(code))"
        }
    }
}

/// 只读 SQLite 查询封装：daemon 是唯一写方，本 App 仅以只读方式打开。
final class Database {
    static var defaultURL: URL { AppPaths.databaseURL }

    private let handle: OpaquePointer

    init(url: URL = Database.defaultURL) throws {
        var opened: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error \(rc)"
            if let opened { sqlite3_close(opened) }
            throw DatabaseError.openFailed(message)
        }
        handle = opened
        sqlite3_busy_timeout(opened, 500)
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Keep all sections of an exported report on one committed SQLite snapshot.
    func readSnapshot<T>(_ body: () throws -> T) throws -> T {
        _ = try query("BEGIN") { _ in 0 }
        do {
            let result = try body()
            _ = try query("COMMIT") { _ in 0 }
            return result
        } catch {
            _ = try? query("ROLLBACK") { _ in 0 }
            throw error
        }
    }

    /// 编译并执行查询，逐行交由 `row` 映射。仅支持 Int64 参数绑定（本 App 的查询足够用）。
    func query<T>(_ sql: String, params: [Int64] = [], row: (OpaquePointer) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        for (index, param) in params.enumerated() {
            sqlite3_bind_int64(stmt, Int32(index + 1), param)
        }
        var rows: [T] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                rows.append(row(stmt))
            case SQLITE_DONE:
                return rows
            case let code:
                throw DatabaseError.stepFailed(code)
            }
        }
    }
}

func columnInt(_ stmt: OpaquePointer, _ index: Int32) -> Int {
    Int(sqlite3_column_int64(stmt, index))
}

func columnInt64(_ stmt: OpaquePointer, _ index: Int32) -> Int64 {
    sqlite3_column_int64(stmt, index)
}

func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
    guard let cString = sqlite3_column_text(stmt, index) else { return "" }
    return String(cString: cString)
}
