# SQL Server TDE with HashiCorp Vault -- a hands-on lab

This lab builds a small, real environment on AWS so you can see, test, and
break SQL Server's Transparent Data Encryption (TDE) when the encryption
key is managed by HashiCorp Vault, instead of trusting the documentation.

It uses HashiCorp's own native EKM (Extensible Key Management) provider for
SQL Server, backed by Vault's Transit secrets engine. It does not use
KMIP, and it does not use any third-party connector.

Everything in this repo was actually run, and every fix in it came from a
real failure along the way. Nothing here is theoretical.

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
- No answer on how HashiCorp SQL Server TDE with Vault performs against
  another vendor's TDE + KMS backend -- Vault is not the only company that offers a Vault + SQL Server EKM implementation

---

## 1. Prerequisites

You need all of these before you start. Missing any one of them will
cause a failure partway through, not a clean error up front.

| What | Why |
|---|---|
| A **Vault Enterprise license** with the **ADP-KM (Advanced Data Protection -- Key Management)** module | Without this, `CREATE ASYMMETRIC KEY ... FROM PROVIDER` fails with error 2050 ("license missing the feature"), and nothing else in this lab works. There is no way around this requirement -- it applies whether you self-host Vault or use HCP Vault Dedicated. |
| An **AWS account** with permission to create EC2 instances, security groups, and key pairs | Read-only permissions are not enough -- you need to actually create infrastructure. |
| **Terraform** installed locally | `terraform -version` to check. |
| **AWS CLI** installed and configured with working credentials | `aws sts get-caller-identity` to check. |
| An **RSA key pair**, not ed25519 | AWS's `get-password-data` (used to decrypt the Windows admin password) only supports RSA. If you generate a different key type, you will not be able to log into the Windows server. |
| A **VPC with at least one public subnet** in your target AWS region | This repo does not create a VPC -- point it at an existing one via variables. |

Generate the RSA key pair and import it to AWS:
```bash
ssh-keygen -t rsa -b 2048 -f ~/.ssh/vault_tde_lab -N ""
aws ec2 import-key-pair --key-name vault-tde-lab --public-key-material fileb://~/.ssh/vault_tde_lab.pub
```

### SQL Server edition matters

TDE's EKM feature only works on SQL Server **Enterprise** or **Developer**
edition. Standard, Web, and Express do not support it at all -- this is a
Microsoft licensing limitation, not a Vault limitation.

AWS's public Windows+SQL Server AMIs come in Standard, Web, Express, and
Enterprise -- there is no public "Developer" edition AMI. This repo
defaults to the **Enterprise** AMI, which bills SQL Server licensing
hourly as part of the EC2 price. If you want the free Developer edition
instead, you'll need to install it yourself onto a bare Windows Server
AMI -- this repo doesn't automate that path.

---

## 2. Repo layout

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
```

---

## 3. Deploy

```bash
terraform init
terraform apply \
  -var="vault_license_file_path=/path/to/your/vault.hclic" \
  -var="allowed_ip=$(curl -s https://checkip.amazonaws.com)/32"
```

This creates both servers, installs and unseals Vault, and fully
configures AppRole and the Transit secrets engine automatically. When it
finishes, two files appear in this directory:
`approle-role-id.txt` and `approle-secret-id.txt`. You'll need both for
the next step.

If your IP address changes partway through this lab (common on
hotel/mobile networks), commands that were working will suddenly time out
with no useful error. Re-run `curl -s https://checkip.amazonaws.com` and
re-apply with the new value -- it only updates the two security group
rules, nothing gets recreated.

---

## 4. The one part that can't be automated

Configuring SQL Server itself has to be done by hand, over Remote Desktop.
This was tried both ways -- pushing the config via `aws ssm send-command`
fails because it runs under the machine's own identity, not a real SQL
admin session. Budget for this as a manual step, not something to script
around.

1. **Get the Windows admin password:**
   ```bash
   terraform output mssql_password_cmd
   # then run the command it prints
   ```
   This can return empty for the first few minutes after the instance
   launches -- Windows needs time to generate and encrypt the password.
   Just retry.

2. **Connect over RDP** to `terraform output mssql_public_ip`, as
   `Administrator`, with that password.
   - On a Mac without a Microsoft Remote Desktop client, search the App
     Store for **"Windows App"** (Microsoft renamed the client).
   - If that's blocked, `brew install freerdp` is an alternative, but it
     needs XQuartz (`brew install --cask xquartz`, then log out and back
     in -- it does not work without a fresh login session).

3. **Install the EKM provider.** Copy `scripts/DeployEKMProvider.PS1` onto
   the box, replace the `$VAULT_API_URL` placeholder with
   `http://<terraform output vault_private_ip>:8200`, and run it as
   Administrator in PowerShell. This also fixes a common
   "Cannot load library / Authenticode signature" error by syncing
   Windows' root certificate store -- expect that step even on a brand
   new image.

4. **Restart SQL Server**, then open `scripts/01-Configure_DB.sql` in
   SSMS. Follow the instructions in the file itself carefully -- there
   are two separate credential blocks that both need your real
   role-id/secret-id, and missing the second one is the single most
   common mistake made while building this lab (see "Known gotchas"
   below). The script ends with a verification query and a live
   offline/online test specifically so you catch that mistake
   immediately, not days later.

---

## 5. Running the tests

Once `01-Configure_DB.sql` completes cleanly, everything in
`scripts/tests/` is ready to run, in any order:

- **Data exposure (Act 1):** `act1-setup-exposure-demo.sql` then
  `act1-search-backups.ps1` -- shows a real backup file search finding
  plaintext customer data in an unencrypted database, and nothing in the
  Vault-encrypted one.
- **Vault outage and recovery (Act 2):** follow
  `act2-ha-failover-procedure.md` step by step.
- **Vault-side key rotation (Act 3):** follow
  `act3-vault-side-kek-rotation.md`.
- **Database-side key rotation:** `03-Rotate_DEK.sql` then
  `04-Re-encrypt_DB.sql`.
- **Performance:** `perf1-startup-latency.sql` (run 5+ times and compare
  medians) and `perf2-insert-throughput.sql` (run once per row-count you
  want to test, against both databases).

---

## 6. Known gotchas (all found the hard way)

These are real problems hit while building this lab, and the fixes are
already built into the Terraform and scripts in this repo. Listed here so
you understand what's already been handled, and what to watch for if you
change anything.

- **`jq` fails to install** on a fresh Ubuntu 22.04 AMI with a
  `libonig5` dependency error. Fixed by enabling the `universe` apt
  repository before installing.
- **Vault's apt install can hit a "weak security information" error**
  if it races with cloud-init's own background updates on a freshly
  booted instance. Fixed by waiting for `cloud-init status --wait`
  before touching apt.
- **AWS metadata calls can silently return empty** on AMIs that enforce
  IMDSv2 -- a plain `curl` to the metadata endpoint needs a token first.
  Fixed in the Vault deploy script.
- **The SQL Server Enterprise AMI needs at least a 100GB root volume** --
  a smaller size fails at instance creation with a snapshot-size error.
- **The SQL Server Enterprise AMI rejects burstable instance types**
  (like `t3.large`) with an explicit `UnsupportedOperation` error. This
  repo uses `m5.xlarge`.
- **AWS Windows password decryption requires an RSA key pair.** An
  ed25519 key will let you SSH into the Vault box fine, but silently
  cannot decrypt the Windows admin password.
- **The most common real mistake:** `01-Configure_DB.sql` has two
  separate `CREATE CREDENTIAL` blocks. `CREATE CREDENTIAL` does not
  validate against Vault at creation time -- it will happily accept
  literal placeholder text with no error. The mistake stays completely
  silent until the next time the database goes offline and back online,
  which could be days or weeks later (a routine restart, a failover, a
  patch). This is why `01-Configure_DB.sql` ends with a verification
  query and a live offline/online test -- run them.
- **A restarted single-node Vault comes back sealed**, and even after
  unsealing, leader election takes a moment. Both steps are required for
  the database to recover -- see `act2-ha-failover-procedure.md`.
- **Rotating the database's own encryption key (`03-Rotate_DEK.sql`)
  starts a background scan** that is not instant, even on a tiny test
  database. Re-wrapping the key immediately afterward
  (`04-Re-encrypt_DB.sql`) can fail with error 33122 ("pending log
  backup") in FULL recovery model -- a log backup is required between
  the two operations, and `04-Re-encrypt_DB.sql` includes it.
- **`RowCount` is a reserved word in SQL Server** (tied to
  `SET ROWCOUNT`) and throws a syntax error if used as a bare column
  alias -- the performance scripts use `RowsInserted` instead.

---

## 7. Security notes

This is a lab, not a reference architecture. A few deliberate
simplifications you should NOT copy into anything customer-facing:

- Vault's listener has TLS disabled. Access is instead restricted at the
  AWS security-group layer (Vault's port only accepts traffic from the
  SQL Server's security group and your own IP -- never the open
  internet), but that's a lab-speed shortcut, not a substitute for real
  TLS.
- A single unseal key share (threshold 1) means one person, one key, can
  unseal Vault. Production Vault should use a proper unseal key quorum
  (or auto-unseal via a cloud KMS).
- Both servers sit in a public subnet with public IPs, rather than a
  properly segmented private-subnet design. This was a deliberate
  trade-off to avoid needing a NAT gateway for a short-lived lab.

---

## 8. Cleanup

```bash
terraform destroy \
  -var="vault_license_file_path=/path/to/your/vault.hclic" \
  -var="allowed_ip=$(curl -s https://checkip.amazonaws.com)/32"
```

Both variables have to match what you used for `apply`, or Terraform will
plan an unexpected change instead of a clean destroy.

If a `terraform apply` ever fails partway through and you're not sure
what's already been created in AWS, check before you retry:
```bash
aws ec2 describe-instances --filters "Name=tag:Name,Values=vault-tde-lab-*" \
  --query "Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key=='Name'].Value|[0]]" --output table
```
Retrying `apply` from a stale or split Terraform state (for example,
after switching working directories) will try to recreate things that
already exist in AWS and fail with a "duplicate" error. If that happens,
it's usually faster to manually terminate the orphaned instance(s) and
delete the orphaned security group(s) in AWS directly, then re-run
`apply` from a single, consistent directory going forward.
