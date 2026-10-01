import Foundation
import Logging
import PostgresWire

// MARK: - Core Namespace Client Types

public struct PostgresMetadataClient: Sendable {
    internal let client: PostgresClient
    init(client: PostgresClient) { self.client = client }
}

public struct PostgresAdminClient: Sendable {
    internal let client: PostgresClient
    init(client: PostgresClient) { self.client = client }
}

public struct PostgresSecurityClient: Sendable {
    internal let client: PostgresClient
    init(client: PostgresClient) { self.client = client }
}

public struct PostgresActivityClient: Sendable {
    internal let client: PostgresClient
    init(client: PostgresClient) { self.client = client }

    public func snapshot(options: PostgresActivityOptions = .init()) async throws -> PostgresActivitySnapshot {
        try await client.wire.activity.snapshot(options: options)
    }

    public func streamSnapshots(every seconds: TimeInterval = 5.0, options: PostgresActivityOptions = .init()) -> AsyncThrowingStream<PostgresActivitySnapshot, Error> {
        client.wire.activity.streamSnapshots(every: seconds, options: options)
    }

    public func killSession(pid: Int32) async throws {
        try await client.wire.activity.killSession(pid: pid)
    }
}

// MARK: - Object Namespace Client Types

public struct PostgresIndexClient: Sendable {
    internal let client: PostgresClient
    init(client: PostgresClient) { self.client = client }
}

public struct PostgresConstraintClient: Sendable {
    internal let client: PostgresClient
    init(client: PostgresClient) { self.client = client }
}

public struct PostgresRoutineClient: Sendable {
    internal let client: PostgresClient
    init(client: PostgresClient) { self.client = client }
}

public struct PostgresViewClient: Sendable {
    internal let client: PostgresClient
    init(client: PostgresClient) { self.client = client }
}

public struct PostgresTriggerClient: Sendable {
    internal let client: PostgresClient
    init(client: PostgresClient) { self.client = client }
}

public struct PostgresTypeClient: Sendable {
    internal let client: PostgresClient
    init(client: PostgresClient) { self.client = client }
}

public struct PostgresSequenceClient: Sendable {
    internal let client: PostgresClient
    init(client: PostgresClient) { self.client = client }
}

// MARK: - Operation Namespace Client Types

public struct PostgresMaintenanceClient: Sendable {
    internal let client: PostgresClient
    init(client: PostgresClient) { self.client = client }
}

/// pg_cron jobs (the `pg_cron` extension, in the database `cron.database_name` names).
public struct PostgresCronClient: Sendable {
    internal let client: PostgresClient
    init(client: PostgresClient) { self.client = client }
}

public struct PostgresTransactionClient: Sendable {
    internal let client: PostgresClient
    init(client: PostgresClient) { self.client = client }
}

public struct PostgresExecutionPlanClient: Sendable {
    internal let client: PostgresClient
    init(client: PostgresClient) { self.client = client }
}

public struct PostgresBulkClient: Sendable {
    internal let client: PostgresClient
    init(client: PostgresClient) { self.client = client }
}

public struct PostgresSessionClient: Sendable {
    internal let client: PostgresClient
    init(client: PostgresClient) { self.client = client }
}

public struct PostgresServerConfigClient: Sendable {
    internal let client: PostgresClient
    init(client: PostgresClient) { self.client = client }
}

public struct PostgresReplicationClient: Sendable {
    internal let client: PostgresClient
    init(client: PostgresClient) { self.client = client }
}

// MARK: - Postgres-Specific Namespace Client Types

public struct PostgresNotifierClient: Sendable {
    internal let client: PostgresClient
    init(client: PostgresClient) { self.client = client }

    public func notify(channel: String, payload: String? = nil) async throws {
        try await client.notifierActor.notify(channel: channel, payload: payload)
    }

    public func listen(channels: [String]) async throws {
        try await client.notifierActor.listen(channels: channels)
    }

    public func unlisten(channel: String) async throws {
        try await client.notifierActor.unlisten(channel: channel)
    }

    public func notifications(for channel: String) async -> AsyncStream<PostgresNotification> {
        await client.notifierActor.notifications(for: channel)
    }
}

// MARK: - Namespace Properties

extension PostgresClient {
    // Core
    public var metadata: PostgresMetadataClient { .init(client: self) }
    public var admin: PostgresAdminClient { .init(client: self) }
    public var security: PostgresSecurityClient { .init(client: self) }
    public var activity: PostgresActivityClient { .init(client: self) }

    // Objects
    public var indexes: PostgresIndexClient { .init(client: self) }
    public var constraints: PostgresConstraintClient { .init(client: self) }
    public var routines: PostgresRoutineClient { .init(client: self) }
    public var views: PostgresViewClient { .init(client: self) }
    public var triggers: PostgresTriggerClient { .init(client: self) }
    public var types: PostgresTypeClient { .init(client: self) }
    public var sequences: PostgresSequenceClient { .init(client: self) }

    // Operations
    public var maintenance: PostgresMaintenanceClient { .init(client: self) }
    public var transactions: PostgresTransactionClient { .init(client: self) }
    public var executionPlan: PostgresExecutionPlanClient { .init(client: self) }
    public var bulk: PostgresBulkClient { .init(client: self) }
    public var scripts: PostgresScriptClient { .init(client: self) }
    public var session: PostgresSessionClient { .init(client: self) }
    public var serverConfig: PostgresServerConfigClient { .init(client: self) }
    public var replication: PostgresReplicationClient { .init(client: self) }

    // Postgres-specific
    public var notifier: PostgresNotifierClient { .init(client: self) }
    public var cron: PostgresCronClient { .init(client: self) }
}
