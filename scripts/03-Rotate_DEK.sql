-- Rotates the DEK itself. This kicks off a BACKGROUND re-encryption scan --
-- it is not instant, even on a small database. Wait for it to finish
-- before doing anything else to the encryption key (see 04, which needs
-- this scan fully complete before it can run).

USE TestTDE;
GO

ALTER DATABASE ENCRYPTION KEY
REGENERATE WITH ALGORITHM = AES_256;
GO

-- Poll until the scan finishes. For a tiny test database this is usually
-- a few seconds; a real production-sized database needs a real wait/poll
-- loop here, not a fixed delay.
WAITFOR DELAY '00:00:05';
GO

SELECT encryption_state, percent_complete
FROM sys.dm_database_encryption_keys
WHERE database_id = DB_ID('TestTDE');
GO

-- You want encryption_state = 3 (steady-state Encrypted) and
-- percent_complete = 0 (scan done) before moving on to 04-Re-encrypt_DB.sql.
-- If it's still mid-scan, re-run the WAITFOR + SELECT above.
