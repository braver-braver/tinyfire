//
//  ZCodeLogAdapter.swift
//  tinyFire
//
//  ZCode: ~/.zcode/cli/db/db.sqlite (model_usage)
//
//  ZCode's JSONL activity logs redact token counts. The local SQLite usage
//  database is the authoritative source used by ZCode's own App Usage view.
//

import Foundation
import SQLite3

enum ZCodeLogAdapter {
    static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/cli/db/db.sqlite", isDirectory: false)
    }

    static func connectionState() -> (SourceConnectionState, String) {
        let url = databaseURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return (.notFound, "Missing ~/.zcode/cli/db/db.sqlite")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return (.noPermission, url.path)
        }

        var db: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open ZCode database"
            if let db { sqlite3_close(db) }
            return (.readError, detail)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        guard supportsUsageSchema(db) else {
            return (.unsupported, "Unsupported ZCode model_usage schema")
        }
        return (.ok, url.path)
    }

    /// Read completed model requests since the supplied timestamp.
    ///
    /// ZCode normalizes input_tokens as the total input side when it is nonzero.
    /// When it is zero, its own usage aggregation falls back to cache read/write.
    /// We mirror that rule so TinyFire totals match ZCode App Usage, then split
    /// cached tokens back out of input for TinyFire's additive breakdown.
    static func readUsage(since: Date) -> [UsageEvent] {
        let url = databaseURL
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let sql = """
        SELECT
          id,
          started_at,
          input_tokens,
          output_tokens,
          cache_creation_input_tokens,
          cache_read_input_tokens
        FROM model_usage
        WHERE started_at >= ?
          AND completed_at IS NOT NULL
          AND (
            input_tokens > 0 OR
            output_tokens > 0 OR
            cache_creation_input_tokens > 0 OR
            cache_read_input_tokens > 0
          )
        ORDER BY started_at ASC, id ASC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        let sinceMS = Int64(since.timeIntervalSince1970 * 1000)
        sqlite3_bind_int64(stmt, 1, sinceMS)

        var events: [UsageEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: idText)
            let startedMS = sqlite3_column_int64(stmt, 1)
            let rawInput = nonnegative(sqlite3_column_int64(stmt, 2))
            let output = nonnegative(sqlite3_column_int64(stmt, 3))
            let rawCacheWrite = nonnegative(sqlite3_column_int64(stmt, 4))
            let rawCacheRead = nonnegative(sqlite3_column_int64(stmt, 5))

            let inputSide: Int
            let cacheRead: Int
            let cacheWrite: Int
            let freshInput: Int

            if rawInput > 0 {
                // Current ZCode records cache as a breakdown of input_tokens.
                inputSide = rawInput
                cacheRead = min(rawCacheRead, inputSide)
                cacheWrite = min(rawCacheWrite, max(0, inputSide - cacheRead))
                freshInput = max(0, inputSide - cacheRead - cacheWrite)
            } else {
                // Compatibility with records where only cache buckets were populated.
                cacheRead = rawCacheRead
                cacheWrite = rawCacheWrite
                freshInput = 0
                inputSide = cacheRead + cacheWrite
            }

            // Mirrors ZCode computed_total_tokens: input side + output.
            // reasoning_tokens is reported separately by ZCode and is not added here.
            let total = inputSide + output
            guard total > 0 else { continue }

            events.append(
                UsageEvent(
                    id: "zcode:\(id)",
                    source: .zcode,
                    timestamp: Date(timeIntervalSince1970: Double(startedMS) / 1000.0),
                    tokens: total,
                    breakdown: UsageBreakdown(
                        input: freshInput > 0 ? freshInput : nil,
                        output: output > 0 ? output : nil,
                        cacheRead: cacheRead > 0 ? cacheRead : nil,
                        cacheWrite: cacheWrite > 0 ? cacheWrite : nil
                    ),
                    filePath: url.path
                )
            )
        }
        return events
    }

    private static func supportsUsageSchema(_ db: OpaquePointer) -> Bool {
        let sql = """
        SELECT
          id,
          started_at,
          completed_at,
          input_tokens,
          output_tokens,
          cache_creation_input_tokens,
          cache_read_input_tokens
        FROM model_usage
        LIMIT 0;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        return sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK
    }

    private static func nonnegative(_ value: Int64) -> Int {
        Int(max(0, value))
    }
}
