extension PGConnection {
    /// Sends SQL with the simple query protocol: several statements in one string work, and each
    /// gives its own results. Rows come in chunks of `chunkSize` (`PQsetChunkedRowsMode`).
    public func send(_ sql: String, chunkSize: Int = 512) async throws {
        let handle = try readyHandle()
        guard PQsendQuery(handle, sql) == 1 else {
            throw PGConnectionError(.sendFailed, message: errorMessage)
        }
        isBusy = true
        if chunkSize > 1 { _ = PQsetChunkedRowsMode(handle, Int32(chunkSize)) }
        try await flush()
    }

    /// The next result of the statement(s) sent, or nil when all were read. Waits for the server
    /// without blocking; nothing is read from the socket until asked, so a slow reader slows the
    /// server down instead of filling memory.
    public func nextResult() async throws -> PGResult? {
        guard let handle else { throw PGConnectionError(.notReady, message: "The connection is closed.") }
        while PQisBusy(handle) == 1 {
            _ = try await waitForSocket(.readable, deadline: nil)
            guard PQconsumeInput(handle) == 1 else {
                isBusy = false
                throw PGConnectionError(.connectionLost, message: errorMessage)
            }
        }
        guard let result = PQgetResult(handle) else {
            isBusy = false
            if PQstatus(handle) == CONNECTION_BAD {
                throw PGConnectionError(.connectionLost, message: errorMessage)
            }
            return nil
        }
        return PGResult(result)
    }

    /// Runs SQL and returns every result, for short statements (catalog queries, SET …).
    public func execute(_ sql: String) async throws -> [PGResult] {
        try await send(sql, chunkSize: 1)
        var results: [PGResult] = []
        while let result = try await nextResult() { results.append(result) }
        return results
    }

    /// Writes what libpq has queued. In nonblocking mode a send may not go out at once; while
    /// waiting to write, input is consumed so a server that is sending can't deadlock us.
    func flush() async throws {
        guard let handle else { return }
        while true {
            switch PQflush(handle) {
            case 0:
                return
            case 1:
                let ready = try await waitForSocket([.readable, .writable], deadline: nil)
                if ready.contains(.readable), PQconsumeInput(handle) != 1 {
                    throw PGConnectionError(.connectionLost, message: errorMessage)
                }
            default:
                throw PGConnectionError(.sendFailed, message: errorMessage)
            }
        }
    }

    func readyHandle() throws -> OpaquePointer {
        guard let handle, PQstatus(handle) == CONNECTION_OK else {
            throw PGConnectionError(.notReady, message: "The connection is closed.")
        }
        guard !isBusy else {
            throw PGConnectionError(.notReady, message: "The connection is still reading the results of another statement.")
        }
        return handle
    }
}
