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

variable "private_endpoint_subnet_id" {
  type = string
}

variable "dns_zone_ids" {
  type = map(string)
}

variable "operator_object_id" {
  type = string
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
    capacity = 30
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
    capacity = 30
  }
}

variable "tags" {
  type = map(string)
}
