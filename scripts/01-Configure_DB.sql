-- Run in SSMS as the SQL Server admin.
--
-- IMPORTANT: replace BOTH pairs of placeholders below with the real values
-- from approle-role-id.txt / approle-secret-id.txt (written to your local
-- machine by Terraform). There are TWO separate CREATE CREDENTIAL blocks in
-- this script, and both need the real values. Missing the second one is an
-- easy, silent mistake: this script will complete with no errors either
-- way, but the database will fail the next time it goes offline and back
-- online. See "Known gotchas" in the README before you run this.

USE master;
GO

EXEC sp_configure 'show advanced options', 1;
GO
RECONFIGURE;
GO

EXEC sp_configure 'EKM provider enabled', 1;
GO
RECONFIGURE;
GO

CREATE CRYPTOGRAPHIC PROVIDER TransitVaultProvider
FROM FILE = 'C:\Program Files\HashiCorp\Transit Vault EKM Provider\TransitVaultEKM.dll'
GO

-- Credential #1 of 2 -- used to open the provider and create the asymmetric key
CREATE CREDENTIAL TransitVaultCredentials
    WITH IDENTITY = 'PASTE_YOUR_ROLE_ID_HERE',
    SECRET = 'PASTE_YOUR_SECRET_ID_HERE'
FOR CRYPTOGRAPHIC PROVIDER TransitVaultProvider;
GO

-- Replace with the actual Windows login SSMS shows you're connected as
-- (run SELECT SUSER_NAME(); in a new query window if you're not sure)
CREATE LOGIN "PASTE_YOUR_WINDOWS_LOGIN_HERE" FROM WINDOWS;
GO
ALTER LOGIN "PASTE_YOUR_WINDOWS_LOGIN_HERE" ADD CREDENTIAL TransitVaultCredentials;
GO

CREATE ASYMMETRIC KEY TransitVaultAsymmetric
FROM PROVIDER TransitVaultProvider
WITH
CREATION_DISPOSITION = OPEN_EXISTING,
PROVIDER_KEY_NAME = 'ekm-encryption-key';
GO

-- Credential #2 of 2 -- used by TransitVaultTDELogin, which SQL Server calls
-- on EVERY database online/startup to unwrap the DEK. This is the one that
-- fails silently at creation time if you miss it.
CREATE CREDENTIAL TransitVaultTDECredentials
    WITH IDENTITY = 'PASTE_YOUR_ROLE_ID_HERE',
    SECRET = 'PASTE_YOUR_SECRET_ID_HERE'
FOR CRYPTOGRAPHIC PROVIDER TransitVaultProvider;
GO

CREATE LOGIN TransitVaultTDELogin
FROM ASYMMETRIC KEY TransitVaultAsymmetric;
GO

ALTER LOGIN TransitVaultTDELogin
ADD CREDENTIAL TransitVaultTDECredentials;
GO

CREATE DATABASE TestTDE
GO

USE TestTDE;
GO

CREATE DATABASE ENCRYPTION KEY
WITH ALGORITHM = AES_256
ENCRYPTION BY SERVER ASYMMETRIC KEY TransitVaultAsymmetric;
GO

ALTER DATABASE TestTDE
SET ENCRYPTION ON;
GO

-- Verification: catches the exact placeholder-not-replaced mistake before
-- it becomes a mystery failure later. Both rows must show a real GUID-like
-- value in credential_identity, never literal "PASTE_YOUR_..." text.
SELECT name, credential_identity
FROM sys.credentials
WHERE name IN ('TransitVaultCredentials', 'TransitVaultTDECredentials');
GO

-- Prove the startup path actually works, right now, while it's fresh in
-- your mind -- not the next time this database happens to restart.
ALTER DATABASE TestTDE SET OFFLINE;
GO
ALTER DATABASE TestTDE SET ONLINE;
GO
SELECT * FROM sys.dm_database_encryption_keys;
GO
