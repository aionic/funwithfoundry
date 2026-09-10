variable "prefix" {
  type = string
}

variable "tenant_id" {
  type        = string
  description = "Single Entra tenant issuing v2 app-only tokens for this ingestion API. Must match the AzureAD provider."

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be a GUID."
  }
}

variable "authorized_caller_principal_ids" {
  type        = map(string)
  description = "Stable caller name => service-principal object ID. Keys must be known at plan time; values may come from managed identities created in this deployment."

  validation {
    condition = length(var.authorized_caller_principal_ids) > 0 && alltrue([
      for principal_id in values(var.authorized_caller_principal_ids) : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", principal_id))
    ])
    error_message = "Supply at least one service-principal object ID, each a GUID."
  }
}

variable "enable_synthetic_fixture" {
  type        = bool
  default     = true
  description = "Permit only the built-in accelerator-v1 PDF through the same authenticated ingestion pipeline."
}

variable "max_document_bytes" {
  type        = number
  default     = 5242880
  description = "Maximum source bytes, enforced against metadata and the actual stream; at most 10 MiB."

  validation {
    condition     = var.max_document_bytes >= 1 && var.max_document_bytes <= 10485760 && floor(var.max_document_bytes) == var.max_document_bytes
    error_message = "max_document_bytes must be an integer between 1 and 10485760."
  }
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "function_subnet_id" {
  type        = string
  description = "Delegated to Microsoft.App/environments for Flex Consumption."
}

variable "private_endpoint_subnet_id" {
  type = string
}

variable "dns_zone_ids" {
  type = map(string)
}

variable "staging_storage_id" {
  type = string
}

variable "staging_blob_endpoint" {
  type = string
}

variable "content_understanding_account_id" {
  type = string
}

variable "content_understanding_endpoint" {
  type = string
}

variable "search_id" {
  type = string
}

variable "search_endpoint" {
  type = string
}

variable "search_index" {
  type    = string
  default = "spo-docs"
}

variable "sharepoint_hostname" {
  type = string
}

variable "sharepoint_site_path" {
  type        = string
  description = "Server-relative site path, e.g. /sites/Contoso. Use / for the root site."
}

variable "sharepoint_file_path" {
  type        = string
  description = "Path to the document within the site's default drive."
}

variable "tags" {
  type    = map(string)
  default = {}
}
