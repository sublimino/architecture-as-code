/**
 * AgentMaxxing Demo Console Lifecycle State Machine & Step-Control Contract
 *
 * This module defines the 5-stage lifecycle state machine and async step-control contract
 * for the AgentMaxxing Interactive Demo Console (`/demos/agentmaxxing`).
 *
 * UI Panel Ownership Matrix for Stages 1-5:
 * - Stage 1 ('operator_init'):
 *     Owned by AMXD-P2-2 (Operator Token Issue Panel)
 *     Renders operator attribution token issuance, TTL countdown, and bootstrap parameters.
 * - Stage 2 ('host_enrolled'):
 *     Owned by AMXD-P2-2 (Host Ed25519 Enrollment Panel)
 *     Renders host sensor registration, cryptographic handshake, and public key verification.
 * - Stage 3 ('confinement_streaming'):
 *     Owned by AMXD-P3-1 (Confinement Telemetry Panel) & AMXD-P3-2 (Zero-Payload Inspector Widget)
 *     Renders real-time process gauges (CPU ticks, RSS bytes, open FDs) and artifact SHA-256 hash checks.
 * - Stage 4 ('adversarial_tamper'):
 *     Owned by AMXD-P4-1 (Adversarial Simulation Panel)
 *     Renders simulated hash tampering, symlink escape detection, and boundary containment alerts.
 * - Stage 5 ('revocation_denied'):
 *     Owned by AMXD-P4-2 (Attributable Revocation & 403 Denial Panel)
 *     Renders operator key revocation dispatch and asserts 403 Forbidden upload denial proof.
 */

// ============================================================================
// 1. Stage Identifiers & Metadata
// ============================================================================

export type StageId =
  | 'operator_init'
  | 'host_enrolled'
  | 'confinement_streaming'
  | 'adversarial_tamper'
  | 'revocation_denied';

export const STAGE_IDS: readonly StageId[] = [
  'operator_init',
  'host_enrolled',
  'confinement_streaming',
  'adversarial_tamper',
  'revocation_denied',
] as const;

export interface StageMetadata {
  readonly id: StageId;
  readonly stepNumber: number;
  readonly title: string;
  readonly shortTitle: string;
  readonly description: string;
  readonly owningCard: string;
}

export const STAGE_METADATA: Readonly<Record<StageId, StageMetadata>> = {
  operator_init: {
    id: 'operator_init',
    stepNumber: 1,
    title: 'Stage 1: Operator Token Issuance',
    shortTitle: 'Token Issue',
    description: 'Issue short-lived cryptographic operator attribution token for host onboarding.',
    owningCard: 'AMXD-P2-2',
  },
  host_enrolled: {
    id: 'host_enrolled',
    stepNumber: 2,
    title: 'Stage 2: Host Ed25519 Enrollment',
    shortTitle: 'Host Enrollment',
    description: 'Exchange one-time token for Ed25519 host credential and register sensor.',
    owningCard: 'AMXD-P2-2',
  },
  confinement_streaming: {
    id: 'confinement_streaming',
    stepNumber: 3,
    title: 'Stage 3: Landlock Confinement & Telemetry',
    shortTitle: 'Confinement & Hashing',
    description: 'Stream metadata-only process metrics and live SHA-256 artifact verification.',
    owningCard: 'AMXD-P3-1 & AMXD-P3-2',
  },
  adversarial_tamper: {
    id: 'adversarial_tamper',
    stepNumber: 4,
    title: 'Stage 4: Adversarial Tamper Simulation',
    shortTitle: 'Tamper Simulation',
    description: 'Inject artifact hash discrepancies and verify instant boundary breach containment.',
    owningCard: 'AMXD-P4-1',
  },
  revocation_denied: {
    id: 'revocation_denied',
    stepNumber: 5,
    title: 'Stage 5: Attributable Revocation & 403 Denial',
    shortTitle: 'Attributable Revocation',
    description: 'Revoke host credential with attribution reason and verify subsequent 403 denial.',
    owningCard: 'AMXD-P4-2',
  },
};

// ============================================================================
// 2. Stage Execution Status & Payloads
// ============================================================================

export type StageExecutionStatus = 'idle' | 'in_flight' | 'confirmed' | 'failed';

export interface OperatorInitPayload {
  readonly tokenId: string;
  readonly issuedAt: string;
  readonly ttlSeconds: number;
  readonly operatorId: string;
  readonly tokenPrefix: string;
}

export interface HostEnrolledPayload {
  readonly hostId: string;
  readonly agentId: string;
  readonly publicKeyFingerprint: string;
  readonly enrolledAt: string;
  readonly status: 'enrolled' | 'pending';
}

export interface ConfinementStreamingPayload {
  readonly processComm: string;
  readonly cpuTicks: number;
  readonly rssBytes: number;
  readonly openFds: number;
  readonly expectedSha256: string;
  readonly observedSha256: string;
  readonly hashMatch: boolean;
  readonly zeroPayloadVerified: boolean;
}

export interface AdversarialTamperPayload {
  readonly tamperType: 'hash_mismatch' | 'symlink_escape' | 'oversized_write';
  readonly injectedAt: string;
  readonly originalSha256: string;
  readonly tamperedSha256: string;
  readonly breachDetected: boolean;
  readonly containmentTriggered: boolean;
  readonly detectionLatencyMs: number;
}

export interface RevocationDeniedPayload {
  readonly hostId: string;
  readonly operatorAttribution: string;
  readonly revokedAt: string;
  readonly attemptedEndpoint: string;
  readonly responseStatusCode: 403;
  readonly denialConfirmed: boolean;
  readonly proofDigest: string;
}

export interface StageFailurePayload {
  readonly stage: StageId;
  readonly errorReason: string;
  readonly errorCode?: string | number;
  readonly failedAt: string;
  readonly recoverable: boolean;
}

export interface StagePayloadMap {
  readonly operator_init: OperatorInitPayload;
  readonly host_enrolled: HostEnrolledPayload;
  readonly confinement_streaming: ConfinementStreamingPayload;
  readonly adversarial_tamper: AdversarialTamperPayload;
  readonly revocation_denied: RevocationDeniedPayload;
}

// ============================================================================
// 3. Strict Transition Table (Data Contract)
// ============================================================================

export interface TransitionRule {
  readonly from: StageId;
  readonly to: StageId;
  readonly actionLabel: string;
  readonly requiresConfirmation: boolean;
  readonly isReset?: boolean;
}

/**
 * Strict transition table defining all legal state progression edges.
 * Progression is strictly forward (1 -> 2 -> 3 -> 4 -> 5).
 * Reset Estate is a first-class transition edge from any stage back to 'operator_init'.
 */
export const LEGAL_TRANSITIONS: readonly TransitionRule[] = [
  // Sequential Forward Edges
  {
    from: 'operator_init',
    to: 'host_enrolled',
    actionLabel: 'Enroll Host',
    requiresConfirmation: true,
  },
  {
    from: 'host_enrolled',
    to: 'confinement_streaming',
    actionLabel: 'Stream Confinement Telemetry',
    requiresConfirmation: true,
  },
  {
    from: 'confinement_streaming',
    to: 'adversarial_tamper',
    actionLabel: 'Inject Adversarial Tamper',
    requiresConfirmation: true,
  },
  {
    from: 'adversarial_tamper',
    to: 'revocation_denied',
    actionLabel: 'Revoke Host & Verify 403 Denial',
    requiresConfirmation: true,
  },

  // First-Class Reset Estate Edges (Any Stage -> operator_init)
  {
    from: 'operator_init',
    to: 'operator_init',
    actionLabel: 'Reset Estate',
    requiresConfirmation: false,
    isReset: true,
  },
  {
    from: 'host_enrolled',
    to: 'operator_init',
    actionLabel: 'Reset Estate',
    requiresConfirmation: false,
    isReset: true,
  },
  {
    from: 'confinement_streaming',
    to: 'operator_init',
    actionLabel: 'Reset Estate',
    requiresConfirmation: false,
    isReset: true,
  },
  {
    from: 'adversarial_tamper',
    to: 'operator_init',
    actionLabel: 'Reset Estate',
    requiresConfirmation: false,
    isReset: true,
  },
  {
    from: 'revocation_denied',
    to: 'operator_init',
    actionLabel: 'Reset Estate',
    requiresConfirmation: false,
    isReset: true,
  },
] as const;

export function isValidTransition(from: StageId, to: StageId): boolean {
  return LEGAL_TRANSITIONS.some((edge) => edge.from === from && edge.to === to);
}

export function getLegalNextStages(current: StageId): readonly StageId[] {
  return LEGAL_TRANSITIONS.filter((edge) => edge.from === current).map((edge) => edge.to);
}

export function getStageIndex(stage: StageId): number {
  return STAGE_IDS.indexOf(stage);
}

// ============================================================================
// 4. Stepper State & Events
// ============================================================================

export interface ActiveTransition {
  readonly from: StageId;
  readonly to: StageId;
  readonly startedAt: number;
}

export interface DemoStepperState {
  readonly currentStage: StageId;
  readonly stageStatuses: Readonly<Record<StageId, StageExecutionStatus>>;
  readonly stagePayloads: Readonly<Partial<StagePayloadMap>>;
  readonly stageFailures: Readonly<Partial<Record<StageId, StageFailurePayload>>>;
  readonly inFlight: boolean;
  readonly activeTransition: ActiveTransition | null;
  readonly lastError: string | null;
}

export type DemoStepperEvent =
  | {
      readonly type: 'START_TRANSITION';
      readonly targetStage: StageId;
      readonly startedAt?: number;
    }
  | {
      readonly type: 'RESOLVE_TRANSITION';
      readonly targetStage: StageId;
      readonly payload?: StagePayloadMap[StageId];
    }
  | {
      readonly type: 'FAIL_TRANSITION';
      readonly targetStage: StageId;
      readonly failure: StageFailurePayload;
    }
  | {
      readonly type: 'RESET_ESTATE';
    }
  | {
      readonly type: 'UPDATE_STAGE_PAYLOAD';
      readonly stage: StageId;
      readonly payload: Partial<StagePayloadMap[StageId]>;
    };

/**
 * Rendered in the "Triggering Operator" field of a live-channel issuance or enrollment
 * record when the session has authenticated no principal.
 *
 * An attributable record names a subject the session actually authenticated. Substituting
 * a plausible-looking account name (this code previously shipped a literal
 * `operator-admin@signalloom.internal`) produces a display that satisfies the *form* of
 * attribution and none of its substance, which is strictly worse than an honest blank:
 * it is indistinguishable from a real attribution to anyone reading the screen.
 */
export const UNATTRIBUTED_OPERATOR_LABEL = 'UNATTRIBUTED: no authenticated principal';

export const INITIAL_STEPPER_STATE: DemoStepperState = {
  currentStage: 'operator_init',
  stageStatuses: {
    operator_init: 'confirmed',
    host_enrolled: 'idle',
    confinement_streaming: 'idle',
    adversarial_tamper: 'idle',
    revocation_denied: 'idle',
  },
  stagePayloads: {},
  stageFailures: {},
  inFlight: false,
  activeTransition: null,
  lastError: null,
};

// ============================================================================
// 5. Pure State Machine Reducer (nextState)
// ============================================================================

/**
 * Pure reducer function governing stage transitions with zero side effects.
 *
 * Rules enforced:
 * 1. Out-of-order or skipped transitions are rejected with an explicit error.
 * 2. Starting a transition while another transition is in-flight is rejected.
 * 3. Resolving a transition that does not match the active in-flight target is rejected.
 * 4. Failed transitions record the failure in a dedicated sub-state without unwinding prior stages.
 * 5. Reset Estate cleanly returns to initial baseline state.
 */
export function nextState(
  currentState: DemoStepperState,
  event: DemoStepperEvent
): DemoStepperState {
  switch (event.type) {
    case 'START_TRANSITION': {
      const { targetStage, startedAt } = event;

      // Rule 1: Cannot initiate a new transition if one is already in flight
      if (currentState.inFlight) {
        return {
          ...currentState,
          lastError: `Cannot start transition to '${targetStage}': transition from '${currentState.activeTransition?.from}' to '${currentState.activeTransition?.to}' is already in flight.`,
        };
      }

      // Rule 2: Validate against the strict legal transition table
      if (!isValidTransition(currentState.currentStage, targetStage)) {
        return {
          ...currentState,
          lastError: `Illegal transition: cannot transition from '${currentState.currentStage}' to '${targetStage}'.`,
        };
      }

      // Rule 3: No-op if target stage is already current stage (and not resetting)
      if (targetStage === currentState.currentStage && targetStage !== 'operator_init') {
        return currentState;
      }

      // Transition is legal: enter in-flight state
      return {
        ...currentState,
        inFlight: true,
        activeTransition: {
          from: currentState.currentStage,
          to: targetStage,
          startedAt: startedAt ?? Date.now(),
        },
        stageStatuses: {
          ...currentState.stageStatuses,
          [targetStage]: 'in_flight',
        },
        lastError: null,
      };
    }

    case 'RESOLVE_TRANSITION': {
      const { targetStage, payload } = event;

      // Rule: Must match active in-flight transition
      if (!currentState.inFlight || currentState.activeTransition?.to !== targetStage) {
        return {
          ...currentState,
          lastError: `Cannot resolve transition for '${targetStage}': active in-flight target is '${currentState.activeTransition?.to ?? 'none'}'.`,
        };
      }

      const updatedPayloads = payload
        ? { ...currentState.stagePayloads, [targetStage]: payload }
        : currentState.stagePayloads;

      return {
        ...currentState,
        currentStage: targetStage,
        inFlight: false,
        activeTransition: null,
        stageStatuses: {
          ...currentState.stageStatuses,
          [targetStage]: 'confirmed',
        },
        stagePayloads: updatedPayloads,
        lastError: null,
      };
    }

    case 'FAIL_TRANSITION': {
      const { targetStage, failure } = event;

      // Model failed confirmation as a terminal sub-state per stage
      return {
        ...currentState,
        inFlight: false,
        activeTransition: null,
        stageStatuses: {
          ...currentState.stageStatuses,
          [targetStage]: 'failed',
        },
        stageFailures: {
          ...currentState.stageFailures,
          [targetStage]: failure,
        },
        lastError: `Stage '${targetStage}' failed: ${failure.errorReason}`,
      };
    }

    case 'RESET_ESTATE': {
      // First-class edge to reset estate to operator_init
      return INITIAL_STEPPER_STATE;
    }

    case 'UPDATE_STAGE_PAYLOAD': {
      const existing = currentState.stagePayloads[event.stage];
      const merged = existing ? { ...existing, ...event.payload } : event.payload;

      return {
        ...currentState,
        stagePayloads: {
          ...currentState.stagePayloads,
          [event.stage]: merged as StagePayloadMap[typeof event.stage],
        },
      };
    }

    default: {
      const _exhaustiveCheck: never = event;
      return _exhaustiveCheck;
    }
  }
}

// ============================================================================
// 6. Async Gate Contract (Dual-Lock: Dwell AND Confirmation)
// ============================================================================

export type AutoPlayPacing = '1x' | '2x' | 'instant';

export const AUTO_PLAY_DWELL_MS: Readonly<Record<AutoPlayPacing, number>> = {
  '1x': 4000,
  '2x': 2000,
  instant: 100,
} as const;

export interface AsyncGateOptions<T> {
  readonly dwellMs: number;
  readonly confirmationPromise: Promise<T> | (() => Promise<T>);
  readonly timeoutMs?: number;
  readonly signal?: AbortSignal;
}

export type AsyncGateResult<T> =
  | {
      readonly status: 'resolved';
      readonly data: T;
      readonly dwellElapsedMs: number;
      readonly confirmationElapsedMs: number;
      readonly totalElapsedMs: number;
    }
  | {
      readonly status: 'failed';
      readonly reason: string;
      readonly error?: unknown;
      readonly dwellElapsedMs: number;
      readonly confirmationElapsedMs: number;
      readonly totalElapsedMs: number;
    }
  | {
      readonly status: 'aborted';
      readonly reason: string;
      readonly totalElapsedMs: number;
    };

/**
 * executeAsyncGate
 *
 * Structurally guarantees that a demo stage transition requires BOTH:
 * 1. Minimum elapsed dwell time (e.g. 4000ms for 1x, 2000ms for 2x, 100ms for instant)
 * 2. Backend confirmation promise resolution (e.g. API 201/200/403 response verification)
 *
 * Council Auto-Play Finding Addressed:
 * The proposal's Auto-Play instant mode (100ms per stage) is significantly faster than
 * the backend confirmation SLA (e.g. 403 verification within 2000ms). Without this dual-lock
 * gate, instant mode would advance stages purely on timer expiration before the backend has
 * answered, producing a false green result on an unverified backend state.
 *
 * Behavior:
 * - Dwell finishes before confirmation -> Continues awaiting confirmation promise.
 * - Confirmation finishes before dwell -> Continues awaiting dwell timer.
 * - Confirmation rejects or errors -> Settles into `{ status: 'failed' }` without throwing.
 * - AbortSignal triggered -> Settles into `{ status: 'aborted' }`.
 * - Timeout reached -> Settles into `{ status: 'failed', reason: 'Timeout...' }`.
 */
export async function executeAsyncGate<T>(
  options: AsyncGateOptions<T>
): Promise<AsyncGateResult<T>> {
  const startTime = Date.now();
  const { dwellMs, confirmationPromise, timeoutMs = 30000, signal } = options;

  if (signal?.aborted) {
    return {
      status: 'aborted',
      reason: 'Async gate aborted before start',
      totalElapsedMs: 0,
    };
  }

  // Dwell timer promise
  let timerId: ReturnType<typeof setTimeout> | undefined;
  const dwellPromise = new Promise<{ elapsed: number }>((resolve) => {
    timerId = setTimeout(() => {
      resolve({ elapsed: Date.now() - startTime });
    }, Math.max(0, dwellMs));
  });

  // Confirmation promise wrapper (catches rejections safely)
  const confirmationStart = Date.now();
  const rawPromise =
    typeof confirmationPromise === 'function' ? confirmationPromise() : confirmationPromise;

  const wrappedConfirmationPromise = rawPromise
    .then((data) => ({
      success: true as const,
      data,
      elapsed: Date.now() - confirmationStart,
    }))
    .catch((error: unknown) => ({
      success: false as const,
      error,
      elapsed: Date.now() - confirmationStart,
    }));

  // Abort / Timeout controller promise
  let timeoutTimerId: ReturnType<typeof setTimeout> | undefined;
  const controlPromise = new Promise<{ control: 'timeout' | 'aborted'; reason: string }>(
    (resolve) => {
      if (signal) {
        signal.addEventListener(
          'abort',
          () => {
            resolve({ control: 'aborted', reason: 'Operation aborted' });
          },
          { once: true }
        );
      }
      if (timeoutMs > 0 && timeoutMs < Infinity) {
        timeoutTimerId = setTimeout(() => {
          resolve({
            control: 'timeout',
            reason: `Async gate timed out after ${timeoutMs}ms waiting for confirmation`,
          });
        }, timeoutMs);
      }
    }
  );

  try {
    const outcome = await Promise.race([
      Promise.all([dwellPromise, wrappedConfirmationPromise]).then(([dwellRes, confRes]) => ({
        control: 'settled' as const,
        dwellRes,
        confRes,
      })),
      controlPromise,
    ]);

    const totalElapsedMs = Date.now() - startTime;

    if (outcome.control !== 'settled') {
      if (outcome.control === 'aborted') {
        return {
          status: 'aborted',
          reason: outcome.reason,
          totalElapsedMs,
        };
      }
      return {
        status: 'failed',
        reason: outcome.reason,
        dwellElapsedMs: Math.min(dwellMs, totalElapsedMs),
        confirmationElapsedMs: totalElapsedMs,
        totalElapsedMs,
      };
    }

    const { dwellRes, confRes } = outcome;

    if (!confRes.success) {
      const errorMsg =
        confRes.error instanceof Error ? confRes.error.message : String(confRes.error);
      return {
        status: 'failed',
        reason: errorMsg,
        error: confRes.error,
        dwellElapsedMs: dwellRes.elapsed,
        confirmationElapsedMs: confRes.elapsed,
        totalElapsedMs,
      };
    }

    return {
      status: 'resolved',
      data: confRes.data,
      dwellElapsedMs: dwellRes.elapsed,
      confirmationElapsedMs: confRes.elapsed,
      totalElapsedMs,
    };
  } finally {
    if (timerId !== undefined) clearTimeout(timerId);
    if (timeoutTimerId !== undefined) clearTimeout(timeoutTimerId);
  }
}

// ============================================================================
// 7. Navigation & Stepper Helper Queries
// ============================================================================

export function isNavigationDisabled(state: DemoStepperState): boolean {
  return state.inFlight;
}

export function canNavigateTo(state: DemoStepperState, targetStage: StageId): boolean {
  if (state.inFlight) return false;
  return isValidTransition(state.currentStage, targetStage);
}

export function isStageComplete(state: DemoStepperState, stage: StageId): boolean {
  return state.stageStatuses[stage] === 'confirmed';
}

export function isStageFailed(state: DemoStepperState, stage: StageId): boolean {
  return state.stageStatuses[stage] === 'failed';
}
