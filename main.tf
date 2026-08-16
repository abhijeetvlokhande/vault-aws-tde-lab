terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# --- Security groups ---
# Deliberately NOT 0.0.0.0/0 anywhere, unlike the Azure demo repo this was
# adapted from (which exposed Vault's API to the entire internet).

resource "aws_security_group" "vault" {
  name        = "${var.prefix}-vault-sg"
  description = "Vault server - lab"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH from admin IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ip]
  }

  # Vault API from your own IP too, for setup/debugging convenience
  ingress {
    description = "Vault API from admin IP"
    from_port   = 8200
    to_port     = 8200
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ip]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-vault-sg" }
}

resource "aws_security_group" "mssql" {
  name        = "${var.prefix}-mssql-sg"
  description = "SQL Server - lab"
  vpc_id      = var.vpc_id

  ingress {
    description = "RDP from admin IP"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ip]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-mssql-sg" }
}

# Vault's 8200 is only reachable from the SQL Server's security group —
# not from the internet, not even from other things in this VPC.
resource "aws_security_group_rule" "vault_api_from_mssql" {
  type                     = "ingress"
  from_port                = 8200
  to_port                  = 8200
  protocol                 = "tcp"
  security_group_id        = aws_security_group.vault.id
  source_security_group_id = aws_security_group.mssql.id
  description               = "Vault API from SQL Server only"
}

module "vault_server" {
  source             = "./vault-server"
  prefix             = var.prefix
  subnet_id          = var.public_subnet_id
  security_group_id  = aws_security_group.vault.id
  key_name           = var.key_name
  ami_id             = var.vault_ami_id
  license_file_path  = var.vault_license_file_path
}

module "mssql_server" {
  source             = "./mssql-server"
  prefix             = var.prefix
  subnet_id          = var.public_subnet_id
  security_group_id  = aws_security_group.mssql.id
  key_name           = var.key_name
  ami_id             = var.sql_ami_id
}

output "vault_public_ip" {
  value = module.vault_server.public_ip
}

output "vault_private_ip" {
  description = "Use THIS for VAULT_API_URL on the SQL Server side — stays inside the VPC, no internet round trip"
  value       = module.vault_server.private_ip
}

output "mssql_public_ip" {
  value = module.mssql_server.public_ip
}

output "mssql_password_cmd" {
  description = "Run this to decrypt the Windows admin password (needs the RSA private key)"
  value       = "aws ec2 get-password-data --instance-id ${module.mssql_server.instance_id} --priv-launch-key ~/.ssh/vault_tde_lab --query PasswordData --output text"
}
