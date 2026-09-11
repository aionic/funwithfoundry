mock_provider "azurerm" {}
mock_provider "time" {}
mock_provider "random" {
  override_during = plan
  mock_resource "random_string" {
    defaults = { result = "abc12" }
  }
}
mock_provider "azapi" {
  override_during = plan
  mock_resource "azapi_resource" {
    defaults = {
      id = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-primary/providers/Microsoft.CognitiveServices/accounts/mock-foundry"
      output = {
        identity = { principalId = "22222222-2222-4222-8222-222222222222" }
      }
    }
  }
}

variables {
  prefix                     = "fwf"
  resource_group_name        = "rg-primary"
  resource_group_id          = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-primary"
  location                   = "centralus"
  tenant_id                  = "11111111-1111-4111-8111-111111111111"
  agent_subnet_id            = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-primary/providers/Microsoft.Network/virtualNetworks/test/subnets/agent"
  private_endpoint_subnet_id = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-primary/providers/Microsoft.Network/virtualNetworks/test/subnets/private"
  dns_zone_ids               = {}
  operator_object_id         = "44444444-4444-4444-8444-444444444444"
  tags                       = {}
}

run "system_identity_default" {
  command = plan
  plan_options {
    target = [azapi_resource.search_shared_private_link]
  }

  assert {
    condition = (
      azapi_resource.search.body.sku.name == "standard" &&
      azapi_resource.search.body.identity.type == "SystemAssigned" &&
      !contains(keys(azapi_resource.search.body.identity), "userAssignedIdentities") &&
      azapi_resource.search.body.properties.publicNetworkAccess == "Disabled" &&
      azapi_resource.search.body.properties.networkRuleSet.bypass == "None" &&
      azapi_resource.search.body.properties.disableLocalAuth
    )
    error_message = "Search must default to S1, retain its system identity, and forbid public/key access."
  }
}

run "ingestion_identity_preserves_planner" {
  command = plan
  variables {
    search_user_assigned_identity_ids = {
      native_ingestion = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-primary/providers/Microsoft.ManagedIdentity/userAssignedIdentities/search-ingestion"
    }
  }
  plan_options {
    target = [azapi_resource.search_shared_private_link]
  }

  assert {
    condition = (
      azapi_resource.search.body.identity.type == "SystemAssigned, UserAssigned" &&
      toset(keys(azapi_resource.search.body.identity.userAssignedIdentities)) == toset(values(var.search_user_assigned_identity_ids)) &&
      azapi_resource.search.body.sku.name == "standard" &&
      azapi_resource.search.body.properties.publicNetworkAccess == "Disabled" &&
      azapi_resource.search.body.properties.networkRuleSet.bypass == "None" &&
      azapi_resource.search.body.properties.disableLocalAuth
    )
    error_message = "Adding the ingestion UAMI must retain SystemAssigned, default S1, and private-only Search settings."
  }

  assert {
    condition = (
      azurerm_role_assignment.search_openai_user.principal_id == azapi_resource.search.output.identity.principalId &&
      azurerm_role_assignment.search_openai_user.scope == azapi_resource.foundry.id &&
      azurerm_role_assignment.search_openai_user.role_definition_name == "Cognitive Services OpenAI User" &&
      azapi_resource.search_shared_private_link.name == "spl-foundry" &&
      azapi_resource.search_shared_private_link.parent_id == azapi_resource.search.id &&
      azapi_resource.search_shared_private_link.body.properties.privateLinkResourceId == azapi_resource.foundry.id &&
      azapi_resource.search_shared_private_link.body.properties.groupId == "openai_account"
    )
    error_message = "The primary planner role and spl-foundry link must still use the Search system identity and primary Foundry account."
  }
}

run "reject_basic_private_ingestion" {
  command = plan
  variables {
    search_sku = "basic"
  }
  plan_options {
    target = [azapi_resource.search]
  }
  expect_failures = [var.search_sku]
}