variable "prefix" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "primary_region" {
  type = string
}

variable "secondary_region" {
  type = string
}

variable "hub_prefix_primary" {
  type = string
}

variable "hub_prefix_secondary" {
  type = string
}

variable "spoke_address_spaces" {
  description = "All spoke CIDRs, used as the source set for egress rules."
  type        = list(string)
}

variable "jumpbox_subnet_prefixes" {
  description = "Jumpbox subnet CIDRs, scoped separately so browser egress is not granted to the whole estate."
  type        = list(string)
}

variable "tags" {
  type = map(string)
}
