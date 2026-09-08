output "foundry_id" {
  value = azapi_resource.foundry.id
}

output "foundry_name" {
  value = azapi_resource.foundry.name
}

output "endpoint" {
  description = "Content Understanding data-plane endpoint, resolvable only from inside the VNet."
  value       = "https://${azapi_resource.foundry.name}.cognitiveservices.azure.com"
}

output "project_name" {
  value = azapi_resource.project.name
}

output "staging_storage_account_name" {
  value = azurerm_storage_account.staging.name
}

output "staging_storage_id" {
  value = azurerm_storage_account.staging.id
}

output "staging_blob_endpoint" {
  value = azurerm_storage_account.staging.primary_blob_endpoint
}
