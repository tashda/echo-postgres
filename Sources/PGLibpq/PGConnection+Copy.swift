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
import Foundation

extension PGConnection {
    /// After `COPY … FROM STDIN` was sent and answered with `.copyIn`: sends `data` (any COPY format:
    /// text, CSV or binary), waiting for the socket when libpq's buffer is full.
    public func putCopyData(_ data: Data) async throws {
        guard let handle else { throw PGConnectionError(.notReady, message: "The connection is closed.") }
        while true {
            let status = data.withUnsafeBytes { bytes -> Int32 in
                guard let base = bytes.baseAddress else { return PQputCopyData(handle, "", 0) }
                return PQputCopyData(handle, base.assumingMemoryBound(to: CChar.self), Int32(bytes.count))
            }
            switch status {
            case 1: return
            case 0: _ = try await waitForSocket(.writable, deadline: nil)
            default: throw PGConnectionError(.sendFailed, message: errorMessage)
            }
        }
    }

    /// Ends `COPY FROM STDIN`: `errorMessage` nil finishes it, otherwise the server aborts the COPY
    /// with that message. Then read the final result with `nextResult()`.
    public func endCopy(failing errorMessage: String? = nil) async throws {
        guard let handle else { throw PGConnectionError(.notReady, message: "The connection is closed.") }
        while true {
            let status = PQputCopyEnd(handle, errorMessage)
            switch status {
            case 1:
                try await flush()
                return
            case 0: _ = try await waitForSocket(.writable, deadline: nil)
            default: throw PGConnectionError(.sendFailed, message: self.errorMessage)
            }
        }
    }

    /// After `COPY … TO STDOUT` was answered with `.copyOut`: the next row of COPY data, or nil when
    /// the COPY is done (then read the final result with `nextResult()`).
    public func getCopyData() async throws -> Data? {
        guard let handle else { throw PGConnectionError(.notReady, message: "The connection is closed.") }
        while true {
            var buffer: UnsafeMutablePointer<CChar>?
            let length = PQgetCopyData(handle, &buffer, 1)
            if length > 0, let buffer {
                defer { PQfreemem(buffer) }
                return Data(bytes: buffer, count: Int(length))
            }
            switch length {
            case 0:
                _ = try await waitForSocket(.readable, deadline: nil)
                guard PQconsumeInput(handle) == 1 else {
                    throw PGConnectionError(.connectionLost, message: errorMessage)
                }
            case -1:
                return nil
            default:
                throw PGConnectionError(.connectionLost, message: errorMessage)
            }
        }
    }
}
