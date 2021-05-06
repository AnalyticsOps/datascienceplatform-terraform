output "storage_account_name" {
  value = module.training_data.name
}

output "storage_account_id" {
  value = module.training_data.id
}

output "virtual_network_name" {
  value = azurerm_virtual_network.this.name
}

output "virtual_network_id" {
  value = azurerm_virtual_network.this.id
}
