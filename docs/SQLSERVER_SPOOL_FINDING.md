# Echo, SQL Server: values after row 200 are shown as raw bytes

Found 2026-09-30 while fixing the same bug on the PostgreSQL path. **Reproduced** with Echo's real
result pipeline (test: [echo-regression-tests/MSSQLSpoolReproTests.swift](echo-regression-tests/MSSQLSpoolReproTests.swift)).

## Symptom

For a SQL Server query whose columns are all "raw-decodable" types, rows 1–200 look right and every row
after that shows garbage. The row *count* is correct.

| Row | `id int` | `name nvarchar` |
|---|---|---|
| 1 / 200 | `1` / `200` | `row1` / `row200` |
| 201 | `c9 00 00 00` | `r\0o\0w\02\00\01\0` |
| 251 | `fb 00 00 00` | `r\0o\0w\02\05\01\0` |
| 1000 | `e8 03 00 00` | `r\0o\0w\01\00\00\00\0` |

Affected: queries where **every** column type is in `TDSBinaryDecoder.canDecodeRaw`: `int`, `bigint`,
`smallint`, `tinyint`, `bit`, `float`, `real`, `char`, `varchar`, `text`, `nchar`, `nvarchar`, `ntext`,
`xml`, `binary`, `varbinary`, `image`, `uniqueidentifier`. A single `datetime` or `decimal` column switches
the whole query to the string path, which is correct. So `SELECT id, name FROM t` breaks, but
`SELECT id, name, created_at FROM t` does not.

## Cause

1. `MSSQLDedicatedQuerySession+Queries.swift` (around lines 127–175) and
   `SQLServerSessionAdapter+Queries.swift` (around line 148) store rows as follows:
   - rows 1–200 as `.stringValues` (UTF-8 strings);
   - when `canUseRawPath` is true, rows 201+ as `.raw(RawRow)` holding the **TDS wire bytes** from
     `row.rawColumnBuffers()`: `int` is Int32 little-endian, `nvarchar` is UTF-16LE, `varchar` is in
     the column's code page.
   The comment there says "String conversion happens at display time via TDSBinaryDecoder".
2. `ResultStreamBatchWorker` encodes both kinds into the same spool row format
   (`0x01` + UInt32-LE length + bytes).
3. Rows after the in-memory preview are read back from the spool by
   `ResultSpoolHandle.decodeRowData` (`ResultSpool/ResultSpoolHandle+Codec.swift`). For SQL Server
   spools it uses `ResultBinaryRowCodec.decode(_:columnCount:)`, which reads every cell as UTF-8 with a
   hex fallback. **`TDSBinaryDecoder` is never called on this path.** The only caller would be
   `ResultBinaryRowCodec.decode(_:columns:)`, which nothing uses.

## Why the obvious fix is wrong

Switching `decodeRowData` to the type-aware `decode(_:columns:)` fixes rows 201+, but breaks rows 1–200.
Those are stored as UTF-8 **strings** in the same spool, and the type-aware decoder would read them as
TDS bytes. Measured: the preview row `["1234", "row1"]` comes back as `["875770417", "潲ㅷ"]`.

## Fix options (pick one)

1. **Store the preview rows as raw TDS bytes too** when `canUseRawPath` is true, keeping the preview
   strings only for the immediate display (`previewValues`). Every spool row is then TDS, and
   `decodeRowData` can use `decode(_:columns:)` (or `TDSBinaryDecoder` directly) for SQL Server spools.
   This is closest to what the PostgreSQL path now does. *Recommended.*
2. **Record the encoding per spool chunk** (strings or TDS) in `ChunkRecord`, and decode each chunk
   accordingly.
3. **Drop the raw path** and always store `.stringValues`. This is simplest but costs per-row string
   conversion on the streaming hot path. Measure before choosing it, because the raw path exists for
   speed.

Also check:
- `varchar`/`char`/`text` raw bytes are in the column's collation code page. UTF-8 decoding is only
  right for ASCII. `TDSBinaryDecoder` needs the collation for non-ASCII text (for example Latin-1 `é`).
- `uniqueidentifier` has TDS's mixed-endian byte order (see the earlier sqlserver-nio byte-swap fix).

## How the PostgreSQL path was fixed (for reference)

Echo commit `6ff48dde`: every Postgres spool row is binary, the columns carry `"NAME(OID)"`, and
`decodeRowData` formats cells with the driver (`PostgresSpoolColumns.decodeRow`) only when *all*
columns are Postgres columns. SQL Server spools still take the old UTF-8 path, so this bug remains.

## Test

Copy `MSSQLSpoolReproTests.swift` into `EchoTests/`. It feeds `ResultStreamBatchWorker` exactly as
`MSSQLDedicatedQuerySession` does (200 `.stringValues` rows, then `.raw` TDS rows), then runs
`consumeFinalResult`, `finishExecution` and the spool. It writes what rows 1, 200, 201, 251 and 1000
display. Turn it into assertions (row 251 must read `["251", "row251"]`) once fixed.
