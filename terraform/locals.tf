locals {
  # Short region tokens used in resource names.
  region_short = {
    (var.primary_region)   = "cus"
    (var.secondary_region) = "scus"
  }

  name = {
    primary   = "${var.prefix}-${local.region_short[var.primary_region]}"
    secondary = "${var.prefix}-${local.region_short[var.secondary_region]}"
  }

  # Virtual WAN hubs. /23 is the practical minimum for a secured hub.
  hub_prefix = {
    primary   = "10.100.0.0/23"
    secondary = "10.101.0.0/23"
  }

  # Spoke address space. The agent subnet sits in a Class B range: Learn says Class A
  # is fine in Central US, but the official BYO-VNet sample lists a region subset that
  # excludes it. Class B satisfies both readings, and the mismatch would otherwise only
  # surface at capability host creation - long after the network is built.
  spoke_primary_space   = ["10.10.0.0/16", "172.16.0.0/16"]
  spoke_secondary_space = ["10.20.0.0/16"]

  # Central US spoke: agent runtime, private endpoints, jumpbox, Bastion.
  spoke_primary_subnets = {
    "snet-agent" = {
      prefixes   = ["172.16.0.0/24"]
      delegation = "Microsoft.App/environments"
    }
    "snet-pe" = {
      prefixes   = ["10.10.1.0/24"]
      delegation = null
    }
    "snet-jumpbox" = {
      prefixes   = ["10.10.2.0/24"]
      delegation = null
    }
    "AzureBastionSubnet" = {
      prefixes   = ["10.10.3.0/26"]
      delegation = null
    }
  }

  # South Central US spoke: private endpoints and the Flex Consumption function.
  spoke_secondary_subnets = {
    "snet-pe" = {
      prefixes   = ["10.20.1.0/24"]
      delegation = null
    }
    "snet-func" = {
      prefixes   = ["10.20.2.0/24"]
      delegation = "Microsoft.App/environments"
    }
  }

  # Private DNS zones are global resources and are linked to BOTH spokes, which
  # removes any need for a DNS Private Resolver for cross-region PE resolution.
  private_dns_zones = [
    "privatelink.cognitiveservices.azure.com",
    "privatelink.openai.azure.com",
    "privatelink.services.ai.azure.com",
    "privatelink.search.windows.net",
    "privatelink.documents.azure.com",
    "privatelink.blob.core.windows.net",
    "privatelink.file.core.windows.net",
    "privatelink.queue.core.windows.net",
    "privatelink.table.core.windows.net",
    "privatelink.vaultcore.azure.net",
    "privatelink.azurewebsites.net",
  ]

  operator_object_id = var.my_object_id != "" ? var.my_object_id : data.azurerm_client_config.current.object_id

  tags = var.tags
}
