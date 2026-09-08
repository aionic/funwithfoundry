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
    cognitive = "privatelink.cognitiveservices.azure.com"
    openai    = "privatelink.openai.azure.com"
    aiservice = "privatelink.services.ai.azure.com"
  }
}

# Landing zone for the SharePoint document before Content Understanding analyses it.
# Stays private: the Function reads it over the blob private endpoint and sends bytes
# to CU via analyzeBinary, because CU cannot fetch a private blob by URL.
resource "azurerm_storage_account" "staging" {
  name                = "${var.prefix}${local.suffix}stage"
  resource_group_name = var.resource_group_name
  location            = var.location

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"

  shared_access_key_enabled       = false
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = false

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  lifecycle {
    ignore_changes = [network_rules[0].private_link_access]
  }

  tags = var.tags
}

resource "azurerm_private_endpoint" "staging_blob" {
  name                = "pe-${var.prefix}${local.suffix}-stage"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-stage-blob"
    private_connection_resource_id = azurerm_storage_account.staging.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-stage-blob"
    private_dns_zone_ids = [var.dns_zone_ids[local.dns.blob]]
  }
}

########################################
# Foundry account for Content Understanding
# No agent subnet and no capability host - CU does not need either.
########################################

resource "azapi_resource" "foundry" {
  type      = "Microsoft.CognitiveServices/accounts@2025-06-01"
  name      = "${var.prefix}${local.suffix}cu"
  parent_id = var.resource_group_id
  location  = var.location
  tags      = var.tags

  schema_validation_enabled = false

  body = {
    kind = "AIServices"
    sku = {
      name = "S0"
    }
    identity = {
      type = "SystemAssigned"
    }
    properties = {
      # Matches what the service enforces once public access is disabled.
      disableLocalAuth       = true
      allowProjectManagement = true
      customSubDomainName    = "${var.prefix}${local.suffix}cu"

      publicNetworkAccess = "Disabled"
      networkAcls = {
        defaultAction = "Allow"
      }
    }
  }

  response_export_values = ["identity.principalId"]
}

# Same provisioning-state race as the injected account: the ARM PUT returns while the
# account is still "Accepted", and private endpoint attachment rejects that state.
resource "time_sleep" "foundry_ready" {
  depends_on      = [azapi_resource.foundry]
  create_duration = "180s"
}

resource "azurerm_private_endpoint" "foundry" {
  name                = "pe-${var.prefix}${local.suffix}-cu"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  depends_on = [time_sleep.foundry_ready]

  private_service_connection {
    name                           = "psc-cu"
    private_connection_resource_id = azapi_resource.foundry.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "dns-cu"
    private_dns_zone_ids = [
      var.dns_zone_ids[local.dns.cognitive],
      var.dns_zone_ids[local.dns.openai],
      var.dns_zone_ids[local.dns.aiservice],
    ]
  }
}

# Content Understanding requires bring-your-own generative and embedding deployments.
resource "azurerm_cognitive_deployment" "chat" {
  name                 = var.chat_model.name
  cognitive_account_id = azapi_resource.foundry.id

  sku {
    name     = "GlobalStandard"
    capacity = var.chat_model.capacity
  }

  model {
    format  = "OpenAI"
    name    = var.chat_model.name
    version = var.chat_model.version
  }
}

resource "azurerm_cognitive_deployment" "embedding" {
  name                 = var.embedding_model.name
  cognitive_account_id = azapi_resource.foundry.id

  sku {
    name     = "GlobalStandard"
    capacity = var.embedding_model.capacity
  }

  model {
    format  = "OpenAI"
    name    = var.embedding_model.name
    version = var.embedding_model.version
  }

  depends_on = [azurerm_cognitive_deployment.chat]
}

resource "azapi_resource" "project" {
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-06-01"
  name      = "${var.prefix}${local.suffix}cuproj"
  parent_id = azapi_resource.foundry.id
  location  = var.location

  schema_validation_enabled = false

  body = {
    sku = {
      name = "S0"
    }
    identity = {
      type = "SystemAssigned"
    }
    properties = {
      displayName = "content-understanding"
      description = "Content Understanding instance for document ingestion."
    }
  }

  response_export_values = ["identity.principalId"]

  depends_on = [azurerm_private_endpoint.foundry]
}

########################################
# Operator access for testing from the jumpbox
########################################

resource "azurerm_role_assignment" "operator_cognitive_user" {
  scope                = azapi_resource.foundry.id
  role_definition_name = "Cognitive Services User"
  principal_id         = var.operator_object_id
}

resource "azurerm_role_assignment" "operator_blob_contributor" {
  scope                = azurerm_storage_account.staging.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.operator_object_id
}
