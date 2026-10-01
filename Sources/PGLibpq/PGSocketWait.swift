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
import Synchronization

/// What a connection waits for on its socket.
struct PGSocketReadiness: OptionSet, Sendable {
    let rawValue: UInt8
    static let readable = PGSocketReadiness(rawValue: 1)
    static let writable = PGSocketReadiness(rawValue: 2)
}

/// The deadline passed before the socket was ready.
struct PGSocketTimeout: Error {}

/// One wait for socket readiness (decision D10): DispatchSources on the connection's own queue, so
/// libpq is only touched there, and no thread blocks while the socket is quiet.
///
/// The wait resumes only after every source's cancel handler has run: Dispatch must have let go of
/// the descriptor before libpq may close it (it does, between hosts and between TLS/GSS attempts).
final class PGSocketWait: Sendable {
    private struct State {
        var continuation: CheckedContinuation<PGSocketReadiness, any Error>?
        var outcome: Result<PGSocketReadiness, any Error>?
        var sources: [any DispatchSourceProtocol] = []
        var pendingCancels = 0
    }

    private let state = Mutex(State())

    /// Waits until the socket is ready for `events`, the deadline passes (`PGSocketTimeout`), or the
    /// task is cancelled (`CancellationError`).
    static func wait(
        socket: Int32,
        for events: PGSocketReadiness,
        on queue: DispatchSerialQueue,
        deadline: ContinuousClock.Instant?
    ) async throws -> PGSocketReadiness {
        let wait = PGSocketWait()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                wait.start(continuation, socket: socket, events: events, queue: queue, deadline: deadline)
            }
        } onCancel: {
            wait.finish(.failure(CancellationError()))
        }
    }

    private func start(
        _ continuation: CheckedContinuation<PGSocketReadiness, any Error>,
        socket: Int32,
        events: PGSocketReadiness,
        queue: DispatchSerialQueue,
        deadline: ContinuousClock.Instant?
    ) {
        // The sources live only inside the lock; making, starting and cancelling them never
        // blocks, and their handlers run later, on the connection's queue.
        state.withLock { state in
            if events.contains(.readable) {
                let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
                source.setEventHandler { [self] in finish(.success(.readable)) }
                state.sources.append(source)
            }
            if events.contains(.writable) {
                let source = DispatchSource.makeWriteSource(fileDescriptor: socket, queue: queue)
                source.setEventHandler { [self] in finish(.success(.writable)) }
                state.sources.append(source)
            }
            if let deadline {
                let remaining = ContinuousClock.now.duration(to: deadline)
                let nanoseconds = max(0, remaining.components.seconds * 1_000_000_000 + remaining.components.attoseconds / 1_000_000_000)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + .nanoseconds(Int(nanoseconds)))
                timer.setEventHandler { [self] in finish(.failure(PGSocketTimeout())) }
                state.sources.append(timer)
            }
            state.continuation = continuation
            state.pendingCancels = state.sources.count
            let cancelledAlready = state.outcome != nil
            for source in state.sources {
                source.setCancelHandler { [self] in cancelled() }
                // Cancelled before the sources existed: cancel them unstarted; their cancel
                // handlers resume the continuation.
                if cancelledAlready { source.cancel() }
                source.resume()
            }
        }
    }

    /// Records the first outcome and cancels the sources; resuming waits for their cancel handlers.
    private func finish(_ outcome: Result<PGSocketReadiness, any Error>) {
        state.withLock { state in
            guard state.outcome == nil else { return }
            state.outcome = outcome
            for source in state.sources { source.cancel() }
        }
    }

    private func cancelled() {
        let ready = state.withLock { state -> (CheckedContinuation<PGSocketReadiness, any Error>, Result<PGSocketReadiness, any Error>)? in
            state.pendingCancels -= 1
            guard state.pendingCancels == 0, let continuation = state.continuation, let outcome = state.outcome else { return nil }
            state.continuation = nil
            state.sources = []
            return (continuation, outcome)
        }
        if let (continuation, outcome) = ready { continuation.resume(with: outcome) }
    }
}
