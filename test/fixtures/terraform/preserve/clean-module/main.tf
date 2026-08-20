# How modules/compute really does it: the auth key is created out of band and
# read, never declared. A destroy of this module cannot remove it.
data "google_secret_manager_secret" "authkey" {
  secret_id = var.authkey_secret_id
}

variable "authkey_secret_id" {
  type = string
}

output "authkey_name" {
  value = data.google_secret_manager_secret.authkey.name
}
