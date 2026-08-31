import { afterEach, describe, expect, test } from 'bun:test';
import { mkdtemp, mkdir, realpath, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {
  defaultGarconRootCandidates,
  discoverGarconRoot,
  findGarconCliPath,
  MISSING_GARCON_ROOT_MESSAGE,
} from '../lib/garcon-path.ts';

const temporaryPaths: string[] = [];

async function temporaryDirectory(): Promise<string> {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'garcon-path-test-'));
  temporaryPaths.push(directory);
  return directory;
}

async function garconRoot(entryPoint: 'main' | 'main.ts'): Promise<string> {
  const directory = await temporaryDirectory();
  await mkdir(path.join(directory, 'cli'));
  await writeFile(path.join(directory, 'cli', entryPoint), '');
  return directory;
}

afterEach(async () => {
  await Promise.all(temporaryPaths.splice(0).map(
    (directory) => rm(directory, { recursive: true, force: true }),
  ));
});

describe('Garcon root discovery', () => {
  test('uses the fixed first-run candidate order', () => {
    expect(defaultGarconRootCandidates('/home/example')).toEqual([
      '/garcon',
      '/home/example/garcon',
    ]);
  });

  test('selects the first valid root and supported CLI entry point', async () => {
    const first = await garconRoot('main.ts');
    const second = await garconRoot('main');

    await expect(discoverGarconRoot([first, second])).resolves.toEqual({
      garconPath: await realpath(first),
      garconCliPath: path.join(await realpath(first), 'cli', 'main.ts'),
    });
    await expect(findGarconCliPath(second)).resolves.toBe(path.join(second, 'cli', 'main'));
  });

  test('skips missing and invalid candidates before using the home root', async () => {
    const missing = path.join(await temporaryDirectory(), 'missing');
    const invalid = await temporaryDirectory();
    const homeRoot = await garconRoot('main.ts');

    await expect(discoverGarconRoot([missing, invalid, homeRoot])).resolves.toEqual({
      garconPath: await realpath(homeRoot),
      garconCliPath: path.join(await realpath(homeRoot), 'cli', 'main.ts'),
    });
  });

  test('fails closed with an explicit user-escalation instruction', async () => {
    const missing = path.join(await temporaryDirectory(), 'missing');
    const invalid = await temporaryDirectory();

    await expect(discoverGarconRoot([missing, invalid])).resolves.toBeUndefined();
    expect(MISSING_GARCON_ROOT_MESSAGE).toContain('stop and ask the user for the Garcon path');
    expect(MISSING_GARCON_ROOT_MESSAGE).toContain('--garcon-path <absolute-path>');
  });
});
