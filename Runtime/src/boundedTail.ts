export class BoundedTail {
  private lines: string[] = [];

  constructor(private readonly maxLines: number) {}

  push(chunk: string) {
    for (const line of chunk.split('\n')) {
      if (!line) continue;
      this.lines.push(line);
    }
    if (this.lines.length > this.maxLines) this.lines = this.lines.slice(-this.maxLines);
  }

  snapshot(): string[] {
    return [...this.lines];
  }
}
