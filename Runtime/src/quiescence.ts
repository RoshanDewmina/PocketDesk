import type { ThreadItem, Turn, TurnItemsView } from './protocol';

const terminalStatusByItemType: Record<string, string[]> = {
  commandExecution: ['completed', 'failed', 'declined'],
  fileChange: ['completed', 'failed', 'declined'],
  mcpToolCall: ['completed', 'failed'],
  dynamicToolCall: ['completed', 'failed'],
  collabAgentToolCall: ['completed', 'failed'],
  imageGeneration: ['completed', 'failed'],
};

const knownItemTypes = new Set(Object.keys(terminalStatusByItemType));
const passiveItemTypes = new Set([
  'userMessage',
  'hookPrompt',
  'agentMessage',
  'plan',
  'reasoning',
  'webSearch',
  'imageView',
  'sleep',
  'enteredReviewMode',
  'exitedReviewMode',
  'contextCompaction',
]);

export type ItemCheck = { reasons: string[]; hasUnknownType: boolean };

export function findNonTerminalItems(items: ThreadItem[], itemsView: TurnItemsView): ItemCheck {
  const reasons: string[] = [];
  let hasUnknownType = false;
  if (itemsView !== 'full') {
    return {
      reasons: [`turn itemsView is ${itemsView}; full item accounting is required`],
      hasUnknownType: true,
    };
  }
  for (const item of items) {
    if (passiveItemTypes.has(item.type)) continue;
    if (!knownItemTypes.has(item.type)) {
      reasons.push(`unknown or unaccountable item type in turn items: ${item.type} (item ${item.id})`);
      hasUnknownType = true;
      continue;
    }
    const terminal = terminalStatusByItemType[item.type]!;
    if (!item.status || !terminal.includes(item.status)) {
      reasons.push(`item ${item.id} (${item.type}) is not terminal: ${item.status ?? 'unknown'}`);
    }
  }
  return { reasons, hasUnknownType };
}

export type BackgroundTerminalCheck = {
  clear: boolean;
  aliveProcessIds: string[];
  unknownEntries: string[];
};

/** Every schema entry represents a currently-running background terminal. */
export function checkBackgroundTerminals(items: Array<Record<string, unknown>>): BackgroundTerminalCheck {
  const aliveProcessIds: string[] = [];
  const unknownEntries: string[] = [];
  for (const item of items) {
    const processId = item.processId;
    if (typeof processId !== 'string') {
      unknownEntries.push(`background terminal entry missing processId: ${JSON.stringify(item)}`);
      continue;
    }
    aliveProcessIds.push(processId);
  }
  return { clear: aliveProcessIds.length === 0 && unknownEntries.length === 0, aliveProcessIds, unknownEntries };
}

export function turnHasTerminalStatus(turn: Turn): boolean {
  return turn.status === 'completed' || turn.status === 'interrupted' || turn.status === 'failed';
}
