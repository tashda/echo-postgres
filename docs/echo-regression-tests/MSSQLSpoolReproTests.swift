import XCTest
import NIOCore
@testable import Echo

/// Reproduces the SQL Server result path of MSSQLDedicatedQuerySession.streamQueryWithProgress:
/// rows 1–200 as `.stringValues`, rows 201+ as `.raw` TDS column bytes (canUseRawPath).
@MainActor
final class MSSQLSpoolReproTests: XCTestCase {
    private var retained: [AnyObject] = []

    func testRowsAfterThePreview() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MSSQLSpoolRepro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let state = QueryEditorState(sql: "SELECT id, name FROM t", initialVisibleRowBatch: 500, previewRowLimit: 512, spoolManager: ResultSpooler(configuration: .defaultConfiguration(rootDirectory: tempRoot)))
        retained.append(state)
        state.startExecution()
        let columns = [ColumnInfo(name: "id", dataType: "int"), ColumnInfo(name: "name", dataType: "nvarchar")]
        let total = 1_000
        let tab: QueryProgressHandler = { [weak state] update in guard let state else { return }; Task { @MainActor in state.applyStreamUpdate(update) } }
        let bridged: QueryProgressHandler = { update in Task { @MainActor in tab(update) } }
        let result: QueryResultSet = await Task.detached {
            let worker = ResultStreamBatchWorker(label: "mssql.repro", columns: columns, streamingPreviewLimit: 200, maxFlushLatency: 0.015, operationStart: CFAbsoluteTimeGetCurrent(), progressHandler: bridged)
            var preview: [[String?]] = []
            var pending: [ResultStreamBatchWorker.Payload] = []
            for i in 1...total {
                if i <= 200 {
                    let strings: [String?] = ["\(i)", "row\(i)"]
                    preview.append(strings)
                    pending.append(.init(previewValues: strings, storage: .stringValues(strings), totalRowCount: i, decodeDuration: 0))
                } else {
                    // TDS wire bytes: int = Int32 little-endian, nvarchar = UTF-16LE.
                    var id = ByteBuffer(); id.writeInteger(Int32(i), endianness: .little)
                    var name = ByteBuffer(); name.writeBytes(Array("row\(i)".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
                    let raw = ResultStreamBatchWorker.RawRow(buffers: [id, name], lengths: [4, name.readableBytes], totalLength: 5 + 4 + 5 + name.readableBytes)
                    pending.append(.init(previewValues: nil, storage: .raw(raw), totalRowCount: i, decodeDuration: 0))
                }
                if pending.count >= 512 { worker.enqueueBatch(pending); pending.removeAll() }
            }
            if !pending.isEmpty { worker.enqueueBatch(pending) }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in worker.finish(totalRowCount: total) { Task { @MainActor in c.resume() } } }
            return QueryResultSet(columns: columns, rows: preview, totalRowCount: total)
        }.value
        state.consumeFinalResult(result)
        state.finishExecution()
        for _ in 0..<100 where state.displayedRowCount < total { try await Task.sleep(for: .milliseconds(50)) }

        let lines = [0, 199, 200, 250, 999].map { index in
            "row \(index): \(String(describing: state.displayedRow(at: index)))"
        }
        let report = (["displayed=\(state.displayedRowCount) of \(total)"] + lines).joined(separator: "\n")
        try report.write(toFile: NSTemporaryDirectory() + "mssql-repro.txt", atomically: true, encoding: .utf8)

        // What the type-aware decoder would do with a preview row stored as a string.
        let stringRow = ResultBinaryRowCodec.encode(row: ["1234", "row1"])
        let typeAware = ResultBinaryRowCodec.decode(stringRow, columns: columns)
        try (report + "\ntype-aware decode of preview row [\"1234\",\"row1\"]: \(typeAware)").write(toFile: NSTemporaryDirectory() + "mssql-repro.txt", atomically: true, encoding: .utf8)
    }
}
