import { describe, expect, test } from 'bun:test';
import { CODE_SCENE_LINES, SYNTHETIC_STACK, THEMES, sceneMetrics } from './code-scene.js';

describe('synthetic code scene fixture', () => {
  test('contains invented code and an advancing-scene stack trace', () => {
    expect(CODE_SCENE_LINES.length).toBeGreaterThan(5);
    expect(SYNTHETIC_STACK.join('\n')).toContain('fixture frame is stale');
    expect(SYNTHETIC_STACK.join('\n')).not.toContain('/Users/');
  });

  test('provides distinct readable light and dark palettes', () => {
    expect(THEMES.dark.background).not.toBe(THEMES.light.background);
    expect(THEMES.dark.keyword).not.toBe(THEMES.dark.string);
    expect(THEMES.light.selection).not.toBe(THEMES.light.background);
  });

  test('scales while retaining a positive monospace layout', () => {
    const compact = sceneMetrics(1440, 900);
    const large = sceneMetrics(2560, 1440);
    expect(compact.fontSize).toBeGreaterThan(0);
    expect(large.fontSize).toBeGreaterThan(compact.fontSize);
    expect(large.gutter).toBeGreaterThan(compact.gutter);
  });
});
