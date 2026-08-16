# SQL Server TDE with HashiCorp Vault -- a hands-on lab

This lab builds a small, real environment on AWS so you can see, test, and
break SQL Server's Transparent Data Encryption (TDE) when the encryption
key is managed by HashiCorp Vault, instead of trusting the documentation.

It uses HashiCorp's own native EKM (Extensible Key Management) provider for
SQL Server, backed by Vault's Transit secrets engine. It does not use
KMIP, and it does not use any third-party connector.

**Every command in this document was actually run to build and test this
lab.** Nothing here is a paraphrase or a summary of what to do -- it is
the literal command. Where a placeholder is unavoidable (your own IP
address, your own license file path), it is marked clearly.

## What you get

- One Ubuntu server running Vault Enterprise
- One Windows server running SQL Server, with a test database encrypted
  through Vault
- A set of test scripts that prove specific things work (or fail safely):
  data is unreadable without the key, the database survives a Vault
  outage the right way, key rotation works, and performance is
  effectively unaffected

## What this does NOT include

- No production hardening. TLS is off on Vault's listener by default (see
  "Security notes" below) and there's a single unseal key, which is fine
  for a lab and wrong for anything real.
- No KMIP. If you need to compare Vault's native EKM provider against a
  KMIP-based path (for example, a third-party EKM connector pointed at
  Vault's KMIP secrets engine), that's a different, more involved setup
  not covered here.
- No answer on how this compares to another vendor's TDE + KMS backend.

---

## 1. Infrastructure this lab creates

This is the actual AWS layout, not a conceptual diagram. Everything here
is created inside your own existing VPC -- this lab does not create a
new VPC.

```
Your machine (Terraform, AWS CLI, RDP client)
   |
   |-- SSH : 22 -----------------> Vault server (Ubuntu, t3.small)
   |-- Vault API : 8200 (your IP only)
   |-- RDP : 3389 ----------------------------------------> SQL Server (Windows + SQL Enterprise, m5.xlarge)
   |
   Both inside AWS VPC "vault-vpc", public subnet, ap-south-1a

SQL Server --Vault API : 8200 (from mssql security group only, never the internet)--> Vault server
```

Two security groups get created:
- `<prefix>-vault-sg` -- allows SSH (22) and Vault API (8200) from your
  IP only, plus Vault API (8200) from the SQL Server's security group.
- `<prefix>-mssql-sg` -- allows RDP (3389) from your IP only.

Neither security group has any rule allowing `0.0.0.0/0` inbound. Every
port is scoped to a specific security group or a single IP address.

---

## 2. Prerequisites

You need all of these before you start. Missing any one of them will
cause a failure partway through, not a clean error up front.

| What | Why |
|---|---|
| A **Vault Enterprise license** with the **ADP-KM (Advanced Data Protection -- Key Management)** module | Without this, `CREATE ASYMMETRIC KEY ... FROM PROVIDER` fails with error 2050 ("license missing the feature"), and nothing else in this lab works. |
| An **AWS account** with permission to create EC2 instances, security groups, and key pairs | Read-only permissions are not enough. |
| **Terraform** installed locally | `terraform -version` to check. |
| **AWS CLI** installed and configured with working credentials | `aws sts get-caller-identity` to check. |
| An **RSA key pair**, not ed25519 | AWS's `get-password-data` (used to decrypt the Windows admin password) only supports RSA. |
| A **VPC with at least one public subnet** in your target AWS region | This repo does not create a VPC -- point it at an existing one via variables. |

### Generate and register your key pair
```bash
ssh-keygen -t rsa -b 2048 -f ~/.ssh/vault_tde_lab -N ""
aws ec2 import-key-pair --key-name vault-tde-lab --public-key-material fileb://~/.ssh/vault_tde_lab.pub
```
If this fails with a file-not-found error, your key landed somewhere
other than `~/.ssh/` -- run `find ~ -iname "vault_tde_lab.pub"` to locate
it and adjust the path.

### SQL Server edition matters
TDE's EKM feature only works on SQL Server **Enterprise** or **Developer**
edition. Standard, Web, and Express do not support it at all -- this is a
Microsoft licensing limitation, not a Vault limitation. AWS's public
Windows+SQL Server AMIs come in Standard, Web, Express, and Enterprise --
there is no public "Developer" edition AMI. This repo defaults to the
**Enterprise** AMI, which bills SQL Server licensing hourly as part of the
EC2 price.

---

## 3. Repo layout

```
main.tf                    Root: security groups, wires the two modules together
variables.tf                Region, VPC/subnet, AMI IDs, your IP, license file path
vault-server/                Vault EC2 instance + full AppRole/Transit setup
mssql-server/                SQL Server EC2 instance
scripts/
  01-Configure_DB.sql          Run manually via SSMS -- sets up the EKM provider
  02-Check_DB.sql               Confirms encryption is on
  03-Rotate_DEK.sql             Rotates the database's own encryption key
  04-Re-encrypt_DB.sql          Re-wraps the key after rotation
  DeployEKMProvider.PS1        Run manually via PowerShell -- installs the EKM provider
  tests/
    act1-setup-exposure-demo.sql   Sets up a side-by-side encrypted/unencrypted comparison
    act1-search-backups.ps1        Proves data is unreadable in the encrypted backup
    act2-ha-failover-procedure.md  Step-by-step: what happens when Vault goes down
    act3-vault-side-kek-rotation.md Step-by-step: does rotating Vault's key break anything
    perf1-startup-latency.sql      Measures the one place Vault adds latency
    perf2-insert-throughput.sql    Measures steady-state write performance
docs/
  solution-brief.docx           Full write-up with test results and screenshots
demo-talktrack/
  talktrack.html                 Self-contained demo script with narration and commands
```

---

## 4. Deploy the infrastructure

```bash
terraform init
terraform apply \
  -var="vault_license_file_path=/path/to/your/vault.hclic" \
  -var="allowed_ip=$(curl -s https://checkip.amazonaws.com)/32"
```

This creates both servers, installs and unseals Vault, and fully
configures AppRole and the Transit secrets engine automatically -- see
`vault-server/templates/initialize-vault-instance.sh` for the exact
commands it runs on your behalf (`vault auth enable approle`,
`vault secrets enable transit`, `vault write transit/keys/...`, the full
`tde-policy` document, and so on).

When it finishes, two files appear in this directory:
`approle-role-id.txt` and `approle-secret-id.txt`. Print them to confirm:
```bash
cat approle-role-id.txt
cat approle-secret-id.txt
```
You'll paste both values into `01-Configure_DB.sql` in the next section.

**If your IP address changes partway through** (common on hotel/mobile
networks), commands that were working will suddenly time out with no
useful error. Recheck and re-apply:
```bash
curl -s https://checkip.amazonaws.com
terraform apply \
  -var="vault_license_file_path=/path/to/your/vault.hclic" \
  -var="allowed_ip=<the new IP>/32"
```
This only updates the two security group rules -- nothing gets recreated.

---

## 5. Configure SQL Server (manual, by design)

Configuring SQL Server itself has to be done by hand, over Remote
Desktop. Pushing the config via `aws ssm send-command` was tried and
fails, because it runs under the machine's own identity, not a real SQL
admin session. Budget for this as a manual step.

### 5.1 Get the Windows admin password
```bash
terraform output mssql_password_cmd
```
This prints a ready-to-run command that looks like:
```bash
aws ec2 get-password-data --instance-id <your-instance-id> --priv-launch-key ~/.ssh/vault_tde_lab --query PasswordData --output text
```
Run that exact command. It can return empty for the first few minutes
after the instance launches -- Windows needs time to generate and
encrypt the password. Retry the same command if so.

### 5.2 Connect over Remote Desktop
```bash
terraform output mssql_public_ip
```
Connect to that address as `Administrator`, using the password from 5.1.

- **On a Mac, no built-in RDP client exists.** Search the App Store for
  **"Windows App"** (Microsoft renamed "Microsoft Remote Desktop" to
  this in 2024 -- same app).
- **If that's blocked by device management**, an alternative is
  `brew install freerdp`, then:
  ```bash
  aws ec2 get-password-data --instance-id <your-instance-id> --priv-launch-key ~/.ssh/vault_tde_lab --query PasswordData --output text | \
    xfreerdp /v:<mssql_public_ip> /u:Administrator /d:. /from-stdin /size:1600x900 /cert:ignore -gfx
  ```
  This needs XQuartz first (`brew install --cask xquartz`), and XQuartz
  requires a full logout/login before it works -- restarting Terminal is
  not enough.
- **On first login**, Windows asks "Do you want to allow your PC to be
  discoverable" -- click **No**. This is standard first-boot behavior,
  not an error.

### 5.3 Install the EKM provider
On the Windows box, open PowerShell as Administrator. Paste and run this
script, first replacing `VAULT_PRIVATE_IP` with the value from
`terraform output vault_private_ip`:

```powershell
$EKM_WORKING_DIR = "C:\Users\Administrator\Desktop\ekm"
$CERT_UPDATE_WORKING_DIR = "$Env:USERPROFILE\Downloads"
$VAULT_API_URL = "http://VAULT_PRIVATE_IP:8200"

$EKM_PROVIDER_SOURCE_URL = "https://releases.hashicorp.com/vault-mssql-ekm-provider/0.2.0+ent/vault-mssql-ekm-provider_0.2.0+ent_windows_amd64.zip"
$EKM_PROVIDER_ZIP_FILE = "$EKM_WORKING_DIR\vault-mssql-ekm-provider_0.2.0+ent_windows_amd64.zip"
$EKM_PROVIDER_MSI_FILE = "$EKM_WORKING_DIR\vault-mssql-ekm-provider.msi"
$EKM_PROVIDER_LOG_FILE = "$EKM_WORKING_DIR\vault-mssql-ekm-provider.log"

New-Item -ItemType Directory -Path $EKM_WORKING_DIR -Force | Out-Null
New-Item -ItemType Directory -Path $CERT_UPDATE_WORKING_DIR -Force | Out-Null

Cmd.exe /C "certutil -syncwithWU $CERT_UPDATE_WORKING_DIR"
Cmd.exe /C "extrac32 /L $CERT_UPDATE_WORKING_DIR $CERT_UPDATE_WORKING_DIR\authrootstl.cab authroot.stl"
Cmd.exe /C "certutil -f -v -ent -AddStore Root $CERT_UPDATE_WORKING_DIR\authroot.stl"

Invoke-WebRequest -URI $EKM_PROVIDER_SOURCE_URL -Outfile $EKM_PROVIDER_ZIP_FILE
Expand-Archive $EKM_PROVIDER_ZIP_FILE -DestinationPath $EKM_WORKING_DIR -Force

Start-Process -FilePath "msiexec" -ArgumentList "/i `"$EKM_PROVIDER_MSI_FILE`" VAULT_API_URL=$VAULT_API_URL VAULT_API_URL_IS_VALID=1 VAULT_INSTALL_FOLDER=`"C:\Program Files\HashiCorp\Transit Vault EKM Provider\`" /qb /l* `"$EKM_PROVIDER_LOG_FILE`"" -Wait

Write-Host "EKM provider installed."
```
The `certutil`/`extrac32` lines are not optional housekeeping -- without
them, `CREATE CRYPTOGRAPHIC PROVIDER` in the next step fails with a
"Cannot load library / Authenticode signature" error on a fresh Windows
image.

### 5.4 Restart SQL Server
Still in PowerShell:
```powershell
Restart-Service -Name 'MSSQL$MSSQLSERVER' -Force -ErrorAction SilentlyContinue
Restart-Service -Name 'MSSQLSERVER' -Force -ErrorAction SilentlyContinue
```
Confirm it actually came back up:
```powershell
Get-Service -Name 'MSSQL$MSSQLSERVER','MSSQLSERVER' -ErrorAction SilentlyContinue | Select-Object Name, Status
```

### 5.5 Run the SQL setup script
Open SQL Server Management Studio (SSMS). Connect with:
- Server name: `.`
- Authentication: Windows Authentication
- If you get a certificate error, check **Trust Server Certificate** in
  the connection dialog and retry -- this is SSMS being strict about
  SQL Server's self-signed certificate, not a real problem for a lab.

Find your exact login name first:
```sql
SELECT SUSER_NAME();
```

Open a new query window and paste in `scripts/01-Configure_DB.sql`.
Before running it, make these substitutions (the file has clear markers
for each):
- `PASTE_YOUR_ROLE_ID_HERE` -> contents of `approle-role-id.txt` (**two
  places** in the file -- see "Known gotchas" below)
- `PASTE_YOUR_SECRET_ID_HERE` -> contents of `approle-secret-id.txt`
  (**two places**)
- `PASTE_YOUR_WINDOWS_LOGIN_HERE` -> the exact output of
  `SELECT SUSER_NAME();` above (**two places**)

Run the whole script (F5). It ends with a verification query and a live
offline/online test -- confirm both succeed before moving on.

---

## 6. Running the tests

Once `01-Configure_DB.sql` completes cleanly, everything in
`scripts/tests/` is ready to run, in any order.

### 6.1 Data exposure (Act 1)
In SSMS, run `scripts/tests/act1-setup-exposure-demo.sql` in full.

Then in PowerShell:
```powershell
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
```
Expect red "MATCH FOUND" for the unprotected backup, green "No match
found" for the encrypted one.

### 6.2 Vault outage and recovery (Act 2)
On the Vault host, over SSH:
```bash
ssh -i ~/.ssh/vault_tde_lab ubuntu@<vault_public_ip>
sudo systemctl stop vault
```

In SSMS:
```sql
ALTER DATABASE TestTDE SET OFFLINE;
GO
ALTER DATABASE TestTDE SET ONLINE;
GO
```
Expect this to fail -- that's the proof the key isn't cached anywhere
useful outside Vault.

Back on the Vault host:
```bash
sudo systemctl start vault
export VAULT_ADDR=http://127.0.0.1:8200
vault operator unseal $(jq -r '.unseal_keys_b64[0]' /home/ubuntu/vault-init.json)
vault status
```
Wait for `HA Mode: active` in the output -- a restarted single-node
Vault comes back sealed, and even after unsealing, leader election takes
a moment. Both are required before the database can recover.

Back in SSMS:
```sql
ALTER DATABASE TestTDE SET ONLINE;
GO
```
This succeeds now, with no SQL Server-side restart needed.

### 6.3 Vault-side key rotation (Act 3)
On the Vault host:
```bash
vault write -f transit/keys/ekm-encryption-key/rotate
vault read transit/keys/ekm-encryption-key
```
Without touching SQL Server at all, in SSMS:
```sql
SELECT TOP 5 * FROM TestTDE.dbo.Customers;
```
This should return data with no error -- rotating Vault's key doesn't
force an immediate re-wrap.

### 6.4 Database-side key rotation
In SSMS, `scripts/03-Rotate_DEK.sql` then `scripts/04-Re-encrypt_DB.sql`,
in that order. The second one includes a required `BACKUP LOG` statement
-- see "Known gotchas" for why.

### 6.5 Performance
**Startup latency** -- run `scripts/tests/perf1-startup-latency.sql` at
least 5 times and compare medians between the two databases.

**Insert throughput** -- `scripts/tests/perf2-insert-throughput.sql`,
once per combination of `{10000, 50000, 100000}` rows x
`{TestTDE, BankDemo_Unprotected}` (change line 1 and `@rows` each time --
six runs total). These are the row counts used in the published results
in `docs/solution-brief.docx` -- match them for directly comparable
numbers.

---

## 7. Known gotchas (all found the hard way)

These are real problems hit while building this lab, and the fixes are
already built into the Terraform and scripts in this repo.

- **`jq` fails to install** on a fresh Ubuntu 22.04 AMI with a
  `libonig5` dependency error. Fixed by enabling the `universe` apt
  repository before installing.
- **Vault's apt install can hit a "weak security information" error**
  if it races with cloud-init's own background updates on a freshly
  booted instance. Fixed by waiting for `cloud-init status --wait`
  before touching apt.
- **AWS metadata calls can silently return empty** on AMIs that enforce
  IMDSv2 -- a plain `curl` to the metadata endpoint needs a token first.
- **The SQL Server Enterprise AMI needs at least a 100GB root volume** --
  a smaller size fails at instance creation with a snapshot-size error.
- **The SQL Server Enterprise AMI rejects burstable instance types**
  (like `t3.large`) with an explicit `UnsupportedOperation` error. This
  repo uses `m5.xlarge`.
- **AWS Windows password decryption requires an RSA key pair.** An
  ed25519 key lets you SSH into the Vault box fine, but silently cannot
  decrypt the Windows admin password.
- **The most common real mistake:** `01-Configure_DB.sql` has two
  separate `CREATE CREDENTIAL` blocks. `CREATE CREDENTIAL` does not
  validate against Vault at creation time -- it will happily accept
  literal placeholder text with no error. The mistake stays completely
  silent until the next time the database goes offline and back online,
  which could be days or weeks later. This is why the script ends with a
  verification query and a live offline/online test -- run them.
- **A restarted single-node Vault comes back sealed**, and even after
  unsealing, leader election takes a moment. Both steps are required.
- **Rotating the database's own encryption key starts a background
  scan** that is not instant, even on a tiny test database. Re-wrapping
  the key immediately afterward can fail with error 33122 ("pending log
  backup") in FULL recovery model -- a log backup is required between
  the two operations.
- **`RowCount` is a reserved word in SQL Server** (tied to
  `SET ROWCOUNT`) and throws a syntax error if used as a bare column
  alias -- the performance scripts use `RowsInserted` instead.
- **A "typo" is easy to make and hard to notice** in the performance
  scripts: `@rows = 500000` instead of the intended `50000` still runs
  successfully, it just measures the wrong thing. Double check the
  `RowsInserted` value in the result before recording a number.

---

## 8. Security notes

This is a lab, not a reference architecture. A few deliberate
simplifications you should NOT copy into anything customer-facing:

- Vault's listener has TLS disabled. Access is instead restricted at the
  AWS security-group layer, but that's a lab-speed shortcut, not a
  substitute for real TLS.
- A single unseal key share (threshold 1) means one person, one key, can
  unseal Vault. Production Vault should use a proper unseal key quorum
  (or auto-unseal via a cloud KMS).
- Both servers sit in a public subnet with public IPs, rather than a
  properly segmented private-subnet design. This was a deliberate
  trade-off to avoid needing a NAT gateway for a short-lived lab.

---

## 9. Cleanup

```bash
terraform destroy \
  -var="vault_license_file_path=/path/to/your/vault.hclic" \
  -var="allowed_ip=$(curl -s https://checkip.amazonaws.com)/32"
```
Both variables have to match what you used for `apply`, or Terraform
will plan an unexpected change instead of a clean destroy.

If a `terraform apply` ever fails partway through and you're not sure
what's already been created in AWS, check before you retry:
```bash
aws ec2 describe-instances --filters "Name=tag:Name,Values=vault-tde-lab-*" \
  --query "Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key=='Name'].Value|[0]]" --output table
```
Retrying `apply` from a stale or split Terraform state (for example,
after switching working directories) will try to recreate things that
already exist in AWS and fail with a "duplicate" error. If that happens,
terminate the orphaned instance(s) and delete the orphaned security
group(s) in AWS directly, then re-run `apply` from a single, consistent
directory going forward:
```bash
aws ec2 terminate-instances --instance-ids <instance-id>
aws ec2 wait instance-terminated --instance-ids <instance-id>
aws ec2 delete-security-group --group-id <security-group-id>
```
