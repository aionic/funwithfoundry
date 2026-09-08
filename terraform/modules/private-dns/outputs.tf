output "zone_ids" {
  description = "Zone name => resource ID."
  value       = { for k, v in azurerm_private_dns_zone.this : k => v.id }
}
