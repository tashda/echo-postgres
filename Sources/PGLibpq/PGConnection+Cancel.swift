#if canImport(CLibpq)
internal import CLibpq
#else
internal import CLibpqSystem
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
extension PGConnection {
    /// Asks the server to cancel the running statement (`PQcancelCreate`/`PQcancelPoll`: its own
    /// connection to the same host, encrypted like this one, waited on without blocking). The
    /// statement then ends with SQLSTATE 57014; keep reading results until `nextResult()` is nil.
    public func cancel(timeout: Duration = .seconds(10)) async throws {
        guard let handle, let cancelConnection = PQcancelCreate(handle) else { return }
        defer { PQcancelFinish(cancelConnection) }
        func failure() -> PGConnectionError {
            PGConnectionError(.sendFailed, message: PGServerError.trimmed(String(cString: PQcancelErrorMessage(cancelConnection))))
        }
        guard PQcancelStart(cancelConnection) == 1 else { throw failure() }
        let deadline = ContinuousClock.now + timeout
        var poll = PGRES_POLLING_WRITING
        while true {
            switch poll {
            case PGRES_POLLING_OK:
                return
            case PGRES_POLLING_FAILED:
                throw failure()
            case PGRES_POLLING_READING, PGRES_POLLING_WRITING:
                let socket = PQcancelSocket(cancelConnection)
                guard socket >= 0 else { throw failure() }
                _ = try await PGSocketWait.wait(
                    socket: socket, for: poll == PGRES_POLLING_READING ? .readable : .writable,
                    on: executorQueue, deadline: deadline)
            default:
                break
            }
            poll = PQcancelPoll(cancelConnection)
        }
    }
}
