/** Mirrors the native Mac rotation override and restores the original policy. */
export class GuestRotation {
  constructor(command) {
    this.command = command;
    this.pending = Promise.resolve();
    this.original = null;
  }
  serialize(operation) {
    const work = this.pending.then(operation);
    this.pending = work.catch(() => {});
    return work;
  }
  rotate(angle) {
    if (!Number.isInteger(angle) || angle < 0 || angle > 3)
      return Promise.reject(new Error('Rotation must be between 0 and 3.'));
    return this.serialize(async () => {
      if (!this.original) {
        const auto = await this.command([
          'settings',
          '--user',
          'current',
          'get',
          'system',
          'accelerometer_rotation',
        ]);
        const rotation = await this.command([
          'settings',
          '--user',
          'current',
          'get',
          'system',
          'user_rotation',
        ]);
        const policy = await this.command(['wm', 'user-rotation']);
        if (
          !/^(0|1|null)$/.test(auto) ||
          !/^([0-3]|null)$/.test(rotation) ||
          !/^(free|lock [0-3])$/.test(policy)
        )
          throw new Error(
            'Android did not return restorable rotation settings. Rotation was left unchanged.',
          );
        this.original = { auto, rotation, policy };
      }
      await this.command(['wm', 'user-rotation', 'lock', String(angle)]);
    });
  }
  restore() {
    return this.serialize(async () => {
      if (!this.original) return;
      const { auto, rotation, policy } = this.original;
      // wm may update the settings too, so repeat the whole ordered set on retry.
      await this.command(['wm', 'user-rotation', ...policy.split(' ')]);
      for (const [key, value] of [
        ['user_rotation', rotation],
        ['accelerometer_rotation', auto],
      ])
        await this.command([
          'settings',
          '--user',
          'current',
          value === 'null' ? 'delete' : 'put',
          'system',
          key,
          ...(value === 'null' ? [] : [value]),
        ]);
      this.original = null;
    });
  }
}
