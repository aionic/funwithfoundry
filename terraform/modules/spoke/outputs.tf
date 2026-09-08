output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "vnet_name" {
  value = azurerm_virtual_network.this.name
}

output "subnet_ids" {
  description = "Subnet name => resource ID."
  value       = { for k, v in azurerm_subnet.this : k => v.id }
}
