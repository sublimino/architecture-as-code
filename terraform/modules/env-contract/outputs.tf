output "environments" {
  description = "Resolved per-environment values, keyed by environment key. Field names match the module input names in CONTRACT.md §4 so a root can for_each over this map directly."
  value       = local.resolved
}

output "environment_keys" {
  description = "All environment keys, sorted. Stable ordering keeps plan output diffable."
  value       = sort(keys(var.environments))
}

output "demo_keys" {
  description = "Keys whose kind is \"demo\", sorted."
  value       = sort([for k, v in var.environments : k if v.kind == "demo"])
}

output "ci_keys" {
  description = "Keys whose kind is \"ci\", sorted."
  value       = sort([for k, v in var.environments : k if v.kind == "ci"])
}

output "name_prefix" {
  description = "Per-environment resource name prefix. Every resource in every module is named <name_prefix>-<role>."
  value       = local.name_prefix
}

output "mandatory_labels" {
  description = "Per-environment label set: the four mandatory labels with the entry's own labels merged over them."
  value       = local.mandatory_labels
}

output "uptime_targets" {
  description = "Input for modules/observability: hostname and app_port for every environment that has DNS enabled."
  value = {
    for k, v in var.environments : k => {
      hostname = v.hostname
      app_port = v.app_port
    } if v.hostname != ""
  }
}
