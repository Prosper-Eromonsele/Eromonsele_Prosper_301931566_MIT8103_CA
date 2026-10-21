# Two-window demos (Portfolio 3, part 2)

Isolation, the double-spend race and the deadlock need **two users at the same time**. Open two PowerShell windows, called **A** and **B**, and start psql in each. Each window saves its own log.

**Window A**
```
docker exec -it tcs-postgres psql -U postgres -d tcsolutions -L /work/portfolio-3-transactions-concurrency/results/window_A.log
```
**Window B**
```
docker exec -it tcs-postgres psql -U postgres -d tcsolutions -L /work/portfolio-3-transactions-concurrency/results/window_B.log
```
Then, in **both** windows:
```
\i /work/portfolio-3-transactions-concurrency/session_start.sql
```
This sets `:bola`, `:kunle` and `:ada` to the three demo wallet numbers.

**Before every demo**, reset the balances in window A, so Bola has N10,000, Kunle N5,000 and Ada N0:
```
\i /work/portfolio-3-transactions-concurrency/02_demo_accounts.sql
```

Type the steps **in order**, one window at a time. When a step says *"hangs"*, that window is waiting for a lock. Leave it and go to the other window.

---

## C. Isolation: Read Committed vs Repeatable Read

| # | Window | Type | What you should see |
|---|---|---|---|
| 1 | A | `BEGIN;` | |
| 2 | A | `SELECT balance FROM wallets WHERE wallet_id = :bola;` | 10000.00 |
| 3 | B | `SELECT transfer(:bola, :kunle, 1000, 'During read committed');` | a txn id (B commits straight away) |
| 4 | A | `SELECT balance FROM wallets WHERE wallet_id = :bola;` | **9000.00**: same query, same transaction, different answer (non-repeatable read) |
| 5 | A | `COMMIT;` | |
| 6 | A | `BEGIN ISOLATION LEVEL REPEATABLE READ;` | |
| 7 | A | `SELECT balance FROM wallets WHERE wallet_id = :bola;` | 9000.00 |
| 8 | B | `SELECT transfer(:bola, :kunle, 1000, 'During repeatable read');` | a txn id |
| 9 | A | `SELECT balance FROM wallets WHERE wallet_id = :bola;` | **still 9000.00**: A keeps reading its own snapshot |
| 10 | A | `COMMIT;` | |
| 11 | A | `SELECT balance FROM wallets WHERE wallet_id = :bola;` | 8000.00, now that A's snapshot has ended |

---

## D1. The double-spend race (the WRONG way)

Bola has N10,000. At the same moment she sends N8,000 to Kunle from her phone and N8,000 to Ada from the web. The "app" reads the balance, decides there is enough, and writes back the new balance it calculated (10,000 - 8,000 = 2,000).

Reset first (window A): `\i /work/portfolio-3-transactions-concurrency/02_demo_accounts.sql`

| # | Window | Type | What you should see |
|---|---|---|---|
| 1 | A | `BEGIN;` | |
| 2 | A | `SELECT balance FROM wallets WHERE wallet_id = :bola;` | 10000.00, "enough for 8,000" |
| 3 | B | `BEGIN;` | |
| 4 | B | `SELECT balance FROM wallets WHERE wallet_id = :bola;` | 10000.00, "enough for 8,000" |
| 5 | A | `UPDATE wallets SET balance = 2000 WHERE wallet_id = :bola;` | UPDATE 1 |
| 6 | A | `UPDATE wallets SET balance = balance + 8000 WHERE wallet_id = :kunle;` | UPDATE 1 |
| 7 | B | `UPDATE wallets SET balance = 2000 WHERE wallet_id = :bola;` | **hangs**: A holds the row lock |
| 8 | A | `COMMIT;` | B's UPDATE 1 appears straight away |
| 9 | B | `UPDATE wallets SET balance = balance + 8000 WHERE wallet_id = :ada;` | UPDATE 1 |
| 10 | B | `COMMIT;` | |
| 11 | A | `SELECT * FROM v_demo_wallets ORDER BY wallet_id;` | Bola 2,000, Kunle 13,000, Ada 8,000, and **MISMATCH** on all three |

**N16,000 left a wallet that only had N10,000.** This is a *lost update*: B overwrote A's result with a value it calculated from an out-of-date read. The reconciliation column catches it, because neither write went through the ledger.

**Optional, while step 7 is hanging:** open a third window and look at who is blocking whom. This is useful evidence.
```
docker exec -it tcs-postgres psql -U postgres -d tcsolutions -c "SELECT pid, pg_blocking_pids(pid) AS blocked_by, state, wait_event_type, left(query,60) AS query FROM pg_stat_activity WHERE datname='tcsolutions' AND pid <> pg_backend_pid();"
```

---

## D2. Fix 1: pessimistic locking with `transfer()`

`transfer()` locks the wallet rows with `SELECT ... FOR UPDATE` **before** it reads the balance.

Reset first (window A).

| # | Window | Type | What you should see |
|---|---|---|---|
| 1 | A | `BEGIN;` | |
| 2 | A | `SELECT transfer(:bola, :kunle, 8000, 'Race A');` | a txn id. A now holds the lock on Bola's wallet. |
| 3 | B | `BEGIN;` | |
| 4 | B | `SELECT transfer(:bola, :ada, 8000, 'Race B');` | **hangs**, waiting for A |
| 5 | A | `COMMIT;` | B wakes up: **ERROR: Insufficient funds: balance 2000.00, amount 8000** |
| 6 | B | `ROLLBACK;` | |
| 7 | A | `SELECT * FROM v_demo_wallets ORDER BY wallet_id;` | Bola 2,000, Kunle 13,000, Ada 0, all **OK** |

---

## D3. Fix 2: optimistic control with REPEATABLE READ

The same wrong "app" code as D1, but both transactions run at REPEATABLE READ.

Reset first (window A).

| # | Window | Type | What you should see |
|---|---|---|---|
| 1 | A | `BEGIN ISOLATION LEVEL REPEATABLE READ;` | |
| 2 | A | `SELECT balance FROM wallets WHERE wallet_id = :bola;` | 10000.00 |
| 3 | B | `BEGIN ISOLATION LEVEL REPEATABLE READ;` | |
| 4 | B | `SELECT balance FROM wallets WHERE wallet_id = :bola;` | 10000.00 |
| 5 | A | `UPDATE wallets SET balance = 2000 WHERE wallet_id = :bola;` | UPDATE 1 |
| 6 | A | `UPDATE wallets SET balance = balance + 8000 WHERE wallet_id = :kunle;` | UPDATE 1 |
| 7 | B | `UPDATE wallets SET balance = 2000 WHERE wallet_id = :bola;` | **hangs** |
| 8 | A | `COMMIT;` | B: **ERROR: could not serialize access due to concurrent update** |
| 9 | B | `ROLLBACK;` | the app would now retry from the start and read 2,000 |

---

## E1. Deadlock

Bola sends Kunle N1,000 while Kunle sends Bola N1,000. Each "app" debits the sender first, then credits the receiver.

Reset first (window A).

| # | Window | Type | What you should see |
|---|---|---|---|
| 1 | A | `BEGIN;` | |
| 2 | A | `UPDATE wallets SET balance = balance - 1000 WHERE wallet_id = :bola;` | A locks Bola |
| 3 | B | `BEGIN;` | |
| 4 | B | `UPDATE wallets SET balance = balance - 1000 WHERE wallet_id = :kunle;` | B locks Kunle |
| 5 | A | `UPDATE wallets SET balance = balance + 1000 WHERE wallet_id = :kunle;` | **hangs**: waits for B |
| 6 | B | `UPDATE wallets SET balance = balance + 1000 WHERE wallet_id = :bola;` | after about 1 second, one window gets **ERROR: deadlock detected** |
| 7 | A and B | `ROLLBACK;` in both | |

PostgreSQL finds the cycle (A waits for B, B waits for A) and kills one transaction so the other can finish.

## E2. Deadlock fixed by lock ordering

`transfer()` always locks the lower wallet number first, whichever direction the money goes.

Reset first (window A).

| # | Window | Type | What you should see |
|---|---|---|---|
| 1 | A | `BEGIN;` | |
| 2 | A | `SELECT transfer(:bola, :kunle, 1000, 'Bola to Kunle');` | a txn id |
| 3 | B | `BEGIN;` | |
| 4 | B | `SELECT transfer(:kunle, :bola, 1000, 'Kunle to Bola');` | **hangs**, but it is only waiting, not deadlocked |
| 5 | A | `COMMIT;` | B finishes with a txn id |
| 6 | B | `COMMIT;` | |
| 7 | A | `SELECT * FROM v_demo_wallets ORDER BY wallet_id;` | Bola 10,000, Kunle 5,000, all **OK**, and no deadlock |

---

When finished, type `\q` in both windows. Take a screenshot of each demo's final state, and of the ERROR lines in D2, D3 and E1.
