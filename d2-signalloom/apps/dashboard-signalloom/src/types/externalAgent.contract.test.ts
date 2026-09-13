import { describe, expect, it } from 'vitest'
import type { ExternalAgentEnrollmentV1, ExternalAgentEvidenceV1, ExternalAgentEvidenceV1Artifact, ExternalAgentPrivacyV1, ExternalAgentRevocationV1, ExternalAgentServerProjectionV1Error, ExternalAgentServerProjectionV1EvidenceItem, ExternalAgentServerProjectionV1IntegrityResult, ExternalAgentServerProjectionV1ServerEvidence, ExternalAgentServerProjectionV1UploadResult, ExternalAgentUploadV1 } from './externalAgent'

describe('external agent generated contracts', () => {
  // @ts-expect-error verified integrity requires a digest, positive count, and verified reason
  const contradictoryVerified: ExternalAgentServerProjectionV1IntegrityResult = { authority: 'agentnono-go-v1', session_id: 'session-001', event_count: 0, final_digest: null, state: 'integrity-verified', evaluated_at: '2026-09-13T10:00:00Z', reason: 'event-tampered' }
  // @ts-expect-error tampered integrity requires a tamper reason and non-null digest
  const contradictoryTampered: ExternalAgentServerProjectionV1IntegrityResult = { authority: 'agentnono-go-v1', session_id: 'session-001', event_count: 0, final_digest: null, state: 'tampered', evaluated_at: '2026-09-13T10:00:00Z', reason: 'verified' }
  void contradictoryVerified
  void contradictoryTampered
  const integrityCount = (result: ExternalAgentServerProjectionV1IntegrityResult): string => result.event_count.toFixed(0)
  void integrityCount
  it('keeps inbound claims separate from server integrity', () => {
    const inbound: keyof ExternalAgentUploadV1 = 'original_chain_reference'
    const authority: ExternalAgentServerProjectionV1IntegrityResult['authority'] = 'agentnono-go-v1'
    expect([inbound, authority]).toEqual(['original_chain_reference', 'agentnono-go-v1'])
  })
  it('contains enrollment and frozen privacy projections', () => {
    const algorithm: ExternalAgentEnrollmentV1['key_algorithm'] = 'Ed25519'
    const exported: ExternalAgentPrivacyV1['raw_paths_exported'] = false
    expect([algorithm, exported]).toEqual(['Ed25519', false])
  })
  it('separates inbound provenance from upload acknowledgement facts', () => {
    const inboundSource: ExternalAgentEvidenceV1['source'] = 'host-sensor-v1'
    const inboundIntegrity: ExternalAgentEvidenceV1['integrity_state'] = 'not-integrity-verified'
    const serverSource: ExternalAgentServerProjectionV1ServerEvidence['source'] = 'host-sensor-v1'
    const serverIntegrity: ExternalAgentServerProjectionV1ServerEvidence['integrity_state'] = 'not-integrity-verified'
    const hostSignature: ExternalAgentServerProjectionV1UploadResult['host_signature_state'] = 'host-signature-verified'
    const originalChain: ExternalAgentServerProjectionV1UploadResult['original_chain_state'] = 'original-chain-not-verified'
    const mtime: ExternalAgentEvidenceV1Artifact['mtime_ns'] = '18446744073709551615'
    expect([inboundSource, inboundIntegrity, serverSource, serverIntegrity, hostSignature, originalChain, mtime]).toHaveLength(7)
  })
  it('narrows host and server attributes through evidence discriminators', () => {
    const hostValue = (evidence: ExternalAgentEvidenceV1): string => {
      switch (evidence.evidence_type) {
        case 'process': return evidence.attributes.health_state
        case 'artifact': return evidence.attributes.sha256
        case 'network': return evidence.attributes.destination_id
        case 'collection-limit': {
          const state: 'unobserved' = evidence.observation_state
          return `${state}:${evidence.attributes.reason_code}`
        }
      }
    }
    const serverValue = (evidence: ExternalAgentServerProjectionV1ServerEvidence): string => {
      switch (evidence.evidence_type) {
        case 'process': return evidence.attributes.health_state
        case 'artifact': return evidence.attributes.sha256
        case 'network': return evidence.attributes.destination_id
        case 'collection-limit': return evidence.attributes.reason_code
      }
    }
    expect([hostValue, serverValue]).toHaveLength(2)
  })
  it('separates acceptance, revocation, and errors from host evidence', () => {
    const evidence: keyof ExternalAgentServerProjectionV1EvidenceItem = 'evidence'
    const acceptance: keyof ExternalAgentServerProjectionV1EvidenceItem = 'acceptance'
    const reason: ExternalAgentRevocationV1['reason_code'] = 'credential-compromise'
    const error: ExternalAgentServerProjectionV1Error['error_code'] = 'validation-failed'
    expect([evidence, acceptance, reason, error]).toHaveLength(4)
  })
})
