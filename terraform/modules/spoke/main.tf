resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = var.address_space
  tags                = var.tags
}

resource "azurerm_subnet" "this" {
  for_each = var.subnets

  name                 = each.key
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = each.value.prefixes

  # Private endpoint network policies must stay disabled on the PE subnet.
  private_endpoint_network_policies = each.key == "snet-pe" ? "Disabled" : "Enabled"

  dynamic "delegation" {
    for_each = each.value.delegation == null ? [] : [each.value.delegation]
    content {
      name = "delegation"
      service_delegation {
        name    = delegation.value
        actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
      }
    }
  }
}

resource "azurerm_virtual_hub_connection" "this" {
  name                      = "conn-${var.name}"
  virtual_hub_id            = var.virtual_hub_id
  remote_virtual_network_id = azurerm_virtual_network.this.id
  internet_security_enabled = true

  # Subnet creation must settle before the connection triggers route programming.
  depends_on = [azurerm_subnet.this]
}

# Azure rejects any route table on AzureBastionSubnet with
# "RouteTableCannotBeAttachedForAzureBastionSubnet", so the routing-intent default
# route cannot be overridden there. Bastion falls back to the platform's own system
# routes for its control plane. Whether that survives routing intent is proven by an
# actual RDP test in P5, not assumed. Fallback if it fails: a standalone Bastion VNet
# peered to this spoke and deliberately not connected to the hub.
