data "azuread_client_config" "current" {}

data "azuread_service_principal" "caller" {
  for_each  = var.authorized_caller_principal_ids
  object_id = each.value
}

locals {
  authorized_callers = {
    for caller in data.azuread_service_principal.caller : lower(caller.client_id) => lower(caller.object_id)
  }
}

resource "random_uuid" "ingest_role" {}

resource "azuread_application" "ingest" {
  display_name     = "${var.prefix}-ingestion-api"
  sign_in_audience = "AzureADMyOrg"

  api {
    requested_access_token_version = 2
  }

  optional_claims {
    access_token {
      name = "idtyp"
    }
  }

  app_role {
    id                   = random_uuid.ingest_role.result
    allowed_member_types = ["Application"]
    description          = "Invoke the configured ingestion pipeline."
    display_name         = "Invoke ingestion"
    enabled              = true
    value                = "Ingestion.Invoke"
  }

  lifecycle {
    ignore_changes = [identifier_uris]

    precondition {
      condition     = lower(data.azuread_client_config.current.tenant_id) == lower(var.tenant_id)
      error_message = "The AzureAD provider must authenticate to the ingestion tenant_id."
    }
  }
}

resource "azuread_application_identifier_uri" "ingest" {
  application_id = azuread_application.ingest.id
  identifier_uri = "api://${azuread_application.ingest.client_id}"
}

resource "azuread_service_principal" "ingest" {
  client_id                    = azuread_application.ingest.client_id
  app_role_assignment_required = true
}

resource "azuread_app_role_assignment" "ingest_caller" {
  for_each            = var.authorized_caller_principal_ids
  app_role_id         = random_uuid.ingest_role.result
  principal_object_id = data.azuread_service_principal.caller[each.key].object_id
  resource_object_id  = azuread_service_principal.ingest.object_id
}
