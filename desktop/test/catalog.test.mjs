import test from 'node:test';
import assert from 'node:assert/strict';
import { parseCatalog, runtimeVersion, officialURL, fetchCatalog } from '../src/core/catalog.mjs';
import { host } from './managed-fixtures.mjs';

function archive({ os, arch, url = 'fixture.zip', size = '100' } = {}) {
  return `<archive><complete><size>${size}</size><checksum type="sha1">${'a'.repeat(40)}</checksum><url>${url}</url></complete>${os ? `<host-os>${os}</host-os>` : ''}${arch ? `<host-arch>${arch}</host-arch>` : ''}</archive>`;
}
function pkg(
  id,
  {
    revision = '37',
    channel = 'channel-0',
    preview = '',
    archives,
    api,
    codename = '',
    dependency = '',
  } = {},
) {
  const image = id.startsWith('system-images;');
  return `<remotePackage path="${id}"><display-name>${id}</display-name><revision><major>${revision}</major>${preview}</revision><channelRef ref="${channel}"/><uses-license ref="license"/>
  <type-details>${image ? `<api-level>${api ?? id.split(';')[1].slice(8)}</api-level><abi>x86_64</abi><tag><id>google_apis</id></tag>${codename}` : ''}</type-details>
  <archives>${archives ?? archive(image ? {} : { os: 'linux', arch: id === 'emulator' ? 'x64' : undefined })}</archives>${dependency}</remotePackage>`;
}
function manifests({ tools, images, license = '\n Terms &amp; Conditions\n ' } = {}) {
  return {
    repository: `<sdk:sdk-repository xmlns:sdk="http://schemas.android.com/sdk/android/repo/repository2/03"><license id="license">${license}</license>${tools ?? pkg('emulator') + pkg('platform-tools')}</sdk:sdk-repository>`,
    systemImages: `<sys:sdk-sys-img xmlns:sys="http://schemas.android.com/sdk/android/repo/sys-img2/03"><license id="license">${license}</license>${images ?? pkg('system-images;android-36;google_apis;x86_64')}</sys:sdk-sys-img>`,
    host,
  };
}

test('catalog preserves exact license, matches x64 host and sorts decimal stable APIs', () => {
  const input = manifests({
    images: ['36', '37.0', '36.1', '30']
      .map((api) => pkg(`system-images;android-${api};google_apis;x86_64`))
      .join(''),
  });
  const plans = parseCatalog(input);
  assert.deepEqual(
    plans.map((plan) => plan.api),
    ['37.0', '36.1', '36', '30'],
  );
  assert.equal(plans[0].title, 'Android 17 · API 37.0');
  assert.equal(plans[0].licenses[0].text, '\n Terms & Conditions\n ');
  assert.equal(plans[0].packages.length, 3);
  assert.equal(plans[0].packages[2].archiveRoot, 'x86_64');
});

test('Windows selects Windows x64 archive instead of Linux or ARM64', () => {
  const archives =
    archive({ os: 'linux', arch: 'x64', url: 'linux.zip' }) +
    archive({ os: 'windows', arch: 'aarch64', url: 'arm.zip' }) +
    archive({ os: 'windows', arch: 'x64', url: 'windows.zip' });
  const input = manifests({
    tools:
      pkg('emulator', { archives }) +
      pkg('platform-tools', { archives: archive({ os: 'windows' }) }),
  });
  const result = parseCatalog({ ...input, host: { ...host, os: 'windows' } });
  assert.match(result[0].packages[0].url, /windows\.zip$/);
});

test('catalog excludes previews and rejects image identity/metadata disagreement', () => {
  const stable = pkg('system-images;android-36;google_apis;x86_64');
  const previews =
    pkg('system-images;android-37;google_apis;x86_64', {
      codename: '<codename>Preview</codename>',
    }) + pkg('system-images;android-38;google_apis;x86_64', { preview: '<preview>1</preview>' });
  assert.equal(parseCatalog(manifests({ images: stable + previews })).length, 1);
  assert.throws(
    () =>
      parseCatalog(
        manifests({ images: pkg('system-images;android-36;google_apis;x86_64', { api: '35' }) }),
      ),
    /metadata/,
  );
  for (const id of [
    'system-images;android-36;google_apis;arm64-v8a',
    'system-images;android-../36;google_apis;x86_64',
    'system-images;android-29;google_apis;x86_64',
  ])
    assert.throws(() => runtimeVersion(id));
});

test('catalog rejects entities, wrong namespace, bad URLs/checksums and missing licenses', () => {
  const fixture = manifests();
  assert.throws(
    () =>
      parseCatalog({
        ...fixture,
        repository: '<!DOCTYPE x [<!ENTITY boom "large">]>' + fixture.repository,
      }),
    /XML/,
  );
  assert.throws(
    () =>
      parseCatalog({
        ...fixture,
        repository: fixture.repository.replace('repository2/03', 'repository2/99'),
      }),
    /namespace/,
  );
  assert.throws(
    () =>
      parseCatalog({
        ...fixture,
        repository: fixture.repository.replaceAll('ref="license"', 'ref="missing"'),
      }),
    /license/,
  );
  assert.throws(
    () =>
      parseCatalog({
        ...fixture,
        repository: fixture.repository.replace('a'.repeat(40), 'x'.repeat(40)),
      }),
    /checksum/,
  );
  for (const url of [
    'https://evil.test/android/repository/a.zip',
    'https://dl.google.com/android/repository/../a.zip',
    'https://dl.google.com/android/repository/%2e%2e/a.zip',
    'https://dl.google.com/android/repository/a.zip?x=1',
  ])
    assert.throws(() => officialURL(url));
});

test('dependency minimum blocks incompatible selected tools', () => {
  const dependency =
    '<dependencies><dependency path="emulator"><min-revision><major>99</major></min-revision></dependency></dependencies>';
  assert.throws(
    () =>
      parseCatalog(
        manifests({ images: pkg('system-images;android-36;google_apis;x86_64', { dependency }) }),
      ),
    /minimum/,
  );
});

test('catalog fetching follows only official redirects and never downloads archive payloads', async () => {
  const input = manifests(),
    urls = [];
  const plans = await fetchCatalog({
    host,
    fetchImpl: async (url) => {
      urls.push(url);
      return new Response(url.includes('sys-img') ? input.systemImages : input.repository);
    },
  });
  assert.equal(plans.length, 1);
  assert.equal(urls.length, 2);
  assert.ok(urls.every((url) => url.endsWith('.xml')));
  await assert.rejects(
    fetchCatalog({
      host,
      fetchImpl: async () =>
        new Response(null, { status: 302, headers: { location: 'https://evil.test/data' } }),
    }),
    /untrusted/,
  );
});
