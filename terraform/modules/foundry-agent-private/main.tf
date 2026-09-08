terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm" }
    azapi   = { source = "Azure/azapi" }
    random  = { source = "hashicorp/random" }
    time    = { source = "hashicorp/time" }
  }
}

resource "random_string" "unique" {
  length  = 5
  special = false
  upper   = false
  numeric = true
  lower   = true
}

locals {
  suffix = random_string.unique.result

  dns = {
    blob      = "privatelink.blob.core.windows.net"
    cosmos    = "privatelink.documents.azure.com"
    search    = "privatelink.search.windows.net"
    vault     = "privatelink.vaultcore.azure.net"
    cognitive = "privatelink.cognitiveservices.azure.com"
    openai    = "privatelink.openai.azure.com"
    aiservice = "privatelink.services.ai.azure.com"
  }
}

########################################
# BYO resources - all three are mandatory
########################################

resource "azurerm_storage_account" "this" {
  name                = "${var.prefix}${local.suffix}st"
  resource_group_name = var.resource_group_name
  location            = var.location

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "ZRS"

  shared_access_key_enabled       = false
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = false

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  tags = var.tags
}

resource "azurerm_cosmosdb_account" "this" {
  name                = "${var.prefix}${local.suffix}cosmos"
  resource_group_name = var.resource_group_name
  location            = var.location

  offer_type        = "Standard"
  kind              = "GlobalDocumentDB"
  free_tier_enabled = false

  local_authentication_enabled  = false
  public_network_access_enabled = false

  automatic_failover_enabled       = false
  multiple_write_locations_enabled = false

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.location
    failover_priority = 0
    zone_redundant    = false
  }

  # Five containers at 1000 RU/s each; 6000 leaves headroom.
  capacity {
    total_throughput_limit = var.cosmos_total_throughput_limit
  }

  tags = var.tags
}

# azapi rather than azurerm so semanticSearch can be set at create time.
resource "azapi_resource" "search" {
  type      = "Microsoft.Search/searchServices@2025-05-01"
  name      = "${var.prefix}${local.suffix}search"
  parent_id = var.resource_group_id
  location  = var.location
  tags      = var.tags

  schema_validation_enabled = true

  body = {
    sku = {
      name = var.search_sku
    }
    identity = {
      type = "SystemAssigned"
    }
    properties = {
      replicaCount   = 1
      partitionCount = 1
      hostingMode    = "Default"

      # The sample sets this to "disabled". Foundry IQ agentic retrieval needs the
      # semantic ranker, so it is enabled here deliberately.
      semanticSearch = "standard"

      disableLocalAuth = false
      authOptions = {
        aadOrApiKey = {
          aadAuthFailureMode = "http401WithBearerChallenge"
        }
      }

      publicNetworkAccess = "Disabled"
      networkRuleSet = {
        bypass = "None"
      }
    }
  }

  response_export_values = ["identity.principalId"]
}

resource "azurerm_key_vault" "this" {
  name                = "${var.prefix}${local.suffix}kv"
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = var.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled    = true
  purge_protection_enabled      = false
  soft_delete_retention_days    = 7
  public_network_access_enabled = false

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }

  tags = var.tags
}

########################################
# Private endpoints - not auto-created by Foundry
########################################

locals {
  private_endpoints = {
    storage = {
      resource_id = azurerm_storage_account.this.id
      subresource = "blob"
      zones       = [var.dns_zone_ids[local.dns.blob]]
    }
    cosmos = {
      resource_id = azurerm_cosmosdb_account.this.id
      subresource = "Sql"
      zones       = [var.dns_zone_ids[local.dns.cosmos]]
    }
    search = {
      resource_id = azapi_resource.search.id
      subresource = "searchService"
      zones       = [var.dns_zone_ids[local.dns.search]]
    }
    vault = {
      resource_id = azurerm_key_vault.this.id
      subresource = "vault"
      zones       = [var.dns_zone_ids[local.dns.vault]]
    }
  }
}

resource "azurerm_private_endpoint" "byo" {
  for_each = local.private_endpoints

  name                = "pe-${var.prefix}${local.suffix}-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${each.key}"
    private_connection_resource_id = each.value.resource_id
    subresource_names              = [each.value.subresource]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-${each.key}"
    private_dns_zone_ids = each.value.zones
  }
}
