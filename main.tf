terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=2.29.0"
    }
  }
}

locals {
  resource_postfix             = "${var.project_name}-${var.resource_number}"
  resource_postfix_restricted  = "${var.project_name}${var.resource_number}"
}

data "azurerm_resource_group" "this" {
  name     = var.resource_group_name
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${local.resource_postfix}"
  address_space       = ["10.0.0.0/16"]
  location            = data.azurerm_resource_group.this.location
  resource_group_name = data.azurerm_resource_group.this.name
}

resource "azurerm_subnet" "amlcompute_subnet" {
  name                 = "snet-compute-aml"
  resource_group_name  = data.azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.0.1.0/24"]
  service_endpoints    = ["Microsoft.Storage"]
}

module "training_data" {
  source                   = "git@ssh.dev.azure.com:v3/energinet/CCoE/azure-stor-module?ref=1.4"
  name                     = "stordata${local.resource_postfix_restricted}"
  resource_group_name      = data.azurerm_resource_group.this.name
  location                 = data.azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  access_tier              = "Hot"
  is_hns_enabled           = true
  containers = [
    {
      name        = var.training_data_container_name
      access_type = "private"
    }
  ]
}


// Network access restrictions on data storage account
resource "azurerm_storage_account_network_rules" "this" {
  resource_group_name  = data.azurerm_resource_group.this.name
  storage_account_name = module.training_data.name

  default_action             = "Deny"
  ip_rules                   = ["194.239.2.0/24"]
  virtual_network_subnet_ids = concat(
    [azurerm_subnet.amlcompute_subnet.id, "/subscriptions/2c63e008-0007-4b92-bfe5-b1fdc94697d5/resourceGroups/analytics-ops-devops-agents/providers/Microsoft.Network/virtualNetworks/vnet-devops-agent-001/subnets/agent-subnet"],
    var.subnets_whitelist
  )
  bypass                     = ["Metrics"]
}

resource "azurerm_container_registry" "model_images" {
  name                    = "cr${local.resource_postfix_restricted}"
  location                = data.azurerm_resource_group.this.location
  resource_group_name     = data.azurerm_resource_group.this.name
  sku                     = "Premium"
  admin_enabled           = true
}


module "aml_sa" {
  source                   = "git@ssh.dev.azure.com:v3/energinet/CCoE/azure-stor-module?ref=1.4"
  name                     = "storaml${local.resource_postfix_restricted}"
  resource_group_name      = data.azurerm_resource_group.this.name
  location                 = data.azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  access_tier              = "Hot"
  is_hns_enabled           = false
}

module "aml_appi" {
  source                   = "git@ssh.dev.azure.com:v3/energinet/CCoE/azure-appi-module?ref=1.1"
  name                     = "appi-aml-${local.resource_postfix}"
  resource_group_name      = data.azurerm_resource_group.this.name
  location                 = data.azurerm_resource_group.this.location
  application_type         = "other"
}

module "aml_kv" {
  source                   = "git@ssh.dev.azure.com:v3/energinet/CCoE/azure-kv-module?ref=purge"
  name                     = "kv-aml-${local.resource_postfix}"
  resource_group_name      = data.azurerm_resource_group.this.name
  location                 = data.azurerm_resource_group.this.location
  soft_delete_enabled      = true
}

resource "azurerm_container_registry" "aml_acr" {
  name                     = "craml${local.resource_postfix_restricted}"
  resource_group_name      = data.azurerm_resource_group.this.name
  location                 = data.azurerm_resource_group.this.location
  sku                      = "Premium"
  admin_enabled            = true
}


resource "azurerm_machine_learning_workspace" "aml" {
  name                    = "aml-${local.resource_postfix}"
  resource_group_name     = data.azurerm_resource_group.this.name
  location                = data.azurerm_resource_group.this.location
  application_insights_id = module.aml_appi.id
  key_vault_id            = module.aml_kv.id
  storage_account_id      = module.aml_sa.id
  container_registry_id   = azurerm_container_registry.aml_acr.id

  identity {
    type = "SystemAssigned"
  }

  tags = {
    vnet_name               = azurerm_virtual_network.this.name
    subnet_name             = azurerm_subnet.amlcompute_subnet.name
    storage_account_name    = azurerm_storage_account_network_rules.this.storage_account_name
    container_registry_name = azurerm_container_registry.aml_acr.name
  }

  /*
   * The following code attaches the training-data storage account
   * as a datastore on the Machine Learning Workspace.
   */
  provisioner "local-exec" {
    interpreter = ["pwsh", "-Command"]
    command = <<EOT
      trap {
          write-output $_
          exit 1
      }

      az config set extension.use_dynamic_install=yes_without_prompt
      az login --service-principal --username ${var.client_id} --password ${var.client_secret} --tenant ${var.tenant_id}

      if ( $(az ml datastore list -g ${data.azurerm_resource_group.this.name} -w ${azurerm_machine_learning_workspace.aml.name} --query "[?name == '${var.training_data_container_name}'].name") -eq '[]') {
        $accountkey = az storage account keys list --account-name ${module.training_data.name} -g ${data.azurerm_resource_group.this.name} --query [0].value
        az ml datastore attach-blob --account-name ${module.training_data.name} --container-name ${var.training_data_container_name} --name ${var.training_data_container_name} -g ${data.azurerm_resource_group.this.name} -w ${azurerm_machine_learning_workspace.aml.name} -k $accountkey
        az ml datastore set-default --name ${var.training_data_container_name} -g ${data.azurerm_resource_group.this.name} -w ${azurerm_machine_learning_workspace.aml.name}
      }
    EOT
  }
}
