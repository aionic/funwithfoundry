mock_provider "azurerm" {}
mock_provider "azapi" {}
mock_provider "random" {}
mock_provider "azuread" {
  mock_data "azuread_client_config" {
    defaults = {
      tenant_id = "11111111-1111-4111-8111-111111111111"
    }
  }
  mock_data "azuread_service_principal" {
    defaults = {
      client_id = "33333333-3333-4333-8333-333333333333"
      object_id = "44444444-4444-4444-8444-444444444444"
    }
  }
}

variables {
  prefix                           = "ingesttest"
  tenant_id                        = "11111111-1111-4111-8111-111111111111"
  authorized_caller_principal_ids  = { jumpbox = "44444444-4444-4444-8444-444444444444" }
  resource_group_name              = "rg-ingest-test"
  location                         = "southcentralus"
  function_subnet_id               = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-ingest-test/providers/Microsoft.Network/virtualNetworks/test/subnets/function"
  private_endpoint_subnet_id       = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-ingest-test/providers/Microsoft.Network/virtualNetworks/test/subnets/private"
  staging_storage_id               = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-ingest-test/providers/Microsoft.Storage/storageAccounts/stagingtest"
  staging_blob_endpoint            = "https://stagingtest.blob.core.windows.net"
  content_understanding_account_id = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-ingest-test/providers/Microsoft.CognitiveServices/accounts/cutest"
  content_understanding_endpoint   = "https://cutest.cognitiveservices.azure.com"
  search_id                        = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-ingest-test/providers/Microsoft.Search/searchServices/searchtest"
  search_endpoint                  = "https://searchtest.search.windows.net"
  sharepoint_hostname              = "tenant.sharepoint.com"
  sharepoint_site_path             = "/sites/Example"
  sharepoint_file_path             = "Documents/Example.pdf"
  dns_zone_ids = {
    "privatelink.blob.core.windows.net"  = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-ingest-test/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
    "privatelink.queue.core.windows.net" = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-ingest-test/providers/Microsoft.Network/privateDnsZones/privatelink.queue.core.windows.net"
    "privatelink.table.core.windows.net" = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-ingest-test/providers/Microsoft.Network/privateDnsZones/privatelink.table.core.windows.net"
    "privatelink.azurewebsites.net"      = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-ingest-test/providers/Microsoft.Network/privateDnsZones/privatelink.azurewebsites.net"
  }
}

run "authenticated_private_ingestion" {
  command = plan

  assert {
    condition = (
      azurerm_function_app_flex_consumption.this.auth_settings_v2[0].auth_enabled &&
      azurerm_function_app_flex_consumption.this.auth_settings_v2[0].require_authentication &&
      azurerm_function_app_flex_consumption.this.auth_settings_v2[0].unauthenticated_action == "Return401" &&
      azurerm_function_app_flex_consumption.this.auth_settings_v2[0].require_https &&
      !azurerm_function_app_flex_consumption.this.public_network_access_enabled
    )
    error_message = "Ingestion must require Entra authentication independently of its private endpoint."
  }

  assert {
    condition = (
      azurerm_function_app_flex_consumption.this.auth_settings_v2[0].active_directory_v2[0].allowed_applications == tolist(["33333333-3333-4333-8333-333333333333"]) &&
      azurerm_function_app_flex_consumption.this.auth_settings_v2[0].active_directory_v2[0].allowed_identities == tolist(["44444444-4444-4444-8444-444444444444"]) &&
      jsondecode(azurerm_function_app_flex_consumption.this.app_settings["INGEST_AUTHORIZED_CALLERS"])["33333333-3333-4333-8333-333333333333"] == "44444444-4444-4444-8444-444444444444"
    )
    error_message = "Both Easy Auth and JWT validation must use the resolved caller application/principal pair."
  }

  assert {
    condition = (
      azuread_application.ingest.sign_in_audience == "AzureADMyOrg" &&
      azuread_application.ingest.api[0].requested_access_token_version == 2 &&
      one(azuread_application.ingest.optional_claims[0].access_token).name == "idtyp" &&
      azuread_service_principal.ingest.app_role_assignment_required &&
      one(azuread_application.ingest.app_role).allowed_member_types == toset(["Application"]) &&
      one(azuread_application.ingest.app_role).value == "Ingestion.Invoke" &&
      length(azuread_app_role_assignment.ingest_caller) == 1
    )
    error_message = "The dedicated API must require the assigned application-only role and v2 tokens."
  }

  assert {
    condition = (
      keys(data.azuread_service_principal.caller) == ["jumpbox"] &&
      keys(azuread_app_role_assignment.ingest_caller) == ["jumpbox"] &&
      data.azuread_service_principal.caller["jumpbox"].object_id == var.authorized_caller_principal_ids["jumpbox"] &&
      azuread_app_role_assignment.ingest_caller["jumpbox"].principal_object_id == data.azuread_service_principal.caller["jumpbox"].object_id
    )
    error_message = "Caller lookups and role assignments must use stable caller names as keys and principal IDs only as values."
  }
}

run "reject_empty_allowlist" {
  command = plan
  variables {
    authorized_caller_principal_ids = {}
  }
  expect_failures = [var.authorized_caller_principal_ids]
}

run "reject_wrong_provider_tenant" {
  command = plan
  variables {
    tenant_id = "55555555-5555-4555-8555-555555555555"
  }
  expect_failures = [azuread_application.ingest]
}
