import { mutateApprovedRooms } from '../../src/rooms';

const [path, action, room] = process.argv.slice(2);
if (!path || !action || !room) throw new Error('missing worker argument');

if (action === 'slow-add') {
  mutateApprovedRooms(path, current => {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
    return current.includes(room) ? current : [...current, room];
  });
} else if (action === 'revoke') {
  mutateApprovedRooms(path, current => current.filter(item => item !== room));
} else {
  throw new Error('invalid worker action');
}
