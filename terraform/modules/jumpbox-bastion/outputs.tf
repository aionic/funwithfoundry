output "bastion_name" {
  value = azurerm_bastion_host.this.name
}

output "jumpbox_id" {
  value = azurerm_windows_virtual_machine.jumpbox.id
}

output "jumpbox_name" {
  value = azurerm_windows_virtual_machine.jumpbox.name
}

output "jumpbox_principal_id" {
  value = azurerm_windows_virtual_machine.jumpbox.identity[0].principal_id
}

output "admin_username" {
  value = var.admin_username
}

output "admin_password" {
  value     = random_password.jumpbox.result
  sensitive = true
}
