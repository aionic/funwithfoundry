variable "subscription_id" {
  description = "Target Azure subscription ID."
  type        = string
}

variable "prefix" {
  description = "Short name prefix for all resources. Lowercase alphanumeric."
  type        = string
  default     = "fwf"

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.prefix))
    error_message = "prefix must be 2-8 lowercase alphanumeric characters."
  }
}

variable "primary_region" {
  description = "Region for the private network-injected Foundry agent platform."
  type        = string
  default     = "centralus"
}

variable "secondary_region" {
  description = "Region for the Content Understanding Foundry instance."
  type        = string
  default     = "southcentralus"
}

variable "jumpbox_size" {
  description = "VM size for the Windows jumpbox."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "jumpbox_admin_username" {
  description = "Local administrator username for the jumpbox."
  type        = string
  default     = "fwfadmin"
}

variable "my_object_id" {
  description = "Object ID of the operator, granted data-plane roles for hands-on testing. Defaults to the current client."
  type        = string
  default     = ""
}

variable "native_agent_principal_id" {
  description = "Object ID of the deployed native hosted agent identity. Leave empty until its first deployment."
  type        = string
  default     = ""

  validation {
    condition     = var.native_agent_principal_id == "" || can(regex("^[0-9a-fA-F-]{36}$", var.native_agent_principal_id))
    error_message = "native_agent_principal_id must be empty or a UUID."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    workload    = "funwithfoundry"
    environment = "lab"
    managed_by  = "terraform"
  }
}

variable "sharepoint_hostname" {
  type        = string
  description = "SharePoint tenant hostname, e.g. contoso.sharepoint.com."
  default     = ""
}

variable "sharepoint_site_path" {
  type        = string
  description = "Server-relative site path. Use / for the root site."
  default     = "/"
}

variable "sharepoint_file_path" {
  type        = string
  description = "Document path within the site default drive."
  default     = ""
}
