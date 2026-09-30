extension PostgresBinaryFormatter {
    static func formatGeometry(oid: UInt32, _ reader: inout PostgresBinaryReader) throws -> String {
        typealias T = PostgresTypeOID
        func number() throws -> String {
            let value = try reader.readFloat8()
            return formatFloat(value, description: value.description, exponentThreshold: 15)
        }
        func point() throws -> String {
            let x = try number()
            let y = try number()
            return "(\(x),\(y))"
        }
        func points(_ count: Int) throws -> String {
            guard count >= 0 else { throw PostgresBinaryFormatError() }
            return try (0..<count).map { _ in try point() }.joined(separator: ",")
        }

        let text: String
        switch oid {
        case T.point:
            text = try point()
        case T.lseg:
            text = "[\(try point()),\(try point())]"
        case T.box:
            text = "\(try point()),\(try point())"
        case T.path:
            let closed = try reader.read(UInt8.self) != 0
            let list = try points(Int(try reader.read(Int32.self)))
            text = closed ? "(\(list))" : "[\(list)]"
        case T.polygon:
            text = "(\(try points(Int(try reader.read(Int32.self)))))"
        case T.line:
            text = "{\(try number()),\(try number()),\(try number())}"
        case T.circle:
            let center = try point()
            text = "<\(center),\(try number())>"
        default:
            throw PostgresBinaryFormatError()
        }
        try reader.expectEnd()
        return text
    }
}
