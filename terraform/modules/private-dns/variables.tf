variable "zones" {
  description = "Private DNS zone names to create."
  type        = list(string)
}

variable "resource_group_name" {
  type = string
}

variable "linked_vnet_ids" {
  description = "Short key => VNet resource ID. Every zone is linked to every VNet here."
  type        = map(string)
}

variable "tags" {
  type = map(string)
}
