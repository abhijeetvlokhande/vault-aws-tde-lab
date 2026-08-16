# Run this INTERACTIVELY on the SQL Server host over RDP, as Administrator.
# (The reference repo tried to push this via remote command execution and
# documented that it fails — it runs under the machine identity, not a SQL
# admin identity — so this has to be run by hand, not scripted remotely.)

$EKM_WORKING_DIR = "C:\Users\Administrator\Desktop\ekm"
$CERT_UPDATE_WORKING_DIR = "$Env:USERPROFILE\Downloads"

# TODO: replace with the vault_private_ip output from `terraform output`
$VAULT_API_URL = "http://VAULT_PRIVATE_IP:8200"

$EKM_PROVIDER_SOURCE_URL = "https://releases.hashicorp.com/vault-mssql-ekm-provider/0.2.0+ent/vault-mssql-ekm-provider_0.2.0+ent_windows_amd64.zip"
$EKM_PROVIDER_ZIP_FILE = "$EKM_WORKING_DIR\vault-mssql-ekm-provider_0.2.0+ent_windows_amd64.zip"
$EKM_PROVIDER_MSI_FILE = "$EKM_WORKING_DIR\vault-mssql-ekm-provider.msi"
$EKM_PROVIDER_LOG_FILE = "$EKM_WORKING_DIR\vault-mssql-ekm-provider.log"

New-Item -ItemType Directory -Path $EKM_WORKING_DIR -Force | Out-Null
New-Item -ItemType Directory -Path $CERT_UPDATE_WORKING_DIR -Force | Out-Null

# Fixes the "Cannot load library / Authenticode signature" error documented
# in HashiCorp's troubleshooting guide — needed on a fresh Windows image.
Cmd.exe /C "certutil -syncwithWU $CERT_UPDATE_WORKING_DIR"
Cmd.exe /C "extrac32 /L $CERT_UPDATE_WORKING_DIR $CERT_UPDATE_WORKING_DIR\authrootstl.cab authroot.stl"
Cmd.exe /C "certutil -f -v -ent -AddStore Root $CERT_UPDATE_WORKING_DIR\authroot.stl"

Invoke-WebRequest -URI $EKM_PROVIDER_SOURCE_URL -Outfile $EKM_PROVIDER_ZIP_FILE
Expand-Archive $EKM_PROVIDER_ZIP_FILE -DestinationPath $EKM_WORKING_DIR -Force

Start-Process -FilePath "msiexec" -ArgumentList "/i `"$EKM_PROVIDER_MSI_FILE`" VAULT_API_URL=$VAULT_API_URL VAULT_API_URL_IS_VALID=1 VAULT_INSTALL_FOLDER=`"C:\Program Files\HashiCorp\Transit Vault EKM Provider\`" /qb /l* `"$EKM_PROVIDER_LOG_FILE`"" -Wait

Write-Host "EKM provider installed. Restart SQL Server, then run 01-Configure_DB.sql in SSMS."
