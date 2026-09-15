import { describe, it, expect } from 'vitest';
import {
  STAGE_IDS,
  STAGE_METADATA,
  INITIAL_STEPPER_STATE,
  isValidTransition,
  getLegalNextStages,
  getStageIndex,
  nextState,
  executeAsyncGate,
  isNavigationDisabled,
  canNavigateTo,
  isStageComplete,
  isStageFailed,
  AUTO_PLAY_DWELL_MS,
  type DemoStepperState,
  type StageFailurePayload,
  type OperatorInitPayload,
  type HostEnrolledPayload,
  type ConfinementStreamingPayload,
  type AdversarialTamperPayload,
  type RevocationDeniedPayload,
} from './types';

describe('AgentMaxxing Demo State Machine Types & Contract', () => {
  describe('Stage Definitions & Ordering', () => {
    it('defines exactly the 5 canonical stages in strict order', () => {
      expect(STAGE_IDS).toEqual([
        'operator_init',
        'host_enrolled',
        'confinement_streaming',
        'adversarial_tamper',
        'revocation_denied',
      ]);
      expect(STAGE_IDS).toHaveLength(5);
    });

    it('provides metadata and owning card mapping for all stages', () => {
      for (const stage of STAGE_IDS) {
        const meta = STAGE_METADATA[stage];
        expect(meta).toBeDefined();
        expect(meta.id).toBe(stage);
        expect(meta.stepNumber).toBeGreaterThanOrEqual(1);
        expect(meta.stepNumber).toBeLessThanOrEqual(5);
        expect(meta.title).toBeTruthy();
        expect(meta.owningCard).toBeTruthy();
      }

      expect(STAGE_METADATA.operator_init.owningCard).toBe('AMXD-P2-2');
      expect(STAGE_METADATA.host_enrolled.owningCard).toBe('AMXD-P2-2');
      expect(STAGE_METADATA.confinement_streaming.owningCard).toBe('AMXD-P3-1 & AMXD-P3-2');
      expect(STAGE_METADATA.adversarial_tamper.owningCard).toBe('AMXD-P4-1');
      expect(STAGE_METADATA.revocation_denied.owningCard).toBe('AMXD-P4-2');
    });

    it('returns correct stage index', () => {
      expect(getStageIndex('operator_init')).toBe(0);
      expect(getStageIndex('host_enrolled')).toBe(1);
      expect(getStageIndex('confinement_streaming')).toBe(2);
      expect(getStageIndex('adversarial_tamper')).toBe(3);
      expect(getStageIndex('revocation_denied')).toBe(4);
    });

    it('provides pacing dwell durations for Auto-Play', () => {
      expect(AUTO_PLAY_DWELL_MS['1x']).toBe(4000);
      expect(AUTO_PLAY_DWELL_MS['2x']).toBe(2000);
      expect(AUTO_PLAY_DWELL_MS.instant).toBe(100);
    });
  });

  describe('Transition Table & Validation Rules', () => {
    it('permits strictly forward sequential progression', () => {
      expect(isValidTransition('operator_init', 'host_enrolled')).toBe(true);
      expect(isValidTransition('host_enrolled', 'confinement_streaming')).toBe(true);
      expect(isValidTransition('confinement_streaming', 'adversarial_tamper')).toBe(true);
      expect(isValidTransition('adversarial_tamper', 'revocation_denied')).toBe(true);
    });

    it('permits Reset Estate from any stage back to operator_init', () => {
      for (const stage of STAGE_IDS) {
        expect(isValidTransition(stage, 'operator_init')).toBe(true);
      }
    });

    it('rejects skipping stages forward', () => {
      expect(isValidTransition('operator_init', 'confinement_streaming')).toBe(false);
      expect(isValidTransition('operator_init', 'adversarial_tamper')).toBe(false);
      expect(isValidTransition('operator_init', 'revocation_denied')).toBe(false);
      expect(isValidTransition('host_enrolled', 'adversarial_tamper')).toBe(false);
      expect(isValidTransition('host_enrolled', 'revocation_denied')).toBe(false);
      expect(isValidTransition('confinement_streaming', 'revocation_denied')).toBe(false);
    });

    it('rejects backward transitions other than Reset Estate', () => {
      expect(isValidTransition('confinement_streaming', 'host_enrolled')).toBe(false);
      expect(isValidTransition('adversarial_tamper', 'confinement_streaming')).toBe(false);
      expect(isValidTransition('adversarial_tamper', 'host_enrolled')).toBe(false);
      expect(isValidTransition('revocation_denied', 'adversarial_tamper')).toBe(false);
      expect(isValidTransition('revocation_denied', 'confinement_streaming')).toBe(false);
      expect(isValidTransition('revocation_denied', 'host_enrolled')).toBe(false);
    });

    it('rejects self-transitions for non-init stages', () => {
      expect(isValidTransition('host_enrolled', 'host_enrolled')).toBe(false);
      expect(isValidTransition('confinement_streaming', 'confinement_streaming')).toBe(false);
      expect(isValidTransition('adversarial_tamper', 'adversarial_tamper')).toBe(false);
      expect(isValidTransition('revocation_denied', 'revocation_denied')).toBe(false);
    });

    it('enumerates legal next stages accurately', () => {
      expect(getLegalNextStages('operator_init')).toEqual(['host_enrolled', 'operator_init']);
      expect(getLegalNextStages('host_enrolled')).toEqual(['confinement_streaming', 'operator_init']);
      expect(getLegalNextStages('confinement_streaming')).toEqual(['adversarial_tamper', 'operator_init']);
      expect(getLegalNextStages('adversarial_tamper')).toEqual(['revocation_denied', 'operator_init']);
      expect(getLegalNextStages('revocation_denied')).toEqual(['operator_init']);
    });
  });

  describe('Pure Reducer nextState', () => {
    it('initializes to baseline operator_init state', () => {
      expect(INITIAL_STEPPER_STATE.currentStage).toBe('operator_init');
      expect(INITIAL_STEPPER_STATE.stageStatuses.operator_init).toBe('confirmed');
      expect(INITIAL_STEPPER_STATE.stageStatuses.host_enrolled).toBe('idle');
      expect(INITIAL_STEPPER_STATE.inFlight).toBe(false);
      expect(INITIAL_STEPPER_STATE.activeTransition).toBeNull();
      expect(INITIAL_STEPPER_STATE.lastError).toBeNull();
    });

    it('executes a complete sequential 5-stage happy path walk', () => {
      let state: DemoStepperState = INITIAL_STEPPER_STATE;

      // 1 -> 2 (host_enrolled)
      state = nextState(state, { type: 'START_TRANSITION', targetStage: 'host_enrolled' });
      expect(state.inFlight).toBe(true);
      expect(state.stageStatuses.host_enrolled).toBe('in_flight');
      expect(state.activeTransition?.to).toBe('host_enrolled');

      const enrolledPayload: HostEnrolledPayload = {
        hostId: 'host-101',
        agentId: 'agent-alpha',
        publicKeyFingerprint: 'ed25519:abcdef123456',
        enrolledAt: '2026-09-15T02:00:00Z',
        status: 'enrolled',
      };
      state = nextState(state, {
        type: 'RESOLVE_TRANSITION',
        targetStage: 'host_enrolled',
        payload: enrolledPayload,
      });
      expect(state.currentStage).toBe('host_enrolled');
      expect(state.inFlight).toBe(false);
      expect(state.stageStatuses.host_enrolled).toBe('confirmed');
      expect(state.stagePayloads.host_enrolled).toEqual(enrolledPayload);

      // 2 -> 3 (confinement_streaming)
      state = nextState(state, { type: 'START_TRANSITION', targetStage: 'confinement_streaming' });
      expect(state.inFlight).toBe(true);
      const confinementPayload: ConfinementStreamingPayload = {
        processComm: 'claude-code',
        cpuTicks: 12044,
        rssBytes: 52428800,
        openFds: 12,
        expectedSha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        observedSha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        hashMatch: true,
        zeroPayloadVerified: true,
      };
      state = nextState(state, {
        type: 'RESOLVE_TRANSITION',
        targetStage: 'confinement_streaming',
        payload: confinementPayload,
      });
      expect(state.currentStage).toBe('confinement_streaming');
      expect(state.stageStatuses.confinement_streaming).toBe('confirmed');

      // 3 -> 4 (adversarial_tamper)
      state = nextState(state, { type: 'START_TRANSITION', targetStage: 'adversarial_tamper' });
      const tamperPayload: AdversarialTamperPayload = {
        tamperType: 'hash_mismatch',
        injectedAt: '2026-09-15T02:02:00Z',
        originalSha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        tamperedSha256: 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
        breachDetected: true,
        containmentTriggered: true,
        detectionLatencyMs: 42,
      };
      state = nextState(state, {
        type: 'RESOLVE_TRANSITION',
        targetStage: 'adversarial_tamper',
        payload: tamperPayload,
      });
      expect(state.currentStage).toBe('adversarial_tamper');
      expect(state.stageStatuses.adversarial_tamper).toBe('confirmed');

      // 4 -> 5 (revocation_denied)
      state = nextState(state, { type: 'START_TRANSITION', targetStage: 'revocation_denied' });
      const revocationPayload: RevocationDeniedPayload = {
        hostId: 'host-101',
        operatorAttribution: 'tamper breach containment action by secops-admin',
        revokedAt: '2026-09-15T02:03:00Z',
        attemptedEndpoint: '/v1/external-agents/evidence-uploads',
        responseStatusCode: 403,
        denialConfirmed: true,
        proofDigest: 'sha256:403forbiddenproof',
      };
      state = nextState(state, {
        type: 'RESOLVE_TRANSITION',
        targetStage: 'revocation_denied',
        payload: revocationPayload,
      });
      expect(state.currentStage).toBe('revocation_denied');
      expect(state.stageStatuses.revocation_denied).toBe('confirmed');
      expect(state.inFlight).toBe(false);
      expect(isStageComplete(state, 'revocation_denied')).toBe(true);
    });

    it('rejects starting a new transition when another is already in-flight', () => {
      const state = nextState(INITIAL_STEPPER_STATE, {
        type: 'START_TRANSITION',
        targetStage: 'host_enrolled',
      });
      expect(state.inFlight).toBe(true);

      const state2 = nextState(state, {
        type: 'START_TRANSITION',
        targetStage: 'host_enrolled',
      });
      expect(state2.lastError).toMatch(/already in flight/i);
      expect(state2.inFlight).toBe(true);
    });

    it('rejects illegal out-of-order stage transitions with an explicit error', () => {
      const state = nextState(INITIAL_STEPPER_STATE, {
        type: 'START_TRANSITION',
        targetStage: 'adversarial_tamper',
      });
      expect(state.lastError).toMatch(/Illegal transition/i);
      expect(state.inFlight).toBe(false);
      expect(state.currentStage).toBe('operator_init');
    });

    it('rejects resolving a transition that does not match the active in-flight target', () => {
      let state = nextState(INITIAL_STEPPER_STATE, {
        type: 'START_TRANSITION',
        targetStage: 'host_enrolled',
      });

      state = nextState(state, {
        type: 'RESOLVE_TRANSITION',
        targetStage: 'confinement_streaming',
      });
      expect(state.lastError).toMatch(/Cannot resolve transition/i);
      expect(state.currentStage).toBe('operator_init');
      expect(state.inFlight).toBe(true);
    });

    it('records failed stage confirmations in a dedicated sub-state without crashing', () => {
      let state = nextState(INITIAL_STEPPER_STATE, {
        type: 'START_TRANSITION',
        targetStage: 'host_enrolled',
      });

      const failurePayload: StageFailurePayload = {
        stage: 'host_enrolled',
        errorReason: 'Ed25519 handshake signature verification failed',
        errorCode: 'SIG_INVALID',
        failedAt: '2026-09-15T02:04:00Z',
        recoverable: true,
      };

      state = nextState(state, {
        type: 'FAIL_TRANSITION',
        targetStage: 'host_enrolled',
        failure: failurePayload,
      });

      expect(state.inFlight).toBe(false);
      expect(state.activeTransition).toBeNull();
      expect(state.stageStatuses.host_enrolled).toBe('failed');
      expect(state.stageFailures.host_enrolled).toEqual(failurePayload);
      expect(state.lastError).toMatch(/Stage 'host_enrolled' failed/);
      expect(isStageFailed(state, 'host_enrolled')).toBe(true);
    });

    it('handles RESET_ESTATE cleanly from any stage or failure state', () => {
      let state: DemoStepperState = {
        ...INITIAL_STEPPER_STATE,
        currentStage: 'adversarial_tamper',
        stageStatuses: {
          operator_init: 'confirmed',
          host_enrolled: 'confirmed',
          confinement_streaming: 'confirmed',
          adversarial_tamper: 'failed',
          revocation_denied: 'idle',
        },
        stageFailures: {
          adversarial_tamper: {
            stage: 'adversarial_tamper',
            errorReason: 'Tamper injection timeout',
            failedAt: '2026-09-15T02:05:00Z',
            recoverable: true,
          },
        },
      };

      state = nextState(state, { type: 'RESET_ESTATE' });
      expect(state).toEqual(INITIAL_STEPPER_STATE);
      expect(state.currentStage).toBe('operator_init');
      expect(state.stageStatuses.operator_init).toBe('confirmed');
      expect(state.stageStatuses.adversarial_tamper).toBe('idle');
      expect(state.stageFailures).toEqual({});
      expect(state.inFlight).toBe(false);
    });

    it('updates stage payload without modifying other state fields', () => {
      const initPayload: OperatorInitPayload = {
        tokenId: 'tok-12345',
        issuedAt: '2026-09-15T02:00:00Z',
        ttlSeconds: 300,
        operatorId: 'secops-alice',
        tokenPrefix: 'amx_tok',
      };

      const state = nextState(INITIAL_STEPPER_STATE, {
        type: 'UPDATE_STAGE_PAYLOAD',
        stage: 'operator_init',
        payload: initPayload,
      });

      expect(state.stagePayloads.operator_init).toEqual(initPayload);
      expect(state.currentStage).toBe('operator_init');
    });

    it('maintains strict reducer purity without mutating previous state objects', () => {
      const stateBefore = INITIAL_STEPPER_STATE;
      Object.freeze(stateBefore);
      Object.freeze(stateBefore.stageStatuses);

      const stateAfter = nextState(stateBefore, {
        type: 'START_TRANSITION',
        targetStage: 'host_enrolled',
      });

      expect(stateAfter).not.toBe(stateBefore);
      expect(stateBefore.inFlight).toBe(false);
      expect(stateAfter.inFlight).toBe(true);
    });
  });

  describe('Async Gate Contract (Dual-Lock: Dwell AND Confirmation)', () => {
    it('waits for confirmation promise when dwell timer completes first', async () => {
      let confirmationResolved = false;
      const dwellMs = 15;

      const confirmationPromise = new Promise<{ id: string }>((resolve) => {
        setTimeout(() => {
          confirmationResolved = true;
          resolve({ id: 'conf-done' });
        }, 50);
      });

      const startTime = Date.now();
      const result = await executeAsyncGate({
        dwellMs,
        confirmationPromise,
      });

      const elapsed = Date.now() - startTime;
      expect(result.status).toBe('resolved');
      if (result.status === 'resolved') {
        expect(result.data).toEqual({ id: 'conf-done' });
        expect(confirmationResolved).toBe(true);
      }
      expect(elapsed).toBeGreaterThanOrEqual(45);
    });

    it('waits for dwell timer when confirmation promise resolves first', async () => {
      const dwellMs = 50;
      const confirmationPromise = Promise.resolve({ ok: true });

      const startTime = Date.now();
      const result = await executeAsyncGate({
        dwellMs,
        confirmationPromise,
      });

      const elapsed = Date.now() - startTime;
      expect(result.status).toBe('resolved');
      if (result.status === 'resolved') {
        expect(result.data).toEqual({ ok: true });
        expect(result.dwellElapsedMs).toBeGreaterThanOrEqual(40);
      }
      expect(elapsed).toBeGreaterThanOrEqual(45);
    });

    it('returns failed status without throwing when confirmation rejects', async () => {
      const confirmationPromise = new Promise<never>((_, reject) => {
        setTimeout(() => {
          reject(new Error('Backend 403 authorization assertion failed'));
        }, 20);
      });

      const result = await executeAsyncGate({
        dwellMs: 10,
        confirmationPromise,
      });

      expect(result.status).toBe('failed');
      if (result.status === 'failed') {
        expect(result.reason).toContain('Backend 403 authorization assertion failed');
      }
    });

    it('aborts cleanly when AbortSignal is pre-aborted', async () => {
      const controller = new AbortController();
      controller.abort();

      const result = await executeAsyncGate({
        dwellMs: 100,
        confirmationPromise: Promise.resolve('ok'),
        signal: controller.signal,
      });

      expect(result.status).toBe('aborted');
    });

    it('aborts in-flight gate when AbortSignal is triggered during dwell', async () => {
      const controller = new AbortController();
      setTimeout(() => {
        controller.abort();
      }, 20);

      const result = await executeAsyncGate({
        dwellMs: 200,
        confirmationPromise: new Promise((res) => setTimeout(res, 300)),
        signal: controller.signal,
      });

      expect(result.status).toBe('aborted');
    });

    it('fails when timeout is exceeded before confirmation arrives', async () => {
      const result = await executeAsyncGate({
        dwellMs: 10,
        confirmationPromise: new Promise((res) => setTimeout(res, 500)),
        timeoutMs: 30,
      });

      expect(result.status).toBe('failed');
      if (result.status === 'failed') {
        expect(result.reason).toMatch(/timed out/i);
      }
    });
  });

  describe('UI Navigation & Stepper Helpers', () => {
    it('disables navigation during in-flight transitions', () => {
      expect(isNavigationDisabled(INITIAL_STEPPER_STATE)).toBe(false);

      const inFlightState = nextState(INITIAL_STEPPER_STATE, {
        type: 'START_TRANSITION',
        targetStage: 'host_enrolled',
      });
      expect(isNavigationDisabled(inFlightState)).toBe(true);
      expect(canNavigateTo(inFlightState, 'host_enrolled')).toBe(false);
      expect(canNavigateTo(inFlightState, 'confinement_streaming')).toBe(false);
    });

    it('allows navigation only to legal next stages when idle', () => {
      expect(canNavigateTo(INITIAL_STEPPER_STATE, 'host_enrolled')).toBe(true);
      expect(canNavigateTo(INITIAL_STEPPER_STATE, 'confinement_streaming')).toBe(false);
      expect(canNavigateTo(INITIAL_STEPPER_STATE, 'adversarial_tamper')).toBe(false);
    });
  });
});
