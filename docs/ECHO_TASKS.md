# Echo: plan for adopting the postgres-wire fixes

Echo is at `/Users/k/Development/Echo`. Other agents work there, so **nothing here has been applied**; this is the plan for whoever changes Echo. The background is in [INVESTIGATION_2026-09-30.md](INVESTIGATION_2026-09-30.md). The postgres-wire side is done on branch `fix/enterprise-hardening` (see §0).

## Ground rules for every phase

1. **Leave the counter and streaming cadence alone.** That means `ResultStreamBatchWorker.flushPolicy`, `maxFlushLatency`, `batchEnqueueSize`, the 200-row preview and the per-row loop in `PostgresDatabase+Streaming.swift`. Changes there have slowed queries before. No phase below needs them: E3 swaps only *where the row sequence comes from*, and the loop body stays byte for byte the same.
2. **Measure before and after** every phase that touches query execution. Use Echo's `run_postgres_streaming_bench.sh` (`postgres_benchmark.env`) or a timed `SELECT … FROM generate_series(1, 500000)`. The driver alone streams 500 000 rows in about 0.4 s, so a regression shows up clearly.
3. **UI changes go through Echo Labs first** (AGENTS.md: look it up, ask the owner if it differs). That applies to the transaction indicator (E3), cancel feedback (E4), the multi-result layout (E5) and the error underline (E6).

---

## Phase 0: Make the driver available to Echo

Echo pins `https://github.com/tashda/postgres-wire` **branch `dev`**, so it gets the fixes only when `fix/enterprise-hardening` is merged into `dev` and pushed. That's a decision for the owner, because every Echo build picks it up on its next package resolve.

**Verified:** a scratch copy of Echo HEAD, pointed at this postgres-wire working tree, builds and runs its tests with **no Echo code changes**.

What changes for Echo the moment it resolves the new `dev`, before any Echo code changes:

| Change | Effect in Echo | Action |
|---|---|---|
| `PostgresCellFormatter` renders every type correctly | Preview rows (1–200) show real arrays, intervals, inet, ranges and so on instead of garbage. `bytea` now reads `\x…` (was without `\x`), `timestamptz` ends in `+01` (was `+01:00`), uuids are lowercase. | Update any Echo tests that assert the old strings. |
| PostgresNIO ≥ 1.32 and swift-crypto 3.9–5.x are required | Echo already resolves 1.33.0 and swift-crypto 4.5.0. | None. |
| `PostgresClient.withConnection` passes errors thrown inside the closure through unchanged | Echo's closures only throw driver errors, which are still translated. | None. |
| `applicationName` is now sent | DBAs see `Echo` in `pg_stat_activity`. | Optional: name each tab, e.g. `Echo – Query 3`. |
| Pool settings are honoured; defaults unchanged (0–20 connections, 60 s idle) | None. | See Phase 3: the sidebar pool can shrink once tabs use sessions. |
| Role passwords are hashed client-side (SCRAM) and every DDL literal is escaped | Passwords containing `'` or `\` now work in the role sheets. | None. |

---

## Phase 1 (P0): Rows 201–N dropped, "200 of N" (E1)

- **Cause:** on Echo `main`, `consumeFinalResult` keeps the spool only when `total > frontBufferLimit` (500). Rows after the 200-row Postgres preview are thrown away when N ≤ 500.
- **Fix:** already on Echo `dev` (`QueryEditorState+Streaming.swift:199-200`, `hasIncompleteFinalResult`). Make sure the shipped build contains it.
- **Test:** copy [echo-regression-tests/PostgresResultPipelineTests.swift](echo-regression-tests/PostgresResultPipelineTests.swift) into `EchoTests/`. It runs Echo's real pipeline with no database. On `main` it fails for 201…499. On `dev` it fails only on values after row 200, which Phase 2 fixes.
- **Counter impact:** none. This runs once, when the query completes.

## Phase 2 (P0): Values after row 200 are binary garbage (E2)

- **Cause:** `ResultSpoolHandle.decodeRowData` (`ResultSpoolHandle+Codec.swift:4`) decodes spooled Postgres binary cells as UTF-8. The type-aware decoder isn't used, and even that one knew only 20 types.
- **Fix:** for Postgres columns, decode each spooled cell with the driver, so rows 201+ render exactly like rows 1–200:
  1. When the spool header is read, compute each column's OID once with `PostgresRowExtractor.oid(fromDataType: column.dataType)`. `dataType` is `"INTEGER(23)"`-style.
  2. In `decodeRowData`, split the row with the existing cell reader. For each cell, call `PostgresCellFormatter().stringValue(oid:data:)`, or the `UnsafeRawBufferPointer` overload to avoid copying. Leave MSSQL columns (`TDSBinaryDecoder.isTDSType`) on their current path.
  3. Switch `QueryEditorState.formatRowsSynchronously` / `PostgresPayloadFormatter` to `PostgresCellFormatter.stringValue(oid:data:)`.
  4. Delete `DirectBinaryDecoder`, `PostgresPayloadFormatter` and `PostgresDataTypeOIDMap` (`ResultSpoolTypes+BinaryDecoding.swift`).
- **Reference implementation:** [echo-reference/ResultSpoolHandle+Codec.swift](echo-reference/ResultSpoolHandle+Codec.swift) (see `decodePostgresRow`). **Verified** in a scratch copy of Echo against the new driver: the Phase 1 template, which fails on every value after row 200 without it, passes with it. Still to do for production: compute the OIDs once per spool instead of once per row.
- **Test:** the Phase 1 template now passes completely. Add a Postgres integration test that spools a table with arrays, intervals, uuids, numerics and timestamps, and compares rows 1 and 300.
- **Counter impact:** none. Decoding happens when rows are read back from disk, not while streaming. Check `loadRows` throughput for a 5 000-row batch before and after.

## Phase 3 (P0): One pinned connection per query tab (E3)

- **Cause:** every run in a Postgres tab borrows a connection from a pool (`client.withConnection`). An open `BEGIN` on a connection idle for 60 s is closed by the pool and rolled back. `COMMIT` then "succeeds" on a new connection: measured 0 of 1 rows committed. `SET`, temp tables and `SET ROLE` are lost the same way.
- **Driver API:** `PostgresServerConnection.makeSession(database:)` returns a `PostgresSessionConnection`:
  - `query(_:)` streams rows, a drop-in for `connection.simpleQuery(_:)`.
  - `queryResult(_:)` returns rows plus the command tag.
  - `transactionStatus` / `refreshTransactionStatus()`.
  - `cancel()`.
  - Throws `PostgresSessionError.connectionClosed(transactionLost:)` instead of reconnecting silently.
- **Changes:**
  1. `makeDedicatedQuerySession()` (`EnvironmentState+Connections.swift`, `+TabManagement.swift`): for Postgres, build the tab's session with `serverConnection.makeSession(database: activeDB)`. Keep the pooled `PostgresClient` for metadata, FK lookups, autocomplete and explain helpers. Those must **not** run on the tab's session, because they would queue behind a long query and interleave with the user's transaction.
  2. `PostgresSession.streamQueryUsingSimpleProtocol`: replace `self.client.withConnection { connection in … connection.simpleQuery(sql) … }` with `let rowSequence = try await querySession.query(sql)`. **Change nothing else in that function.** The preview, the worker, the flush cadence and the counter stay the same (ground rule 1).
  3. `PostgresSession.executeSimpleQuery` (message-only statements: `BEGIN`, `COMMIT`, `SET`, DDL): use `querySession.queryResult(sql)`. Otherwise `BEGIN` still lands on the pool.
  4. Switching the tab's database closes the session and opens one for the new database. If a transaction is open, ask first.
  5. Closing a tab with `transactionStatus != .idle`: ask Commit / Roll back / Cancel.
  6. `PostgresSessionError.connectionClosed(transactionLost: true)`: tell the user nothing since `BEGIN` was saved, and offer to reconnect explicitly.
  7. `normalizeError` (`PostgresDatabase+Utilities.swift`) handles only `PSQLError` today. Sessions throw `PostgresKit.PostgresError`, `PostgresSessionError` and `PostgresScriptError`. Map `sqlState`, `hint`, `detail` and `position` from `PostgresError` the same way.
  8. Optional, after measuring: shrink the sidebar pool (`PostgresConfiguration.pool`, for example max 5) now that tabs no longer draw from it.
- **Design (Echo Labs):** a transaction indicator for the tab or footer, plus the close-tab dialog.
- **Test:** `BEGIN; INSERT …;` wait 65 s, then `COMMIT`: the row is stored. `SET search_path` survives across runs. Kill the backend with `pg_terminate_backend` during a transaction and check the lost-transaction message.
- **Counter impact:** none, because only the source of the row sequence changes. Benchmark 500k rows before and after anyway.

## Phase 4 (P1): Cancel stops the query on the server (E4)

- **Cause:** Cancel only cancels the Swift task, and the loop checks between rows. Measured: a 0.5 s cancel of `pg_sleep(6)` returned after 6 s. An abandoned big result keeps the connection busy while PostgresNIO drains it (15 s measured).
- **Changes:**
  1. Add `cancelCurrentQuery()` to `DatabaseSession`, with a default no-op. For Postgres, call `try await querySession.cancel(using: client)`, which sends `pg_cancel_backend` through the pool with no new handshake.
  2. In the cancel path (`QueryEditorState.cancelExecution` → executing task), **cancel on the server first**, then cancel the Swift task. The row loop then ends with SQLSTATE `57014`; show that as "cancelled", not as an error.
  3. Settings: a per-connection statement timeout (`PostgresConfiguration.statementTimeout`) and optionally a per-tab one (`querySession.setStatementTimeout`, where `nil` means the connection default and `.zero` means none).
- **Test:** cancel `SELECT pg_sleep(10)` after 0.5 s: done in under 1 s, and the next query runs at once. Cancel a 20M-row `SELECT` after 1 000 rows: the next query runs at once.
- **Counter impact:** none.

## Phase 5 (P1): Scripts with several statements (E5)

- **Cause:** PostgresNIO runs one statement per query, and Echo splits scripts only for MSSQL (`GO`). So `SELECT 1; SELECT 2` fails.
- **Driver API:**
  - `PostgresSQLSplitter.split(_:)` returns statements with `text`, `range` and `utf16Range` (for `NSRange`). It understands quotes, `$$` bodies, comments and `BEGIN ATOMIC`.
  - `returnsRows(_:)` tells whether a statement produces rows.
  - `PostgresSessionConnection.executeScript(_:onStatement:)` runs a script and names the failing statement.
- **Changes:** in `WorkspaceTabContainerView+Execution`, split Postgres SQL the way MSSQL batches are split:
  - A row-returning statement runs through the **existing** streaming path, one result set each, reusing the worker unchanged.
  - A command statement goes through `queryResult` and appears as a message with its command tag (`UPDATE 3`).
  - Stop at the first error, like psql's `ON_ERROR_STOP`, and report the statement index.
  - Use `utf16Range` for "results inline at the end of what ran" (QE2) and for error locations.
- **Design (Echo Labs):** how several result sets and messages appear. Reuse the MSSQL multi-batch layout if the owner agrees.
- **Test:** a script with a `CREATE`, an `INSERT` containing `';'`, a `DO $$ … ; … $$`, and two `SELECT`s gives two grids and three messages.

## Phase 6 (P2): Underline the error position (E6)

- `PostgresError.position` is the 1-based **character** position in the statement that failed. For scripts, add the statement's start (`PostgresSQLStatement.range.lowerBound`) and convert to UTF-16 for the editor. `internalPosition` covers errors inside functions. Show `hint` and `detail` under the message.

## Phase 7 (P2): Suspected wrong database while waiting for the dedicated session (E7)

- `WorkspaceTabContainerView+Execution.swift`: line 111 resolves `sessionForDatabase(activeDB)`, but when `needsDedicatedSessionWait` is true, line 162 uses `awaitDedicatedSession()` directly, which is connected to its own database. Phase 3 replaces this path; check it there.

## Testing debt to clear alongside the phases

All of Echo's Postgres integration tests are disabled (`EchoTests/Integration/Postgres/*.swift.disabled`, including `PGStreamingTests`, `PGStreamingSpoolTests` and the `PGDataType*Tests`). Re-enable them together with Phases 2–5, on the `PostgresDockerTestCase` fixture, so the grid path has coverage against a real server.

## Phase 8 (P3): Small items

- `ResultGridValueClassifier` treats any type token `bit` as boolean. A Postgres `bit(4)` column (`"BIT(1560)"`) would show `1011` as a boolean. Limit this to `bit(1)` and to MSSQL `bit`.
- PostgresNIO requests binary results, so a column whose type has no binary output function fails the whole query with SQLSTATE `42883` ("no binary output function available for type aclitem"). The common case is `pg_class.relacl` / `aclitem[]`. Verified on PG 18. Show a hint to cast the column (`relacl::text[]`) instead of the bare error.
- `PostgresSession.streamQuery` returns no command tag. After Phase 5, command statements carry theirs.

---

## Suggested order and size

| Phase | Priority | Touches the streaming path? | Rough size |
|---|---|---|---|
| 0 Merge driver to `dev` | – | no | owner decision |
| 1 E1 regression test / ship `dev` fix | P0 | no | small |
| 2 E2 spool decoding | P0 | no (materialization only) | small–medium |
| 3 E3 pinned sessions | P0 | only the row-sequence source | medium |
| 4 E4 server-side cancel | P1 | no | small |
| 5 E5 scripts | P1 | reuses it per statement | medium (plus a design round) |
| 6 E6 error underline | P2 | no | small (plus a design round) |
| 7 E7, 8 small items | P2–P3 | no | small |
