variable "prefix" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "resource_group_id" {
  type = string
}

variable "location" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "agent_subnet_id" {
  description = "Subnet delegated to Microsoft.App/environments. Exclusive to this Foundry account; its name must not exceed 62 characters."
  type        = string

  validation {
    condition     = length(basename(trimsuffix(var.agent_subnet_id, "/"))) <= 62
    error_message = "The Foundry agent subnet name must be 62 characters or fewer; longer names fail during capability-host creation."
  }
}

variable "private_endpoint_subnet_id" {
  type = string
}

variable "dns_zone_ids" {
  description = "Private DNS zone name => resource ID."
  type        = map(string)
}

variable "operator_object_id" {
  description = "Human operator granted search data-plane roles for testing."
  type        = string
}

variable "search_sku" {
  description = "Search tier for directly configured native CU indexers, not generated knowledge-source ingestion. S1 private enrichment requires live service createdAt >= 2024-04-03."
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "standard2", "standard3"], var.search_sku)
    error_message = "Directly configured native CU ingestion supports Search S1, S2 or S3 with default hosting; S1 eligibility requires live createdAt >= 2024-04-03."
  }
}

variable "search_user_assigned_identity_ids" {
  description = "Stable identity name => UAMI resource ID to attach alongside the Search system identity."
  type        = map(string)
  default     = {}
}

variable "cosmos_total_throughput_limit" {
  description = "Five agent containers at 1000 RU/s each, plus headroom."
  type        = number
  default     = 6000
}

variable "chat_model" {
  type = object({
    name     = string
    version  = string
    capacity = number
  })
  default = {
    name     = "gpt-5.2"
    version  = "2025-12-11"
    capacity = 50
  }
}

variable "embedding_model" {
  type = object({
    name     = string
    version  = string
    capacity = number
  })
  default = {
    name     = "text-embedding-3-large"
    version  = "1"
    capacity = 50
  }
}

# Agents that attach the azure_ai_search tool must run on this model, not chat_model.
variable "agent_tool_model" {
  type = object({
    name     = string
    version  = string
    capacity = number
  })
  default = {
    name     = "gpt-4o"
    version  = "2024-11-20"
    capacity = 50
  }
}

variable "tags" {
  type = map(string)
}

variable "search_shared_link_group_id" {
  description = "Private link group ID on the Foundry account for the Search shared private link."
  type        = string
  default     = "openai_account"
}
