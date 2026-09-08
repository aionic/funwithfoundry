output "resource_groups" {
  value = {
    network   = azurerm_resource_group.net.name
    primary   = azurerm_resource_group.primary.name
    secondary = azurerm_resource_group.secondary.name
  }
}

output "hub_ids" {
  value = {
    primary   = module.vwan.hub_primary_id
    secondary = module.vwan.hub_secondary_id
  }
}

output "firewall_private_ips" {
  value = {
    primary   = module.vwan.firewall_primary_private_ip
    secondary = module.vwan.firewall_secondary_private_ip
  }
}

output "spoke_primary_subnets" {
  value = module.spoke_primary.subnet_ids
}

output "spoke_secondary_subnets" {
  value = module.spoke_secondary.subnet_ids
}

output "jumpbox" {
  value = {
    name           = module.jumpbox.jumpbox_name
    bastion        = module.jumpbox.bastion_name
    admin_username = module.jumpbox.admin_username
  }
}

output "jumpbox_admin_password" {
  description = "Retrieve with: terraform output -raw jumpbox_admin_password"
  value       = module.jumpbox.admin_password
  sensitive   = true
}

output "foundry_primary" {
  description = "Private agent platform in the primary region. Endpoints resolve only inside the VNet."
  value = {
    account          = module.foundry_primary.foundry_name
    project          = module.foundry_primary.project_name
    project_endpoint = module.foundry_primary.project_endpoint
    search           = module.foundry_primary.search_name
    search_endpoint  = module.foundry_primary.search_endpoint
    storage          = module.foundry_primary.storage_account_name
    cosmos           = module.foundry_primary.cosmos_account_name
    key_vault        = module.foundry_primary.key_vault_name
    agent_tool_model = module.foundry_primary.agent_tool_model_name
  }
}

output "foundry_primary_account_id" {
  description = "ARM ID of the primary Foundry account, used by the capability-host deployment step."
  value       = module.foundry_primary.foundry_id
}

output "foundry_agent_subnet_id" {
  description = "ARM ID of the network-injected agent subnet."
  value       = module.spoke_primary.subnet_ids["snet-agent"]
}

output "foundry_secondary" {
  description = "Content Understanding instance in the secondary region."
  value = {
    account         = module.foundry_secondary.foundry_name
    project         = module.foundry_secondary.project_name
    endpoint        = module.foundry_secondary.endpoint
    staging_storage = module.foundry_secondary.staging_storage_account_name
  }
}

output "ingest_function" {
  value = {
    name            = module.ingest_function.function_app_name
    hostname        = module.ingest_function.default_hostname
    identity_client = module.ingest_function.identity_client_id
    identity_object = module.ingest_function.identity_principal_id
    storage         = module.ingest_function.storage_account_name
  }
}

output "sharepoint" {
  value = {
    hostname  = var.sharepoint_hostname
    site_path = var.sharepoint_site_path
    file_path = var.sharepoint_file_path
  }
}
