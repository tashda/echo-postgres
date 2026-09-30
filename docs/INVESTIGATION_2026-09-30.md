# postgres-wire investigation — 2026-09-30

> **Status (same day): the postgres-wire items PW1–PW10 are fixed** on branch `fix/enterprise-hardening` (not merged or pushed). See "Fix status" at the end. The Echo side is planned in [ECHO_TASKS.md](ECHO_TASKS.md).

Scope: (1) why Echo shows only 200 rows for Postgres results, (2) whether the row counter / streaming path is healthy, (3) whether postgres-wire is ready for enterprise use, (4) whether Echo uses the driver correctly.

No code was changed in postgres-wire or Echo. Echo was read only. Evidence comes from code reading plus three experiments, all in a scratch directory:

- **Echo pipeline reproduction.** A `git archive` copy of Echo, with one test (`PGReproTests`). The test drives the real `ResultStreamBatchWorker` → `QueryEditorState` → spool → progressive materialization. It uses the same 200-row preview and the same two MainActor hops as `PostgresSession`.
- **Driver audit harness.** A small SwiftPM executable that uses postgres-wire exactly the way Echo does. It ran against a throwaway `postgres:17` Docker container, which is now stopped.
- postgres-wire at `dev` `3b9f60b`, the revision Echo pins. PostgresNIO 1.33.0, as resolved by Echo.

Echo task items referenced below (`E1`…) are in [ECHO_TASKS.md](ECHO_TASKS.md). postgres-wire items (`PW1`…) are at the end of this document.

---

## 1. Verdict

| Question | Answer |
|---|---|
| Does postgres-wire fetch all rows? | **Yes.** Measured: 201, 10 000 and 500 000 rows all arrive (500 000 rows in 0.38 s through the exact API Echo uses). |
| Where do rows > 200 disappear? | **In Echo, not the driver.** Echo `main` drops everything after the 200-row preview when the result is ≤ 500 rows. It is fixed on Echo `dev` but not on `main`. |
| Is that the only problem with rows > 200? | **No.** On every branch, rows after 200 that Echo reloads from its disk spool are decoded as raw binary. `id = 251` shows as `00 00 00 fb`. |
| Is the counter / streaming path OK? | **Yes, as Echo does it today.** Echo bypasses postgres-wire's own `streamQuery` API. That API would be slow if anyone used it (§3). Do not change Echo's counter cadence as part of these fixes; none of them need it. |
| Enterprise-ready? | **Not yet.** Moving rows is fast and correct. But session and transaction behaviour on the pool can **silently lose committed work**. There is no server-side cancel, several settings are silently ignored, many data types render as garbage, and multi-statement scripts fail. |
| Does Echo use the driver correctly? | Mostly well for speed (low-level extractor and formatter, no actor per row). The big misuse is running query tabs on a **pool** instead of one pinned connection. |

---

## 2. The 200-row bug

### 2.1 What happens

`PostgresSession.streamQueryUsingSimpleProtocol` (Echo, `PostgresDatabase+Streaming.swift:27`) formats the first **200** rows (`initialPreviewBatch = 200`). Every later row is sent to `ResultStreamBatchWorker` as binary only. The final `QueryResultSet` carries those 200 preview rows plus `totalRowCount = N`.

When the query finishes, `QueryEditorState.consumeFinalResult` decides whether to keep the binary rows (the "spool"):

- **Echo `main`:** `shouldPersistResults = shouldPersistResults || total > frontBufferLimit`. `frontBufferLimit` = `resultsInitialRowLimit`, 500 by default. For 201 ≤ N ≤ 500, and when streaming never reached the spool activation threshold (2 000), this is false. The else branch then runs `deferredSpoolUpdates.removeAll()`, which **throws away rows 201…N**. The grid shows 200 while the counter says N.
- **Echo `dev` / current checkout:** `QueryEditorState+Streaming.swift:199-200` adds `hasIncompleteFinalResult = result.rows.count < total`, so the spool is always kept when the preview is incomplete. This change arrived in the large refactor commit `fb371df4` and was never merged to `main`.

If someone raised "Initial rows" in Settings, the cut-off moves with it: every result smaller than that setting would show only 200 rows.

### 2.2 Reproduction (real Echo code)

`PGReproTests` feeds N synthetic Postgres rows (int4 + text, binary format, the same encoding as `PostgresRowExtractor.encodeBinaryRow`) through the real worker, double MainActor hop, `consumeFinalResult`, `finishExecution` and spool:

| N | Echo `main` shown / reported | Echo `dev` shown / reported | Row 250 value (`id`) on either branch |
|---|---|---|---|
| 150 | 150 / 150 | 150 / 150 | – |
| 201 | **200 / 201** | 201 / 201 | – |
| 250 | **200 / 250** | 250 / 250 | – |
| 450 | **200 / 450** | 450 / 450 | **`00 00 00 fb`** (should be `251`) |
| 499 | **200 / 499** | 499 / 499 | **`00 00 00 fb`** |
| 501 … 10 000 | N / N | N / N | **`00 00 00 fb`** |

### 2.3 The second bug: rows after 200 are garbled

`ResultSpoolHandle.decodeRowData` (`ResultSpoolHandle+Codec.swift:4`) decodes spooled rows with `ResultBinaryRowCodec.decode(_:columnCount:)`. That function reads every cell as UTF-8 and falls back to hex. The type-aware `decode(_:columns:)` in `ResultSpoolTypes.swift:128` (OID-based `DirectBinaryDecoder`) exists but **nothing calls it**. The bytes are Postgres **binary** wire format, because PostgresNIO always requests binary results. So every non-text column after row 200 shows as hex or mojibake. → **E2**

Even the type-aware decoder only knows about 20 OIDs. Arrays, `interval`, `inet` and other types would still be wrong (§4.4). The long-term fix is a single complete binary formatter in postgres-wire used for *both* preview rows and spool rows (**PW2** + **E2**). Then rows 1–200 and rows 201+ cannot drift apart. Today they already differ: uuids are UPPERCASE in the preview and lowercase from the spool.

### 2.4 If you run a `dev` build and still see 200

The model-level reproduction passes on `dev`. The remaining piece not covered is the AppKit table refresh (`QueryResultsTableBridge+Update`). First confirm which branch the running Echo was built from. If it is `dev` and the problem remains, instrument `displayedRowCount` against `numberOfRows(in:)` after completion. → **E1**

---

## 3. Counter and streaming performance

**What Echo does today (fine, leave it alone):**

- **Per row:** during the preview, Echo formats the row with the synchronous `PostgresCellFormatter` (no actors). After row 200 it only captures `ByteBuffer` slices, and encoding happens on a GCD queue in `ResultStreamBatchWorker`.
- **Worker flush policy:**
  - While preview rows are pending, the worker flushes about every 32 rows.
  - After the preview it flushes at 8 192 rows, or at 2 048 rows after 100 ms, or at 256 rows after 150 ms.
  - So the counter updates at most every ~100–150 ms, not per row. Each flush costs two MainActor hops plus `applyStreamUpdate`.
- The driver loop itself is not the bottleneck: 500 000 rows in 0.38 s through PostgresNIO.

None of the fixes in this report touch that cadence. E2 changes decoding at *materialization* time (reading back from disk), which is off the streaming path.

**postgres-wire's own streaming API (`PostgresWireClient.streamQuery`, `PostgresDataStream`) is the slow one.** Echo does not use it, and nobody should in its current form:

- Default `liveCounterFrequency = 5`: a progress update every 5 rows. Each update awaits the `PostgresDataStream` actor about five times and copies row arrays.
- `processedRowCount % liveCounterFrequency` crashes on division by zero if the frequency is set to 0.
- After `maxConcurrentRows` (100 000), `enforceMemoryLimits` calls `removeFirst` for **every** row. That is O(n) per row, so O(n²) overall. It also shifts the arrays, so `getFormattedRows(in:)` then returns the **wrong rows** for a given index.
- `row.contains(nil)` treats real SQL NULLs as "not yet formatted", so those rows are formatted again and again.
- `streamQueryWithCursor` wraps the user SQL in `DECLARE … CURSOR FOR <sql>`, which breaks on a trailing `;` or multiple statements, and runs its own `BEGIN`/`COMMIT`.
- The `incrementalWindowSize = 200` and `initialPreviewRows` knobs are not used by Echo. (That 200 is a coincidence and not the cause.)

→ **PW9**: deprecate or remove `PostgresDataStream` and `streamQuery`, or rebuild them on the extractor, formatter and batch model Echo proved out.

---

## 4. Enterprise readiness

Severity: **S1** can lose or corrupt data, or show wrong values as if they were right. **S2** is a major functional or resilience gap. **S3** is correctness or hygiene.

### 4.1 Sessions, transactions, pooling

| # | Finding | Sev | Evidence |
|---|---|---|---|
| A1 | **Pooled "sessions" silently lose transactions.** `PostgresClient` is a PostgresNIO pool (min 0, max 20, idle timeout 60 s, keep-alive `SELECT 1` every 30 s). Every Echo run is a separate `withConnection` lease. If a connection holding an open `BEGIN` sits idle for 60 s, the pool closes it and the server rolls back. The next statement (`COMMIT`) runs on a new connection with only a server WARNING. | **S1** | Measured: `BEGIN` → `INSERT` → idle 65 s → `COMMIT` ⇒ backend pid 90 → 97, **0 rows** in the table. |
| A2 | `PostgresTransactionClient` (`client.transactions.beginTransaction/commit/savepoint…`) sends each statement through the pool, so each one can run on a different connection. That can leave a connection "idle in transaction" in the pool, and later unrelated queries run inside it. Echo does not use this API. | **S1** | `TransactionManagement.swift`, `PostgresClient.executeDDL` → `wire.query` (pooled). |
| A3 | Session state (`SET search_path`, `SET ROLE`, temp tables, `LISTEN`, advisory locks) is lost whenever the pool rotates or expires a connection. The same happens whenever two operations on one tab overlap, for example the FK-metadata fetch Echo starts right after a query. | S2 | Same mechanism as A1. |
| A4 | `PostgresConfiguration.pool` (min / max / idle) is **ignored**. `makeWireConfiguration()` drops it, and `PostgresWireClient.connect` never sets `PostgresClient.Configuration.options`. | S2 | `PostgresConfiguration.swift:92-106`, `WireClient.swift:178-188`. |
| A5 | `applicationName` is **ignored** and never passed as a startup parameter. Echo sets `"Echo"`, but DBAs see an empty `application_name` in `pg_stat_activity`. | S2 | Measured: `application_name=''`. |
| A6 | Each `PostgresServerConnection.client(for:)` database gets its own 20-connection pool. Concurrent first calls for the same database race and create two pools, and one of them is never closed. With per-tab dedicated sessions, the connection count per Echo window grows quickly. | S2 | `PostgresServerConnection.swift:114-129`. |
| A7 | Retain cycle: `PostgresClient` holds `notifierActor`, which holds the client strongly. `deinit { wire.close() }` can never run, so connections are released only by an explicit `close()`. | S3 | `PostgresClient.swift:14,21`, `PostgresNotifier.swift:11`. |
| A8 | `PreparedRegistry` keeps caches per `ObjectIdentifier(connection)` and never evicts them, so memory grows as the pool churns connections. Identifiers can be reused after deallocation. | S3 | `PostgresClient.swift:100-116`. |

### 4.2 Cancellation, timeouts, resilience

| # | Finding | Sev | Evidence |
|---|---|---|---|
| B1 | **No server-side cancel.** There is no CancelRequest and no `pg_cancel_backend` path. Cancelling the Swift task only stops the loop *between rows*. | **S2** | Measured: `SELECT pg_sleep(6)` cancelled at 0.5 s returned after **6.02 s**. |
| B2 | Abandoning a large result keeps the connection busy: PostgresNIO drains all remaining rows before the connection can be reused. | **S2** | Measured: broke after 1 000 of 20 M rows, and the next query on that connection waited **15.4 s**. |
| B3 | No statement timeout or lock timeout options on queries. | S2 | – |
| B4 | The connect timeout works (measured 3.00 s for a 3 s setting). But the comment in `WireClient.connect` describes a continuation race while the code uses a task group, which waits for its children. That is fine today but fragile. | S3 | `WireClient.swift:139-167`. |
| B5 | No multi-host failover, `target_session_attrs`, Unix sockets, IAM / RDS token auth, or Kerberos. `sslmode=allow` behaves like `prefer`. | S3 | `WireClient.swift` TLS mapping. |

### 4.3 Query protocol

| # | Finding | Sev | Evidence |
|---|---|---|---|
| C1 | **Multi-statement scripts fail.** `simpleQuery` is *not* the simple query protocol. Everything goes through PostgresNIO's extended protocol. | **S2** | Measured: `SELECT 1; SELECT 2` ⇒ `cannot insert multiple commands into a prepared statement`. Echo only splits scripts for MSSQL (`GO`). |
| C2 | The "prepared statement cache" is a no-op. `WireConnection.prepare` just wraps the SQL string, so the LRU and the `26000` retry are dead code. `LRUCache` indices also go stale after eviction, so it degrades to FIFO. | S3 | `WireTypes.swift:140-151`, `StatementCache.swift`. |
| C3 | `PostgresError` drops the server's error `position`, so Echo cannot underline the error location in the editor. The hint is only reachable through `withDebugging()`. | S3 | `PostgresError.swift:55-62`. |

### 4.4 Data type rendering (`PostgresCellFormatter`, which Echo uses for every preview row)

PostgresNIO returns **binary** for every column. For types the formatter does not handle, it calls `cell.decode(String.self)`, and PostgresNIO's fallback reads the raw bytes as UTF-8, which never fails. Measured output:

| Type | Shown in Echo | Should be |
|---|---|---|
| `int4[]`, `text[]` (all arrays) | `\u{0}\u{0}\u{0}\u{1}…` | `{1,2,3}`, `{a,b}` |
| `interval` | control characters | `1 day 02:03:04` |
| `inet`, `cidr`, `macaddr` | control characters | `192.168.1.10/24`, … |
| `point`, ranges, `tsvector`, `bit`, `oid` | control characters | text forms |
| `money` | `00000000000004d2` | `$12.34` |
| `timetz '12:00+02'` | `12:00:00+120:00` (offset read as minutes; it is seconds) | `12:00:00+02` |
| `numeric 'NaN'` | **`0`** (wrong value, looks valid) | `NaN` |
| `timestamp 'infinity'` | `294277-01-09 04:00:54.775807` | `infinity` |
| `date '0044-03-15 BC'` | `0044-03-17` (no era, Gregorian vs. proleptic) | `0044-03-15 BC` |
| `uuid` | UPPERCASE (spool path gives lowercase) | lowercase |

Correct today: `bool`, `int2/4/8`, `float4/8`, normal `numeric`, `text`/`varchar`/`name`/`char`, `json`/`jsonb`, `xml`, `bytea`, `date`/`time`/`timestamp`/`timestamptz` (finite values).

Tests miss all of this because `DataTypeRoundTripTests` casts values to `::text` on the server. Nothing tests `PostgresCellFormatter` or `PostgresRowExtractor`, the two APIs Echo actually depends on. → **PW2**, **PW8**. (One more option: request text format for OIDs without a binary formatter. PostgresNIO does not expose per-column result formats today, so a complete binary formatter is the practical route.)

### 4.5 Admin, DDL and bulk

| # | Finding | Sev |
|---|---|---|
| D1 | Role passwords and several DDL literals are interpolated **without escaping**: `WITH PASSWORD '\(password)'`, `VALID UNTIL`, `ENCODING`/`LC_*`/`ICU_*`, `publish = '…'`, column defaults. A password containing `'` breaks, or injects SQL. Plain-text passwords in DDL also end up in server logs when `log_statement=ddl` is set; libpq-style clients pre-hash SCRAM on the client. (`RoleManagement.swift:27,38,93,103,136,146`, `DatabaseOperations.swift:32-38`, `DatabaseIntrospection.swift:252-256`, `ReplicationOperations.swift:26`, `PostgresColumnDefinition.swift:154`) | S1/S2 |
| D2 | "Bulk copy" is not COPY. `copyIn` parses CSV line by line, which breaks quoted multi-line fields. It builds `INSERT … VALUES` batches outside any transaction, so a failure leaves a partial import. `copyOut` writes **binary** cell bytes as UTF-8 text, so the CSV contains garbage for non-text columns. | S2 |
| D3 | `quoteIdentifier` splits on the first `.`, so a real identifier containing a dot cannot be quoted. | S3 |

### 4.6 What is already good

- Moving rows is fast and has correct backpressure (PostgresNIO `AdaptiveRowBuffer`). The Echo-style extractor and formatter path adds almost no overhead.
- The TLS mode spectrum, including verify-ca / verify-full and mTLS, maps correctly to NIOSSL.
- Connecting fails fast on bad DNS, bad credentials (probe connection) and unreachable hosts.
- `PostgresError` gives useful messages (constraint, table, detail) and SQLSTATE helpers.
- A clean package split, strict concurrency, and a Docker multi-version CI matrix.

---

## 5. How Echo uses the driver

| Area | Assessment |
|---|---|
| Row path | ✅ Good. It uses `PostgresRowExtractor.encodeBinaryRow` plus the synchronous `PostgresCellFormatter` for 200 preview rows, raw `ByteBuffer` capture after that, and a GCD batch worker. This is the right design; the driver's own `streamQuery` should adopt it (PW9). |
| Result completion | ❌ `main` drops rows 201…N when N ≤ 500 (E1). ❌ The spool decodes binary as UTF-8 on all branches (E2). |
| Sessions | ❌ Query tabs run on a pooled `PostgresClient`, so transactions are not safe (A1). Needs a pinned connection (PW1 → E3). |
| Cancel | ❌ Only cancels the Swift task, so the server keeps running and the connection stays busy (B1/B2 → PW3 → E4). |
| Scripts | ❌ Postgres scripts with several statements fail (C1 → E5). |
| Database switching | ⚠️ Suspected. When a tab is still waiting for its dedicated session, `WorkspaceTabContainerView+Execution.swift:161-163` runs on the dedicated session's own database instead of `sessionForDatabase(activeDB)` (line 111). Needs checking (E7). |
| Counter | ✅ Leave as is (§3). |

---

## 6. postgres-wire work items (for later; nothing changed yet)

In priority order:

1. **PW1 (S1)**: Provide a **pinned, non-pooled session connection** for interactive use: one `PostgresConnection` owned by the caller.
   - Track transaction state (idle / in transaction / failed) from command tags or ReadyForQuery.
   - Detect a dropped connection and report "transaction lost" instead of reconnecting silently.
   - Fix or remove `PostgresTransactionClient` so all its statements run on one leased connection, for example `withTransaction { conn in … }`.
2. **PW2 (S1)**: Write a complete **binary formatter** in `PostgresCellFormatter`:
   - arrays (recursive, any element OID)
   - `interval`, `inet`/`cidr`, `macaddr`/`macaddr8`, geometric types, ranges and multiranges, `tsvector`/`tsquery`, `bit`/`varbit`, `money`, `oid`/`regclass`-style types
   - `numeric` NaN / ±Infinity, `timestamp`/`date` ±infinity and BC, a correct `timetz` offset, lowercase `uuid`
   - Add a `Data`/slice-based entry point (OID + bytes) so Echo's spool uses the same code.
3. **PW3 (S2)**: **Server-side cancel.** Expose the backend pid and secret key, or run `pg_cancel_backend(pid)` on a side connection. Offer `cancel()` on the session and per-query statement / lock timeouts.
4. **PW4 (S2)**: **Multi-statement execution.** Either use the simple query protocol (needs PostgresNIO support) or add a Postgres-aware statement splitter that handles `$$` bodies, quotes and comments, returning multiple result sets with command tags.
5. **PW5 (S2)**: Honour `pool` and `applicationName`: map them to `PostgresClient.Configuration.options` and `additionalStartupParameters`. Make `client(for:)` race-free.
6. **PW6 (S1/S2)**: Escape every literal interpolation. Hash role passwords with SCRAM on the client.
7. **PW7 (S2)**: Real `COPY FROM STDIN` / `TO STDOUT` (needs PostgresNIO copy support), or at least a transactional, RFC-4180-correct CSV path with text-format output.
8. **PW8**: Tests for the paths Echo uses:
   - `PostgresRowExtractor` and `PostgresCellFormatter` against every type in `SampleData.sql`, **without** `::text` casts
   - streaming N > 200 rows
   - cancel
   - idle-pool transaction loss
   - multi-statement scripts
9. **PW9**: Deprecate or remove `PostgresDataStream`/`streamQuery`/`streamQueryWithCursor`, or rebuild them on the extractor, formatter and batch model (§3).
10. **PW10 (S3)**:
    - Fix the retain cycle (A7) and the registry leak (A8).
    - Remove or implement the no-op prepared cache (C2).
    - Pass the error `position` through (C3).
    - Fix `quoteIdentifier` (D3) and the connect comment (B4).

## 7. Reproduction assets

These stay in the session scratchpad and are not in either repo:

- `echo-copy/EchoTests/PGReproTests.swift`: the Echo pipeline reproduction. It is a template for Echo's regression test in E1/E2.
- `pgaudit/`: the driver audit harness. Modes are `rows`, `types`, `multi`, `appname`, `cancel`, `tx`, `timeout` and `earlyexit`.

---

## 8. Fix status (branch `fix/enterprise-hardening`)

| Item | Status | What changed |
|---|---|---|
| PW1 pinned sessions (A1–A3) | ✅ | `PostgresSessionConnection`: one dedicated connection, transaction tracking, `refreshTransactionStatus()`, `PostgresSessionError.connectionClosed(transactionLost:)` instead of a silent reconnect, and a keep-alive only while idle outside transactions. `PostgresServerConnection.makeSession()`. `PostgresClient.withTransaction`. The pooled `client.transactions.begin/commit/…` are deprecated. |
| PW2 binary formatter (§4.4) | ✅ | `PostgresBinaryFormatter`, behind `PostgresCellFormatter`. Covers every built-in type, including arrays (with bounds), ranges and multiranges, records, hstore/enums/ltree detected at run time, exact numeric, BC and infinite dates, `timetz`, intervals and IPv6. `stringValue(oid:data:)` serves spooled bytes. **About 150 values checked against the server's own output function** (`FormatterServerParityTests`). The deliberate differences are `bool` printed as `true`/`false`, `money` as a plain decimal, `reg*` as the OID, and `timestamptz` in a configurable zone. |
| PW3 cancel and timeouts (B1–B3) | ✅ | `PostgresSessionConnection.cancel(using:)` and `PostgresClient.cancelBackend(pid:)` (`pg_cancel_backend`). `statementTimeout` / `lockTimeout` / `idleInTransactionSessionTimeout` in the configuration, and `setStatementTimeout` / `setLockTimeout` per session. Measured: cancel returns in under 1 s (was 6 s). |
| PW4 multi-statement (C1) | ✅ | `PostgresSQLSplitter` (quotes, `E''`, `$$`, nested comments, `BEGIN ATOMIC`), `returnsRows`, `transactionEffect`, and `PostgresSessionConnection.executeScript` with `PostgresScriptError`. |
| PW5 configuration (A4–A6) | ✅ | Pool min/max/idle/keep-alive, `application_name`, timeouts, extra startup parameters and a Unix socket path now reach PostgresNIO. `client(for:)` shares one in-flight connect per database. |
| PW6 escaping and passwords (D1) | ✅ | `PostgresQuoting` everywhere a value is spliced into SQL. Role passwords are hashed client-side as SCRAM-SHA-256 verifiers (ASCII passwords; non-ASCII are left to the server's SASLprep). |
| PW7 COPY (D2) | ✅ | `copyIn` streams over the real COPY protocol, so one statement is atomic. CSV is parsed per RFC 4180 on the client, including quoted multi-line fields, and NULL stays distinct from an empty string. `copyOut` renders with the binary formatter and writes server-style CSV or text. The parser handles schema-qualified quoted names, column lists and `COPY (query)` with nested parentheses. |
| PW8 tests | ✅ | New: `PostgresBinaryFormatterTests`, `PostgresSQLSplitterTests`, `PostgresQuotingTests`, `FormatterServerParityTests`, `SessionConnectionTests`, `PoolAndSecurityHardeningTests`, `BulkCopyEdgeCaseTests`, `CopyParsingTests`. Test harness fix: eight test classes reloaded `.env` after the Docker override, which could point a Docker test run at the real server in `.env`. |
| PW9 streaming API | ✅ | `PostgresDataStream`: amortised trimming with correct absolute indexes; NULLs no longer mistaken for unformatted rows. `streamQuery`: no divide-by-zero, defaults of 1 000 rows / 100 ms (was 5 rows / 50 ms). `streamQueryWithCursor`: rejects multiple statements and handles a trailing `;`. `PostgresFormatterEngine` delegates to the binary formatter (it read integers little-endian). |
| PW10 hygiene | ✅ | Notifier retain cycle broken (the notifier holds the client weakly). Per-connection registry keyed by the pool's connection id and bounded. `LRUCache` rewritten (it had stale indexes) and made thread-safe. `PostgresError.position` / `hint` / `detail` / `internalPosition`. `quoteQualifiedIdentifier` accepts quoted parts. Portable errno mapping. The connect deadline really returns at the deadline. `withConnection` no longer wraps the caller's own errors. |

**Test results:** the full suite (477 tests) passes against Docker Postgres 17, 14 and 18. Echo builds against the new driver unchanged.

### Follow-up (same day): former limits closed

| Former limit | Now |
|---|---|
| Types without binary output (`aclitem`) fail the query | `PostgresSessionConnection` retries with only those columns cast to text (outside transactions; inside, the error carries a hint). |
| COPY binary not supported | `copyOut` writes binary COPY from the binary cells; `copyIn` parses binary COPY and re-encodes it as text using the target column types. Round-trip tested over 11 types. |
| No multi-host / `target_session_attrs` | `additionalHosts`, `targetSessionAttributes` (any, read-write, read-only, primary, standby, prefer-standby), `loadBalanceHosts`. |
| No IAM / token auth | `passwordProvider` (called per connection; pools are replaced before the credential expires) and `PostgresAWSRDSAuthToken` (SigV4, checked against AWS's published example). |
| `sslmode=allow` behaved like `prefer` | Plain first, TLS when `pg_hba.conf` rejects unencrypted connections. |
| Oversized files | `PostgresActivityMonitor`, `AdvancedIntrospection` and three test files split under 500 lines. |

**Still open: Kerberos / GSSAPI.** PostgresNIO's authentication state machine rejects GSS, and its types are internal. Supporting it needs a PostgresNIO fork plus a GSS.framework / libgssapi bridge, and a KDC to test against.

