module "leaky_bucket" {
  source = "../leaky-bucket"
}

module "leaky_secret" {
  source = "../leaky-secret"
}

module "clean" {
  source = "../clean-module"
}
