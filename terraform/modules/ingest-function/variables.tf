variable "prefix" {
  type = string
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
