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
    /// `PQconnectStartParams` + `PQconnectPoll`, waiting on the socket between steps. libpq may
    /// switch sockets (another host, a TLS or GSS retry), so the socket is read again each time.
    func open(_ parameters: PGConnectionParameters, deadline: ContinuousClock.Instant) async throws {
        guard handle == nil else { throw PGConnectionError(.notReady, message: "The connection is already open.") }
        guard let started = parameters.closedToTheEnvironment().withCArrays({ PQconnectStartParams($0, $1, 0) }) else {
            throw PGConnectionError(.connectFailed, message: "libpq could not allocate a connection.")
        }
        handle = started
        guard PQstatus(started) != CONNECTION_BAD else { throw failConnect(.connectFailed) }
        _ = PQsetnonblocking(started, 1)

        var poll = PGRES_POLLING_WRITING
        while true {
            switch poll {
            case PGRES_POLLING_OK:
                installNoticeReceiver()
                try await requireISODates()
                return
            case PGRES_POLLING_FAILED:
                throw failConnect(.connectFailed)
            case PGRES_POLLING_READING, PGRES_POLLING_WRITING:
                do {
                    _ = try await waitForSocket(poll == PGRES_POLLING_READING ? .readable : .writable, deadline: deadline)
                } catch is PGSocketTimeout {
                    closeHandle()
                    throw PGConnectionError(.connectTimedOut, message: "The server did not answer in time.")
                } catch {
                    closeHandle()
                    throw error
                }
            default:
                break
            }
            guard let handle else { throw PGConnectionError(.connectFailed, message: "The connection was closed while connecting.") }
            poll = PQconnectPoll(handle)
        }
    }

    /// Values are read as the server's text, which needs ISO dates. `options` asks for them, but a
    /// `PGDATESTYLE` in the environment reaches the server later and wins; the server reports the
    /// result at connect, so this costs a round trip only then. `SET DateStyle = ISO` keeps the
    /// date order (DMY/MDY) the session had.
    private func requireISODates() async throws {
        guard let style = parameterStatus("DateStyle"), !style.hasPrefix("ISO") else { return }
        for result in try await execute("SET DateStyle = ISO") {
            if let error = result.error {
                closeHandle()
                throw PGConnectionError(.connectFailed, message: error.message)
            }
        }
    }

    private func failConnect(_ kind: PGConnectionError.Kind) -> PGConnectionError {
        let error = PGConnectionError(kind, message: errorMessage)
        closeHandle()
        return error
    }
}
