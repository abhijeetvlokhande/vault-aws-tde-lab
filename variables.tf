variable "aws_region" {
  default = "ap-south-1"
}

variable "prefix" {
  default = "vault-tde-lab"
}

# Existing "vault-vpc" already present in this account
variable "vpc_id" {
  default = "vpc-035af168973f7932c"
}

# public1-ap-south-1a — both instances go here; access is controlled by
# security groups, not network segmentation (see README for the tradeoff)
variable "public_subnet_id" {
  default = "subnet-0f1a308136f919da0"
}

variable "key_name" {
  default = "vault-tde-lab"
}

# Your current public IP, /32. Re-check with:  curl -s https://checkip.amazonaws.com
variable "allowed_ip" {
  default = "58.84.62.204/32"
}

# REQUIRED — no default. Path to your Vault Enterprise ADP-KM license file.
variable "vault_license_file_path" {
  type = string
}

# Ubuntu 22.04, ap-south-1, resolved 2026-08-15 — re-check periodically, AMI IDs roll
variable "vault_ami_id" {
  default = "ami-0aa761682283b4cc8"
}

# Windows_Server-2019-English-Full-SQL_2019_Enterprise-2026.08.12
# AWS does not publish a "Developer" edition AMI — only Enterprise supports EKM
# among the published editions (Standard/Web/Express do not). See README if you'd
# rather self-install the free Developer edition on a bare Windows AMI instead.
variable "sql_ami_id" {
  default = "ami-0ebe02ac580afd0ee"
}
