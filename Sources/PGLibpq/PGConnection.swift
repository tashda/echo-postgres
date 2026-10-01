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
import Dispatch

/// One libpq connection.
///
/// The actor runs on its own serial queue (decision D10) and every libpq call happens there. It
/// waits for the socket with `PGSocketWait` instead of blocking, so an idle or slow connection
/// holds no thread. While one call is suspended on the socket, others can run (a cancel during a
/// query, for example).
public actor PGConnection {
    private let queue: PGConnectionQueue
    var executorQueue: PGConnectionQueue { queue }
    var handle: OpaquePointer?
    /// Notices (RAISE NOTICE, warnings) since the last `takeNotices()`.
    let noticeBox = PGNoticeBox()
    private var noticeContext: Unmanaged<PGNoticeBox>?
    var pendingNotifications: [PGNotification] = []
    /// Socket waits in progress (a closing connection ends them first).
    var activeWaits: [ObjectIdentifier: PGSocketWait] = [:]
    /// A statement was sent and its results haven't all been read.
    public internal(set) var isBusy = false

    #if canImport(Darwin)
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }
    #endif

    public init(label: String = "PGConnection") {
        queue = PGConnectionQueue(label: label)
    }

    isolated deinit {
        closeHandle()
    }

    /// Opens a connection. The whole attempt (DNS, TCP, TLS, sign-in, every host) must finish
    /// within `timeout`.
    public static func connect(_ parameters: PGConnectionParameters, timeout: Duration) async throws -> PGConnection {
        let connection = PGConnection()
        try await connection.open(parameters, deadline: .now + timeout)
        return connection
    }

    /// Closes the connection, also while a statement is waiting on the socket (that wait ends with
    /// `connectionLost`). Safe to call twice.
    public func close() async {
        let waits = Array(activeWaits.values)
        activeWaits.removeAll()
        for wait in waits {
            await wait.abort(with: PGConnectionError(.connectionLost, message: "The connection was closed."))
        }
        closeHandle()
    }

    /// Whether the connection is still usable, checked without waiting: an idle connection reads
    /// what the socket has, which tells whether the server closed it.
    public func isAlive() -> Bool {
        guard let handle else { return false }
        if !isBusy, activeWaits.isEmpty {
            if PQconsumeInput(handle) == 0 { return false }
            collectNotifications()
        }
        return PQstatus(handle) == CONNECTION_OK
    }

    public var isOpen: Bool {
        guard let handle else { return false }
        return PQstatus(handle) == CONNECTION_OK
    }

    // MARK: Server facts

    public var backendPID: Int32 { handle.map { PQbackendPID($0) } ?? 0 }
    public var serverVersion: Int { handle.map { Int(PQserverVersion($0)) } ?? 0 }
    /// The host and port this connection reached (with several hosts, the one libpq picked).
    public var host: String? { handle.flatMap { PQhost($0) }.map { String(cString: $0) } }
    public var port: String? { handle.flatMap { PQport($0) }.map { String(cString: $0) } }

    /// A parameter the server reports (`server_version`, `TimeZone`, `in_hot_standby` …).
    public func parameterStatus(_ name: String) -> String? {
        guard let handle, let value = PQparameterStatus(handle, name) else { return nil }
        return String(cString: value)
    }

    public enum TransactionStatus: Sendable, Equatable {
        case idle, active, inTransaction, failedTransaction, unknown
    }

    public var transactionStatus: TransactionStatus {
        guard let handle else { return .unknown }
        switch PQtransactionStatus(handle) {
        case PQTRANS_IDLE: return .idle
        case PQTRANS_ACTIVE: return .active
        case PQTRANS_INTRANS: return .inTransaction
        case PQTRANS_INERROR: return .failedTransaction
        default: return .unknown
        }
    }

    public enum Encryption: Sendable, Equatable {
        case none
        case kerberos
        case tls(protocol: String?, cipher: String?)
    }

    public var encryption: Encryption {
        guard let handle else { return .none }
        if PQgssEncInUse(handle) == 1 { return .kerberos }
        if PQsslInUse(handle) == 1 {
            func attribute(_ name: String) -> String? { PQsslAttribute(handle, name).map { String(cString: $0) } }
            return .tls(protocol: attribute("protocol"), cipher: attribute("cipher"))
        }
        return .none
    }

    /// Notices received since the last call.
    public func takeNotices() -> [PGServerError] {
        defer { noticeBox.notices.removeAll() }
        return noticeBox.notices
    }

    // MARK: Internals

    var errorMessage: String {
        guard let handle, let message = PQerrorMessage(handle) else { return "" }
        return PGServerError.trimmed(String(cString: message))
    }

    func waitForSocket(_ events: PGSocketReadiness, deadline: ContinuousClock.Instant?) async throws -> PGSocketReadiness {
        guard let handle else { throw PGConnectionError(.notReady, message: "The connection is closed.") }
        let socket = PQsocket(handle)
        guard socket >= 0 else { throw PGConnectionError(.connectionLost, message: errorMessage) }
        let wait = PGSocketWait()
        let id = ObjectIdentifier(wait)
        activeWaits[id] = wait
        defer { activeWaits[id] = nil }
        let ready = try await wait.run(socket: socket, for: events, on: queue, deadline: deadline)
        guard self.handle != nil else { throw PGConnectionError(.connectionLost, message: "The connection was closed.") }
        return ready
    }

    func installNoticeReceiver() {
        guard let handle else { return }
        let context = Unmanaged.passRetained(noticeBox)
        noticeContext = context
        PQsetNoticeReceiver(handle, { context, result in
            guard let context, let result else { return }
            Unmanaged<PGNoticeBox>.fromOpaque(context).takeUnretainedValue().notices.append(PGServerError(result: result))
        }, context.toOpaque())
    }

    func closeHandle() {
        if let handle { PQfinish(handle) }
        handle = nil
        isBusy = false
        noticeContext?.release()
        noticeContext = nil
    }
}

/// Where the notice receiver puts notices. Only touched on the connection's queue: libpq calls the
/// receiver from inside `PQgetResult`/`PQconsumeInput`, which the actor calls.
final class PGNoticeBox {
    var notices: [PGServerError] = []
}
