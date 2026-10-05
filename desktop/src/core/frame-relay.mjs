/** Bounds compressed IPC traffic without resuming on an undecodable delta frame. */
export class FrameRelay {
  constructor(limit = 8) {
    this.limit = limit;
    this.sequence = 0;
    this.pending = new Set();
    this.desynced = new Set();
  }
  packet(packet) {
    if (packet.kind !== 'frame' && this.pending.size >= this.limit + 4) {
      throw new Error('The display is not consuming video metadata. Reopen it to reconnect.');
    }
    if (packet.kind === 'frame') {
      if (this.pending.size >= this.limit) {
        this.desynced.add(packet.id);
        return null;
      }
      if (this.desynced.has(packet.id) && !packet.key) return null;
    }
    // Configuration/metadata can arrive between dropped frames and a new IDR.
    // They do not repair the missing frame references on their own.
    const reset = packet.kind === 'frame' && packet.key && this.desynced.delete(packet.id);
    const sequence = ++this.sequence;
    this.pending.add(sequence);
    return {
      ...packet,
      data: packet.data ? new Uint8Array(packet.data) : undefined,
      sequence,
      reset: Boolean(reset),
    };
  }
  acknowledge(sequence) {
    if (Number.isSafeInteger(sequence)) this.pending.delete(sequence);
  }
  clear() {
    this.pending.clear();
    this.desynced.clear();
  }
}
