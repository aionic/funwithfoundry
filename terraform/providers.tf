terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    # Foundry network injection and capability hosts are not modelled by azurerm.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    # Managed identity replication and RBAC propagation need explicit waits.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  # The storage accounts disable shared keys, so the provider must use Entra ID for
  # data-plane calls. Without this its availability probe fails with
  # "Key based authentication is not permitted on this storage account".
  storage_use_azuread = true

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    # Foundry accounts must be purged, not just deleted, or the agent subnet's
    # serviceAssociationLink blocks VNet teardown.
    cognitive_account {
      purge_soft_delete_on_destroy = true
    }
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
}

provider "azapi" {
  subscription_id = var.subscription_id
}
