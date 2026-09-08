resource "azurerm_private_dns_zone" "this" {
  for_each = toset(var.zones)

  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# Private DNS zones are global. Linking every zone to BOTH spokes is what lets a
# resource in one region resolve a private endpoint in the other, and removes any
# need for an Azure DNS Private Resolver.
resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = {
    for pair in setproduct(var.zones, keys(var.linked_vnet_ids)) :
    "${pair[1]}|${pair[0]}" => {
      zone     = pair[0]
      vnet_key = pair[1]
    }
  }

  name                  = "link-${each.value.vnet_key}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.value.zone].name
  virtual_network_id    = var.linked_vnet_ids[each.value.vnet_key]
  registration_enabled  = false
  tags                  = var.tags
}
