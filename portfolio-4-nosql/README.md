# Portfolio 4: NoSQL and Advanced Data Models

**TC.Solutions Fintech Ltd** · Prosper Eromonsele (301931566)

## Why a graph database for this problem

Portfolios 1 to 3 kept TC.Solutions' money in PostgreSQL, and that is where it should stay. Balances and the double-entry ledger need ACID transactions, constraints and joins on fixed keys, and a relational database is built for exactly that.

Fraud investigation asks a different kind of question. From my SOC work, the useful questions are rarely "what is this account's balance?". They are questions like:
- Which accounts log in from the same phone?
- Where did this money go next, and after that?
- Who else is connected to this suspect within two steps?

These are questions about **relationships**, often of unknown depth. In SQL every extra step is another self-join or another level of a recursive query. In a graph database, relationships are stored as direct links between records, so following them is the basic operation.

For this portfolio I modelled the fraud-relevant part of TC.Solutions as a property graph in **Neo4j 5.26 (Community Edition)**, running in Docker next to PostgreSQL.

## Other NoSQL models I considered

| Model | Example product | Where it would fit at TC.Solutions | Why not for this problem |
|---|---|---|---|
| Key-value | Redis | Real-time velocity counters per customer, idempotency keys, sessions | Fast lookups by key, but it cannot follow links between accounts |
| Document | MongoDB | KYC profiles with varying documents per tier, app event logs | Good for self-contained records, but links between customers would still need joins in application code |
| Column-family | Cassandra | Very high-volume device and login telemetry over time | Built for writes and time-range reads, not path traversal |
| **Graph** | **Neo4j** | **Fraud rings, mule chains, link analysis** | **Chosen: the questions are about connections** |

## The graph model

```
(:Customer {id, name, tier, state})
(:Device {id, fingerprint, os})
(:BankAccount {key, bank_code, bank_name, account_number, account_name})

(:Customer)-[:USES {first_used}]->(:Device)
(:Customer)-[:SENT {txn_id, amount, at}]->(:Customer)
(:Customer)-[:PAID_OUT {txn_id, amount, at}]->(:BankAccount)
```

- Customers, devices and external bank accounts are the "things", so they are **nodes**.
- Money moving and a phone being used are the "connections", so they are **relationships**, carrying the amount and time as properties.
- The `customer_devices` link table from Portfolio 1 simply becomes the `USES` relationship. The many-to-many structure that needed a separate table in SQL is natural in a graph.

I only copied what the fraud team needs: names, KYC tier, state, device fingerprints and 1 to 15 October money movements. **There is no BVN, NIN, phone number or balance in the graph.** That keeps the copy small and follows NDPA data minimisation: a second store of personal data should hold only what its purpose needs.

## How the data gets there

PostgreSQL stays the **system of record**. Neo4j is an analytical copy:
1. `01_export_from_postgres.sql` exports six CSV files with `\copy` (customers, devices, device use, transfers, bank accounts, payouts).
2. `02_load_graph.cypher` creates uniqueness constraints, then loads the CSVs with `LOAD CSV` in batches of 10,000 rows (`CALL { } IN TRANSACTIONS`).

What was loaded:

| Nodes | Count | Relationships | Count |
|---|---|---|---|
| Customer | 40,003 | USES | 46,104 |
| Device | 46,082 | SENT | 27,242 |
| BankAccount | 3,169 | PAID_OUT | 3,601 |

Because it is a batch copy, the graph is only as fresh as the last load. In production I would stream changes from PostgreSQL into Neo4j (change data capture), so fraud analysts see new transfers within seconds rather than the next day.

## Fraud queries and what they found

All four are in `03_fraud_queries.cypher`. The output is in `results/fraud_queries.txt`.

**G1. Devices shared by three or more customers.** Three phones, `fp-ring-01`, `fp-ring-02` and `fp-ring-03`, are each used by **8 different customers**. One phone behind many accounts is a common sign of an account farm, where one person opens many accounts to spread money around or abuse sign-up bonuses.

**G2. Collector accounts.** **Oluwaseun Bello (customer 407)** received money from **10 different people on 11 October, N98,000 in total**. Ordinary customers in the data receive from one to five people a day.

**G3. Follow the money.** Starting from the collector, the query follows transfers where each hop happens within one hour of the last, until the money leaves to a bank:

```
Oluwaseun Bello → Funmilayo Salami → Ifeoma Balogun → Ifeoma Oladipo → Esther Ogunleye → United Bank for Africa 0987654321
  N95,000          N94,500            N94,000          N93,500           N93,000
4 wallet hops, 55 minutes from the first hop to the bank
```

This is a classic money-mule **layering** pattern. Victims' money is pooled, passed quickly through several accounts with a small cut taken at each step, and cashed out to an account named "Unknown Ventures". Each single transfer looks normal on its own. Only the path is suspicious.

**G4. Who else is connected.** Within two steps of the collector, through money flows or shared devices, there are **29 customers and 13 devices**. This is the list an investigator would review before deciding which accounts to freeze.

The two pictures from Neo4j Browser (`04_browser_visuals.cypher`) show this better than any table: three star-shaped device rings, and ten victims feeding one account with a single chain leading out to the bank.

## The same question in SQL

To be fair to PostgreSQL, I wrote G3 in SQL as well (`05_same_question_in_sql.sql`), as a recursive CTE with the same rules. **It found exactly the same trail** (407 → 408 → 409 → 410 → 411 → 033-0987654321, 4 hops, 55 minutes).

| | PostgreSQL (recursive CTE) | Neo4j (Cypher path pattern) |
|---|---|---|
| Result | Same trail | Same trail |
| Query length (excluding comments) | 37 lines | 13 lines |
| Time on my laptop | 2,143 ms and 3,376 ms (two runs) | 324 ms (first row after 2 ms) |
| How depth is handled | A recursive CTE that joins the transfers back onto itself for each extra hop | `[:SENT*1..6]`: depth is a single number in the pattern |

The graph query was roughly 6 to 10 times faster here, and much easier to read and change. If the fraud team wants to allow 8 hops instead of 6, or add "and the account shares a device with a ring member", in Cypher that is one more pattern. In SQL it is another join inside the recursion.

I would not over-claim from one test. The data is small (27,242 transfers), the SQL could be tuned further, and the two engines run with different memory settings. The bigger difference is that the SQL gets slower as the number of hops grows, because each level joins the whole transfer set again, while the graph only follows the links that actually exist from each account.

## Limits and what I would do in production

- **Two stores means two places to secure.** The graph holds personal data too. Neo4j Community has no role-based access control, so in production I would use Enterprise or AuraDB, restrict access to the fraud team, and log every query.
- **Consistency.** Neo4j here is eventually consistent with PostgreSQL. That is acceptable for investigation, but blocking a transfer in real time should still be decided by the transactional checks in Portfolio 3, perhaps using a risk score the graph calculated earlier.
- **Detection to action.** G1 to G3 would run on a schedule and write their findings back into the `fraud_alerts` table in PostgreSQL (rule codes `SHARED_DEVICE` and `MULE_PATTERN` already exist from Portfolio 1). The alerts then reach the compliance team inside the main system, with an audit trail.

## Screenshots

All in `docs/screenshots/`:

| File | Shows |
|---|---|
| `p4_01_export_from_postgres` | CSV export from PostgreSQL with row counts |
| `p4_02_neo4j_browser_connect` | Neo4j Browser login |
| `p4_03_graph_loaded` | Neo4j image pulled, container started, graph loaded with node and relationship counts |
| `p4_04_fraud_queries_g1_to_g4` | G1 to G4 results from cypher-shell |
| `p4_05_same_question_in_sql` | G3 written in SQL, same trail found |
| `p4_06_v1_shared_device_rings` | Graph picture: the three device rings |
| `p4_07_v2_mule_network` | Graph picture: ten victims, the collector and the chain to the bank |
| `p4_08a`, `p4_08b` | G3 in Neo4j Browser and its timing |

## Files

| File | Purpose |
|---|---|
| `01_export_from_postgres.sql` | Export from PostgreSQL to CSV |
| `02_load_graph.cypher` | Constraints and graph load |
| `03_fraud_queries.cypher` | G1 to G4 |
| `04_browser_visuals.cypher` | V1 (rings) and V2 (mule network) for Neo4j Browser |
| `05_same_question_in_sql.sql` | G3 in SQL for comparison |
| `results/load_graph.txt`, `results/fraud_queries.txt`, `results/sql_comparison.log` | Outputs |
| `import/` | CSV files, regenerated by step 1 (not committed) |

## How to run

```
docker compose up -d neo4j
docker exec tcs-postgres psql -U postgres -d tcsolutions -f /work/portfolio-4-nosql/01_export_from_postgres.sql
docker exec tcs-neo4j sh -c "cypher-shell -u neo4j -p tcs_lab_2026 --format plain -f /p4/02_load_graph.cypher | tee /p4/results/load_graph.txt"
docker exec tcs-neo4j sh -c "cypher-shell -u neo4j -p tcs_lab_2026 --format plain -f /p4/03_fraud_queries.cypher | tee /p4/results/fraud_queries.txt"
docker exec tcs-postgres psql -U postgres -d tcsolutions -f /work/portfolio-4-nosql/05_same_question_in_sql.sql -L /work/portfolio-4-nosql/results/sql_comparison.log
```
Neo4j Browser: http://localhost:7474 (user `neo4j`, lab password `tcs_lab_2026`).
