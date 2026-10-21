// =====================================================================
// TC.Solutions - build the fraud graph in Neo4j (Portfolio 4)
// MIT 8103 CA - Prosper Eromonsele (301931566)
// Reads the CSV files from /import. Safe to run again: it starts empty.
//
// Model
//   (:Customer {id, name, tier, state})
//   (:Device {id, fingerprint, os})
//   (:BankAccount {key, bank_code, bank_name, account_number, account_name})
//   (:Customer)-[:USES {first_used}]->(:Device)
//   (:Customer)-[:SENT {txn_id, amount, at}]->(:Customer)
//   (:Customer)-[:PAID_OUT {txn_id, amount, at}]->(:BankAccount)
// =====================================================================

// 0. start from an empty graph
MATCH (n) CALL { WITH n DETACH DELETE n } IN TRANSACTIONS OF 10000 ROWS;

// 1. uniqueness constraints (they also create the indexes used by the loads below)
CREATE CONSTRAINT customer_id IF NOT EXISTS FOR (c:Customer) REQUIRE c.id IS UNIQUE;
CREATE CONSTRAINT device_id IF NOT EXISTS FOR (d:Device) REQUIRE d.id IS UNIQUE;
CREATE CONSTRAINT bank_account_key IF NOT EXISTS FOR (a:BankAccount) REQUIRE a.key IS UNIQUE;

// 2. nodes
LOAD CSV WITH HEADERS FROM 'file:///customers.csv' AS row
CALL { WITH row
  CREATE (:Customer {id: toInteger(row.customer_id), name: row.name,
                     tier: toInteger(row.kyc_tier), state: row.state})
} IN TRANSACTIONS OF 10000 ROWS;

LOAD CSV WITH HEADERS FROM 'file:///devices.csv' AS row
CALL { WITH row
  CREATE (:Device {id: toInteger(row.device_id), fingerprint: row.fingerprint, os: row.os})
} IN TRANSACTIONS OF 10000 ROWS;

LOAD CSV WITH HEADERS FROM 'file:///bank_accounts.csv' AS row
CALL { WITH row
  CREATE (:BankAccount {key: row.key, bank_code: row.bank_code, bank_name: row.bank_name,
                        account_number: row.account_number, account_name: row.account_name})
} IN TRANSACTIONS OF 10000 ROWS;

// 3. relationships
LOAD CSV WITH HEADERS FROM 'file:///uses.csv' AS row
CALL { WITH row
  MATCH (c:Customer {id: toInteger(row.customer_id)})
  MATCH (d:Device {id: toInteger(row.device_id)})
  CREATE (c)-[:USES {first_used: datetime(row.first_used)}]->(d)
} IN TRANSACTIONS OF 10000 ROWS;

LOAD CSV WITH HEADERS FROM 'file:///transfers.csv' AS row
CALL { WITH row
  MATCH (a:Customer {id: toInteger(row.from_customer)})
  MATCH (b:Customer {id: toInteger(row.to_customer)})
  CREATE (a)-[:SENT {txn_id: toInteger(row.txn_id), amount: toFloat(row.amount), at: datetime(row.at)}]->(b)
} IN TRANSACTIONS OF 10000 ROWS;

LOAD CSV WITH HEADERS FROM 'file:///payouts.csv' AS row
CALL { WITH row
  MATCH (c:Customer {id: toInteger(row.customer_id)})
  MATCH (a:BankAccount {key: row.account_key})
  CREATE (c)-[:PAID_OUT {txn_id: toInteger(row.txn_id), amount: toFloat(row.amount), at: datetime(row.at)}]->(a)
} IN TRANSACTIONS OF 10000 ROWS;

// 4. what was loaded
MATCH (n) RETURN labels(n)[0] AS node_label, count(*) AS nodes ORDER BY node_label;
MATCH ()-[r]->() RETURN type(r) AS relationship, count(*) AS relationships ORDER BY relationship;
