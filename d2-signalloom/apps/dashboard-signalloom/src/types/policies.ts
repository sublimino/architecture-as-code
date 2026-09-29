export interface PolicyRule {
  id: string
  name: string
  description?: string
  cel_expression: string
  severity?: 'critical' | 'high' | 'medium' | 'low' | string
  remediation?: string
  status?: string
}

export interface PolicyBundle {
  id: string
  framework_id: string
  tenant_id?: string
  version: string
  author: string
  description?: string
  created_at: string
  status?: string
  rules: PolicyRule[]
  raw_bundle?: string
  checksum: string
}

export interface VersionHistoryItem {
  version: string
  author: string
  description: string
  created_at: string
  rule_count: number
  checksum: string
}

export interface PolicyBundleSummary {
  framework_id: string
  tenant_id?: string
  active_version: string
  latest_version: string
  active_bundle: PolicyBundle | null
  version_history: VersionHistoryItem[]
}

export interface RollbackRequest {
  tenant_id?: string
  framework_id: string
  target_version: string
}
