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

output "ai_services_endpoint" {
  value = "https://${azapi_resource.foundry.name}.services.ai.azure.com"
}

output "openai_endpoint" {
  value = "https://${azapi_resource.foundry.name}.openai.azure.com"
}

output "chat_deployment" {
  value = azurerm_cognitive_deployment.chat.name
}

output "chat_model" {
  value = azurerm_cognitive_deployment.chat.model[0].name
}

output "embedding_deployment" {
  value = azurerm_cognitive_deployment.embedding.name
}

output "embedding_model" {
  value = azurerm_cognitive_deployment.embedding.model[0].name
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
