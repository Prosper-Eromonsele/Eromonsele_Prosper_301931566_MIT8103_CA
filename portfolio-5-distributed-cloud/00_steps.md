# Portfolio 5: steps to run

This adds a second PostgreSQL server, **tcs-replica** (port 5433), which copies everything from the primary, **tcs-postgres** (port 5432), as it happens. This is called *streaming replication*.

Run all commands in PowerShell, in the project folder, unless a step says "psql window".

---

## Stage 1. Build the replica

**1.1 Allow the replication user to connect to the primary**
```
docker exec tcs-postgres bash -c "echo 'host replication replicator all scram-sha-256' >> /var/lib/postgresql/data/pg_hba.conf"
```
**1.2 Create the replication user and reload the settings**
```
docker exec tcs-postgres psql -U postgres -d tcsolutions -f /work/portfolio-5-distributed-cloud/01_primary_setup.sql -L /work/portfolio-5-distributed-cloud/results/01_primary_setup.log
```
**1.3 Start the replica.** It copies the whole primary first (about 450 MB), then starts streaming.
```
docker compose up -d replica
docker logs tcs-replica
```
Run `docker logs tcs-replica` again until you see `started streaming WAL from primary`.

**1.4 Check from the primary**
```
docker exec tcs-postgres psql -U postgres -d tcsolutions -f /work/portfolio-5-distributed-cloud/02_primary_status.sql -L /work/portfolio-5-distributed-cloud/results/02_primary_status.log
```
Expected: `application_name = tcs_replica`, `state = streaming`, `sync_state = async`, `bytes_behind = 0 bytes`.

---

## Stage 2. Write on the primary, read on the replica

**2.1 Post a N500 transfer on the PRIMARY**
```
docker exec tcs-postgres psql -U postgres -d tcsolutions -f /work/portfolio-5-distributed-cloud/04_write_then_read.sql -L /work/portfolio-5-distributed-cloud/results/04_write_on_primary.log
```
**2.2 Straight away, read it on the REPLICA**
```
docker exec tcs-replica psql -U postgres -d tcsolutions -f /work/portfolio-5-distributed-cloud/05_read_after_write.sql -L /work/portfolio-5-distributed-cloud/results/05_read_on_replica.log
```
Expected: the same txn_id and reference, with a `replay_delay` of a fraction of a second.

**2.3 Replica checks**
```
docker exec tcs-replica psql -U postgres -d tcsolutions -f /work/portfolio-5-distributed-cloud/03_replica_checks.sql -L /work/portfolio-5-distributed-cloud/results/03_replica_checks.log
```
Expected:
- R1 `t` (I am a replica);
- R2 `streaming`;
- R4 the same row counts as the primary;
- R5 **ERROR: cannot execute UPDATE in a read-only transaction**;
- R6 the Portfolio 2 reconciliation report runs on the replica and returns 0.

---

## Stage 3. Watch the replica fall behind (two windows)

**Window A: psql on the primary**
```
docker exec -it tcs-postgres psql -U postgres -d tcsolutions
```
Then paste this. It repeats every second:
```
SELECT clock_timestamp()::time(0) AS at, pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS behind, replay_lag FROM pg_stat_replication \watch 1
```
**Window B: PowerShell.** Write about 3 million rows on the primary:
```
docker exec tcs-postgres psql -U postgres -d tcsolutions -f /work/portfolio-5-distributed-cloud/06_lag_load.sql
```
Watch window A while B runs: `behind` jumps to tens or hundreds of MB and `replay_lag` rises, then both drop back once the replica catches up. **Screenshot window A at its peak.** Press **Ctrl+C** in window A to stop the repeating query, but stay in psql for Stage 4.

---

## Stage 4. Synchronous vs asynchronous (consistency vs availability)

**4.1 Switch the primary to synchronous replication** (window B, PowerShell)
```
docker exec tcs-postgres psql -U postgres -d tcsolutions -f /work/portfolio-5-distributed-cloud/07_sync_on.sql -L /work/portfolio-5-distributed-cloud/results/07_sync_on.log
```
Expected: `sync_state = sync`.

**4.2 A transfer with the replica up** (window A, psql)
```
\i /work/portfolio-3-transactions-concurrency/session_start.sql
\timing on
SELECT transfer(:bola, :kunle, 100, 'Sync - replica up');
```
It completes. Note the time: a little slower than usual, because COMMIT waited for the replica.

**4.3 Stop the replica** (window B)
```
docker stop tcs-replica
```
**4.4 The same transfer again** (window A)
```
SELECT transfer(:bola, :kunle, 100, 'Sync - replica down');
```
⚠️ **It hangs.** The primary will not confirm the COMMIT until a replica has it, and there is no replica. Leave it hanging.

**4.5 See why** (window B)
```
docker exec tcs-postgres psql -U postgres -d tcsolutions -c "SELECT pid, state, wait_event_type, wait_event, left(query,50) AS query FROM pg_stat_activity WHERE wait_event = 'SyncRep';"
```
Expected: `wait_event = SyncRep`. **Screenshot it.**

**4.6 Switch back to asynchronous** (window B)
```
docker exec tcs-postgres psql -U postgres -d tcsolutions -f /work/portfolio-5-distributed-cloud/08_sync_off.sql -L /work/portfolio-5-distributed-cloud/results/08_sync_off.log
```
Window A finishes straight away, and `\timing` shows how long it waited.

**4.7 Start the replica again** (window B)
```
docker start tcs-replica
```

---

## Stage 5. Failover drill (the primary "dies")

**5.1 Stop the primary** (window B). Window A will lose its connection; that is expected.
```
docker stop tcs-postgres
```
**5.2 The replica still answers reads**
```
docker exec tcs-replica psql -U postgres -d tcsolutions -c "SELECT pg_is_in_recovery() AS still_replica, count(*) AS transactions FROM tcs.transactions;"
```
**5.3 Promote the replica to be the new primary**
```
docker exec tcs-replica psql -U postgres -d tcsolutions -c "SELECT pg_promote();" -c "SELECT pg_is_in_recovery() AS still_replica;"
```
Expected: `still_replica = f`. It now accepts writes.

**5.4 Write on the new primary**
```
docker exec tcs-replica psql -U postgres -d tcsolutions -c "SET search_path TO tcs" -c "SELECT transfer((SELECT w.wallet_id FROM wallets w JOIN customers c USING (customer_id) WHERE c.phone='+2348099000001'), (SELECT w.wallet_id FROM wallets w JOIN customers c USING (customer_id) WHERE c.phone='+2348099000002'), 100, 'Written after failover');"
```
**5.5 Bring the old primary back: two primaries ("split brain")**
```
docker start tcs-postgres
docker exec tcs-postgres psql -U postgres -d tcsolutions -c "SELECT pg_is_in_recovery() AS still_replica, (SELECT count(*) FROM tcs.transactions WHERE narration = 'Written after failover') AS has_failover_txn;"
```
Expected: `still_replica = f` and `has_failover_txn = 0`. Both servers now think they are the primary, and they disagree about the data.

**5.6 Rebuild the replica from the primary**, the clean way back
```
docker compose rm -sfv replica
docker compose up -d replica
```

---

## Stage 6. Tidy up
```
docker exec tcs-postgres psql -U postgres -d tcsolutions -c "DROP SCHEMA lab CASCADE;"
```
