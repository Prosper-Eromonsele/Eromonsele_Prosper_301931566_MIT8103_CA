# TC.Solutions Fintech: Advanced Database Systems Portfolio

**Course:** MIT 8103 Advanced Database Systems, Miva Open University
**Student:** Prosper Eromonsele (301931566)
**Case study:** TC.Solutions Fintech Ltd (simulated organisation)

## Case study

TC.Solutions is a Lagos-based payment company that I first created as a scenario in an earlier security project. For this portfolio I have extended it into a full database case study. The company runs a mobile wallet and payment platform for about 40,000 active customers across Nigeria. Customers can fund their wallet, send money to other TC.Solutions users or to any Nigerian bank account, pay merchants by card or QR code, and buy airtime and pay bills. TC.Solutions also runs a network of POS agents in places like Ikeja, Aba and Kano, where people without a smartphone can deposit or withdraw cash. Online businesses connect to the platform through its payment API.

As a payment service provider, TC.Solutions is regulated by the Central Bank of Nigeria. It also has to comply with PCI DSS v4.0 for card data and the Nigeria Data Protection Act 2023 for customer personal data. Every naira that moves must be traceable, failed transfers must be reversed correctly, and identity data such as BVN and NIN must be protected. The company is also planning to expand to Ghana, which raises questions about multi-currency wallets and where customer data may be stored.

**Users of the database:**
- customers (mobile app and USSD);
- POS agents (cash-in and cash-out);
- merchants (payment API);
- customer support staff;
- the compliance and fraud team;
- finance (reconciliation and settlement).

**Major data:**
- customers and their KYC tier;
- wallets and balances;
- transactions and double-entry ledger entries;
- beneficiaries;
- merchants and agents;
- devices;
- fraud alerts;
- the staff audit log.

**Key operations:**
- open and verify an account;
- fund a wallet;
- transfer funds;
- reverse a failed transfer;
- merchant payment and settlement;
- agent cash-in and cash-out;
- account statement;
- reconcile balances against the ledger;
- flag suspicious activity.

*Assumptions: about 1,200 merchants and 350 agents; Ghana expansion planned for 2027. All data in this repository is synthetic.*

## Repository structure

| Folder | Portfolio |
|---|---|
| `portfolio-1-database-design/` | ER model, relational schema, constraints, normalisation |
| `portfolio-2-query-optimisation/` | queries, execution plans, indexing and performance |
| `portfolio-3-transactions-concurrency/` | commit, rollback, isolation, concurrency control |
| `portfolio-4-nosql/` | graph model (Neo4j) for fraud detection |
| `portfolio-5-distributed-cloud/` | replication, consistency and data residency |
| `docs/screenshots/` | evidence screenshots |

## How to run

```
docker compose up -d
docker exec -it tcs-postgres psql -U postgres -d tcsolutions -f /work/portfolio-1-database-design/schema.sql
docker exec -it tcs-postgres psql -U postgres -d tcsolutions -f /work/portfolio-1-database-design/seed.sql
```
