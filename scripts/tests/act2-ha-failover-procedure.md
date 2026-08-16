# Act 2 -- Vault outage / recovery test

Proves what actually happens to the encrypted database when Vault goes
down, and exactly what recovery requires. Run after 01-Configure_DB.sql.

**Before you start:** confirm the credential check at the end of
`01-Configure_DB.sql` showed real values, not `PASTE_YOUR_...` placeholder
text. If a placeholder was missed, this test will fail for the wrong
reason (a broken credential, not a real Vault outage) -- see "Known
gotchas" in the main README.

## 1. Stop Vault
On the Vault host, over SSH:
```bash
sudo systemctl stop vault
```

## 2. Confirm the database fails safely
In SSMS:
```sql
ALTER DATABASE TestTDE SET OFFLINE;
GO
ALTER DATABASE TestTDE SET ONLINE;
GO
```
Expect this to fail with a "Cannot open session for cryptographic
provider" error (code 2050). This is the whole point of the test: taking
the database offline and back online forces SQL Server to re-fetch the DEK
from Vault right now, which is why this specific action fails while Vault
is down. It does not mean the key is never cached -- if the database had
stayed running and never gone through this offline/online cycle, Vault
being down wouldn't have affected it, since the key was already unwrapped
and sitting in memory. SQL Server reverts the database to offline rather
than leaving it in a broken half-state.

## 3. Bring Vault back and unseal it
Still on the Vault host:
```bash
sudo systemctl start vault
export VAULT_ADDR=http://127.0.0.1:8200
vault operator unseal $(jq -r '.unseal_keys_b64[0]' /home/ubuntu/vault-init.json)
vault status
```
Wait for `HA Mode: active` in the output before moving on -- a restarted
single-node Vault comes back **sealed**, and even after unsealing, leader
election needs a moment to complete. Both steps are required; skipping
either one leaves the database unable to recover.

## 4. Retry -- should now succeed
Back in SSMS:
```sql
ALTER DATABASE TestTDE SET ONLINE;
GO
```
With a correctly configured credential, this succeeds with no SQL
Server-side restart needed -- unsealing Vault and confirming active HA mode
is the whole recovery path.
