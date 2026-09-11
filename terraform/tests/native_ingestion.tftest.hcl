mock_provider "azurerm" {
  override_during = plan

  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "11111111-1111-4111-8111-111111111111"
      object_id = "22222222-2222-4222-8222-222222222222"
    }
  }

  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-fwf-cus/providers/Microsoft.ManagedIdentity/userAssignedIdentities/search-ingestion"
      principal_id = "33333333-3333-4333-8333-333333333333"
    }
  }

  mock_resource "azurerm_storage_account" {
    defaults = {
      id                    = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-fwf-scus/providers/Microsoft.Storage/storageAccounts/fwfabc12stage"
      primary_blob_endpoint = "https://fwfabc12stage.blob.core.windows.net/"
    }
  }
}

mock_provider "azapi" {
  override_during = plan
  mock_resource "azapi_resource" {
    defaults = {
      id = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-fwf-cus/providers/Microsoft.Search/searchServices/fwfabc12search/sharedPrivateLinkResources/mock-link"
    }
  }
}
mock_provider "azuread" {}
mock_provider "time" {}
mock_provider "random" {
  override_during = plan
  mock_resource "random_string" {
    defaults = { result = "abc12" }
  }
}

override_resource {
  target          = module.foundry_primary.azapi_resource.search
  override_during = plan
  values          = { id = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-fwf-cus/providers/Microsoft.Search/searchServices/fwfabc12search" }
}

override_resource {
  target          = module.foundry_secondary.azapi_resource.foundry
  override_during = plan
  values          = { id = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-fwf-scus/providers/Microsoft.CognitiveServices/accounts/fwfabc12cu" }
}

variables {
  subscription_id = "11111111-1111-4111-8111-111111111111"
}

run "native_ingestion_contract" {
  command = plan

  plan_options {
    target = [
      azapi_resource.search_ingestion_shared_private_link,
      module.foundry_secondary.azurerm_cognitive_deployment.embedding,
    ]
  }

  assert {
    condition = (
      var.search_sku == "standard" &&
      azurerm_user_assigned_identity.search_ingestion.resource_group_name == azurerm_resource_group.primary.name &&
      azurerm_user_assigned_identity.search_ingestion.location == var.primary_region
    )
    error_message = "Directly configured native CU ingestion must default to S1 with its dedicated identity in the primary resource group."
  }

  assert {
    condition = (
      azurerm_role_assignment.search_ingestion_blob_reader.scope == module.foundry_secondary.staging_storage_id &&
      azurerm_role_assignment.search_ingestion_blob_reader.role_definition_name == "Storage Blob Data Reader" &&
      azurerm_role_assignment.search_ingestion_cognitive_user.scope == module.foundry_secondary.foundry_id &&
      azurerm_role_assignment.search_ingestion_cognitive_user.role_definition_name == "Cognitive Services User" &&
      azurerm_role_assignment.search_ingestion_openai_user.scope == module.foundry_secondary.foundry_id &&
      azurerm_role_assignment.search_ingestion_openai_user.role_definition_name == "Cognitive Services OpenAI User" &&
      alltrue([for assignment in [
        azurerm_role_assignment.search_ingestion_blob_reader,
        azurerm_role_assignment.search_ingestion_cognitive_user,
        azurerm_role_assignment.search_ingestion_openai_user,
      ] : assignment.principal_id == azurerm_user_assigned_identity.search_ingestion.principal_id])
    )
    error_message = "Only the dedicated ingestion UAMI gets the three resource-scoped ingestion grants."
  }

  assert {
    condition = (
      toset(keys(output.native_ingestion)) == toset([
        "storage_resource_id", "storage_endpoint", "container_name", "folder_path",
        "identity_resource_id", "ai_services_endpoint", "openai_endpoint",
        "chat_deployment", "chat_model", "embedding_deployment", "embedding_model",
        "shared_private_links",
      ]) &&
      output.native_ingestion.storage_resource_id == module.foundry_secondary.staging_storage_id &&
      output.native_ingestion.storage_endpoint == "https://fwfabc12stage.blob.core.windows.net/" &&
      output.native_ingestion.container_name == "spo-staging" &&
      output.native_ingestion.folder_path == "native/" &&
      output.native_ingestion.identity_resource_id == azurerm_user_assigned_identity.search_ingestion.id &&
      output.native_ingestion.ai_services_endpoint == "https://fwfabc12cu.services.ai.azure.com" &&
      output.native_ingestion.openai_endpoint == "https://fwfabc12cu.openai.azure.com" &&
      output.native_ingestion.chat_deployment == "gpt-5.2" &&
      output.native_ingestion.chat_model == "gpt-5.2" &&
      output.native_ingestion.embedding_deployment == "text-embedding-3-large" &&
      output.native_ingestion.embedding_model == "text-embedding-3-large"
    )
    error_message = "The native_ingestion output must expose exactly the agreed secondary endpoint, model, storage, and identity contract."
  }

  assert {
    condition = (
      { for name, link in output.native_ingestion.shared_private_links : name => link.group_id } == {
        spl-native-staging-blob = "blob"
        spl-native-foundry      = "foundry_account"
        spl-native-openai       = "openai_account"
      } &&
      alltrue([for name, link in azapi_resource.search_ingestion_shared_private_link :
        link.name == name &&
        link.parent_id == module.foundry_primary.search_id &&
        link.body.properties.privateLinkResourceId == (name == "spl-native-staging-blob" ? module.foundry_secondary.staging_storage_id : module.foundry_secondary.foundry_id) &&
        link.body.properties.groupId == output.native_ingestion.shared_private_links[name].group_id &&
        output.native_ingestion.shared_private_links[name].target_resource_id == link.body.properties.privateLinkResourceId &&
        output.native_ingestion.shared_private_links[name].id == link.id &&
      toset(keys(output.native_ingestion.shared_private_links[name])) == toset(["id", "target_resource_id", "group_id"])])
    )
    error_message = "The three named SPLs must target secondary dependencies from Search and expose exact approval coordinates."
  }

  assert {
    condition = toset(flatten(regexall("role_definition_name\\s*=\\s*\"([^\"]+)\"", file("${path.module}/modules/ingest-function/main.tf")))) == toset([
      "Storage Blob Data Owner", "Storage Queue Data Contributor", "Storage Table Data Contributor", "Storage Blob Data Contributor",
    ])
    error_message = "The Function module must have only host-storage and staging grants, never CU or Search RBAC."
  }

  assert {
    condition = (
      can(regex("search_sku\\s*=\\s*var.search_sku", file("${path.module}/main.tf"))) &&
      can(regex("native_ingestion\\s*=\\s*azurerm_user_assigned_identity.search_ingestion.id", file("${path.module}/main.tf")))
    )
    error_message = "The parent must forward the tier and real UAMI resource ID with the stable native_ingestion map key."
  }
}

run "reject_basic_private_ingestion" {
  command = plan
  variables {
    search_sku = "basic"
  }
  plan_options {
    target = [module.foundry_primary.azapi_resource.search]
  }
  expect_failures = [var.search_sku]
}