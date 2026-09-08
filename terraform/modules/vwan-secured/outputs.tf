output "virtual_wan_id" {
  value = azurerm_virtual_wan.this.id
}

output "hub_primary_id" {
  value = azurerm_virtual_hub.primary.id
}

output "hub_secondary_id" {
  value = azurerm_virtual_hub.secondary.id
}

output "firewall_policy_id" {
  value = azurerm_firewall_policy.this.id
}

output "firewall_primary_private_ip" {
  value = try(azurerm_firewall.primary.virtual_hub[0].private_ip_address, null)
}

output "firewall_secondary_private_ip" {
  value = try(azurerm_firewall.secondary.virtual_hub[0].private_ip_address, null)
}
