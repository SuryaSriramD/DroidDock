import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
export async function testServer(command, args, { env } = {}) {
  const client = new Client({ name: 'droiddock-self-test', version: '1.0.0' });
  const transport = new StdioClientTransport({
    command,
    args: [...args, '--self-test'],
    stderr: 'pipe',
    ...(env && { env }),
  });
  let diagnostic = '';
  transport.stderr?.on('data', (data) => {
    diagnostic = (diagnostic + data).slice(-4096);
  });
  const timeout = setTimeout(() => {
    void client.close();
  }, 30000);
  try {
    await client.connect(transport);
    const tools = await client.listTools();
    if (!tools.tools.some((tool) => tool.name === 'inspect_device'))
      throw new Error('Missing DroidDock tools.');
    const devices = await client.callTool({ name: 'list_devices', arguments: {} });
    if (devices.isError) throw new Error('Device listing failed.');
    return {
      success: true,
      message: `Server passed initialization, ${tools.tools.length} tools and device listing. Check your client separately.`,
    };
  } catch (error) {
    throw new Error(error.message + (diagnostic ? '\n' + diagnostic : ''));
  } finally {
    clearTimeout(timeout);
    await client.close();
  }
}
if (process.argv[2] === '--command') {
  try {
    process.stdout.write(JSON.stringify(await testServer(process.argv[3], process.argv.slice(4))));
  } catch (error) {
    process.stderr.write(error.message + '\n');
    process.exitCode = 1;
  }
}
