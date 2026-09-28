export type RequestId = string | number;

export type JsonRpcRequest = { id: RequestId; method: string; params?: unknown };
export type JsonRpcNotification = { method: string; params?: unknown };
export type JsonRpcSuccess = { id: RequestId; result: unknown };
export type JsonRpcFailure = { id: RequestId; error: { code: number; message: string; data?: unknown } };
export type JsonRpcResponse = JsonRpcSuccess | JsonRpcFailure;
export type JsonRpcInbound = JsonRpcRequest | JsonRpcNotification | JsonRpcResponse;

export function isResponse(message: JsonRpcInbound): message is JsonRpcResponse {
  return 'id' in message && !('method' in message);
}

export function isRequest(message: JsonRpcInbound): message is JsonRpcRequest {
  return 'id' in message && 'method' in message;
}

export function isNotification(message: JsonRpcInbound): message is JsonRpcNotification {
  return !('id' in message) && 'method' in message;
}

export type ThreadActiveFlag = 'waitingOnApproval' | 'waitingOnUserInput';

export type ThreadStatus =
  | { type: 'notLoaded' }
  | { type: 'idle' }
  | { type: 'systemError' }
  | { type: 'active'; activeFlags: ThreadActiveFlag[] };

export type TurnStatus = 'completed' | 'interrupted' | 'failed' | 'inProgress';

export type CommandExecutionStatus = 'inProgress' | 'completed' | 'failed' | 'declined';
export type PatchApplyStatus = 'inProgress' | 'completed' | 'failed' | 'declined';
export type McpToolCallStatus = 'inProgress' | 'completed' | 'failed';
export type DynamicToolCallStatus = 'inProgress' | 'completed' | 'failed';
export type CollabAgentToolCallStatus = 'inProgress' | 'completed' | 'failed';
export type TurnItemsView = 'notLoaded' | 'summary' | 'full';

export type ThreadItem =
  | { id: string; type: 'commandExecution'; status: CommandExecutionStatus; [key: string]: unknown }
  | { id: string; type: 'fileChange'; status: PatchApplyStatus; [key: string]: unknown }
  | { id: string; type: 'mcpToolCall'; status: McpToolCallStatus; [key: string]: unknown }
  | { id: string; type: 'dynamicToolCall'; status: DynamicToolCallStatus; [key: string]: unknown }
  | { id: string; type: 'collabAgentToolCall'; status: CollabAgentToolCallStatus; [key: string]: unknown }
  | { id: string; type: 'imageGeneration'; status: string; [key: string]: unknown }
  | { id: string; type: 'subAgentActivity'; [key: string]: unknown }
  | { id: string; type: 'userMessage' | 'hookPrompt' | 'agentMessage' | 'plan' | 'reasoning' | 'webSearch' | 'imageView' | 'sleep' | 'enteredReviewMode' | 'exitedReviewMode' | 'contextCompaction'; [key: string]: unknown }
  | { id: string; type: string; status?: string; [key: string]: unknown };

export type Turn = {
  id: string;
  items: ThreadItem[];
  itemsView: TurnItemsView;
  status: TurnStatus;
  error: unknown | null;
  startedAt: number | null;
  completedAt: number | null;
  durationMs: number | null;
};

export type Thread = {
  id: string;
  sessionId: string;
  status: ThreadStatus;
  cwd: string;
  path: string | null;
  turns: Turn[];
  [key: string]: unknown;
};

export type BackgroundTerminalEntry = {
  itemId: string;
  processId: string;
  command: string;
  cwd: string;
  osPid: number | null;
  cpuPercent: number | null;
  rssKb: bigint | number | null;
  [key: string]: unknown;
};

export type ThreadStartResponse = { thread: Thread; [key: string]: unknown };
export type TurnStartResponse = { turn: Turn };
export type BackgroundTerminalsListResponse = {
  data: BackgroundTerminalEntry[];
  nextCursor: string | null;
};

export type ApprovalKind =
  | 'commandExecution'
  | 'fileChange'
  | 'permissions'
  | 'toolUserInput'
  | 'toolCall'
  | 'mcpElicitation';

export const approvalRequestMethods: Record<string, ApprovalKind> = {
  'item/commandExecution/requestApproval': 'commandExecution',
  'item/fileChange/requestApproval': 'fileChange',
  'item/permissions/requestApproval': 'permissions',
  'item/tool/requestUserInput': 'toolUserInput',
  'item/tool/call': 'toolCall',
  'mcpServer/elicitation/request': 'mcpElicitation',
  applyPatchApproval: 'fileChange',
  execCommandApproval: 'commandExecution',
};

export type ApprovalDecision = 'accept' | 'acceptForSession' | 'decline' | 'cancel';

export type PendingApproval = {
  id: RequestId;
  kind: ApprovalKind;
  method: string;
  threadId: string;
  turnId?: string;
  itemId?: string;
  summary: string;
  receivedAt: string;
};

export type SupportedApprovalKind = 'commandExecution' | 'fileChange';
