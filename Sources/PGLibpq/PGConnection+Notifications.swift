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
/// A `NOTIFY` received on a channel this connection listens to.
public struct PGNotification: Sendable, Equatable {
    public let channel: String
    public let payload: String
    /// The backend that sent it.
    public let pid: Int32
}

extension PGConnection {
    /// Notifications received since the last call (`LISTEN` must have been run on this connection).
    public func takeNotifications() -> [PGNotification] {
        collectNotifications()
        defer { pendingNotifications.removeAll() }
        return pendingNotifications
    }

    /// Waits while the connection is idle until the server sends something (a notification, or a
    /// message that it is closing) and returns the notifications received; throws
    /// `connectionLost` when the connection closed. Stop it (cancel the task) before sending a
    /// statement: only one reader may wait on the socket.
    public func waitWhileIdle() async throws -> [PGNotification] {
        guard let handle else { throw PGConnectionError(.notReady, message: "The connection is closed.") }
        while true {
            let ready = takeNotifications()
            if !ready.isEmpty { return ready }
            guard !isBusy else { throw PGConnectionError(.notReady, message: "A statement is running.") }
            _ = try await waitForSocket(.readable, deadline: nil)
            guard PQconsumeInput(handle) == 1, PQstatus(handle) == CONNECTION_OK else {
                let message = errorMessage
                closeHandle()
                throw PGConnectionError(.connectionLost, message: message)
            }
        }
    }

    func collectNotifications() {
        guard let handle else { return }
        while let notify = PQnotifies(handle) {
            defer { PQfreemem(notify) }
            pendingNotifications.append(PGNotification(
                channel: String(cString: notify.pointee.relname),
                payload: String(cString: notify.pointee.extra),
                pid: notify.pointee.be_pid
            ))
        }
    }
}
