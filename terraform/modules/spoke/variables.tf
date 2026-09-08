variable "name" {
  description = "Spoke name suffix, e.g. fwf-cus."
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "address_space" {
  type = list(string)
}

variable "subnets" {
  description = "Subnet name => { prefixes, delegation }. delegation is a service name or null."
  type = map(object({
    prefixes   = list(string)
    delegation = optional(string)
  }))
}

variable "virtual_hub_id" {
  type = string
}

variable "tags" {
  type = map(string)
}
