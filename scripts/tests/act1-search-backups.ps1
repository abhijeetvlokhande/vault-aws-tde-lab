# Run in PowerShell on the SQL Server host, after act1-setup-exposure-demo.sql
# has completed. Searches both raw backup files for a customer SSN that only
# exists as data inside the database -- never anywhere in application code.

Write-Host "Unprotected backup:" -ForegroundColor Yellow
if (Select-String -Path "C:\Backups\BankDemo_Unprotected.bak" -Pattern "123-45-6789" -SimpleMatch -Quiet) {
    Write-Host "  MATCH FOUND -- customer SSN readable in raw backup file" -ForegroundColor Red
} else {
    Write-Host "  No match found" -ForegroundColor Green
}

Write-Host "`nVault-encrypted backup:" -ForegroundColor Yellow
if (Select-String -Path "C:\Backups\TestTDE.bak" -Pattern "123-45-6789" -SimpleMatch -Quiet) {
    Write-Host "  MATCH FOUND" -ForegroundColor Red
} else {
    Write-Host "  No match found -- data unreadable without the Vault-managed key" -ForegroundColor Green
}
