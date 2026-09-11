resource "azurerm_user_assigned_identity" "search_ingestion" {
  name                = "id-${local.name.primary}-search-ingestion"
  resource_group_name = azurerm_resource_group.primary.name
  location            = var.primary_region
  tags                = local.tags
}

resource "azurerm_role_assignment" "search_ingestion_blob_reader" {
  scope                = module.foundry_secondary.staging_storage_id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.search_ingestion.principal_id
}

resource "azurerm_role_assignment" "search_ingestion_cognitive_user" {
  scope                = module.foundry_secondary.foundry_id
  role_definition_name = "Cognitive Services User"
  principal_id         = azurerm_user_assigned_identity.search_ingestion.principal_id
}

resource "azurerm_role_assignment" "search_ingestion_openai_user" {
  scope                = module.foundry_secondary.foundry_id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_user_assigned_identity.search_ingestion.principal_id
}

locals {
  native_ingestion_shared_private_links = {
    spl-native-staging-blob = {
      target_resource_id = module.foundry_secondary.staging_storage_id
      group_id           = "blob"
    }
    spl-native-foundry = {
      target_resource_id = module.foundry_secondary.foundry_id
      group_id           = "foundry_account"
    }
    spl-native-openai = {
      target_resource_id = module.foundry_secondary.foundry_id
      group_id           = "openai_account"
    }
  }
}

resource "azapi_resource" "search_ingestion_shared_private_link" {
  for_each = local.native_ingestion_shared_private_links

  type      = "Microsoft.Search/searchServices/sharedPrivateLinkResources@2025-05-01"
  name      = each.key
  parent_id = module.foundry_primary.search_id

  body = {
    properties = {
      privateLinkResourceId = each.value.target_resource_id
      groupId               = each.value.group_id
      requestMessage        = "Foundry IQ native private ingestion; explicit approval required"
    }
  }

  lifecycle {
    ignore_changes = [body, schema_validation_enabled]
  }

  depends_on = [
    azurerm_role_assignment.search_ingestion_blob_reader,
    azurerm_role_assignment.search_ingestion_cognitive_user,
    azurerm_role_assignment.search_ingestion_openai_user,
  ]
}