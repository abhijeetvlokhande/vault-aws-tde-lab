-- Act 1: shows the actual difference TDE makes -- a raw backup file search
-- finds plaintext data in an unencrypted database and nothing in the
-- Vault-encrypted one. Run this after 01-Configure_DB.sql.

USE master;
GO

EXEC master.dbo.xp_create_subdir 'C:\Backups';
GO

-- Add a realistic table to the already-encrypted TestTDE database
USE TestTDE;
GO
CREATE TABLE dbo.Customers (
    CustomerID INT IDENTITY(1,1) PRIMARY KEY,
    FullName NVARCHAR(100),
    AccountNumber VARCHAR(20),
    SSN VARCHAR(11),
    Balance DECIMAL(12,2)
);
GO
INSERT INTO dbo.Customers (FullName, AccountNumber, SSN, Balance) VALUES
('Priya Sharma', '4000123456789012', '123-45-6789', 542300.00),
('Rohan Mehta', '4000987654321098', '987-65-4321', 128900.50),
('Ananya Iyer', '4000456789012345', '456-78-9012', 76500.25);
GO

-- Unencrypted twin database, same data, for contrast
CREATE DATABASE BankDemo_Unprotected;
GO
USE BankDemo_Unprotected;
GO
CREATE TABLE dbo.Customers (
    CustomerID INT IDENTITY(1,1) PRIMARY KEY,
    FullName NVARCHAR(100),
    AccountNumber VARCHAR(20),
    SSN VARCHAR(11),
    Balance DECIMAL(12,2)
);
GO
INSERT INTO dbo.Customers (FullName, AccountNumber, SSN, Balance) VALUES
('Priya Sharma', '4000123456789012', '123-45-6789', 542300.00),
('Rohan Mehta', '4000987654321098', '987-65-4321', 128900.50),
('Ananya Iyer', '4000456789012345', '456-78-9012', 76500.25);
GO

BACKUP DATABASE TestTDE TO DISK = 'C:\Backups\TestTDE.bak';
GO
BACKUP DATABASE BankDemo_Unprotected TO DISK = 'C:\Backups\BankDemo_Unprotected.bak';
GO
