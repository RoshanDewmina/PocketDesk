export function createRing(capacity) {
  const items = [];
  return {
    push(item) { items.push(item); if (items.length > capacity) items.shift(); },
    list() { return items.slice(); },
    get length() { return items.length; },
  };
}
