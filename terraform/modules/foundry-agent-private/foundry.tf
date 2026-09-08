########################################
# Foundry account - network injection MUST be set at creation
########################################

resource "azapi_resource" "foundry" {
  type      = "Microsoft.CognitiveServices/accounts@2025-06-01"
  name      = "${var.prefix}${local.suffix}foundry"
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
      # The service forces this to true once public access is disabled. Declaring false
      # makes Terraform issue a full account PUT every plan, which resets private endpoint
      # connections from Approved to Pending and is then rejected by Azure.
      disableLocalAuth       = true
      allowProjectManagement = true
      customSubDomainName    = "${var.prefix}${local.suffix}foundry"

      publicNetworkAccess = "Disabled"
      networkAcls = {
        defaultAction = "Allow"
      }

      # Cannot be added after creation. Changing it means rebuilding the account.
      networkInjections = [
        {
          scenario                   = "agent"
          subnetArmId                = var.agent_subnet_id
          useMicrosoftManagedNetwork = false
        }
      ]
    }
  }

  response_export_values = ["identity.principalId"]
}

# The ARM PUT returns while the account is still in "Accepted". Attaching a private
# endpoint before it reaches "Succeeded" fails with AccountProvisioningStateInvalid.
resource "time_sleep" "foundry_ready" {
  depends_on      = [azapi_resource.foundry]
  create_duration = "180s"
}

resource "azurerm_private_endpoint" "foundry" {
  name                = "pe-${var.prefix}${local.suffix}-foundry"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  depends_on = [time_sleep.foundry_ready]

  private_service_connection {
    name                           = "psc-foundry"
    private_connection_resource_id = azapi_resource.foundry.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "dns-foundry"
    private_dns_zone_ids = [
      var.dns_zone_ids[local.dns.cognitive],
      var.dns_zone_ids[local.dns.openai],
      var.dns_zone_ids[local.dns.aiservice],
    ]
  }
}

########################################
# Model deployments
########################################

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

  # Cognitive deployments serialise on the account.
  depends_on = [azurerm_cognitive_deployment.chat]
}

# Separate model for agent tool calling. The Agent Service fails every run with an
# opaque server_error when an agent using gpt-5.2 has the azure_ai_search tool
# attached; the identical agent on gpt-4o completes. gpt-5.2 is still the knowledge
# base planner, where it works.
resource "azurerm_cognitive_deployment" "agent_tools" {
  name                 = var.agent_tool_model.name
  cognitive_account_id = azapi_resource.foundry.id

  sku {
    name     = "GlobalStandard"
    capacity = var.agent_tool_model.capacity
  }

  model {
    format  = "OpenAI"
    name    = var.agent_tool_model.name
    version = var.agent_tool_model.version
  }

  depends_on = [azurerm_cognitive_deployment.embedding]
}

########################################
# Project
########################################

resource "azapi_resource" "project" {
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-06-01"
  name      = "${var.prefix}${local.suffix}proj"
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
      displayName = "funwithfoundry"
      description = "Network-secured agent project with BYO storage, search, and thread storage."
    }
  }

  response_export_values = ["identity.principalId", "properties.internalId"]

  depends_on = [
    azurerm_private_endpoint.foundry,
    azurerm_private_endpoint.byo,
  ]
}

locals {
  project_principal_id = azapi_resource.project.output.identity.principalId
  internal_id          = azapi_resource.project.output.properties.internalId

  # internalId comes back as an undashed GUID; the storage ABAC condition needs it dashed.
  project_id_guid = join("-", [
    substr(local.internal_id, 0, 8),
    substr(local.internal_id, 8, 4),
    substr(local.internal_id, 12, 4),
    substr(local.internal_id, 16, 4),
    substr(local.internal_id, 20, 12),
  ])
}

resource "time_sleep" "project_identity" {
  depends_on      = [azapi_resource.project]
  create_duration = "30s"
}

########################################
# Project connections - all three required or capability host creation fails
########################################

resource "azapi_resource" "conn_cosmos" {
  type                      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01"
  name                      = azurerm_cosmosdb_account.this.name
  parent_id                 = azapi_resource.project.id
  schema_validation_enabled = false

  body = {
    name = azurerm_cosmosdb_account.this.name
    properties = {
      category = "CosmosDb"
      target   = azurerm_cosmosdb_account.this.endpoint
      authType = "AAD"
      metadata = {
        ApiType    = "Azure"
        ResourceId = azurerm_cosmosdb_account.this.id
        location   = var.location
      }
    }
  }

  depends_on = [time_sleep.project_identity]
}

resource "azapi_resource" "conn_storage" {
  type                      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01"
  name                      = azurerm_storage_account.this.name
  parent_id                 = azapi_resource.project.id
  schema_validation_enabled = false

  body = {
    name = azurerm_storage_account.this.name
    properties = {
      category = "AzureStorageAccount"
      target   = azurerm_storage_account.this.primary_blob_endpoint
      authType = "AAD"
      metadata = {
        ApiType    = "Azure"
        ResourceId = azurerm_storage_account.this.id
        location   = var.location
      }
    }
  }

  depends_on = [time_sleep.project_identity]
}

resource "azapi_resource" "conn_search" {
  type                      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01"
  name                      = azapi_resource.search.name
  parent_id                 = azapi_resource.project.id
  schema_validation_enabled = false

  body = {
    name = azapi_resource.search.name
    properties = {
      category = "CognitiveSearch"
      target   = "https://${azapi_resource.search.name}.search.windows.net"
      authType = "AAD"
      metadata = {
        ApiType    = "Azure"
        ApiVersion = "2025-05-01-preview"
        ResourceId = azapi_resource.search.id
        location   = var.location
      }
    }
  }

  depends_on = [time_sleep.project_identity]
}

########################################
# Control-plane RBAC for the project managed identity
########################################

resource "azurerm_role_assignment" "cosmos_operator" {
  scope                = azurerm_cosmosdb_account.this.id
  role_definition_name = "Cosmos DB Operator"
  principal_id         = local.project_principal_id
  depends_on           = [time_sleep.project_identity]
}

resource "azurerm_role_assignment" "storage_account_contributor" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Account Contributor"
  principal_id         = local.project_principal_id
  depends_on           = [time_sleep.project_identity]
}

resource "azurerm_role_assignment" "storage_blob_contributor" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = local.project_principal_id
  depends_on           = [time_sleep.project_identity]
}

resource "azurerm_role_assignment" "search_index_contributor" {
  scope                = azapi_resource.search.id
  role_definition_name = "Search Index Data Contributor"
  principal_id         = local.project_principal_id
  depends_on           = [time_sleep.project_identity]
}

resource "azurerm_role_assignment" "search_service_contributor" {
  scope                = azapi_resource.search.id
  role_definition_name = "Search Service Contributor"
  principal_id         = local.project_principal_id
  depends_on           = [time_sleep.project_identity]
}

resource "time_sleep" "rbac_propagation" {
  depends_on = [
    azurerm_role_assignment.cosmos_operator,
    azurerm_role_assignment.storage_account_contributor,
    azurerm_role_assignment.storage_blob_contributor,
    azurerm_role_assignment.search_index_contributor,
    azurerm_role_assignment.search_service_contributor,
  ]
  create_duration = "90s"
}

########################################
# Capability hosts - immutable once created, and order matters
########################################

# The ACCOUNT capability host is deliberately not managed here.
#
# Creating it via ARM succeeds, but the platform stores it under its own name
# (<account>@aml_aiagentservice) rather than the name supplied in the PUT, and it is a
# singleton per account. The supplied name then 404s, so Terraform can neither read nor
# re-create it, and any retry fails with:
#   "There is an existing Capability Host ... cannot create a new Capability Host with
#    name: caphostacct for the same ClientId."
#
# It must also carry customerSubnet matching the injected agent subnet, despite the docs
# describing an empty body.
#
# On a fresh build, create it once out of band before the project capability host with
# scripts/Ensure-AgentCapabilityHost.ps1. The deployment workflow applies the account and
# subnet first, runs that idempotent helper, and then applies this project capability host.
# Purging the Foundry account removes it.

resource "azapi_resource" "project_capability_host" {
  type                      = "Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-04-01-preview"
  name                      = "caphostproj"
  parent_id                 = azapi_resource.project.id
  schema_validation_enabled = false

  body = {
    properties = {
      capabilityHostKind       = "Agents"
      vectorStoreConnections   = [azapi_resource.search.name]
      storageConnections       = [azurerm_storage_account.this.name]
      threadStorageConnections = [azurerm_cosmosdb_account.this.name]
    }
  }

  depends_on = [
    time_sleep.rbac_propagation,
    azapi_resource.conn_search,
    azapi_resource.conn_storage,
    azapi_resource.conn_cosmos,
  ]
}

########################################
# Data-plane RBAC on containers the capability host creates
########################################

resource "azurerm_cosmosdb_sql_role_assignment" "project_data_contributor" {
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.this.name
  scope               = azurerm_cosmosdb_account.this.id
  principal_id        = local.project_principal_id

  # Built-in Cosmos DB Data Contributor.
  role_definition_id = "${azurerm_cosmosdb_account.this.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"

  depends_on = [azapi_resource.project_capability_host]
}

resource "azurerm_role_assignment" "storage_blob_owner_agents" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = local.project_principal_id
  condition_version    = "2.0"

  # Scopes Owner down to the agent blob containers the capability host provisions.
  condition = <<-EOT
  (
    (
      !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/read'})
      AND !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/filter/action'})
      AND !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/write'})
    )
    OR
    (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringStartsWithIgnoreCase '${local.project_id_guid}'
    AND @Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringLikeIgnoreCase '*-azureml-agent')
  )
  EOT

  depends_on = [azapi_resource.project_capability_host]
}

########################################
# Operator access for hands-on testing from the jumpbox
########################################

# Foundry IQ agentic retrieval runs its query planner AS THE SEARCH SERVICE identity,
# calling chat/completions on the Foundry account. Without this the knowledge base
# retrieve call fails with 401 "lacks the required data action ...chat/completions".
resource "azurerm_role_assignment" "search_openai_user" {
  scope                = azapi_resource.foundry.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azapi_resource.search.output.identity.principalId
}

# RBAC alone is not enough. AI Search is an external PaaS service with no VNet
# integration for OUTBOUND calls, so reaching a Foundry account with
# publicNetworkAccess=Disabled requires a shared private link. Without it the planner
# call is refused and surfaces as 401 "Principal does not have access to API/Operation",
# which looks like an RBAC problem but is not.
resource "azapi_resource" "search_shared_private_link" {
  type      = "Microsoft.Search/searchServices/sharedPrivateLinkResources@2025-05-01"
  name      = "spl-foundry"
  parent_id = azapi_resource.search.id

  body = {
    properties = {
      privateLinkResourceId = azapi_resource.foundry.id
      groupId               = var.search_shared_link_group_id
      requestMessage        = "Foundry IQ agentic retrieval query planner"
    }
  }

  # Once the link is Approved, re-PUTting it is rejected. The approval itself is a
  # manual step: scripts/Approve-SharedPrivateLink.ps1.
  lifecycle {
    ignore_changes = [body, schema_validation_enabled]
  }

  depends_on = [azurerm_role_assignment.search_openai_user]
}

resource "azurerm_role_assignment" "operator_search_index" {
  scope                = azapi_resource.search.id
  role_definition_name = "Search Index Data Contributor"
  principal_id         = var.operator_object_id
}

resource "azurerm_role_assignment" "operator_search_service" {
  scope                = azapi_resource.search.id
  role_definition_name = "Search Service Contributor"
  principal_id         = var.operator_object_id
}
