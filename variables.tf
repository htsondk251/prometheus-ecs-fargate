variable "account" {}
variable "ssh_key" {}
variable "prometheus_config_location" {
  type = string
  default = "https://tomgregory-cloudformation-resources.s3-eu-west-1.amazonaws.com/prometheus.yml"
}