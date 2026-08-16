output "public_ip" {
  value = aws_instance.vault.public_ip
}

output "private_ip" {
  value = aws_instance.vault.private_ip
}
