import { XMLParser, XMLValidator } from 'fast-xml-parser';
import { hostInfo } from './platform.mjs';

export const REPOSITORY_URL = 'https://dl.google.com/android/repository/repository2-3.xml';
export const IMAGES_URL =
  'https://dl.google.com/android/repository/sys-img/google_apis/sys-img2-3.xml';
const MAX_MANIFEST = 8 * 1024 * 1024;
const fail = (message) => {
  throw new Error(`Android catalog: ${message}`);
};
const array = (value) => (value === undefined ? [] : Array.isArray(value) ? value : [value]);
function field(node, name) {
  const keys = Object.keys(node ?? {}).filter(
    (key) => !key.startsWith('@_') && key.split(':').at(-1) === name,
  );
  if (keys.length > 1) fail(`ambiguous ${name}`);
  return keys.length ? node[keys[0]] : undefined;
}
function one(node, name) {
  const value = field(node, name);
  if (Array.isArray(value)) fail(`duplicate ${name}`);
  return value;
}
const text = (value) =>
  typeof value === 'string' ? value : typeof value?.['#text'] === 'string' ? value['#text'] : '';
const trimmed = (value) => text(value).trim();
function required(node, name) {
  const value = trimmed(one(node, name));
  if (!value) fail(`missing ${name}`);
  return value;
}

export function runtimeVersion(id) {
  const match =
    /^system-images;android-([1-9][0-9]{1,3}(?:\.(?:0|[1-9][0-9]{0,2}))?);google_apis;x86_64$/.exec(
      id ?? '',
    );
  if (!match || Number(match[1].split('.')[0]) < 30)
    throw new Error('Unsupported Android image identity.');
  const api = match[1];
  const releases = {
    30: '11',
    31: '12',
    32: '12L',
    33: '13',
    34: '14',
    35: '15',
    36: '16',
    37: '17',
  };
  const release = releases[api.split('.')[0]];
  return {
    id,
    api,
    abi: 'x86_64',
    title: release ? `Android ${release} · API ${api}` : `Android API ${api}`,
    imagePath: id.replaceAll(';', '/'),
    deviceName: `DroidDock_Phone_API_${api.replaceAll('.', '_')}_x86_64`,
  };
}

export function compareRevisions(a, b) {
  const parse = (value) => {
    if (!/^\d+(?:\.\d+){0,3}$/.test(value)) fail('invalid revision');
    const numbers = value.split('.').map(Number);
    if (!numbers.every(Number.isSafeInteger)) fail('oversized revision');
    return numbers;
  };
  const left = parse(a),
    right = parse(b);
  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    const difference = (left[i] ?? 0) - (right[i] ?? 0);
    if (difference) return Math.sign(difference);
  }
  return 0;
}

function revision(node) {
  if (!node || Array.isArray(node)) fail('missing revision');
  return ['major', 'minor', 'micro']
    .map((key, i) => {
      const value = trimmed(one(node, key)) || (i ? '0' : '');
      if (!/^\d+$/.test(value) || !Number.isSafeInteger(Number(value))) fail('invalid revision');
      return String(Number(value));
    })
    .join('.');
}

export function officialURL(value, base) {
  if (
    typeof value !== 'string' ||
    /[%\\\s\u0000-\u001f]/.test(value) ||
    value.startsWith('//') ||
    value.split('/').some((p) => p === '.' || p === '..')
  )
    fail('untrusted archive URL');
  const url = new URL(value, base);
  if (
    url.protocol !== 'https:' ||
    url.hostname !== 'dl.google.com' ||
    url.port ||
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    !url.pathname.startsWith('/android/repository/')
  )
    fail('untrusted archive URL');
  return url.href;
}

export async function officialResponse(url, { signal, fetchImpl = fetch } = {}) {
  url = officialURL(url);
  for (let redirects = 0; redirects < 6; redirects++) {
    signal?.throwIfAborted();
    const response = await fetchImpl(url, { signal, redirect: 'manual', cache: 'no-store' });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get('location');
      await response.body?.cancel();
      if (!location) fail('redirect missing location');
      url = officialURL(location, url);
      continue;
    }
    if (response.status !== 200 || !response.body) {
      await response.body?.cancel();
      throw new Error(`Android download failed (HTTP ${response.status}).`);
    }
    return response;
  }
  fail('too many download redirects');
}

async function fetchManifest(url, options) {
  const response = await officialResponse(url, options);
  if (Number(response.headers.get('content-length')) > MAX_MANIFEST) {
    await response.body.cancel();
    fail('manifest too large');
  }
  const chunks = [];
  let size = 0;
  for await (const chunk of response.body) {
    size += chunk.length;
    if (size > MAX_MANIFEST) fail('manifest too large');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}

export async function fetchCatalog({ host = hostInfo(), signal, fetchImpl = fetch } = {}) {
  const deadline = AbortSignal.timeout(60_000);
  const combined = signal ? AbortSignal.any([signal, deadline]) : deadline;
  const [repository, systemImages] = await Promise.all(
    [REPOSITORY_URL, IMAGES_URL].map((url) => fetchManifest(url, { signal: combined, fetchImpl })),
  );
  return parseCatalog({ repository, systemImages, host });
}

function document(xml, rootName, namespace) {
  xml = Buffer.isBuffer(xml) ? xml.toString('utf8') : xml;
  if (
    typeof xml !== 'string' ||
    !xml.length ||
    Buffer.byteLength(xml) > MAX_MANIFEST ||
    /<!\s*(?:DOCTYPE|ENTITY)/i.test(xml)
  )
    fail('unsupported XML');
  if (XMLValidator.validate(xml) !== true) fail('malformed XML');
  const tree = new XMLParser({
    ignoreAttributes: false,
    parseTagValue: false,
    parseAttributeValue: false,
    trimValues: false,
    processEntities: true,
    ignoreDeclaration: true,
    ignorePiTags: true,
  }).parse(xml);
  const roots = Object.keys(tree).filter((key) => !key.startsWith('?'));
  if (roots.length !== 1 || roots[0].split(':').at(-1) !== rootName) fail('wrong manifest root');
  const root = tree[roots[0]],
    prefix = roots[0].includes(':') ? `:${roots[0].split(':')[0]}` : '';
  if (root?.[`@_xmlns${prefix}`] !== namespace) fail('wrong manifest namespace');
  let count = 0;
  function bound(value, depth = 0) {
    if (++count > 100_000 || depth > 64) fail('manifest structure too large');
    if (value && typeof value === 'object')
      for (const child of Object.values(value)) bound(child, depth + 1);
  }
  bound(root);
  const licenses = new Map();
  for (const license of array(field(root, 'license'))) {
    const id = license['@_id'],
      contents = text(license);
    if (
      !id ||
      !contents.trim() ||
      licenses.has(id) ||
      Object.keys(license).some((key) => !key.startsWith('@_') && key !== '#text')
    )
      fail('invalid or duplicate license');
    licenses.set(id, { id, text: contents });
  }
  return { packages: array(field(root, 'remotePackage')), licenses };
}

function stable(node) {
  return (
    node['@_obsolete'] !== 'true' &&
    one(node, 'channelRef')?.['@_ref'] === 'channel-0' &&
    one(one(node, 'revision'), 'preview') === undefined &&
    !trimmed(one(one(node, 'type-details'), 'codename'))
  );
}

function compatible(node, id, host) {
  return array(field(one(node, 'archives'), 'archive')).find((archive) => {
    if (!one(archive, 'complete')) return false;
    const os = trimmed(one(archive, 'host-os')),
      arch = trimmed(one(archive, 'host-arch')),
      bits = trimmed(one(archive, 'host-bits'));
    if (bits && bits !== '64') return false;
    if (id.startsWith('system-images;')) return !os && !arch;
    // Google's legacy Windows/Linux x64 archives omit host-arch. Explicit ARM
    // and x86 (32-bit) entries must never be substituted for this preview.
    return os === host.os && (!arch || arch === 'x86_64' || arch === 'x64');
  });
}

function selectPackage(source, id, base, host) {
  const candidates = source.packages
    .filter((node) => node['@_path'] === id && stable(node))
    .map((node) => ({ node, revision: revision(one(node, 'revision')) }))
    .sort((a, b) => compareRevisions(b.revision, a.revision));
  const selected = candidates.find((item) => compatible(item.node, id, host));
  if (!selected) fail(`no compatible stable ${id} package for ${host.os}/x64`);
  const { node } = selected,
    complete = one(compatible(node, id, host), 'complete');
  const size = Number(required(complete, 'size'));
  if (!Number.isSafeInteger(size) || size <= 0 || size > 20 * 1024 ** 3)
    fail('invalid archive size');
  const digest = one(complete, 'checksum'),
    checksumType = digest?.['@_type']?.toLowerCase(),
    checksum = trimmed(digest).toLowerCase();
  if (
    !['sha1', 'sha256'].includes(checksumType) ||
    !new RegExp(`^[a-f0-9]{${checksumType === 'sha1' ? 40 : 64}}$`).test(checksum)
  )
    fail('invalid checksum');
  const url = officialURL(required(complete, 'url'), base);
  if (!url.endsWith('.zip')) fail('archive must be ZIP');
  const licenses = array(field(node, 'uses-license')).map((ref) =>
    source.licenses.get(ref['@_ref']),
  );
  if (!licenses.length || licenses.some((value) => !value)) fail('missing license text');
  const minimumDependencies = {};
  for (const dependency of array(field(one(node, 'dependencies'), 'dependency'))) {
    const key = dependency['@_path'];
    if (!['emulator', 'platform-tools'].includes(key) || Object.hasOwn(minimumDependencies, key))
      fail('unsupported or duplicate dependency');
    minimumDependencies[key] = one(dependency, 'min-revision')
      ? revision(one(dependency, 'min-revision'))
      : '0';
  }
  if (id.startsWith('system-images;')) {
    const version = runtimeVersion(id),
      details = one(node, 'type-details');
    if (
      compareRevisions(required(details, 'api-level'), version.api) !== 0 ||
      required(details, 'abi') !== version.abi ||
      !array(field(details, 'tag')).some((tag) => trimmed(one(tag, 'id')) === 'google_apis')
    )
      fail('image metadata does not match package identity');
  }
  return {
    id,
    revision: selected.revision,
    displayName: required(node, 'display-name'),
    url,
    size,
    checksum,
    checksumType,
    license: licenses[0],
    licenses,
    minimumDependencies,
    relativeInstallPath: id.replaceAll(';', '/'),
    archiveRoot: id.startsWith('system-images;') ? 'x86_64' : id,
  };
}

export function parseCatalog({ repository, systemImages, host = hostInfo() }) {
  if (
    !host ||
    !['windows', 'linux'].includes(host.os) ||
    host.arch !== 'x64' ||
    host.abi !== 'x86_64'
  )
    fail('unsupported host');
  const tools = document(
    repository,
    'sdk-repository',
    'http://schemas.android.com/sdk/android/repo/repository2/03',
  );
  const images = document(
    systemImages,
    'sdk-sys-img',
    'http://schemas.android.com/sdk/android/repo/sys-img2/03',
  );
  const ids = new Set(
    images.packages
      .filter(stable)
      .map((node) => node['@_path'])
      .filter((id) => {
        try {
          runtimeVersion(id);
          return true;
        } catch {
          return false;
        }
      }),
  );
  if (!ids.size) fail('no compatible stable Android versions');
  const shared = ['emulator', 'platform-tools'].map((id) =>
    selectPackage(tools, id, new URL('.', REPOSITORY_URL).href, host),
  );
  return [...ids]
    .map((id) => {
      const image = selectPackage(images, id, new URL('.', IMAGES_URL).href, host),
        packages = [...shared, image];
      for (const pkg of packages)
        for (const [dependency, minimum] of Object.entries(pkg.minimumDependencies)) {
          if (
            compareRevisions(
              packages.find((candidate) => candidate.id === dependency).revision,
              minimum,
            ) < 0
          )
            fail(`unsatisfied ${dependency} minimum revision`);
        }
      const licenses = new Map();
      for (const pkg of packages)
        for (const license of pkg.licenses) {
          if (licenses.has(license.id) && licenses.get(license.id).text !== license.text)
            fail('conflicting license text');
          licenses.set(license.id, license);
        }
      return {
        ...runtimeVersion(id),
        revision: image.revision,
        packages,
        licenses: [...licenses.values()],
        host: { ...host },
      };
    })
    .sort((a, b) => compareRevisions(b.api, a.api) || b.api.localeCompare(a.api));
}
