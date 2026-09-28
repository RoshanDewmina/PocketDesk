export type SupervisorState =
  | 'idle'
  | 'agent_working'
  | 'pause_requested'
  | 'quiescing'
  | 'human_control'
  | 'resume_requested'
  | 'stopped'
  | 'error'
  | 'takeover_blocked';

export type SupervisorEvent =
  | 'START'
  | 'REQUEST_TAKEOVER'
  | 'TAKEOVER_NO_ACTIVE_TURN'
  | 'IMMEDIATE_BLOCK'
  | 'INTERRUPT_ACKED'
  | 'QUIESCENCE_CONFIRMED'
  | 'QUIESCENCE_TIMEOUT'
  | 'QUIESCENCE_ERROR'
  | 'RESUME_REQUESTED'
  | 'RESUME_STARTED'
  | 'STOP'
  | 'CHILD_EXIT_UNEXPECTED'
  | 'RPC_ERROR';

const transitions: Record<SupervisorEvent, Partial<Record<SupervisorState, SupervisorState>>> = {
  START: { idle: 'agent_working', stopped: 'agent_working' },
  REQUEST_TAKEOVER: { agent_working: 'pause_requested' },
  TAKEOVER_NO_ACTIVE_TURN: { agent_working: 'human_control', idle: 'human_control' },
  IMMEDIATE_BLOCK: { agent_working: 'takeover_blocked', idle: 'takeover_blocked' },
  INTERRUPT_ACKED: { pause_requested: 'quiescing' },
  QUIESCENCE_CONFIRMED: { quiescing: 'human_control' },
  QUIESCENCE_TIMEOUT: { quiescing: 'takeover_blocked' },
  QUIESCENCE_ERROR: { quiescing: 'takeover_blocked', pause_requested: 'takeover_blocked' },
  RESUME_REQUESTED: { human_control: 'resume_requested' },
  RESUME_STARTED: { resume_requested: 'agent_working' },
  STOP: {
    idle: 'stopped',
    agent_working: 'stopped',
    pause_requested: 'stopped',
    quiescing: 'stopped',
    human_control: 'stopped',
    resume_requested: 'stopped',
    takeover_blocked: 'stopped',
    error: 'stopped',
  },
  CHILD_EXIT_UNEXPECTED: {
    idle: 'error',
    agent_working: 'error',
    pause_requested: 'error',
    quiescing: 'error',
    resume_requested: 'error',
    human_control: 'error',
  },
  RPC_ERROR: {
    idle: 'error',
    agent_working: 'error',
    pause_requested: 'error',
    quiescing: 'error',
    resume_requested: 'error',
  },
};

export class InvalidTransitionError extends Error {
  constructor(public readonly event: SupervisorEvent, public readonly from: SupervisorState) {
    super(`event ${event} is not valid from state ${from}`);
  }
}

export class SupervisorStateMachine {
  private listeners: Array<(state: SupervisorState, event: SupervisorEvent) => void> = [];

  constructor(private current: SupervisorState) {}

  get state(): SupervisorState {
    return this.current;
  }

  onTransition(listener: (state: SupervisorState, event: SupervisorEvent) => void) {
    this.listeners.push(listener);
  }

  canApply(event: SupervisorEvent): boolean {
    return transitions[event][this.current] !== undefined;
  }

  apply(event: SupervisorEvent): SupervisorState {
    const next = transitions[event][this.current];
    if (!next) throw new InvalidTransitionError(event, this.current);
    this.current = next;
    for (const listener of this.listeners) listener(next, event);
    return next;
  }
}
