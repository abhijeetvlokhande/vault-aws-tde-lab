-- Measures the ONE place Vault actually sits in the critical path: how
-- long it takes to bring the database online, which is when SQL Server
-- asks Vault to unwrap the DEK. Run this several times (5+) for both
-- databases and compare medians -- a single run is noise.

ALTER DATABASE TestTDE SET OFFLINE WITH ROLLBACK IMMEDIATE;
GO
DECLARE @start DATETIME2 = SYSDATETIME();
ALTER DATABASE TestTDE SET ONLINE;
SELECT DATEDIFF(MILLISECOND, @start, SYSDATETIME()) AS OnlineMs, 'TestTDE (Vault TDE)' AS Label;
GO

ALTER DATABASE BankDemo_Unprotected SET OFFLINE WITH ROLLBACK IMMEDIATE;
GO
DECLARE @start2 DATETIME2 = SYSDATETIME();
ALTER DATABASE BankDemo_Unprotected SET ONLINE;
SELECT DATEDIFF(MILLISECOND, @start2, SYSDATETIME()) AS OnlineMs, 'BankDemo_Unprotected (no TDE)' AS Label;
GO
