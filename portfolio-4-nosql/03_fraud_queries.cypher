// =====================================================================
// TC.Solutions - fraud questions answered on the graph (Portfolio 4)
// MIT 8103 CA - Prosper Eromonsele (301931566)
// =====================================================================

// G1. Devices shared by 3 or more customers (possible account farm / fraud ring)
MATCH (c:Customer)-[:USES]->(d:Device)
WITH d, count(c) AS customers_on_device, collect(c.name) AS customers
WHERE customers_on_device >= 3
RETURN d.fingerprint AS device, d.os AS os, customers_on_device, customers
ORDER BY customers_on_device DESC, device;

// G2. "Collector" accounts: 8 or more different people paid them on the same day
MATCH (v:Customer)-[s:SENT]->(m:Customer)
WITH m, date(s.at) AS day, count(DISTINCT v) AS senders, sum(s.amount) AS received
WHERE senders >= 8
RETURN m.id AS customer_id, m.name AS collector, day, senders, received
ORDER BY senders DESC;

// G3. Follow the money out of each collector: a chain of wallet transfers,
//     each hop within 1 hour of the previous one, ending in a payout to a bank account.
MATCH (v:Customer)-[s:SENT]->(m:Customer)
WITH m, date(s.at) AS day, count(DISTINCT v) AS senders
WHERE senders >= 8
MATCH p = (m)-[hops:SENT*1..6]->(:Customer)-[out:PAID_OUT]->(acct:BankAccount)
WHERE hops[0].at >= datetime({date: day})
  AND hops[0].at <  datetime({date: day}) + duration('P2D')
  AND all(i IN range(0, size(hops) - 2)
          WHERE hops[i+1].at > hops[i].at AND hops[i+1].at <= hops[i].at + duration('PT1H'))
  AND out.at > hops[-1].at AND out.at <= hops[-1].at + duration('PT1H')
RETURN [n IN nodes(p) | coalesce(n.name, acct.bank_name + ' ' + acct.account_number)] AS money_trail,
       [r IN relationships(p) | r.amount] AS amounts,
       size(hops) AS wallet_hops,
       duration.between(hops[0].at, out.at).minutes AS minutes_from_first_hop_to_bank;

// G4. Who is linked to a collector within two steps (shared device or money flow)?
//     Useful to decide which other accounts to freeze while investigating.
MATCH (v:Customer)-[s:SENT]->(m:Customer)
WITH m, date(s.at) AS day, count(DISTINCT v) AS senders
WHERE senders >= 8
MATCH (m)-[:SENT|USES*1..2]-(linked)
WHERE linked <> m
RETURN m.name AS collector, labels(linked)[0] AS linked_type,
       count(DISTINCT linked) AS how_many
ORDER BY linked_type;
