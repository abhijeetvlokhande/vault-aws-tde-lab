#!/bin/bash
set -euxo pipefail

sudo cloud-init status --wait || true

sudo apt-get update -y
sudo apt-get install -y --no-install-recommends software-properties-common
sudo add-apt-repository -y universe
sudo apt-get update -y
sudo apt-get install -y wget gpg lsb-release jq curl unzip

# Official HashiCorp apt repo — serves both CE and Enterprise packages.
# Preferred over a hand-pinned curl+zip download: no version number to keep
# current, and it wires up the systemd unit + vault user/group for you.
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt-get update -y
sudo apt-get install -y vault-enterprise

sudo mkdir -p /opt/vault/raft/data
sudo chown -R vault:vault /opt/vault

IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
HOST_IP=$(curl -s -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" http://169.254.169.254/latest/meta-data/local-ipv4)

# NOTE: TLS is intentionally disabled here for lab speed, same simplification
# the reference demo repo made. Access is instead restricted at the AWS
# security-group layer (Vault's 8200 only accepts traffic from the SQL
# Server's SG + your own IP — never 0.0.0.0/0). Don't carry tls_disable
# into anything you'd call a customer POC.
cat << EOF | sudo tee /etc/vault.d/vault.hcl
ui = true
disable_mlock = true

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"
}

storage "raft" {
  path    = "/opt/vault/raft/data"
  node_id = "raft_node_1"
}

api_addr     = "http://${HOST_IP}:8200"
cluster_addr = "https://${HOST_IP}:8201"

license_path = "/etc/vault.d/vault.hclic"
EOF

sudo chown vault:vault /etc/vault.d/vault.hcl
sudo chmod 640 /etc/vault.d/vault.hcl

sudo systemctl enable vault
