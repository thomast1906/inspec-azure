terraform {
  required_version = "~> 0.12.0"
}

provider "azurerm" {
  version         = "~> 1.36.0"
  subscription_id = var.subscription_id
  client_id       = var.client_id
  client_secret   = var.client_secret
  tenant_id       = var.tenant_id
}

provider "random" {
  version = "~> 2.2.1"
}

data "azurerm_client_config" "current" {}

data "azurerm_role_definition" "contributor" {
  name = "Contributor"
}

resource "azurerm_resource_group" "rg" {
  name     = "Inspec-Azure-${terraform.workspace}"
  location = var.location
  tags = {
    CreatedBy  = terraform.workspace
    ExampleTag = "example"
  }
}

resource "azurerm_container_registry" "acr" {
  name                     = var.container_registry_name
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  sku                      = "Basic"
}

resource "azurerm_management_group" "mg_parent" {
  count = var.management_group_count
  group_id = "mg_parent"
  display_name = "Management Group Parent"
}

resource "azurerm_management_group" "mg_child_one" {
  count = var.management_group_count
  group_id = "mg_child_one"
  display_name = "Management Group Child 1"
  parent_management_group_id = azurerm_management_group.mg_parent.0.id
}

resource "azurerm_management_group" "mg_child_two" {
  count = var.management_group_count
  group_id = "mg_child_two"
  display_name = "Management Group Child 2"
  parent_management_group_id = azurerm_management_group.mg_parent.0.id
}

resource "random_string" "password" {
  length           = 16
  upper            = true
  lower            = true
  special          = true
  override_special = "/@\" "
  min_numeric      = 3
  min_special      = 3
}

resource "azurerm_network_watcher" "rg" {
  name                = "${azurerm_resource_group.rg.name}-netwatcher"
  count               = var.network_watcher_count
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags = {
    CreatedBy = terraform.workspace
  }
}

resource "random_string" "storage_account" {
  length  = 10
  special = false
  upper   = false
}

resource "azurerm_storage_account" "sa" {
  name                      = random_string.storage_account.result
  location                  = var.location
  resource_group_name       = azurerm_resource_group.rg.name
  enable_https_traffic_only = true
  account_tier              = "Standard"
  account_replication_type  = "LRS"
  depends_on                = [azurerm_resource_group.rg]
  tags = {
    user = terraform.workspace
  }
}

resource "azurerm_storage_container" "container" {
  name                  = "vhds"
  storage_account_name  = azurerm_storage_account.sa.name
  container_access_type = "private"
}

resource "random_pet" "blob_name" {
  length    = 2
  prefix    = "blob"
  separator = "-"
}

resource "azurerm_storage_container" "blob" {
  name                  = random_pet.blob_name.id
  storage_account_name  = azurerm_storage_account.sa.name
  container_access_type = "private"
}

resource "random_pet" "vault" {
  length    = 2
  prefix    = "vault"
  separator = "-"
}

resource "azurerm_key_vault" "disk_vault" {
  name                = random_pet.vault.id
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  tenant_id           = var.tenant_id
  sku_name            = "premium"

  access_policy {
    tenant_id = var.tenant_id
    object_id = data.azurerm_client_config.current.service_principal_object_id

    key_permissions = [
      "create",
      "delete",
      "encrypt",
      "get",
      "import",
      "list",
      "sign",
      "unwrapKey",
      "verify",
      "wrapKey",
    ]

    secret_permissions = [
      "delete",
      "get",
      "list",
      "set",
    ]
  }

  enabled_for_disk_encryption = true
}

resource "azurerm_key_vault_secret" "vs" {
  name         = "secret"
  value        = random_string.password.result
  key_vault_id = azurerm_key_vault.disk_vault.id
}

resource "azurerm_key_vault_key" "vk" {
  name         = "key"
  key_vault_id = azurerm_key_vault.disk_vault.id
  key_type     = "EC"
  key_size     = 2048

  key_opts = [
    "sign",
    "verify",
  ]
}

resource "azurerm_managed_disk" "disk" {
  name                = var.encrypted_disk_name
  resource_group_name = azurerm_resource_group.rg.name

  location = var.location

  storage_account_type = var.managed_disk_type
  create_option        = "Empty"
  disk_size_gb         = 1

  encryption_settings {
    enabled = true
    disk_encryption_key {
      secret_url      = azurerm_key_vault_secret.vs.id
      source_vault_id = azurerm_key_vault.disk_vault.id
    }
    key_encryption_key {
      key_url         = azurerm_key_vault_key.vk.id
      source_vault_id = azurerm_key_vault.disk_vault.id
    }
  }
}

resource "azurerm_network_security_group" "nsg" {
  name                = "Inspec-NSG"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_network_security_group" "nsg_insecure" {
  name                = "Inspec-NSG-Insecure"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_network_security_rule" "SSHAllow" {
  name                        = "SSH-Allow"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nsg_insecure.name
}

resource "azurerm_network_security_rule" "RDP-Allow" {
  name                        = "RDP-Allow"
  priority                    = 105
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nsg_insecure.name
}

resource "azurerm_network_security_rule" "DB-Allow" {
  name                        = "DB-Allow"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_ranges     = ["1433-1434", "1521", "4300-4350", "5000-6000"]
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nsg_insecure.name
}

resource "azurerm_network_security_rule" "File-Allow" {
  name                        = "File-Allow"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_ranges     = ["130-140", "445", "20-21", "69"]
  source_address_prefix       = "0.0.0.0/0"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nsg_insecure.name
}

resource "azurerm_network_security_group" "nsg_open" {
  name                = "Inspec-NSG-Open"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  security_rule {
    name                       = "Open-All-To-World"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_virtual_network" "vnet" {
  name                = "Inspec-VNet"
  address_space       = ["10.1.1.0/24"]
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
}

data "azurerm_virtual_network" "vnet" {
  name                = azurerm_virtual_network.vnet.name
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet" {
  name                 = "Inspec-Subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefix       = "10.1.1.0/24"
  # "Soft" deprecated, required until v2 of azurerm provider:
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_subnet_network_security_group_association" "subnet_nsg" {
  network_security_group_id = azurerm_network_security_group.nsg.id
  subnet_id                 = azurerm_subnet.subnet.id
}

resource "azurerm_network_interface" "nic1" {
  name                = "Inspec-NIC-1"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipConfiguration1"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "dynamic"
  }
}

resource "azurerm_network_interface" "nic3" {
  name                = "Inspec-NIC-3"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipConfiguration1"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "dynamic"
  }
}

resource "azurerm_virtual_machine" "vm_linux_internal" {
  name                  = "Linux-Internal-VM"
  location              = var.location
  resource_group_name   = azurerm_resource_group.rg.name
  network_interface_ids = [azurerm_network_interface.nic1.id]
  vm_size               = "Standard_DS2_v2"

  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "16.04.0-LTS"
    version   = "latest"
  }

  storage_os_disk {
    name          = var.linux_internal_os_disk
    vhd_uri       = "${azurerm_storage_account.sa.primary_blob_endpoint}${azurerm_storage_container.container.name}/linux-internal-osdisk.vhd"
    caching       = "ReadWrite"
    create_option = "FromImage"
  }

  storage_data_disk {
    name          = var.unmanaged_data_disk_name
    vhd_uri       = "${azurerm_storage_account.sa.primary_blob_endpoint}${azurerm_storage_container.container.name}/linux-internal-datadisk-1.vhd"
    disk_size_gb  = 15
    create_option = "empty"
    lun           = 0
  }

  os_profile {
    computer_name  = "linux-internal-1"
    admin_username = "azure"
    admin_password = random_string.password.result
  }

  os_profile_linux_config {
    disable_password_authentication = false
  }

  boot_diagnostics {
    enabled     = true
    storage_uri = azurerm_storage_account.sa.primary_blob_endpoint
  }
}

resource "azurerm_virtual_machine" "vm_windows_internal" {
  name                  = "Windows-Internal-VM"
  location              = var.location
  resource_group_name   = azurerm_resource_group.rg.name
  network_interface_ids = [azurerm_network_interface.nic3.id]
  vm_size               = "Standard_DS2_v2"

  storage_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2016-Datacenter"
    version   = "latest"
  }

  storage_os_disk {
    name              = var.windows_internal_os_disk
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }

  storage_data_disk {
    name              = var.windows_internal_data_disk
    create_option     = "Empty"
    managed_disk_type = "Standard_LRS"
    lun               = 0
    disk_size_gb      = "1024"
  }

  os_profile {
    computer_name  = "win-internal-1"
    admin_username = "azure"
    admin_password = random_string.password.result
  }

  os_profile_windows_config {
    provision_vm_agent = true
  }
}

resource "random_pet" "workspace" {
  length = 2
}

resource "azurerm_log_analytics_workspace" "workspace" {
  name                = random_pet.workspace.id
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"
  retention_in_days   = 30
}

resource "azurerm_virtual_machine_extension" "log_extension" {
  name                 = var.monitoring_agent_name
  location             = var.location
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_machine_name = azurerm_virtual_machine.vm_windows_internal.name
  publisher            = "Microsoft.EnterpriseCloud.Monitoring"
  type                 = "MicrosoftMonitoringAgent"
  type_handler_version = "1.0"

  settings = <<SETTINGS
    {
      "workspaceId": "${azurerm_log_analytics_workspace.workspace.workspace_id}"
    }
SETTINGS

  protected_settings = <<PROTECTED_SETTINGS
    {
      "workspaceKey": "${azurerm_log_analytics_workspace.workspace.primary_shared_key}"
    }
PROTECTED_SETTINGS
}

# Only one log_profile can be created per subscription if this fails run:
# az monitor log-profiles list --query [*].[id,name]
# the default log_profile should be deleted to enable this TF to work:
# az monitor log-profiles delete --name default
resource "azurerm_monitor_log_profile" "log_profile" {
  name = "default"

  categories = [
    "Action",
    "Write",
  ]

  locations = [
    "eastus",
    "global",
  ]

  storage_account_id = azurerm_storage_account.sa.id

  retention_policy {
    enabled = true
    days    = 365
  }
  depends_on = [azurerm_storage_account.sa]
}

# MSI External Access VM
# Use only when testing MSI access controls
resource "azurerm_public_ip" "public_ip" {
  name                = "Inspec-PublicIP-1"
  count               = var.public_vm_count
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Dynamic"
}

resource "azurerm_network_interface" "nic2" {
  name                = "Inspec-NIC-2"
  count               = var.public_vm_count
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipConfiguration1"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "dynamic"
    public_ip_address_id          = azurerm_public_ip.public_ip[0].id
  }
}

resource "azurerm_virtual_machine" "vm_linux_external" {
  name                  = "Linux-External-VM"
  count                 = var.public_vm_count
  location              = var.location
  resource_group_name   = azurerm_resource_group.rg.name
  network_interface_ids = [azurerm_network_interface.nic2[0].id]
  vm_size               = "Standard_DS2_v2"

  tags = {
    Description = "Externally facing Linux machine with SSH access"
  }

variable "functionapp" {
  type = "string"
  default = "../test/fixtures/functionapp.zip"
}

resource "azurerm_subnet" "backend" {
  name                 = "backend"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.app-gw.name
  address_prefix       = "10.254.2.0/24"
}

resource "azurerm_public_ip" "test" {
  name  = "example-pip"
  resource_group_name = azurerm_resource_group.rg.name
  location = azurerm_resource_group.rg.location
  allocation_method = "Dynamic"
}

# since these variables are re-used - a locals block makes this more maintainable
locals {
  backend_address_pool_name      = "${azurerm_virtual_network.app-gw.name}-beap"
  frontend_port_name             = "${azurerm_virtual_network.app-gw.name}-feport"
  frontend_ip_configuration_name = "${azurerm_virtual_network.app-gw.name}-feip"
  http_setting_name              = "${azurerm_virtual_network.app-gw.name}-be-htst"
  listener_name                  = "${azurerm_virtual_network.app-gw.name}-httplstn"
  request_routing_rule_name      = "${azurerm_virtual_network.app-gw.name}-rqrt"
  redirect_configuration_name    = "${azurerm_virtual_network.app-gw.name}-rdrcfg"
}

resource "random_string" "appgw-random" {
  length  = 10
  special = false
  upper   = false
}

resource "azurerm_application_gateway" "network" {
  name                = "${random_string.appgw-random.result}-appgw"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  sku {
    name     = "Standard_Small"
    tier     = "Standard"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "my-gateway-ip-configuration"
    subnet_id = azurerm_subnet.frontend.id
  }

  frontend_port {
    name = local.frontend_port_name
    port = 443
  }

  frontend_ip_configuration {
    name                 = local.frontend_ip_configuration_name
    public_ip_address_id = azurerm_public_ip.test.id
  }

  backend_address_pool {
    name = local.backend_address_pool_name
  }

  backend_http_settings {
    name                  = local.http_setting_name
    cookie_based_affinity = "Disabled"
    path                  = "/path1/"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 1
  }

  ssl_certificate {
    name     = "inspec.example.com"
    data     = filebase64("app-gw/inspec.example.com.pfx")
    password = "InSpec1234"
  }

  http_listener {
    name                           = local.listener_name
    frontend_ip_configuration_name = local.frontend_ip_configuration_name
    frontend_port_name             = local.frontend_port_name
    protocol                       = "Https"
    ssl_certificate_name           = "inspec.example.com"
  }

  request_routing_rule {
    name                        = local.request_routing_rule_name
    rule_type                   = "Basic"
    http_listener_name          = local.listener_name
    redirect_configuration_name = local.redirect_configuration_name
  }

  redirect_configuration {
    name          = local.redirect_configuration_name
    target_url    = "http://example.com"
    redirect_type = "Permanent"
  }

  ssl_policy {
    # https://docs.microsoft.com/en-us/azure/application-gateway/application-gateway-ssl-policy-overview
    # disabled_protocols   = ["TLSv1_0", "TLSv1_1"]
    # min_protocol_version = "TLSv1_2"
    policy_name = "AppGwSslPolicy20170401S"
    policy_type = "Predefined"
  }
}

resource "random_string" "ip-address-random" {
  length  = 10
  special = false
  upper   = false
}

resource "azurerm_public_ip" "public_ip_address" {
  count               = var.public_ip_count
  name                = random_string.ip-address-random.result
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Dynamic"
}

resource "random_string" "apim-random" {
  length  = 10
  special = false
  upper   = false
}

resource "azurerm_api_management" "apim01" {
  count               = var.api_management_count
  name                = "apim-${random_string.apim-random.result}"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  publisher_name      = "My Inspec"
  publisher_email     = "company@inspec.io"

  sku_name = "Developer_1"

  policy {
    xml_content = <<XML
    <policies>
      <inbound />
      <backend />
      <outbound />
      <on-error />
    </policies>
XML

  }
}

resource "azurerm_storage_account" "web_app_function_db" {
  name                     = "functions_app${random_string.storage_account.result}"
  location                 = var.location
  resource_group_name      = azurerm_resource_group.rg.name
  account_tier             = "Standard"
  account_replication_type = "LRS"
  depends_on               = [azurerm_resource_group.rg]
  tags = {
    user = terraform.workspace
  }
}

resource "azurerm_app_service_plan" "web_app_function_app_service" {
  name                = "functions_app_service${random_pet.workspace.id}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags = {
    user = terraform.workspace
  }

  sku {
    tier = "Free"
    size = "F1"
  }
}

resource "azurerm_function_app" "web_app_function" {
  name                       = "functions_function_app${random_pet.workspace.id}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  app_service_plan_id        = azurerm_app_service_plan.web_app_function_app_service.id
  storage_connection_string  = azurerm_storage_account.web_app_function_db.primary_connection_string
  tags = {
    user = terraform.workspace
  }
}