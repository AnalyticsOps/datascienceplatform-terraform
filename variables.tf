variable "project_name" {
  type = string
}

variable "resource_number" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "environment_name" {
  type = string
}

variable "client_id" {
  type = string
}

variable "client_secret" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "subnets_whitelist" {
  type = list
  default = []
}

variable "training_data_container_name" {
  type = string
  default = "trainingdata"
}
