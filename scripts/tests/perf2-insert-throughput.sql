-- Measures steady-state write throughput. Since the DEK stays cached in
-- memory once the database is online, Vault is NOT involved in any of
-- these inserts -- this measures generic TDE overhead (same for any TDE
-- backend), not anything Vault-specific.
--
-- Run once per combination of {10000, 50000, 100000} rows x
-- {TestTDE, BankDemo_Unprotected} -- change line 1 and @rows each time.
-- These are the exact row counts used in the published results (solution
-- brief, demo talktrack) -- match them if you want directly comparable
-- numbers, rather than testing arbitrary different row counts.
--
-- NOTE: RowCount is a reserved word in SQL Server (tied to SET ROWCOUNT)
-- and will throw a syntax error if used bare as a column alias -- that's
-- why the alias below is RowsInserted, not RowCount.

USE TestTDE; -- change to BankDemo_Unprotected for the other half
GO
IF OBJECT_ID('dbo.PerfTest') IS NOT NULL DROP TABLE dbo.PerfTest;
CREATE TABLE dbo.PerfTest (ID INT IDENTITY(1,1), Data NVARCHAR(200));
GO
DECLARE @rows INT = 10000; -- change to 50000, then 100000
DECLARE @start DATETIME2 = SYSDATETIME();
DECLARE @i INT = 0;
WHILE @i < @rows
BEGIN
    INSERT INTO dbo.PerfTest (Data) VALUES (NEWID());
    SET @i += 1;
END
SELECT DATEDIFF(MILLISECOND, @start, SYSDATETIME()) AS InsertMs, @rows AS RowsInserted;
GO
