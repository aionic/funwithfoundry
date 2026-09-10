output "foundry_id" {
  value = azapi_resource.foundry.id
}

output "foundry_name" {
  value = azapi_resource.foundry.name
}

output "project_id" {
  value = azapi_resource.project.id
}

output "project_name" {
  value = azapi_resource.project.name
}

output "project_principal_id" {
  value = local.project_principal_id
}

output "search_name" {
  value = azapi_resource.search.name
}

output "search_id" {
  value = azapi_resource.search.id
}

output "search_endpoint" {
  value = "https://${azapi_resource.search.name}.search.windows.net"
}

output "storage_account_name" {
  value = azurerm_storage_account.this.name
}

output "cosmos_account_name" {
  value = azurerm_cosmosdb_account.this.name
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "project_endpoint" {
  description = "Foundry project data-plane endpoint, resolvable only from inside the VNet."
  value       = "https://${azapi_resource.foundry.name}.services.ai.azure.com/api/projects/${azapi_resource.project.name}"
}

output "agent_tool_model_name" {
  description = "Model to use for agents that attach the azure_ai_search tool."
  value       = azurerm_cognitive_deployment.agent_tools.name
}

output "planner_deployment" {
  value = azurerm_cognitive_deployment.chat.name
}

output "planner_model" {
  value = var.chat_model.name
}
