import { randomUUID } from 'node:crypto';
import { validate, validateEnvelope, VERSION } from './contract.mjs';
import { privateDirectory, cleanArtifacts } from './security.mjs';
import { executeOperation, artifactResult } from './operations.mjs';
export class AgentController {
  constructor(backend) {
    this.backend = backend;
    this.connections = new Map();
    this.grants = new Map();
    this.pending = new Map();
    this.active = new Map();
    this.audit = [];
    this.timer = setInterval(() => this.expire(), 1000);
    this.timer.unref();
  }
  expire() {
    for (const [connection, value] of this.connections)
      if (Date.now() - value.seen > 45000) this.disconnect(connection);
    for (const [device, grant] of this.grants) {
      try {
        if (this.backend.identity(device) !== grant.identity) this.revoke(device);
      } catch {
        this.revoke(device);
      }
    }
  }
  disconnect(connection) {
    this.connections.delete(connection);
    for (const [device, grant] of this.grants)
      if (grant.connection === connection) this.revoke(device);
    for (const [key, request] of this.pending)
      if (request.connection === connection) this.pending.delete(key);
    this.backend.changed?.();
  }
  revoke(device) {
    const grant = this.grants.get(device);
    for (const operation of this.active.values())
      if (operation.device === device) operation.abort.abort();
    this.grants.delete(device);
    for (const [key, pending] of this.pending)
      if (pending.device === device) this.pending.delete(key);
    this.backend.changed?.();
    return Boolean(grant);
  }
  approve(key, roots) {
    const pending = this.pending.get(key);
    if (!pending || !this.connections.has(pending.connection))
      throw new Error('Control request expired. Ask the agent to retry.');
    const identity = this.backend.identity(pending.device);
    if (identity !== pending.identity || this.grants.has(pending.device))
      throw new Error('Phone session changed or already has a controller.');
    this.grants.set(pending.device, {
      ...pending,
      identity,
      handle: randomUUID(),
      roots,
      inspection: undefined,
    });
    for (const [id, request] of this.pending)
      if (request.device === pending.device) this.pending.delete(id);
    this.backend.changed?.();
  }
  status() {
    this.expire();
    return {
      connected: [...this.connections.values()].filter((c) => !c.selfTest && c.initialized).length,
      pending: [...this.pending.entries()].map(([key, value]) => ({
        key,
        device: value.device,
        client: value.client,
      })),
      grants: [...this.grants.entries()].map(([device, grant]) => ({
        device,
        client: grant.client,
      })),
    };
  }
  async call(raw) {
    const request = validateEnvelope(raw);
    const { tool, args, connection } = request;
    this.expire();
    if (tool === 'handshake') {
      await privateDirectory(this.backend.artifacts);
      await cleanArtifacts(this.backend.artifacts);
      this.connections.set(connection, { seen: Date.now(), selfTest: args.selfTest === true });
      this.backend.changed?.();
      return { version: VERSION, artifacts: this.backend.artifacts };
    }
    const client = this.connections.get(connection);
    if (!client) throw new Error('Agent connection expired. Reconnect to DroidDock.');
    client.seen = Date.now();
    if (tool === 'client_initialized') {
      client.initialized = true;
      this.backend.changed?.();
      return { success: true };
    }
    if (tool === 'heartbeat') return { success: true };
    if (tool === 'disconnect') {
      this.disconnect(connection);
      return { success: true };
    }
    if (tool === 'cancel') {
      const operation = this.active.get(args.request);
      if (operation?.connection === connection) operation.abort.abort();
      return { success: true };
    }
    const params = validate(tool, args);
    if (tool === 'list_devices') return { devices: await this.backend.list() };
    if (tool === 'device_status') return { status: await this.backend.status(params.device) };
    if (tool === 'boot_device') return { status: await this.backend.boot(params.device) };
    const identity = this.backend.identity(params.device);
    const grant = this.grants.get(params.device);
    if (tool === 'request_control') {
      if (grant && (grant.connection !== connection || grant.identity !== identity))
        throw new Error('device_busy: This phone has another controller. Revoke it in DroidDock.');
      if (grant) return { handle: grant.handle };
      const key = `${connection}:${params.device}`;
      if (!this.pending.has(key)) {
        this.pending.set(key, {
          connection,
          device: params.device,
          identity,
          client: params.client,
        });
        this.backend.changed?.();
      }
      return {
        error: 'confirmation_required',
        message: 'Approve full guest control in DroidDock Agent Setup, then retry.',
      };
    }
    if (
      !grant ||
      grant.connection !== connection ||
      grant.handle !== params.handle ||
      grant.identity !== identity
    )
      throw new Error('Control grant is missing, revoked or stale. Request control in DroidDock.');
    if (tool === 'release_control') {
      this.revoke(params.device);
      return { success: true };
    }
    if (tool === 'stop_device') {
      this.revoke(params.device);
      await this.backend.stop(params.device);
      return { success: true };
    }
    if ([...this.active.values()].some((op) => op.device === params.device))
      throw new Error('device_busy: Wait for the current agent operation.');
    const abort = new AbortController();
    this.active.set(request.request, { connection, device: params.device, abort });
    const started = Date.now();
    try {
      await this.backend.verify(params.device, abort.signal);
      const result = await executeOperation(
        {
          ...this.backend.config(params.device),
          roots: grant.roots,
          artifacts: this.backend.artifacts,
        },
        tool,
        params,
        {
          signal: abort.signal,
          inspection: grant.inspection,
          input: (action) => this.backend.input(params.device, action),
        },
      );
      if (
        abort.signal.aborted ||
        this.grants.get(params.device) !== grant ||
        this.backend.identity(params.device) !== identity
      )
        throw new Error('Control revoked or runtime changed; completion may be uncertain.');
      if (tool === 'inspect_device') {
        const { image, ...snapshot } = result;
        grant.inspection = snapshot;
      }
      return await artifactResult(this.backend.artifacts, result);
    } finally {
      this.active.delete(request.request);
      this.audit.push({ tool, device: params.device, duration: Date.now() - started });
      if (this.audit.length > 100) this.audit.shift();
    }
  }
  close() {
    clearInterval(this.timer);
    for (const connection of this.connections.keys()) this.disconnect(connection);
  }
}
