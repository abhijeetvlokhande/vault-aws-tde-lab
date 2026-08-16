resource "aws_instance" "vault" {
  ami                         = var.ami_id
  instance_type               = "t3.small"
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [var.security_group_id]
  key_name                    = var.key_name
  associate_public_ip_address = true

  tags = { Name = "${var.prefix}-vault" }
}

resource "null_resource" "provision_vault" {
  depends_on = [aws_instance.vault]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file(pathexpand("~/.ssh/vault_tde_lab"))
    host        = aws_instance.vault.public_ip
    timeout     = "5m"
  }

  provisioner "file" {
    source      = "${path.module}/templates/deploy-vault-instance.sh"
    destination = "/tmp/deploy-vault-instance.sh"
  }

  provisioner "file" {
    source      = "${path.module}/templates/initialize-vault-instance.sh"
    destination = "/tmp/initialize-vault-instance.sh"
  }

  provisioner "file" {
    source      = var.license_file_path
    destination = "/tmp/vault.hclic"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/deploy-vault-instance.sh /tmp/initialize-vault-instance.sh",
      "sudo bash /tmp/deploy-vault-instance.sh",
      "sudo mv /tmp/vault.hclic /etc/vault.d/vault.hclic",
      "sudo chown vault:vault /etc/vault.d/vault.hclic",
      "bash /tmp/initialize-vault-instance.sh",
    ]
  }
}

# Pulls the generated AppRole role-id/secret-id back to your machine so you
# can paste them into the SQL Server CREATE CREDENTIAL statements.
resource "null_resource" "fetch_approle_creds" {
  depends_on = [null_resource.provision_vault]

  provisioner "local-exec" {
    command = <<-EOT
      scp -o StrictHostKeyChecking=no -i ${pathexpand("~/.ssh/vault_tde_lab")} ubuntu@${aws_instance.vault.public_ip}:/home/ubuntu/approle-role-id.txt ${path.root}/approle-role-id.txt
      scp -o StrictHostKeyChecking=no -i ${pathexpand("~/.ssh/vault_tde_lab")} ubuntu@${aws_instance.vault.public_ip}:/home/ubuntu/approle-secret-id.txt ${path.root}/approle-secret-id.txt
    EOT
  }
}
