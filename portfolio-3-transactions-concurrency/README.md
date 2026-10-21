# Portfolio 3: Transactions and Concurrency

**TC.Solutions Fintech Ltd** · Prosper Eromonsele (301931566)

In a payment company the worst bugs are not crashes. They are a transfer that half happens, or two transfers that both spend the same money. This portfolio shows how PostgreSQL transactions stop both, and what goes wrong when the application gets concurrency wrong.

## Files

| File | Purpose |
|---|---|
| `01_transfer_function.sql` | `transfer()`: one wallet transfer as a single safe unit of work |
| `02_demo_accounts.sql` | Three demo customers: Bola (N10,000), Kunle (N5,000) and Ada (N0). Re-run it to reset them. |
| `03_commit_rollback.sql` | Single-window demos: COMMIT, ROLLBACK, automatic rollback, atomicity, SAVEPOINT, KYC limit |
| `04_two_window_demos.md` | Step-by-step guide for the two-session demos C to E |
| `session_start.sql` | Loads the three demo wallet numbers into each psql window |
| `results/commit_rollback.log` | Output of `03_commit_rollback.sql` |
| `results/window_A.log`, `results/window_B.log` | Everything typed and returned in the two concurrent sessions |

## The transfer function

`transfer(from, to, amount, ...)` runs inside the caller's transaction and does five things in order:
1. It locks **both** wallet rows with `SELECT ... FOR UPDATE`, always in `wallet_id` order.
2. It checks both wallets exist, are active and use the same currency.
3. For customer wallets, it checks the KYC tier single-transaction limit and daily limit. In Portfolio 2 (Q6) I found 118 days where Tier 1 customers went over their daily limit, because nothing enforced it. This function closes that gap.
4. It checks the balance, **after** taking the lock, so nobody can spend the same money in between.
5. It writes the transaction header, the debit and credit ledger legs, and the two balance updates.

If any check fails, it raises an error and the whole transaction rolls back.

## Part 1: COMMIT and ROLLBACK (one session)

| Demo | What I did | Result |
|---|---|---|
| A. COMMIT | Bola sends Kunle N2,500 | Bola 7,500, Kunle 7,500, ledger matches |
| B1. ROLLBACK by choice | Bola starts sending Ada N1,000, then cancels | Inside the transaction Ada had 1,000. After ROLLBACK, back to 0. |
| B2. Automatic rollback | Ada (N0) tries to send N3,000 | `Insufficient funds: balance 0.00, amount 3000`. The next statement got `current transaction is aborted`. |
| B3. Atomicity | Header and debit leg written by hand, then Kunle's balance pushed to -42,500 | `wallets_balance_check` rejected it. After ROLLBACK, **0 rows** with that reference: the header and leg written before the error were undone too. |
| B4. SAVEPOINT | A batch of three transfers where the middle one fails | `ROLLBACK TO SAVEPOINT` skipped only item 2. Items 1 and 3 committed. |
| B5. KYC limit | Bola (Tier 2) sends N150,000 | `Amount 150000 is above the Tier 2 single transaction limit of 100000.00` |

All final balances showed `OK` in the reconciliation column.

B3 is the one I find most important. A transfer is several writes: a header, two ledger legs and two balance updates. If the server failed half-way, a customer could be debited without anyone being credited. Atomicity means the database treats all of it as one unit: either every write happens, or none does.

## Part 2: two sessions at the same time

I opened two psql sessions (window A and window B) in separate PowerShell windows and typed the steps in a fixed order. The psql prompt itself shows the state: `=#` means no open transaction, `=*#` means inside a transaction, and `=!#` means the transaction has failed and only ROLLBACK is accepted.

### C. Isolation levels

| Level | Window A reads Bola's balance | Window B transfers N1,000 and commits | Window A reads again |
|---|---|---|---|
| READ COMMITTED (default) | 10,000 | committed | **9,000**: same query, same transaction, different answer |
| REPEATABLE READ | 9,000 | committed | **still 9,000**: A reads its own snapshot until it commits |

Read Committed is fine for a single transfer. But a statement or report that reads the same data twice must not see it change halfway, and that is what Repeatable Read gives.

### D1. The double-spend race (the wrong way)

Bola has N10,000 and sends N8,000 to Kunle from window A and N8,000 to Ada from window B at the same time. The "application" reads her balance, decides 10,000 is enough, and writes back the new balance it worked out itself (`SET balance = 2000`).

B's write had to wait for A's lock. As soon as A committed, B overwrote A's value with its own, which it had calculated from an out-of-date read.

| Wallet | Stored balance | Ledger balance | Reconciles |
|---|---|---|---|
| Bola | 2,000 | 10,000 | MISMATCH |
| Kunle | 13,000 | 5,000 | MISMATCH |
| Ada | 8,000 | 0 | MISMATCH |

**N16,000 left a wallet that only had N10,000.** This is a *lost update*. Note that row locking alone did not prevent it: B did wait, but it still wrote a figure it had calculated before the wait. The reconciliation check from Portfolio 2 catches the damage, but only after the money is gone.

### D2. Fix 1: pessimistic locking (`transfer()`)

Window A ran `transfer(bola → kunle, 8,000)` and left its transaction open. Window B ran `transfer(bola → ada, 8,000)` and **hung**. From a third window, `pg_stat_activity` showed exactly why:

| pid | blocked_by | state | wait_event_type | query |
|---|---|---|---|---|
| 2431 (A) | {} | idle in transaction | Client | transfer(41552, 41553, 8000, 'Race A') |
| 2439 (B) | **{2431}** | active | **Lock** | transfer(41552, 41554, 8000, 'Race B') |

When A committed, B continued, read the **real** balance and stopped: `Insufficient funds: balance 2000.00, amount 8000`. Final balances: Bola 2,000, Kunle 13,000, Ada 0, all `OK`. Only N8,000 left Bola's wallet.

### D3. Fix 2: optimistic control (REPEATABLE READ)

The same wrong application code as D1, but both sessions used `BEGIN ISOLATION LEVEL REPEATABLE READ`. When A committed, B's update failed with `could not serialize access due to concurrent update`. B is not allowed to overwrite a row that changed after its snapshot was taken. The application has to catch this error and retry, and on the retry it would read 2,000.

| | Pessimistic (D2) | Optimistic (D3) |
|---|---|---|
| How | Lock first, then read and write | Read freely, conflict detected at write time |
| Loser | Waits, then sees the true balance | Gets an error and must retry |
| Best when | Conflicts are common: the same wallet is busy (a merchant or agent float) | Conflicts are rare and waiting is expensive |

For TC.Solutions I would use D2 for transfers. A busy merchant or agent wallet is updated many times a second, so constant retries would be worse than short waits.

### E1. Deadlock

Bola sends Kunle N1,000 while Kunle sends Bola N1,000. Each session debits its own sender first, so A locks Bola and B locks Kunle. Then each needs the other's row.

```
ERROR:  deadlock detected
DETAIL: Process 2439 waits for ShareLock on transaction 968; blocked by process 2431.
        Process 2431 waits for ShareLock on transaction 969; blocked by process 2439.
```

PostgreSQL found the cycle after about a second and aborted B (2439), so A could finish. Both sessions then rolled back. The process numbers are the same two sessions seen in D2.

### E2. Deadlock prevented by lock ordering

The same two opposite transfers, this time through `transfer()`: A ran `transfer(bola → kunle, 1,000)` and B ran `transfer(kunle → bola, 1,000)`. Because the function always locks the **lower wallet number first**, both sessions try to lock Bola's wallet (41552) first. B simply waited for A, there was no cycle, and both committed (transactions 300729 and 300730). Final balances: Bola 10,000, Kunle 5,000, all `OK`.

## What I take from this

- **Correctness comes from the database, not from the app's good intentions.** The D1 application code looks reasonable, and it lost N6,000 of real money in one race. Moving the read, the check and the write into one locked unit (D2) fixed it.
- **Locks must be taken before the check, not after.** The balance check in `transfer()` is only safe because it happens after `FOR UPDATE`.
- **Deadlocks are a design problem.** PostgreSQL detects them, but each one still fails a customer's transfer. A fixed lock order removes them by design.
- **Monitoring matters.** `pg_stat_activity` and `pg_blocking_pids()` showed exactly which session was blocking which. In production I would alert on long lock waits and on any transaction left `idle in transaction`. An open transaction holding a wallet lock would freeze every payment to that wallet, which is effectively a denial of service.
- **The reconciliation check from Portfolio 2 is the safety net,** not the fix. It caught D1 straight away, but after the money had moved.

## Screenshots

In `docs/screenshots/`: `p3_*` files covering demos A to E2 and the `pg_stat_activity` blocking evidence.
