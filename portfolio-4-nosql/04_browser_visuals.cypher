// =====================================================================
// Paste these ONE AT A TIME into Neo4j Browser (http://localhost:7474)
// to draw the pictures for the report. Screenshot each graph.
// =====================================================================

// V1. The three shared-device rings
MATCH p = (:Customer)-[:USES]->(d:Device)
WHERE d.fingerprint STARTS WITH 'fp-ring'
RETURN p;

// V2. The mule network: victims paying the collector, and the chain out to the bank
MATCH (v:Customer)-[s:SENT]->(m:Customer)
WITH m, date(s.at) AS day, count(DISTINCT v) AS senders
WHERE senders >= 8
MATCH fan = (:Customer)-[s2:SENT]->(m) WHERE date(s2.at) = day
MATCH chain = (m)-[hops:SENT*1..6]->(:Customer)-[out:PAID_OUT]->(:BankAccount)
WHERE hops[0].at >= datetime({date: day})
  AND hops[0].at <  datetime({date: day}) + duration('P2D')
  AND all(i IN range(0, size(hops) - 2)
          WHERE hops[i+1].at > hops[i].at AND hops[i+1].at <= hops[i].at + duration('PT1H'))
  AND out.at > hops[-1].at AND out.at <= hops[-1].at + duration('PT1H')
RETURN fan, chain;
