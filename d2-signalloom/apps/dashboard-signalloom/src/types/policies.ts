export interface PolicyRule {
  id: string
  name: string
  description?: string
  cel_expression: string
  severity?: 'critical' | 'high' | 'medium' | 'low' | string
  remediation?: string
  status?: string
  docs_url?: string
  tested_separately?: boolean
  tested_separately_note?: string
  attestation_type?: 'cel' | 'manual' | 'cluster' | string
  manual_attestation?: boolean
  manual_attestation_note?: string
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
  official_docs_url?: string
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
