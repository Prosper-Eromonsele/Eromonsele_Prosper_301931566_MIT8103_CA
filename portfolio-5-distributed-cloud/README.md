# Portfolio 5: Distributed and Cloud Database

**TC.Solutions Fintech Ltd** · Prosper Eromonsele (301931566)

A payment company cannot run on one database server. If it fails, nobody in Nigeria can fund a wallet, pay a merchant or withdraw cash at an agent. If its disk is lost, the ledger is lost. This portfolio adds a second PostgreSQL server as a **streaming replica**, measures what that copy can and cannot promise, runs a failover drill, and then looks at how TC.Solutions should distribute its data across Nigeria and Ghana under the regulators' rules.

## What I built

```
            writes + reads                         reads only (reports, statements)
 app ───────────────────►  tcs-postgres  ──WAL stream──►  tcs-replica
                           primary, :5432                 hot standby, :5433
```

- **tcs-postgres:** the primary from Portfolios 1 to 3. Every transfer is written here.
- **tcs-replica:** a second PostgreSQL 16 container (`docker-compose.yml`). On first start it copies the whole primary with `pg_basebackup` (241,815 kB), then receives every change through the write-ahead log (WAL) as it happens.
- A `replicator` role that may only stream WAL. It cannot read or change table data.

From the primary, `pg_stat_replication` showed `tcs_replica`, at `172.18.0.4` on the Docker network, `streaming`, `async`, with `0 bytes` behind.

## Stage 2: write on the primary, read on the replica

| Check | Result |
|---|---|
| N500 transfer written on the primary | txn 300731, `TCS-20261021131343347634` |
| Read on the replica | Same transaction, same reference |
| Is it a replica? | `pg_is_in_recovery() = t` |
| Same data? | 40,003 customers, 300,709 transactions, 592,570 ledger entries |
| Try to write on the replica | `ERROR: cannot execute UPDATE in a read-only transaction` |
| Portfolio 2 reconciliation (Q2) on the replica | 0 mismatches, 2.0 s, with no load on the primary |

That last row matters. In Portfolio 2 I said the reconciliation report and the October velocity report are full-table jobs that should not run on the primary during business hours. The replica is where they belong.

A note on one number: my script printed a `replay_delay` of about 11 seconds. That is **not** replication lag. It is the time since the last change the replica replayed, and it keeps growing on an idle system: I simply ran the read about 11 seconds after the write. The real lag is in `pg_stat_replication`, which showed `sent_lsn = replay_lsn` (`0/1A008CE0`), i.e. zero bytes behind.

## Stage 3: how far behind can it get?

**Under load.** I wrote 3,000,000 rows (220 MB) on the primary while watching `pg_stat_replication` every second. The replica kept pace: straight after the burst it was `0 bytes` behind with a `replay_lag` of **3.7 ms**. I ran the burst twice (30.7 s and 14.1 s). On my laptop the bottleneck was the primary producing the data, not the replica applying it.

**But nothing guarantees that.** Asynchronous replication makes no promise about how far behind the replica may be. To show what a lagging replica means for a customer, I paused replay on the replica (`pg_wal_replay_pause()`), which is what a slow network link or an overloaded replica would do, and moved N2,000 out of Bola's wallet on the primary:

| | Before | After Bola sent N2,000 (txn 300732) |
|---|---|---|
| Primary | 9,500 | **7,500** |
| Replica (paused) | 9,500 | **9,500**, which is wrong |

The primary reported the replica **47 kB behind with a replay lag of 3 min 45 s**. After `pg_wal_replay_resume()` the replica caught up at once and showed 7,500.

If a balance screen read from that replica, Bola would see money she no longer has. If a transfer were *approved* against it, that is the double-spend from Portfolio 3 again, caused by replication instead of by concurrency. So my rule for TC.Solutions is:

> **Anything that moves money, or decides whether money can move, reads and writes the primary. Only reports, statements, analytics and the fraud graph export read the replica.**

## Stage 4: synchronous vs asynchronous replication (CAP in practice)

PostgreSQL can be told to confirm a COMMIT only once a named replica has also received it (`synchronous_standby_names = 'tcs_replica'`).

| Setting | Replica | Transfer | Time |
|---|---|---|---|
| Synchronous | Up | txn 300733 committed | 184.6 ms |
| Synchronous | **Down** (`docker stop`) | txn 300734 **hung**, `wait_event = SyncRep` | **50,991 ms**, released only when I switched back to async |

For those 51 seconds no customer could complete a transfer. This is the CAP trade-off made concrete. During a failure (a *partition*), the system must choose:
- **Consistency:** synchronous mode never confirms a payment that exists on only one server, so a crash cannot lose it. But when the replica is unreachable, payments stop.
- **Availability:** asynchronous mode keeps taking payments, but if the primary dies, the last few transactions not yet shipped to the replica can be lost.

Even without a failure the choice has a cost (the PACELC extension of CAP): every synchronous commit waits for a network round trip.

**What I would do at TC.Solutions:** use synchronous replication, but with **two** standbys and `synchronous_standby_names = 'ANY 1 (replica_a, replica_b)'`. Each COMMIT waits for one of the two, so a single replica failure does not stop payments, and no confirmed payment exists on only one server. A customer who has seen "Transfer successful" must never lose that money because a server failed a second later.

## Stage 5: failover drill

| Step | Result |
|---|---|
| Stop the primary (`docker stop tcs-postgres`) | — |
| The replica still answers reads | `still_replica = t`, 300,712 transactions |
| Promote it (`pg_promote()`) | `still_replica = f`: it is now a primary |
| Write on the new primary | txn **300766** committed |
| Start the old primary again | `still_replica = f`, `has_failover_txn = 0` |

Three lessons:
1. **Promotion works and is fast,** so read-only service never stopped and write service came back in seconds.
2. **Split brain.** When the old primary came back, **both servers believed they were the primary**, and they disagreed: the transfer written after failover existed only on one of them. If the application had reconnected to the old primary, customers would have seen two different versions of their balances. In production, failover must be done by a tool that guarantees only one primary at a time (for example Patroni with a consensus store), and the old primary must be fenced before it can rejoin. I rebuilt the replica from the primary (`docker compose rm -sfv replica` then `up -d replica`), which is the clean way back.
3. **Sequence gaps.** The new primary's next transaction id was 300766, not 300735. PostgreSQL logs sequence values in batches of 32, so a promoted replica skips ahead. Transaction ids must therefore never be used as a gap-free count. Auditors should rely on the `reference` and the ledger, which is how the Portfolio 1 design already works.

## Distribution across Nigeria and Ghana: sharding and data residency

TC.Solutions plans to launch in Ghana in 2027 (Portfolio 1 assumptions). That turns "where is the replica?" into a legal question as well as a technical one.

**Nigeria: the CBN localisation rule.** A CBN circular of 15 June 2026 requires payment transaction data generated in Nigeria to be stored and managed in Nigeria from **1 January 2027**. It applies to banks, payment service providers, switches, mobile money operators and other payment operators [1]. Legal commentary reads it as covering backups and replication too, and as requiring a review of arrangements that rely on foreign cloud providers [2]. The commentary also notes that detailed implementation guidance has not yet been published, so I treat this reading as the safe assumption, not a settled fact. Separately, the **NDPA 2023** (Part VIII, sections 41 to 43) only allows personal data to leave Nigeria where the destination offers adequate protection or another listed basis applies [3]. Complying with the NDPA alone does not satisfy the CBN rule [2].

**Ghana.** Ghanaian customers' personal data falls under the **Data Protection Act, 2012 (Act 843)** [5], and the Bank of Ghana issued a revised Cyber and Information Security Directive in March 2026 [4]. From public reporting I could not confirm a Ghanaian data-residency rule equivalent to the CBN's, so TC.Solutions would confirm the Bank of Ghana's position before launch rather than assume one either way.

**Design: shard by country.** Customers are partitioned by their country of residence, and each country has its own primary and replicas inside its own borders:

| Shard | Primary | Synchronous standbys | Holds |
|---|---|---|---|
| Nigeria | Lagos data centre | Lagos (second site) and Abuja | Nigerian customers, wallets, NGN ledger |
| Ghana | Accra data centre | Second Accra site / Kumasi | Ghanaian customers, wallets, GHS ledger |

- **Country is the right shard key.** Almost every transaction stays inside one country (a Lagos customer pays a Lagos merchant), so no ordinary transfer needs a distributed transaction across shards. The Portfolio 1 schema already has `currency` on wallets and transactions, which maps directly to the shard.
- **Cross-border payments** (Nigeria to Ghana) become two local transactions, a debit in the Nigerian ledger and a credit in the Ghanaian ledger, linked by a shared reference and settled through a settlement account. This is how real cross-border schemes work, and it avoids two-phase commit between countries.
- **Group reporting** receives only aggregated, non-personal figures (daily volumes and totals per currency), so no customer data needs to cross the border.
- **Disaster recovery stays in-country.** A replica in a South African cloud region would be the obvious choice technically, but it would breach the CBN rule for the Nigerian shard. Lagos is expanding local data-centre capacity, including Kasi's 40 MW LOS1 campus [6], but reporting also notes Nigerian enterprises spend about $850 million a year on foreign cloud [6]. The CBN rule forces exactly the shift away from that.

## Cloud deployment

My lab runs both servers in Docker on one laptop, so it shows the mechanism but not real fault tolerance: one machine failing takes down both. In production:
- run a **managed or Kubernetes-operated PostgreSQL** (Patroni or CloudNativePG) on infrastructure **located in Nigeria** for the Nigerian shard, with the primary and standbys in separate facilities (Lagos and Abuja);
- encrypt replication traffic with TLS (`sslmode=verify-full`), keep the `replicator` credentials in a vault, and restrict `pg_hba.conf` to the replicas' addresses, not `all` as in my lab;
- monitor `pg_stat_replication` (bytes behind, `replay_lag`) and alert well before lag becomes visible to customers;
- take encrypted base backups and WAL archives, also in-country, for point-in-time recovery, because a replica faithfully copies mistakes such as an accidental `DELETE`, so it is not a backup.

## Screenshots

All in `docs/screenshots/`:

| Files | Shows |
|---|---|
| `p5_01` to `p5_03` | Primary setup, replica base backup, streaming status |
| `p5_04` to `p5_06` | Write on the primary, read on the replica, replica checks R1 to R6 |
| `p5_07a` to `p5_07d` | Lag watch and the two write bursts |
| `p5_08a` to `p5_08c` | The stale read: replica paused, 47 kB / 3 min 45 s behind, then resumed |
| `p5_09a`, `p5_09b` | Synchronous replication: `SyncRep` wait and the 51-second hang |
| `p5_10a`, `p5_10b` | Failover: promotion, write after failover, split brain, rebuild |
| `p5_11` | Rebuilt replica streaming again |

## Files

| File | Purpose |
|---|---|
| `00_steps.md` | Every command, in order, with what to expect |
| `01_primary_setup.sql` | Replication role and WAL settings on the primary |
| `02_primary_status.sql` | `pg_stat_replication`: state, bytes behind, lag |
| `03_replica_checks.sql` | R1 to R6 on the replica |
| `04_write_then_read.sql`, `05_read_after_write.sql` | Write on the primary, read on the replica |
| `06_lag_load.sql` | 3 million row write burst (scratch schema `lab`, dropped afterwards) |
| `07_sync_on.sql`, `08_sync_off.sql` | Switch synchronous replication on and off |
| `results/` | Logs of every scripted step |
| `../docker-compose.yml` | The `replica` service |

## References

[1] BusinessDay, "CBN ends offshore payment processing as banks, fintechs face 2027 data localisation deadline", June 2026. https://businessday.ng/technology/article/cbn-ends-offshore-payment-processing-as-banks-fintechs-face-2027-data-localisation-deadline/

[2] Pavestones Legal (Mondaq), "CBN's Data Localisation Directive: Compliance Considerations for Payment System Participants", 2026. https://www.mondaq.com/cbns-data-localisation-directive-compliance-considerations-for-payment-system-participants/1812264

[3] Mondaq, "Cross-Border Data Transfers: An Overview of Legal Requirements and Compliance Mechanisms in Nigeria". https://www.mondaq.com/nigeria/data-protection/1789480/cross-border-data-transfers-an-overview-of-legal-requirements-and-compliance-mechanisms-in-nigeria

[4] Graphic Online, "BoG updates Cyber and Information Security Directive to safeguard financial sector", March 2026. https://www.graphic.com.gh/news/general-news/ghana-news-bog-updates-cyber-information-security-directive-to-safeguard-financial-sector.html

[5] Data Protection Act, 2012 (Act 843), Ghana. Overview: https://en.wikipedia.org/wiki/Data_Protection_Act,_2012

[6] TechCabal, "Lagos wants to triple its data centre capacity by 2030", 20 May 2026. https://techcabal.com/2026/05/20/lagos-wants-to-triple-its-data-centre-capacity-by-2030/

PostgreSQL 16 documentation: High Availability, Load Balancing, and Replication (chapter 27) and the `pg_stat_replication` view. https://www.postgresql.org/docs/16/high-availability.html
