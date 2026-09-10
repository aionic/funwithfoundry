output "function_app_name" {
  value = azurerm_function_app_flex_consumption.this.name
}

output "function_app_id" {
  value = azurerm_function_app_flex_consumption.this.id
}

output "default_hostname" {
  value = azurerm_function_app_flex_consumption.this.default_hostname
}

output "identity_principal_id" {
  value = azurerm_user_assigned_identity.func.principal_id
}

output "identity_client_id" {
  value = azurerm_user_assigned_identity.func.client_id
}

output "storage_account_name" {
  value = azurerm_storage_account.func.name
}

output "ingestion_api_client_id" {
  description = "Dedicated v2 access-token audience (aud), not the Function managed identity client ID."
  value       = azuread_application.ingest.client_id
}

output "ingestion_api_resource" {
  description = "Resource for managed-identity token requests. Client credentials use ingestion_api_scope instead."
  value       = azuread_application_identifier_uri.ingest.identifier_uri
}

output "ingestion_api_scope" {
  description = "Scope for tenant-specific OAuth2 client_credentials requests."
  value       = "${azuread_application_identifier_uri.ingest.identifier_uri}/.default"
}

output "ingestion_api_principal_id" {
  value = azuread_service_principal.ingest.object_id
}

output "ingestion_invoke_role_id" {
  value = random_uuid.ingest_role.result
}

output "ingestion_authorized_callers" {
  description = "Resolved caller application/client ID to service-principal object ID mapping."
  value       = local.authorized_callers
}
