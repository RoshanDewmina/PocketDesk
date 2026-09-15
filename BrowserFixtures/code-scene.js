export const CODE_SCENE_LINES = [
  { indent: 0, parts: [['keyword', 'async '], ['keyword', 'function '], ['function', 'compilePreview'], ['punctuation', '('], ['variable', 'frame'], ['punctuation', ') {']] },
  { indent: 1, parts: [['keyword', 'const '], ['variable', 'selection'], ['operator', ' = '], ['string', '"src/remote-session.ts"'], ['punctuation', ';']] },
  { indent: 1, parts: [['keyword', 'const '], ['variable', 'status'], ['operator', ' = await '], ['function', 'decode'], ['punctuation', '('], ['variable', 'frame'], ['punctuation', ');']] },
  { indent: 1, parts: [['keyword', 'if '], ['punctuation', '('], ['variable', 'status'], ['operator', '?.'], ['property', 'stale'], ['punctuation', ') {']] },
  { indent: 2, parts: [['keyword', 'throw new '], ['class', 'Error'], ['punctuation', '('], ['string', '"fixture frame is stale"'], ['punctuation', ');']] },
  { indent: 1, parts: [['punctuation', '}']] },
  { indent: 1, parts: [['keyword', 'return '], ['variable', 'selection'], ['punctuation', ';']] },
  { indent: 0, parts: [['punctuation', '}']] },
];

export const SYNTHETIC_STACK = [
  'Error: fixture frame is stale',
  '    at compilePreview (src/remote-session.ts:18:11)',
  '    at async renderFixture (src/preview.ts:42:5)',
  '    at async localProbe (browser-probe:1:1)',
];

export const THEMES = {
  dark: {
    background: '#111827', gutter: '#172033', line: '#344158', text: '#d7e0ee', muted: '#8b9bb4',
    keyword: '#c792ea', function: '#82aaff', variable: '#d7e0ee', string: '#c3e88d', punctuation: '#aeb9cc',
    operator: '#89ddff', property: '#f78c6c', class: '#ffcb6b', selection: '#31577f', stack: '#f07178',
  },
  light: {
    background: '#f8fafc', gutter: '#e8edf5', line: '#cbd5e1', text: '#1f2937', muted: '#64748b',
    keyword: '#7c3aed', function: '#0369a1', variable: '#1f2937', string: '#4d7c0f', punctuation: '#475569',
    operator: '#0f766e', property: '#c2410c', class: '#a16207', selection: '#bfdbfe', stack: '#be123c',
  },
};

export function sceneMetrics(width, height) {
  const scale = Math.max(0.8, Math.min(2.4, width / 1440));
  return { scale, fontSize: Math.round(17 * scale), lineHeight: Math.round(29 * scale), gutter: Math.round(70 * scale), padding: Math.round(32 * scale), height };
}

export function drawCodeScene(context, { width, height, themeName = 'dark', frame = 0, timestamp = Date.now() }) {
  const theme = THEMES[themeName] ?? THEMES.dark;
  const metrics = sceneMetrics(width, height);
  const { fontSize, lineHeight, gutter, padding } = metrics;
  context.fillStyle = theme.background;
  context.fillRect(0, 0, width, height);
  context.fillStyle = theme.gutter;
  context.fillRect(0, 0, gutter, height);
  context.strokeStyle = theme.line;
  context.lineWidth = Math.max(1, metrics.scale);
  context.beginPath();
  context.moveTo(gutter, 0);
  context.lineTo(gutter, height);
  context.stroke();
  context.font = `${fontSize}px ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace`;
  context.textBaseline = 'middle';

  const startY = padding + lineHeight;
  CODE_SCENE_LINES.forEach((line, index) => {
    const y = startY + index * lineHeight;
    context.fillStyle = theme.muted;
    context.textAlign = 'right';
    context.fillText(String(index + 12), gutter - Math.round(16 * metrics.scale), y);
    context.textAlign = 'left';
    let x = gutter + padding + line.indent * Math.round(fontSize * 2);
    if (index === 1) {
      context.fillStyle = theme.selection;
      context.fillRect(x - 3, y - lineHeight / 2 + 2, Math.round(fontSize * 31), lineHeight - 4);
    }
    line.parts.forEach(([kind, text]) => {
      context.fillStyle = theme[kind] ?? theme.text;
      context.fillText(text, x, y);
      x += context.measureText(text).width;
    });
  });

  const stackTop = startY + (CODE_SCENE_LINES.length + 2) * lineHeight;
  context.fillStyle = theme.line;
  context.fillRect(gutter + padding, stackTop - lineHeight, width - gutter - padding * 2, Math.max(1, metrics.scale));
  context.font = `${Math.round(fontSize * 0.88)}px ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace`;
  SYNTHETIC_STACK.forEach((line, index) => {
    context.fillStyle = index === 0 ? theme.stack : theme.muted;
    context.fillText(line, gutter + padding, stackTop + index * Math.round(lineHeight * 0.85));
  });
  context.fillStyle = theme.muted;
  context.textAlign = 'right';
  context.fillText(`SYNTHETIC LOCAL FIXTURE  •  frame ${String(frame).padStart(6, '0')}  •  ${new Date(timestamp).toISOString().slice(11, 23)}`, width - padding, height - padding);
  context.textAlign = 'left';
  return { ...metrics, frame, themeName };
}
