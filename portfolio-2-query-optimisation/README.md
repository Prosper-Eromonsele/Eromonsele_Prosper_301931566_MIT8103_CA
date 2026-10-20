# Portfolio 2: Query Processing and Optimisation

**TC.Solutions Fintech Ltd** · Prosper Eromonsele (301931566)

## Files

| File | Purpose |
|---|---|
| `01_generate_data.sql` | Loads synthetic data on top of the Portfolio 1 seed |
| `02_business_queries.sql` | Six business queries (Q1 to Q6) |
| `03_explain_plans.sql` | `EXPLAIN (ANALYZE, BUFFERS)` for five operations (E1 to E5) |
| `04_indexes.sql` | The four indexes I added after reading the plans |
| `results/explain_before.log` | Plans and timings before indexing |
| `results/explain_after.log` | Plans and timings straight after indexing (cold cache) |
| `results/explain_after_warm.log` | The same, run again with the indexes in memory |

## How to run

```
docker exec tcs-postgres psql -U postgres -d tcsolutions -f /work/portfolio-1-database-design/schema.sql
docker exec tcs-postgres psql -U postgres -d tcsolutions -f /work/portfolio-1-database-design/seed.sql
docker exec tcs-postgres psql -U postgres -d tcsolutions -f /work/portfolio-1-database-design/test_constraints.sql
docker exec tcs-postgres psql -U postgres -d tcsolutions -f /work/portfolio-2-query-optimisation/01_generate_data.sql
docker exec tcs-postgres psql -U postgres -d tcsolutions -f /work/portfolio-2-query-optimisation/02_business_queries.sql
docker exec tcs-postgres psql -U postgres -d tcsolutions -f /work/portfolio-2-query-optimisation/03_explain_plans.sql -L /work/portfolio-2-query-optimisation/results/explain_before.log
docker exec tcs-postgres psql -U postgres -d tcsolutions -f /work/portfolio-2-query-optimisation/04_indexes.sql
docker exec tcs-postgres psql -U postgres -d tcsolutions -f /work/portfolio-2-query-optimisation/03_explain_plans.sql -L /work/portfolio-2-query-optimisation/results/explain_after.log
```

## The test data

Ten transactions are not enough to see how a query really behaves, so I generated a realistic volume for TC.Solutions. The generator uses `setseed()`, so anyone who runs it gets exactly the same data.

| Table | Rows |
|---|---|
| customers | 40,000 |
| wallets | 41,551 |
| merchants | 1,200 |
| agents | 350 |
| devices | 46,082 |
| beneficiaries | 15,002 |
| transactions | 300,700 |
| ledger_entries | 592,552 |

The total database size is 228 MB. The transactions are a mix of card funding, transfers, merchant payments, transfers to other banks, agent cash-in and cash-out, 4,424 failed transfers and 300 reversals, spread over August to mid-October 2026.

I also planted three fraud patterns, so I could test whether my queries actually catch them:
- 5 accounts that each make 18 transfers just under N10,000 inside one hour;
- 3 phones that are each shared by 8 different customers;
- a chain where 10 people pay one account and the money is passed through 4 more accounts in under an hour, then sent out to a bank.

**Bulk load and the ledger trigger.** The balanced-ledger trigger from Portfolio 1 checks every ledger row one at a time. For a one-off load of 592,552 rows, I switched it off inside the load transaction, inserted the rows, switched it back on, and then checked the same rule once over the whole table. The result was `unbalanced_transactions = 0`.

## Business queries and results

| Query | Who asks | What it does | My result |
|---|---|---|---|
| Q1 | Customer support | Statement for one wallet for September, with running balance | 7 entries for customer 1006 |
| Q2 | Finance | Wallets whose stored balance does not match the ledger | **0 rows**. Every wallet reconciles. |
| Q2b | Finance | The same check after I change one balance without a ledger entry, then roll back | Caught: wallet 1006 shows N5,000 difference |
| Q3 | Finance | Merchant settlement for 15 Sept: payments, gross, 1.5% fee capped at N2,000, net | Top 10 merchants |
| Q4 | Fraud team | Accounts with 10 or more transfers in any 60 minutes (window function) | **The 5 planted accounts**, each with 18 transfers averaging about N9,700 |
| Q4b | Fraud team | The same rule for one customer, as it would run before approving a transfer | 18 transfers, N174,489 in the hour |
| Q5 | Fraud / KYC | Devices used by 3 or more customers | **The 3 planted phones**, each with 8 customers |
| Q6 | Compliance | Customers whose money out in a day went over their KYC tier daily limit | 118 customer-days, all Tier 1 |

Q4 and Q6 together tell a story I see often in security work. Three of the velocity accounts are Tier 1, with a N50,000 daily limit, yet each moved about N174,000 in one night. The database detected it after the fact, but the limit should have been enforced before each transfer was approved. This is exactly why Q4b needs to be fast: it has to run on every single transfer.

Q2 is the control for the denormalised `wallets.balance` from Portfolio 1. Q2b shows the control works: a balance changed without a matching ledger entry is caught straight away.

## Execution plans: before indexing

PostgreSQL automatically creates an index for every primary key and UNIQUE column, but **not for foreign-key columns**. My Portfolio 1 schema had no other indexes. In the "before" plans, four of the five operations read the whole `transactions` or `ledger_entries` table:

| Test | Plan before indexing | Rows thrown away | Pages read |
|---|---|---|---|
| E1 statement | Parallel Seq Scan on `ledger_entries` | 128,979 per worker | 5,994 |
| E2 settlement | Parallel Seq Scan on `transactions` | 99,965 per worker | 5,673 |
| E3 real-time velocity | Parallel Seq Scan on `transactions` to find 18 rows | 100,228 per worker | 5,566 |
| E4 batch velocity | Parallel Seq Scan on `transactions` | 91,152 per worker | 5,656 |
| E5 posting one transfer | The trigger scans `ledger_entries` at COMMIT | n/a | n/a |

## Indexes added and why

| Index | For | Reason |
|---|---|---|
| `ledger_entries (wallet_id, created_at)` | E1 | Finds one wallet's entries for a date range, already in date order |
| `ledger_entries (txn_id)` | E5 | The balanced-ledger trigger and the foreign key both look up by `txn_id` |
| `transactions (created_at) WHERE txn_type='MERCHANT_PAYMENT' AND status='SUCCESS'` | E2 | Partial index: only successful merchant payments (about 20% of rows), so it is small (1.3 MB) |
| `transactions (initiated_by, created_at) WHERE txn_type='TRANSFER' AND status='SUCCESS'` | E3, E4 | One sender's transfers in time order, also partial (4.5 MB) |

## Results

| Test | Before | After (first run) | After (warm) | Pages read before → after |
|---|---|---|---|---|
| E1 statement | 67.7 ms | 0.39 ms | 2.38 ms | 5,994 → 47 |
| E2 settlement | 37.5 ms | 4.12 ms | 3.66 ms | 5,673 → 97 |
| E3 real-time velocity | 48.2 ms | 0.42 ms | 0.74 ms | 5,566 → 7 |
| E4 batch velocity | 81.2 ms | 123.9 ms | 45.9 ms | 5,656 → 564 |
| E5 COMMIT of one transfer | 93.3 ms | 7.0 ms | 11.3 ms | n/a |

All timings come from PostgreSQL 16.15 in Docker Desktop on my Windows laptop. They change a little between runs, so I look at the plan and the pages read as much as at the milliseconds. Pages read do not depend on what else my laptop is doing at that moment.

## Analysis

**The indexes that worked best are the ones that find a few rows out of many.** E1 needs 7 ledger rows out of 592,552, and E3 needs 18 transfers out of 300,700. Without an index, PostgreSQL had to read the whole table (around 5,600 to 6,000 pages) and throw away nearly everything. With the index it reads 7 to 47 pages. The plan changed from `Parallel Seq Scan` to `Index Scan`, and the time fell from tens of milliseconds to under 3 ms.

**E3 is the one that matters most for the business.** It is the check that should run before every transfer is approved. At 48 ms with a full table scan, it would get slower every month as the table grows, and it would slow down every customer's transfer. With the index it reads 7 pages, and that stays roughly the same whether the table has 300,000 rows or 30 million.

**E5 surprised me the most.** My Portfolio 1 trigger, which protects the double-entry rule, was quietly scanning the whole ledger on every COMMIT, because `ledger_entries.txn_id` is a foreign key and PostgreSQL does not index foreign keys automatically. Posting one N100 transfer took 93 ms. After indexing `txn_id` it took 7 to 11 ms. An integrity control that makes every payment slow would eventually be switched off by someone under pressure, so its performance is part of its security.

**E4 shows the limit of indexing.** The October velocity report has to read every successful transfer in October, about 27,000 rows. The first run after indexing was actually slower (124 ms vs 81 ms). The plan explains why: `Buffers: shared hit=6 read=558` means the new index was read from disk because it was not in memory yet. On the warm run, all 564 pages came from memory (`shared hit=564`) and it took 46 ms, so it is about 1.8 times faster than before. The gain comes from the index returning rows already sorted by customer and time, which saves the sort step, not from skipping rows. For a report like this, the better fix is to run it off-peak or on a read replica, which I come back to in Portfolio 5.

**Q2 (reconciliation) I deliberately did not index.** It has to sum every ledger row for every wallet, so no index can avoid reading the table. It takes about 0.7 seconds. That is fine for a nightly finance job, but it should not run on the primary database during business hours.

**Trade-offs.** The four indexes take about 35 MB, against a 228 MB database. Every new transaction now also has to update the indexes, so inserts get slightly slower. In this test that cost is small compared with the 93 ms the trigger was wasting without the `txn_id` index. I used partial indexes for E2 and E3 so that only the rows those queries need are indexed, which keeps them small and cheap to maintain.

## Screenshots

All in `docs/screenshots/`:

| Files | Shows |
|---|---|
| `p2_00a` to `p2_00c` | Fresh database rebuilt from the Portfolio 1 scripts |
| `p2_01a` to `p2_01c` | Data generation, ending with `unbalanced_transactions = 0` and the row counts |
| `p2_02a` to `p2_02c` | Business queries Q1 to Q6 and their results |
| `p2_03a` to `p2_03d` | Execution plans before indexing (E1 to E5) |
| `p2_04_indexes_created` | The four indexes and their sizes |
| `p2_05a` to `p2_05c` | Execution plans after indexing |
| `p2_06_results_logs` | The three saved log files |
