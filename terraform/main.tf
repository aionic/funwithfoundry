data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "net" {
  name     = "rg-${var.prefix}-net"
  location = var.primary_region
  tags     = local.tags
}

resource "azurerm_resource_group" "primary" {
  name     = "rg-${local.name.primary}"
  location = var.primary_region
  tags     = local.tags
}

resource "azurerm_resource_group" "secondary" {
  name     = "rg-${local.name.secondary}"
  location = var.secondary_region
  tags     = local.tags
}

module "vwan" {
  source = "./modules/vwan-secured"

  prefix               = var.prefix
  resource_group_name  = azurerm_resource_group.net.name
  primary_region       = var.primary_region
  secondary_region     = var.secondary_region
  hub_prefix_primary   = local.hub_prefix.primary
  hub_prefix_secondary = local.hub_prefix.secondary

  spoke_address_spaces    = concat(local.spoke_primary_space, local.spoke_secondary_space)
  jumpbox_subnet_prefixes = local.spoke_primary_subnets["snet-jumpbox"].prefixes

  tags = local.tags
}

module "spoke_primary" {
  source = "./modules/spoke"

  name                = local.name.primary
  resource_group_name = azurerm_resource_group.primary.name
  location            = var.primary_region
  address_space       = local.spoke_primary_space
  subnets             = local.spoke_primary_subnets
  virtual_hub_id      = module.vwan.hub_primary_id
  tags                = local.tags
}

module "spoke_secondary" {
  source = "./modules/spoke"

  name                = local.name.secondary
  resource_group_name = azurerm_resource_group.secondary.name
  location            = var.secondary_region
  address_space       = local.spoke_secondary_space
  subnets             = local.spoke_secondary_subnets
  virtual_hub_id      = module.vwan.hub_secondary_id
  tags                = local.tags
}

module "private_dns" {
  source = "./modules/private-dns"

  zones               = local.private_dns_zones
  resource_group_name = azurerm_resource_group.net.name

  linked_vnet_ids = {
    (local.name.primary)   = module.spoke_primary.vnet_id
    (local.name.secondary) = module.spoke_secondary.vnet_id
  }

  tags = local.tags
}

module "jumpbox" {
  source = "./modules/jumpbox-bastion"

  name                = local.name.primary
  resource_group_name = azurerm_resource_group.primary.name
  location            = var.primary_region
  bastion_subnet_id   = module.spoke_primary.subnet_ids["AzureBastionSubnet"]
  jumpbox_subnet_id   = module.spoke_primary.subnet_ids["snet-jumpbox"]
  vm_size             = var.jumpbox_size
  admin_username      = var.jumpbox_admin_username
  tags                = local.tags
}

module "foundry_primary" {
  source = "./modules/foundry-agent-private"

  prefix              = var.prefix
  resource_group_name = azurerm_resource_group.primary.name
  resource_group_id   = azurerm_resource_group.primary.id
  location            = var.primary_region
  tenant_id           = data.azurerm_client_config.current.tenant_id

  agent_subnet_id            = module.spoke_primary.subnet_ids["snet-agent"]
  private_endpoint_subnet_id = module.spoke_primary.subnet_ids["snet-pe"]
  dns_zone_ids               = module.private_dns.zone_ids
  operator_object_id         = local.operator_object_id

  tags = local.tags
}

module "foundry_secondary" {
  source = "./modules/foundry-content-understanding"

  prefix              = var.prefix
  resource_group_name = azurerm_resource_group.secondary.name
  resource_group_id   = azurerm_resource_group.secondary.id
  location            = var.secondary_region

  private_endpoint_subnet_id = module.spoke_secondary.subnet_ids["snet-pe"]
  dns_zone_ids               = module.private_dns.zone_ids
  operator_object_id         = local.operator_object_id

  tags = local.tags
}

# Sits in the secondary spoke next to Content Understanding. The Graph fetch egresses
# through the firewall; every hop after it stays on private endpoints.
module "ingest_function" {
  source = "./modules/ingest-function"

  prefix              = var.prefix
  resource_group_name = azurerm_resource_group.secondary.name
  location            = var.secondary_region

  function_subnet_id         = module.spoke_secondary.subnet_ids["snet-func"]
  private_endpoint_subnet_id = module.spoke_secondary.subnet_ids["snet-pe"]
  dns_zone_ids               = module.private_dns.zone_ids

  staging_storage_id    = module.foundry_secondary.staging_storage_id
  staging_blob_endpoint = module.foundry_secondary.staging_blob_endpoint

  content_understanding_account_id = module.foundry_secondary.foundry_id
  content_understanding_endpoint   = module.foundry_secondary.endpoint

  search_id       = module.foundry_primary.search_id
  search_endpoint = module.foundry_primary.search_endpoint

  sharepoint_hostname  = var.sharepoint_hostname
  sharepoint_site_path = var.sharepoint_site_path
  sharepoint_file_path = var.sharepoint_file_path

  tags = local.tags
}

# The jumpbox is the only place that can reach these endpoints, so its managed identity
# needs the data-plane roles for any in-VNet testing or post-deploy setup.

# The function's SCM endpoint is private, so code can only be pushed from the jumpbox.
resource "azurerm_role_assignment" "jumpbox_function_contributor" {
  scope                = module.ingest_function.function_app_id
  role_definition_name = "Website Contributor"
  principal_id         = module.jumpbox.jumpbox_principal_id
}

resource "azurerm_role_assignment" "jumpbox_search_index" {
  scope                = module.foundry_primary.search_id
  role_definition_name = "Search Index Data Contributor"
  principal_id         = module.jumpbox.jumpbox_principal_id
}

resource "azurerm_role_assignment" "jumpbox_search_service" {
  scope                = module.foundry_primary.search_id
  role_definition_name = "Search Service Contributor"
  principal_id         = module.jumpbox.jumpbox_principal_id
}

resource "azurerm_role_assignment" "jumpbox_foundry_primary" {
  scope                = module.foundry_primary.foundry_id
  role_definition_name = "Cognitive Services User"
  principal_id         = module.jumpbox.jumpbox_principal_id
}

resource "azurerm_role_assignment" "jumpbox_foundry_secondary" {
  scope                = module.foundry_secondary.foundry_id
  role_definition_name = "Cognitive Services User"
  principal_id         = module.jumpbox.jumpbox_principal_id
}

resource "azurerm_role_assignment" "jumpbox_staging_blob" {
  scope                = module.foundry_secondary.staging_storage_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = module.jumpbox.jumpbox_principal_id
}
