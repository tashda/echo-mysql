#if canImport(Darwin)
import Darwin
import Foundation
import MySQLKit
import MySQLKitTesting
import Testing

/// Rows are pulled from the server as they are read (`mysql_use_result`, batches): two million
/// rows, about 210 MB of data, stream through in bounded memory (Phase 6 acceptance).
@Suite(.testServer)
struct StreamingMemoryTests {
    static func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    @Test func twoMillionRowsStreamInBoundedMemory() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            let limit = try await client.serverFlavor().isMySQL ? "cte_max_recursion_depth" : "max_recursive_iterations"
            _ = try await client.simpleQuery("SET SESSION \(limit) = 3000000")
            let sql = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000000) SELECT i, REPEAT('x', 100) AS pad FROM n"
            let baseline = Self.residentBytes()
            var peak = baseline
            var count = 0
            var last = ""
            for try await event in try await client.events(sql, batchSize: 512) {
                guard case .rows(let rows) = event else { continue }
                count += rows.count
                last = rows.last?.column("i")?.string ?? last
                if count % 50_000 < rows.count { peak = max(peak, Self.residentBytes()) }
            }
            #expect(count == 2_000_000)
            #expect(last == "2000000")
            let grown = (peak - baseline) / 1_048_576
            #expect(grown < 100, "grew \(grown) MB while streaming about 210 MB")
        }
    }
}
#endif
