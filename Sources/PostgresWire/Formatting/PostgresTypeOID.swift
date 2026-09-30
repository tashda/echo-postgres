/// Built-in Postgres type OIDs the binary formatter knows about.
enum PostgresTypeOID {
    static let bool: UInt32 = 16
    static let bytea: UInt32 = 17
    static let char: UInt32 = 18
    static let name: UInt32 = 19
    static let int8: UInt32 = 20
    static let int2: UInt32 = 21
    static let int2vector: UInt32 = 22
    static let int4: UInt32 = 23
    static let regproc: UInt32 = 24
    static let text: UInt32 = 25
    static let oid: UInt32 = 26
    static let tid: UInt32 = 27
    static let xid: UInt32 = 28
    static let cid: UInt32 = 29
    static let oidvector: UInt32 = 30
    static let json: UInt32 = 114
    static let xml: UInt32 = 142
    static let point: UInt32 = 600
    static let lseg: UInt32 = 601
    static let path: UInt32 = 602
    static let box: UInt32 = 603
    static let polygon: UInt32 = 604
    static let line: UInt32 = 628
    static let cidr: UInt32 = 650
    static let float4: UInt32 = 700
    static let float8: UInt32 = 701
    static let unknown: UInt32 = 705
    static let circle: UInt32 = 718
    static let macaddr8: UInt32 = 774
    static let money: UInt32 = 790
    static let macaddr: UInt32 = 829
    static let inet: UInt32 = 869
    static let bpchar: UInt32 = 1042
    static let varchar: UInt32 = 1043
    static let date: UInt32 = 1082
    static let time: UInt32 = 1083
    static let timestamp: UInt32 = 1114
    static let timestamptz: UInt32 = 1184
    static let interval: UInt32 = 1186
    static let timetz: UInt32 = 1266
    static let bit: UInt32 = 1560
    static let varbit: UInt32 = 1562
    static let numeric: UInt32 = 1700
    static let refcursor: UInt32 = 1790
    static let regprocedure: UInt32 = 2202
    static let regoper: UInt32 = 2203
    static let regoperator: UInt32 = 2204
    static let regclass: UInt32 = 2205
    static let regtype: UInt32 = 2206
    static let record: UInt32 = 2249
    static let void: UInt32 = 2278
    static let uuid: UInt32 = 2950
    static let txidSnapshot: UInt32 = 2970
    static let pgLSN: UInt32 = 3220
    static let tsvector: UInt32 = 3614
    static let tsquery: UInt32 = 3615
    static let regconfig: UInt32 = 3734
    static let regdictionary: UInt32 = 3769
    static let jsonb: UInt32 = 3802
    static let jsonpath: UInt32 = 4072
    static let regnamespace: UInt32 = 4089
    static let regrole: UInt32 = 4096
    static let regcollation: UInt32 = 4191
    static let pgSnapshot: UInt32 = 5038
    static let xid8: UInt32 = 5069

    /// OID-valued types whose binary form is the referenced object's OID.
    static let oidLike: Set<UInt32> = [
        oid, regproc, regprocedure, regoper, regoperator, regclass, regtype,
        regconfig, regdictionary, regnamespace, regrole, regcollation, xid, cid,
    ]

    /// Types whose binary form is the same UTF-8 text as their text form.
    static let textLike: Set<UInt32> = [text, varchar, bpchar, name, unknown, refcursor, xml, json]

    /// Range type → element type.
    static let rangeSubtype: [UInt32: UInt32] = [
        3904: int4, 3906: numeric, 3908: timestamp, 3910: timestamptz, 3912: date, 3926: int8,
    ]

    /// Multirange type → range type (Postgres 14+).
    static let multirangeRange: [UInt32: UInt32] = [
        4451: 3904, 4532: 3906, 4533: 3908, 4534: 3910, 4535: 3912, 4536: 3926,
    ]

    /// Built-in array types. The element OID is also embedded in the value itself.
    static let arrayTypes: Set<UInt32> = [
        143, 199, 271, 629, 651, 719, 775, 791, 1000, 1001, 1002, 1003, 1005, 1006, 1007, 1008,
        1009, 1010, 1011, 1012, 1013, 1014, 1015, 1016, 1017, 1018, 1019, 1020, 1021, 1022, 1027,
        1028, 1034, 1040, 1041, 1115, 1182, 1183, 1185, 1187, 1231, 1263, 1270, 1561, 1563, 2201,
        2207, 2208, 2209, 2210, 2211, 2287, 2949, 2951, 3221, 3643, 3645, 3735, 3770, 3807, 3905,
        3907, 3909, 3911, 3913, 3927, 4073, 4090, 4097, 4192, 5039, 6150, 6151, 6152, 6153, 6155, 6157,
    ]
}
