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
