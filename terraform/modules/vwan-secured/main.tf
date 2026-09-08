resource "azurerm_virtual_wan" "this" {
  name                = "vwan-${var.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.primary_region
  type                = "Standard" # Basic cannot do hub-to-hub transit.
  tags                = var.tags
}

resource "azurerm_virtual_hub" "primary" {
  name                = "vhub-${var.prefix}-primary"
  resource_group_name = var.resource_group_name
  location            = var.primary_region
  virtual_wan_id      = azurerm_virtual_wan.this.id
  address_prefix      = var.hub_prefix_primary
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_virtual_hub" "secondary" {
  name                = "vhub-${var.prefix}-secondary"
  resource_group_name = var.resource_group_name
  location            = var.secondary_region
  virtual_wan_id      = azurerm_virtual_wan.this.id
  address_prefix      = var.hub_prefix_secondary
  sku                 = "Standard"
  tags                = var.tags
}

# Shared policy across both hubs. Standard tier: Premium only buys TLS inspection,
# which must NOT be enabled - a self-signed cert breaks agent provisioning.
resource "azurerm_firewall_policy" "this" {
  name                = "afwp-${var.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.primary_region
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_firewall" "primary" {
  name                = "afw-${var.prefix}-primary"
  resource_group_name = var.resource_group_name
  location            = var.primary_region
  sku_name            = "AZFW_Hub"
  sku_tier            = "Standard"
  firewall_policy_id  = azurerm_firewall_policy.this.id
  tags                = var.tags

  virtual_hub {
    virtual_hub_id  = azurerm_virtual_hub.primary.id
    public_ip_count = 1
  }
}

resource "azurerm_firewall" "secondary" {
  name                = "afw-${var.prefix}-secondary"
  resource_group_name = var.resource_group_name
  location            = var.secondary_region
  sku_name            = "AZFW_Hub"
  sku_tier            = "Standard"
  firewall_policy_id  = azurerm_firewall_policy.this.id
  tags                = var.tags

  virtual_hub {
    virtual_hub_id  = azurerm_virtual_hub.secondary.id
    public_ip_count = 1
  }
}

# Routing intent sends both private and internet traffic through the hub firewall.
# This is what programs 0.0.0.0/0 onto every connected spoke - and what makes the
# AzureBastionSubnet route-table override in the spoke module mandatory.
resource "azurerm_virtual_hub_routing_intent" "primary" {
  name           = "ri-${var.prefix}-primary"
  virtual_hub_id = azurerm_virtual_hub.primary.id

  routing_policy {
    name         = "InternetTraffic"
    destinations = ["Internet"]
    next_hop     = azurerm_firewall.primary.id
  }

  routing_policy {
    name         = "PrivateTraffic"
    destinations = ["PrivateTraffic"]
    next_hop     = azurerm_firewall.primary.id
  }
}

resource "azurerm_virtual_hub_routing_intent" "secondary" {
  name           = "ri-${var.prefix}-secondary"
  virtual_hub_id = azurerm_virtual_hub.secondary.id

  routing_policy {
    name         = "InternetTraffic"
    destinations = ["Internet"]
    next_hop     = azurerm_firewall.secondary.id
  }

  routing_policy {
    name         = "PrivateTraffic"
    destinations = ["PrivateTraffic"]
    next_hop     = azurerm_firewall.secondary.id
  }
}

resource "azurerm_firewall_policy_rule_collection_group" "egress" {
  name               = "rcg-${var.prefix}-egress"
  firewall_policy_id = azurerm_firewall_policy.this.id
  priority           = 200

  # Container Apps platform egress. The agent subnet is delegated to
  # Microsoft.App/environments, so it inherits these requirements.
  application_rule_collection {
    name     = "aca-platform"
    priority = 200
    action   = "Allow"

    rule {
      name             = "aca-required-fqdns"
      source_addresses = var.spoke_address_spaces
      destination_fqdns = [
        "mcr.microsoft.com",
        "*.data.mcr.microsoft.com",
        "*.blob.core.windows.net",
        "login.microsoft.com",
        "*.login.microsoft.com",
        "login.microsoftonline.com",
        "*.login.microsoftonline.com",
        "*.identity.azure.net",
        "*.azurecr.io",
        "packages.microsoft.com",
        "acs-mirror.azureedge.net",
        "management.azure.com",
      ]
      protocols {
        type = "Https"
        port = 443
      }
      protocols {
        type = "Http"
        port = 80
      }
    }
  }

  # Workload egress. The SharePoint fetch is a public-internet call - this is the
  # only place the lab reaches outside Azure for data.
  application_rule_collection {
    name     = "workload"
    priority = 300
    action   = "Allow"

    rule {
      name             = "graph-and-sharepoint"
      source_addresses = var.spoke_address_spaces
      destination_fqdns = [
        "graph.microsoft.com",
        "*.sharepoint.com",
        "*.sharepointonline.com",
      ]
      protocols {
        type = "Https"
        port = 443
      }
    }

    # Oryx remote build resolves the Python SDK from its CDN and installs
    # requirements.txt from PyPI. Without these the build fails inside Oryx with a
    # null XML node, because the version lookup returns an empty response.
    rule {
      name             = "function-remote-build"
      source_addresses = var.spoke_address_spaces
      destination_fqdns = [
        "oryx-cdn.microsoft.io",
        "pypi.org",
        "files.pythonhosted.org",
        "pypi.python.org",
      ]
      protocols {
        type = "Https"
        port = 443
      }
    }
  }

  # Jumpbox needs to actually reach the Foundry portal, or the whole private
  # setup is unusable by a human.
  application_rule_collection {
    name     = "jumpbox"
    priority = 400
    action   = "Allow"

    rule {
      name             = "portal-and-foundry"
      source_addresses = var.jumpbox_subnet_prefixes
      destination_fqdns = [
        "ai.azure.com",
        "*.ai.azure.com",
        "portal.azure.com",
        "*.portal.azure.com",
        "*.portal.azure.net",
        "*.msauth.net",
        "*.msftauth.net",
        "aadcdn.msftauth.net",
        "*.azure.com",
        "*.windows.net",
        "*.windowsupdate.com",
        "*.microsoft.com",
      ]
      protocols {
        type = "Https"
        port = 443
      }
      protocols {
        type = "Http"
        port = 80
      }
    }
  }

  network_rule_collection {
    name     = "private-to-private"
    priority = 100
    action   = "Allow"

    # Azure Firewall evaluates network rules BEFORE application rules. Without this,
    # cross-spoke traffic to private endpoints falls through to an application rule
    # (e.g. *.azure.com), which proxies the request and re-originates it from the
    # firewall's PUBLIC IP - so the PaaS service sees a public caller and returns
    # "Public access is disabled. Please configure private endpoint."
    rule {
      name                  = "spoke-to-spoke-private"
      source_addresses      = var.spoke_address_spaces
      destination_addresses = var.spoke_address_spaces
      destination_ports     = ["443", "80", "53", "1024-65535"]
      protocols             = ["TCP", "UDP"]
    }
  }

  network_rule_collection {
    name     = "azure-platform"
    priority = 500
    action   = "Allow"

    rule {
      name                  = "entra-and-arm"
      source_addresses      = var.spoke_address_spaces
      destination_addresses = ["AzureActiveDirectory", "AzureResourceManager", "AzureMonitor"]
      destination_ports     = ["443"]
      protocols             = ["TCP"]
    }
  }
}
