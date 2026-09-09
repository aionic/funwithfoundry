resource "random_password" "jumpbox" {
  length           = 24
  special          = true
  override_special = "!#$%*()-_=+[]{}"
}

resource "azurerm_public_ip" "bastion" {
  name                = "pip-${var.name}-bastion"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags

  lifecycle {
    # Azure stamps ip_tags {FirstPartyUsage = "/Unprivileged"} on Bastion public IPs
    # server-side. Without this, every plan wants to strip it and force a rebuild of
    # both the IP and the Bastion host behind it.
    ignore_changes = [ip_tags]
  }
}

# Standard SKU is required for native-client tunneling (RDP from a local terminal
# and port forwarding), which Developer and Basic do not support.
resource "azurerm_bastion_host" "this" {
  name                = "bas-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"
  tunneling_enabled   = true
  tags                = var.tags

  ip_configuration {
    name                 = "configuration"
    subnet_id            = var.bastion_subnet_id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

resource "azurerm_network_interface" "jumpbox" {
  name                = "nic-${var.name}-jump"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.jumpbox_subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_windows_virtual_machine" "jumpbox" {
  name                  = "vm-${var.name}-jump"
  resource_group_name   = var.resource_group_name
  location              = var.location
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = random_password.jumpbox.result
  network_interface_ids = [azurerm_network_interface.jumpbox.id]
  tags                  = var.tags

  # 2025-datacenter-azure-edition is hotpatch-enabled and rejects any other patch mode.
  patch_mode                                             = "AutomaticByPlatform"
  bypass_platform_safety_checks_on_user_schedule_enabled = true

  # No public IP by design - Bastion is the only way in.
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2025-datacenter-azure-edition"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }
}
