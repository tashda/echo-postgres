import Foundation

/// Information about an aggregate function.
public struct PostgresAggregateInfo: Sendable {
    public let name: String
    public let schema: String
    public let inputType: String
    public let stateType: String
    public let stateFunction: String
    public let initialValue: String?

    public init(name: String, schema: String, inputType: String, stateType: String, stateFunction: String, initialValue: String?) {
        self.name = name
        self.schema = schema
        self.inputType = inputType
        self.stateType = stateType
        self.stateFunction = stateFunction
        self.initialValue = initialValue
    }
}

/// Information about an operator.
public struct PostgresOperatorInfo: Sendable {
    public let name: String
    public let schema: String
    public let leftType: String?
    public let rightType: String?
    public let resultType: String
    public let procedure: String

    public init(name: String, schema: String, leftType: String?, rightType: String?, resultType: String, procedure: String) {
        self.name = name
        self.schema = schema
        self.leftType = leftType
        self.rightType = rightType
        self.resultType = resultType
        self.procedure = procedure
    }
}

/// Information about a procedural language.
public struct PostgresLanguageInfo: Sendable {
    public let name: String
    public let owner: String
    public let isPL: Bool
    public let isTrusted: Bool

    public init(name: String, owner: String, isPL: Bool, isTrusted: Bool) {
        self.name = name
        self.owner = owner
        self.isPL = isPL
        self.isTrusted = isTrusted
    }
}

/// Information about a type cast.
public struct PostgresCastInfo: Sendable {
    public let sourceType: String
    public let targetType: String
    public let function: String?
    public let context: String

    public init(sourceType: String, targetType: String, function: String?, context: String) {
        self.sourceType = sourceType
        self.targetType = targetType
        self.function = function
        self.context = context
    }
}
