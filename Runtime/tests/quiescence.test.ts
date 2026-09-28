import { describe, expect, test } from 'bun:test';
import { findNonTerminalItems } from '../src/quiescence';
import type { ThreadItem, Turn } from '../src/protocol';

const passiveItems: ThreadItem[] = [
  { type: 'userMessage', id: 'u1', clientId: null, content: [] },
  { type: 'hookPrompt', id: 'h1', fragments: [] },
  { type: 'agentMessage', id: 'a1', text: 'done', phase: null, memoryCitation: null },
  { type: 'plan', id: 'p1', text: 'done' },
  { type: 'reasoning', id: 'r1', summary: [], content: [] },
  { type: 'webSearch', id: 'w1', query: 'q', action: null, results: [] },
  { type: 'imageView', id: 'i1', path: '/tmp/image.png' },
  { type: 'sleep', id: 's1', durationMs: 1 },
  { type: 'enteredReviewMode', id: 'er1', review: 'review' },
  { type: 'exitedReviewMode', id: 'xr1', review: 'review' },
  { type: 'contextCompaction', id: 'c1' },
];

describe('turn item completeness', () => {
  test('accepts all passive schema item variants without requiring a status', () => {
    expect(findNonTerminalItems(passiveItems, 'full')).toEqual({ reasons: [], hasUnknownType: false });
  });

  test('uses the schema discriminator `type` and blocks an in-progress collaboration call', () => {
    const item = { type: 'collabAgentToolCall', id: 'collab-1', status: 'inProgress' } as ThreadItem;
    expect(findNonTerminalItems([item], 'full').reasons).toContain('item collab-1 (collabAgentToolCall) is not terminal: inProgress');
  });

  test('fails closed for sub-agent activity, unknown variants, and incomplete item views', () => {
    const subAgent = { type: 'subAgentActivity', id: 'sub-1', kind: 'started', agentThreadId: 'other', agentPath: 'a' } as ThreadItem;
    expect(findNonTerminalItems([subAgent], 'full').hasUnknownType).toBe(true);
    expect(findNonTerminalItems([{ type: 'futureItem', id: 'future-1' } as ThreadItem], 'full').hasUnknownType).toBe(true);
    expect(findNonTerminalItems([], 'summary').reasons[0]).toContain('itemsView is summary');
    expect(findNonTerminalItems([], 'notLoaded').reasons[0]).toContain('itemsView is notLoaded');
  });

  test('real-schema turn fixture includes required itemsView', () => {
    const turn: Turn = {
      id: 'turn-1',
      items: [],
      itemsView: 'full',
      status: 'completed',
      error: null,
      startedAt: 1,
      completedAt: 2,
      durationMs: 1000,
    };
    expect(turn.itemsView).toBe('full');
  });
});
