output "public_ip" {
  value = aws_instance.mssql.public_ip
}

output "instance_id" {
  value = aws_instance.mssql.id
}
