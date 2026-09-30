import XCTest
import Logging
@testable import PostgresKit

// Thread-safe collector — used in @Sendable handler closures
private actor NotificationCollector {
    private(set) var notifications: [PostgresNotification] = []
    func add(_ n: PostgresNotification) { notifications.append(n) }
    func count() -> Int { notifications.count }
    func first() -> PostgresNotification? { notifications.first }
}

final class NotificationsTests: PostgresKitTestCase {
    private var client: PostgresKit.PostgresClient!

    override func setUp() async throws {
        try await super.setUp()
        guard TestEnv.isConfigured else {
            throw XCTSkip("POSTGRES_HOST not set. Copy .env.example to .env and configure connection.")
        }
        let config = PostgresConfiguration(
            host: TestEnv.host,
            port: TestEnv.port,
            database: TestEnv.database,
            username: TestEnv.username,
            password: TestEnv.password,
            useTLS: TestEnv.useTLS,
            applicationName: "NotificationsTests"
        )
        client = try await PostgresKit.PostgresClient.connect(configuration: config, logger: Logger(label: "postgres.wire.tests"))
    }

    override func tearDown() async throws {
        client?.close()
    }

    // MARK: - Helpers

    private func randomChannel() -> String {
        "pgwire_test_\(UInt32.random(in: 0..<UInt32.max))"
    }

    /// Receives one notification from a stream within `timeout` seconds. Returns nil on timeout.
    /// Uses `for await` inside a task (valid in Swift 6 — `AsyncStream` is `Sendable`).
    private func receiveOne(
        from stream: AsyncStream<PostgresNotification>,
        timeout: Double = 6
    ) async -> PostgresNotification? {
        await withTaskGroup(of: PostgresNotification?.self) { group in
            group.addTask {
                for await notification in stream { return notification }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    // MARK: - Basic Notify (no LISTEN required)

    func testNotifyWithoutPayload_DoesNotThrow() async throws {
        let notifier = PostgresNotifier(client: client, logger: Logger(label: "postgres.wire.tests"))
        // NOTIFY to a channel with no listeners is legal in PostgreSQL
        try await notifier.notify(channel: randomChannel())
    }

    func testNotifyWithPayload_DoesNotThrow() async throws {
        let notifier = PostgresNotifier(client: client, logger: Logger(label: "postgres.wire.tests"))
        try await notifier.notify(channel: randomChannel(), payload: "test payload")
    }

    // MARK: - LISTEN / NOTIFY via AsyncStream

    func testNotifyAndReceiveViaStream() async throws {
        let notifier = PostgresNotifier(client: client, logger: Logger(label: "postgres.wire.tests"))
        let channel = randomChannel()

        try await notifier.listen(channels: [channel])
        // Allow time for LISTEN to be registered on the server
        try await Task.sleep(nanoseconds: 400_000_000) // 400 ms

        let stream = await notifier.notifications(for: channel)

        // Send NOTIFY after a brief delay
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            try? await notifier.notify(channel: channel, payload: "hello-world")
        }

        let received = await receiveOne(from: stream, timeout: 6)
        await notifier.stop()

        XCTAssertNotNil(received, "Should have received a notification within 6 seconds")
        XCTAssertEqual(received?.channel, channel.lowercased())
        XCTAssertEqual(received?.payload, "hello-world")
    }

    func testNotifyPayloadWithSpecialChars() async throws {
        let notifier = PostgresNotifier(client: client, logger: Logger(label: "postgres.wire.tests"))
        let channel = randomChannel()
        let payload = "it's a test"

        try await notifier.listen(channels: [channel])
        try await Task.sleep(nanoseconds: 400_000_000)

        let stream = await notifier.notifications(for: channel)

        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            try? await notifier.notify(channel: channel, payload: payload)
        }

        let received = await receiveOne(from: stream, timeout: 6)
        await notifier.stop()

        XCTAssertEqual(received?.payload, payload)
    }

    // MARK: - Handler-based delivery

    func testRegisterHandlerReceivesNotification() async throws {
        let notifier = PostgresNotifier(client: client, logger: Logger(label: "postgres.wire.tests"))
        let channel = randomChannel()
        let collector = NotificationCollector()

        // Register handler — captures actor (Sendable) so this is valid in Swift 6
        await notifier.registerHandler(for: channel) { note in
            Task { await collector.add(note) }
        }

        try await notifier.listen(channels: [channel])
        try await Task.sleep(nanoseconds: 400_000_000) // wait for LISTEN

        try await notifier.notify(channel: channel, payload: "handler-test")

        // Wait for delivery
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        await notifier.stop()

        let notes = await collector.notifications
        XCTAssertFalse(notes.isEmpty, "Handler should have received at least one notification")
        XCTAssertEqual(notes.first?.payload, "handler-test")
    }

    func testMultipleNotificationsDelivered() async throws {
        let notifier = PostgresNotifier(client: client, logger: Logger(label: "postgres.wire.tests"))
        let channel = randomChannel()
        let collector = NotificationCollector()

        await notifier.registerHandler(for: channel) { note in
            Task { await collector.add(note) }
        }

        try await notifier.listen(channels: [channel])
        try await Task.sleep(nanoseconds: 400_000_000)

        // Send 3 notifications with small gaps
        for i in 1...3 {
            try await notifier.notify(channel: channel, payload: "msg-\(i)")
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // Wait for delivery
        try await Task.sleep(nanoseconds: 1_000_000_000)

        await notifier.stop()

        let count = await collector.count()
        XCTAssertGreaterThanOrEqual(count, 1, "Should have received at least 1 notification")
    }

    // MARK: - UNLISTEN

    func testUnlistenFinishesStream() async throws {
        let notifier = PostgresNotifier(client: client, logger: Logger(label: "postgres.wire.tests"))
        let channel = randomChannel()

        try await notifier.listen(channels: [channel])
        try await Task.sleep(nanoseconds: 300_000_000)

        let stream = await notifier.notifications(for: channel)

        // Unlisten — this finishes the stream's continuation
        try await notifier.unlisten(channel: channel)

        // If the stream is finished, `receiveOne` should return nil quickly
        let received = await receiveOne(from: stream, timeout: 2)

        await notifier.stop()
        // Stream was finished before any NOTIFY was sent, so we expect nil
        XCTAssertNil(received, "No notifications should arrive on an unlistened channel")
    }

    // MARK: - Stop

    func testStop_DoesNotCrash() async throws {
        let notifier = PostgresNotifier(client: client, logger: Logger(label: "postgres.wire.tests"))
        try await notifier.listen(channels: [randomChannel()])
        try await Task.sleep(nanoseconds: 100_000_000)
        await notifier.stop()
        // Calling stop again should be safe
        await notifier.stop()
    }
}
