-- =====================================================================
-- TC.Solutions - G3 "follow the money" written in SQL, for comparison
-- MIT 8103 CA - Prosper Eromonsele (301931566)
-- Same rule as the Cypher query: start at a collector (8+ senders in a day),
-- follow wallet transfers where each hop is within 1 hour of the last,
-- and stop at a payout to a bank account within 1 hour.
-- =====================================================================
SET search_path TO tcs;
\timing on

WITH RECURSIVE
xfer AS (                      -- wallet-to-wallet transfers as sender -> receiver customer
  SELECT t.initiated_by AS from_c, w.customer_id AS to_c, t.amount, t.created_at AS at
  FROM transactions t
  JOIN ledger_entries le ON le.txn_id = t.txn_id AND le.direction = 'CR'
  JOIN wallets w ON w.wallet_id = le.wallet_id AND w.wallet_type = 'CUSTOMER'
  WHERE t.txn_type = 'TRANSFER' AND t.status = 'SUCCESS'
    AND t.created_at >= '2026-10-01' AND t.created_at < '2026-10-16'
),
collector AS (
  SELECT to_c AS customer_id, (at AT TIME ZONE 'UTC')::date AS day
  FROM xfer GROUP BY 1, 2 HAVING count(DISTINCT from_c) >= 8
),
chain AS (
  SELECT c.customer_id AS start_c, ARRAY[c.customer_id] AS path, ARRAY[]::numeric[] AS amounts,
         c.customer_id AS last_c, NULL::timestamptz AS last_at, NULL::timestamptz AS first_at,
         c.day, 0 AS hops
  FROM collector c
  UNION ALL
  SELECT ch.start_c, ch.path || x.to_c, ch.amounts || x.amount, x.to_c, x.at,
         COALESCE(ch.first_at, x.at), ch.day, ch.hops + 1
  FROM chain ch
  JOIN xfer x ON x.from_c = ch.last_c
  WHERE ch.hops < 6
    AND x.to_c <> ALL (ch.path)
    AND ( (ch.hops = 0 AND x.at >= ch.day::timestamp AT TIME ZONE 'UTC'
                       AND x.at <  (ch.day + 2)::timestamp AT TIME ZONE 'UTC')
       OR (ch.hops > 0 AND x.at > ch.last_at AND x.at <= ch.last_at + INTERVAL '1 hour') )
)
SELECT ch.path AS customer_ids, ch.amounts || t.amount AS amounts,
       b.bank_code || '-' || b.account_number AS bank_account, ch.hops AS wallet_hops,
       round(extract(epoch FROM t.created_at - ch.first_at) / 60) AS minutes_from_first_hop_to_bank
FROM chain ch
JOIN transactions t ON t.initiated_by = ch.last_c AND t.txn_type = 'EXTERNAL_TRANSFER' AND t.status = 'SUCCESS'
                   AND t.created_at > ch.last_at AND t.created_at <= ch.last_at + INTERVAL '1 hour'
JOIN beneficiaries b ON b.beneficiary_id = t.beneficiary_id
WHERE ch.hops >= 1;
