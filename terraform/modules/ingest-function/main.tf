terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = ">= 4.81.0, < 5.0" }
    azuread = { source = "hashicorp/azuread", version = ">= 3.9.0, < 4.0" }
    azapi   = { source = "Azure/azapi" }
    random  = { source = "hashicorp/random" }
  }
}

resource "random_string" "unique" {
  length  = 5
  special = false
  upper   = false
  numeric = true
}

locals {
  suffix = random_string.unique.result

  dns = {
    blob  = "privatelink.blob.core.windows.net"
    queue = "privatelink.queue.core.windows.net"
    table = "privatelink.table.core.windows.net"
    sites = "privatelink.azurewebsites.net"
  }

  deployment_container = "deployments"
  storage_name         = "${var.prefix}${local.suffix}fn"
}

resource "azurerm_user_assigned_identity" "func" {
  name                = "id-${var.prefix}-ingest"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

########################################
# Host storage - same private posture as the rest of the lab
########################################

resource "azurerm_storage_account" "func" {
  name                = local.storage_name
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

# Created through the ARM control plane. azurerm_storage_container uses the data
# plane, which is unreachable from a public runner once the firewall is set to Deny.
resource "azapi_resource" "deployments" {
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01"
  name      = local.deployment_container
  parent_id = "${azurerm_storage_account.func.id}/blobServices/default"

  body = {
    properties = {
      publicAccess = "None"
    }
  }
}

resource "azurerm_private_endpoint" "func_storage" {
  for_each = {
    blob  = local.dns.blob
    queue = local.dns.queue
    table = local.dns.table
  }

  name                = "pe-${var.prefix}${local.suffix}-fn-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-fn-${each.key}"
    private_connection_resource_id = azurerm_storage_account.func.id
    subresource_names              = [each.key]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-fn-${each.key}"
    private_dns_zone_ids = [var.dns_zone_ids[each.value]]
  }
}

########################################
# Flex Consumption function app
########################################

resource "azurerm_service_plan" "func" {
  name                = "asp-${var.prefix}-ingest"
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = var.tags
}

resource "azurerm_function_app_flex_consumption" "this" {
  name                = "func-${var.prefix}-${local.suffix}-ingest"
  resource_group_name = var.resource_group_name
  location            = var.location
  service_plan_id     = azurerm_service_plan.func.id

  storage_container_type            = "blobContainer"
  storage_container_endpoint        = "${azurerm_storage_account.func.primary_blob_endpoint}${local.deployment_container}"
  storage_authentication_type       = "UserAssignedIdentity"
  storage_user_assigned_identity_id = azurerm_user_assigned_identity.func.id

  runtime_name    = "python"
  runtime_version = "3.11"

  maximum_instance_count = 40
  instance_memory_in_mb  = 2048

  virtual_network_subnet_id     = var.function_subnet_id
  public_network_access_enabled = false
  https_only                    = true

  webdeploy_publish_basic_authentication_enabled = false

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.func.id]
  }

  site_config {}

  auth_settings_v2 {
    auth_enabled           = true
    require_authentication = true
    unauthenticated_action = "Return401"
    require_https          = true
    default_provider       = "azureactivedirectory"

    active_directory_v2 {
      client_id            = azuread_application.ingest.client_id
      tenant_auth_endpoint = "https://login.microsoftonline.com/${lower(var.tenant_id)}/v2.0"
      allowed_audiences    = [azuread_application.ingest.client_id]
      allowed_applications = sort(keys(local.authorized_callers))
      allowed_identities   = sort(values(local.authorized_callers))
    }

    login {
      token_store_enabled = false
    }
  }

  app_settings = {
    # DefaultAzureCredential needs this to select the user-assigned identity.
    AZURE_CLIENT_ID = azurerm_user_assigned_identity.func.client_id

    AzureWebJobsStorage__blobServiceUri  = azurerm_storage_account.func.primary_blob_endpoint
    AzureWebJobsStorage__queueServiceUri = azurerm_storage_account.func.primary_queue_endpoint
    AzureWebJobsStorage__tableServiceUri = azurerm_storage_account.func.primary_table_endpoint
    AzureWebJobsStorage__credential      = "managedidentity"
    AzureWebJobsStorage__clientId        = azurerm_user_assigned_identity.func.client_id

    INGEST_TENANT_ID          = lower(var.tenant_id)
    INGEST_AUDIENCE           = azuread_application.ingest.client_id
    INGEST_AUTHORIZED_CALLERS = jsonencode(local.authorized_callers)
    INGEST_FIXTURE_ENABLED    = tostring(var.enable_synthetic_fixture)
    INGEST_MAX_BYTES          = tostring(var.max_document_bytes)

    SP_SITE_HOSTNAME = var.sharepoint_hostname
    SP_SITE_PATH     = var.sharepoint_site_path
    SP_FILE_PATH     = var.sharepoint_file_path

    STAGING_BLOB_ENDPOINT = var.staging_blob_endpoint
    STAGING_CONTAINER     = "spo-staging"
  }

  depends_on = [
    azapi_resource.deployments,
    azurerm_role_assignment.func_storage_blob_owner,
    azuread_application_identifier_uri.ingest,
    azuread_app_role_assignment.ingest_caller,
  ]

  tags = var.tags
}

resource "azurerm_private_endpoint" "func_sites" {
  name                = "pe-${var.prefix}${local.suffix}-fn-sites"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-fn-sites"
    private_connection_resource_id = azurerm_function_app_flex_consumption.this.id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-fn-sites"
    private_dns_zone_ids = [var.dns_zone_ids[local.dns.sites]]
  }
}

########################################
# RBAC
########################################

# The host needs these on its own storage before it can start.
resource "azurerm_role_assignment" "func_storage_blob_owner" {
  scope                = azurerm_storage_account.func.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_user_assigned_identity.func.principal_id
}

resource "azurerm_role_assignment" "func_storage_queue" {
  scope                = azurerm_storage_account.func.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_user_assigned_identity.func.principal_id
}

resource "azurerm_role_assignment" "func_storage_table" {
  scope                = azurerm_storage_account.func.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_user_assigned_identity.func.principal_id
}

resource "azurerm_role_assignment" "func_staging_blob" {
  scope                = var.staging_storage_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.func.principal_id
}
