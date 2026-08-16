resource "aws_instance" "mssql" {
  ami                         = var.ami_id
  instance_type               = "m5.xlarge"
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [var.security_group_id]
  key_name                    = var.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 100
  }

  tags = { Name = "${var.prefix}-mssql" }
}
