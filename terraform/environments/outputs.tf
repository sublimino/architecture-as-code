output "environment_keys" {
  description = "Every environment key this root manages, sorted."
  value       = module.env_contract.environment_keys
}

output "demo_keys" {
  description = "Demo environment keys, sorted."
  value       = module.env_contract.demo_keys
}

output "ci_keys" {
  description = "CI lane keys, sorted."
  value       = module.env_contract.ci_keys
}

output "name_prefix" {
  description = "Per-environment resource name prefix. Every module names its resources <name_prefix>-<role>."
  value       = module.env_contract.name_prefix
}

output "mandatory_labels" {
  description = "Per-environment label set applied to every resource."
  value       = module.env_contract.mandatory_labels
}

output "resolved_environments" {
  description = "Fully resolved per-environment inputs, exactly as the sibling modules will receive them."
  value       = module.env_contract.environments
}

output "uptime_targets" {
  description = "Input for modules/observability: hostname and app_port for DNS-enabled environments."
  value       = module.env_contract.uptime_targets
}

output "integration_inputs" {
  description = "Root-level knobs the commented integration blocks in main.tf will consume. Reviewable before any sibling module exists."
  value       = local.integration_inputs
}
