#!/bin/bash
set -euxo pipefail

sudo systemctl start vault

export VAULT_ADDR="http://127.0.0.1:8200"

for i in $(seq 1 30); do
  if curl -s -o /dev/null "${VAULT_ADDR}/v1/sys/health?standbyok=true&sealedcode=200&uninitcode=200"; then
    break
  fi
  sleep 2
done

sudo systemctl status vault --no-pager

# Single key share/threshold — fine for a lab, never for anything real.
vault operator init \
  -format=json \
  -key-shares=1 \
  -key-threshold=1 \
  > /home/ubuntu/vault-init.json

VAULT_UNSEAL=$(jq -r '.unseal_keys_b64[0]' /home/ubuntu/vault-init.json)
VAULT_ROOT_TOKEN=$(jq -r '.root_token' /home/ubuntu/vault-init.json)

echo "export VAULT_ADDR=http://127.0.0.1:8200" >> /home/ubuntu/.bashrc
echo "export VAULT_TOKEN=${VAULT_ROOT_TOKEN}" >> /home/ubuntu/.bashrc

vault operator unseal "${VAULT_UNSEAL}"
sleep 5

export VAULT_TOKEN="${VAULT_ROOT_TOKEN}"

# --- Everything below matches HashiCorp's official Vault EKM provider docs ---
# https://developer.hashicorp.com/vault/docs/platform/mssql/installation

vault auth enable approle

vault write auth/approle/role/ekm-encryption-key-role \
  token_ttl=20m \
  max_token_ttl=30m \
  token_policies=tde-policy

vault secrets enable transit
vault write -f transit/keys/ekm-encryption-key type="rsa-2048"

vault policy write tde-policy - <<'EOF'
path "transit/keys/ekm-encryption-key" {
  capabilities = ["create", "read", "update", "delete"]
}
path "transit/keys" {
  capabilities = ["list"]
}
path "transit/encrypt/ekm-encryption-key" {
  capabilities = ["update"]
}
path "transit/decrypt/ekm-encryption-key" {
  capabilities = ["update"]
}
path "sys/license/status" {
  capabilities = ["read"]
}
EOF

vault write auth/approle/role/ekm-encryption-key-role token_policies=tde-policy

ROLE_ID=$(vault read -field=role_id auth/approle/role/ekm-encryption-key-role/role-id)
SECRET_ID=$(vault write -f -field=secret_id auth/approle/role/ekm-encryption-key-role/secret-id)

echo "${ROLE_ID}" > /home/ubuntu/approle-role-id.txt
echo "${SECRET_ID}" > /home/ubuntu/approle-secret-id.txt

echo "Vault ready. AppRole role-id/secret-id written to /home/ubuntu/approle-*.txt"
