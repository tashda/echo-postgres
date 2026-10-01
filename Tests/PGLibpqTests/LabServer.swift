import Foundation
import PGLibpq
import Testing

/// The lab server from `POSTGRES_TEST_URL` (`serverlab run --recipe pg-18-empty -- swift test`).
enum LabServer {
    static let url = ProcessInfo.processInfo.environment["POSTGRES_TEST_URL"].flatMap(URLComponents.init(string:))
    static var isAvailable: Bool { url != nil }

    /// The URL as libpq keywords (what PostgresKit builds from its configuration).
    static var parameters: PGConnectionParameters {
        var parameters = PGConnectionParameters()
        guard let url else { return parameters }
        parameters.set("host", url.host)
        parameters.set("port", url.port.map(String.init))
        parameters.set("user", url.user?.removingPercentEncoding)
        parameters.set("password", url.password?.removingPercentEncoding)
        let database = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parameters.set("dbname", database.isEmpty ? "postgres" : database)
        parameters.set("sslmode", url.queryItems?.first { $0.name == "sslmode" }?.value ?? "prefer")
        parameters.set("gssencmode", "disable")
        parameters.set("application_name", "PGLibpqTests")
        parameters.set("client_encoding", "UTF8")
        return parameters
    }

    static func connect() async throws -> PGConnection {
        try await PGConnection.connect(parameters, timeout: .seconds(15))
    }
}

extension Trait where Self == ConditionTrait {
    static var labServer: Self { .enabled(if: LabServer.isAvailable, "Needs POSTGRES_TEST_URL (serverlab run)") }
}
