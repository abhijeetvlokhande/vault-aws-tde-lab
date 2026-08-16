# Act 3 -- Vault-side key (KEK) rotation test

Answers a real question: does rotating the Vault Transit key break a
database that's already running, or is there a grace period?

## 1. Rotate the Transit key
On the Vault host, over SSH:
```bash
export VAULT_ADDR=http://127.0.0.1:8200
vault write -f transit/keys/ekm-encryption-key/rotate
vault read transit/keys/ekm-encryption-key
```

## 2. Without touching SQL Server at all, confirm the database still works
In SSMS:
```sql
SELECT TOP 5 * FROM TestTDE.dbo.Customers;
```

If this returns data with no error, Vault's key versioning is keeping the
old key version valid for decrypt -- rotating the KEK does not force an
immediate re-wrap or cause an outage. You get a grace period to re-wrap on
your own schedule (`04-Re-encrypt_DB.sql`), not a forced action.
