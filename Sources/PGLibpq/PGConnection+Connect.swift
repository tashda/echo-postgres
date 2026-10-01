extension PGConnection {
    /// `PQconnectStartParams` + `PQconnectPoll`, waiting on the socket between steps. libpq may
    /// switch sockets (another host, a TLS or GSS retry), so the socket is read again each time.
    func open(_ parameters: PGConnectionParameters, deadline: ContinuousClock.Instant) async throws {
        guard handle == nil else { throw PGConnectionError(.notReady, message: "The connection is already open.") }
        guard let started = parameters.withCArrays({ PQconnectStartParams($0, $1, 0) }) else {
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

    private func failConnect(_ kind: PGConnectionError.Kind) -> PGConnectionError {
        let error = PGConnectionError(kind, message: errorMessage)
        closeHandle()
        return error
    }
}
