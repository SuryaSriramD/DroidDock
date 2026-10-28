import { z } from 'zod';
export const VERSION = 1;
const string = z
  .string()
  .min(1)
  .max(8192)
  .refine((s) => !s.includes('\0'));
const device = { device: string };
const controlled = { ...device, handle: z.string().uuid() };
const point = z.number().int().min(0).max(16384);
const selector = z
  .object({ attribute: z.enum(['resource-id', 'text', 'content-desc']), value: string })
  .strict();
export const tools = {
  list_devices: { description: 'List DroidDock phones and their stable IDs.', shape: {} },
  device_status: { description: 'Inspect readiness of one explicit phone.', shape: device },
  boot_device: {
    description: 'Boot a DroidDock phone and show its window. Waits for readiness.',
    shape: device,
  },
  request_control: {
    description:
      'Request full guest control in DroidDock. User must approve in the app, then retry. Client name is unverified.',
    shape: { ...device, client: z.string().min(1).max(100) },
  },
  release_control: { description: 'Release control of a phone.', shape: controlled },
  inspect_device: {
    description:
      'Capture native-resolution PNG and Android accessibility nodes. Canvas content may have no nodes.',
    shape: controlled,
  },
  tap: {
    description:
      'Tap native Android pixels or a node from the latest inspection. Never use host window coordinates.',
    shape: {
      ...controlled,
      x: point.optional(),
      y: point.optional(),
      inspection: z.string().uuid().optional(),
      node: z.number().int().nonnegative().optional(),
    },
  },
  swipe: {
    description: 'Swipe between native Android pixel coordinates.',
    shape: {
      ...controlled,
      x: point,
      y: point,
      endX: point,
      endY: point,
      duration: z.number().int().min(1).max(5000).default(300),
    },
  },
  type_text: {
    description:
      'Paste Unicode text via scrcpy. Replaces the Android guest clipboard; never reads the host clipboard.',
    shape: { ...controlled, text: z.string().max(8192) },
  },
  press_key: {
    description: 'Press an Android navigation or editing key.',
    shape: { ...controlled, key: z.enum(['back', 'home', 'recents', 'enter', 'delete']) },
  },
  wait_for_element: {
    description: 'Wait for one exact, unambiguous Android UI match.',
    shape: { ...controlled, selector, timeout: z.number().int().min(1).max(60).default(10) },
  },
  app_action: {
    description:
      'Install, launch, stop, uninstall, clear app data, or open a deep link. Install paths must be within approved host folders.',
    shape: {
      ...controlled,
      action: z.enum(['install', 'launch', 'force-stop', 'uninstall', 'clear-data', 'open-url']),
      value: string,
    },
  },
  read_logs: {
    description: 'Read bounded Logcat. Package filtering uses the currently running package PID.',
    shape: {
      ...controlled,
      package: string.optional(),
      priority: z.enum(['V', 'D', 'I', 'W', 'E', 'F']).default('I'),
      lines: z.number().int().min(1).max(1000).default(300),
    },
  },
  android_shell: {
    description:
      'Run argument-array Android guest shell with full control. sh -c is allowed and can erase guest data. No host shell or arbitrary ADB commands.',
    shape: {
      ...controlled,
      args: z.array(string).min(1).max(128),
      timeout: z.number().int().min(1).max(60).default(30),
    },
  },
  transfer_file: {
    description:
      'Push/pull one file through approved host folders. Pull never overwrites an existing host file.',
    shape: {
      ...controlled,
      direction: z.enum(['push', 'pull']),
      hostPath: string,
      guestPath: string,
    },
  },
  stop_device: { description: 'Stop an app-owned phone and revoke control.', shape: controlled },
};
export function validate(tool, args) {
  if (!Object.hasOwn(tools, tool))
    throw new Error('Unsupported agent tool. Update DroidDock and reconnect.');
  return z.object(tools[tool].shape).strict().parse(args);
}
export function validateEnvelope(value) {
  return z
    .object({
      version: z.literal(VERSION),
      connection: z.string().uuid(),
      request: z.string().uuid(),
      tool: z.string().min(1).max(100),
      args: z.record(z.unknown()).default({}),
    })
    .strict()
    .parse(value);
}
