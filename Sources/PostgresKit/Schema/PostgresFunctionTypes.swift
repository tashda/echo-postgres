import Foundation

/// PostgreSQL function parameter mode.
public enum PostgresFunctionMode: Sendable {
    case `in`
    case `out`
    case `inout`
}

/// PostgreSQL function language.
public enum PostgresFunctionLanguage: String, Sendable {
    case sql = "SQL"
    case plpgsql = "PLPGSQL"
    case plpython = "PLPYTHON3U"
    case plperl = "PLPERLU"
    case pltcl = "PLTCL"
}

/// PostgreSQL function security.
public enum PostgresFunctionSecurity: Sendable {
    case definer
    case invoker
}

/// PostgreSQL function parameter definition.
public struct PostgresFunctionParameter: Sendable {
    public let name: String
    public let dataType: String
    public let mode: PostgresFunctionMode
    public let defaultValue: String?

    public init(
        name: String,
        dataType: String,
        mode: PostgresFunctionMode = .`in`,
        defaultValue: String? = nil
    ) {
        self.name = name
        self.dataType = dataType
        self.mode = mode
        self.defaultValue = defaultValue
    }
}
