-- Re-wraps the current DEK under the KEK -- run this after rotating the
-- Vault-side transit key, or after 03-Rotate_DEK.sql, to re-protect the
-- DEK with the current key version.
--
-- In FULL recovery model (the default), SQL Server will refuse to run a
-- second encryption-scan operation back to back with the first one until
-- you take a log backup. If you just ran 03-Rotate_DEK.sql, run this log
-- backup first or the next statement will fail with error 33122.

USE TestTDE;
GO

BACKUP LOG TestTDE TO DISK = 'C:\Backups\TestTDE_log.bak';
GO

ALTER DATABASE ENCRYPTION KEY
ENCRYPTION BY SERVER ASYMMETRIC KEY TransitVaultAsymmetric;
GO

SELECT * FROM sys.dm_database_encryption_keys;
GO
