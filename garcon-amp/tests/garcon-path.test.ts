import { afterEach, describe, expect, test } from 'bun:test';
import { chmod, mkdtemp, mkdir, realpath, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {
  defaultGarconRootCandidates,
  discoverGarconCli,
  discoverGarconRoot,
  findGarconCliPath,
  MISSING_GARCON_CLI_MESSAGE,
  resolveGarconCliExecutable,
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

async function garconExecutable(): Promise<string> {
  const directory = await temporaryDirectory();
  const executable = path.join(directory, 'garcon-cli');
  await writeFile(executable, '#!/bin/sh\n', { mode: 0o700 });
  return executable;
}

afterEach(async () => {
  await Promise.all(temporaryPaths.splice(0).map(
    (directory) => rm(directory, { recursive: true, force: true }),
  ));
});

describe('Garcon CLI discovery', () => {
  test('uses the fixed first-run candidate order', () => {
    expect(defaultGarconRootCandidates('/home/example')).toEqual([
      '/home/example/garcon',
      '/garcon',
    ]);
  });

  test('prefers an executable from PATH over repository candidates', async () => {
    const executable = await garconExecutable();
    const root = await garconRoot('main.ts');

    await expect(discoverGarconCli(executable, [root])).resolves.toEqual({
      garconPath: path.dirname(executable),
      garconCliPath: executable,
      garconCliRunner: 'direct',
    });

    await chmod(executable, 0o600);
    await expect(resolveGarconCliExecutable(executable)).resolves.toBeUndefined();
    await expect(discoverGarconCli(executable, [root])).resolves.toEqual({
      garconPath: await realpath(root),
      garconCliPath: path.join(await realpath(root), 'cli', 'main.ts'),
      garconCliRunner: 'bun',
    });
  });

  test('selects the first valid root and supported CLI entry point', async () => {
    const first = await garconRoot('main.ts');
    const second = await garconRoot('main');

    await expect(discoverGarconRoot([first, second])).resolves.toEqual({
      garconPath: await realpath(first),
      garconCliPath: path.join(await realpath(first), 'cli', 'main.ts'),
      garconCliRunner: 'bun',
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
      garconCliRunner: 'bun',
    });
  });

  test('fails closed with an explicit user-escalation instruction', async () => {
    const missing = path.join(await temporaryDirectory(), 'missing');
    const invalid = await temporaryDirectory();

    await expect(discoverGarconRoot([missing, invalid])).resolves.toBeUndefined();
    expect(MISSING_GARCON_CLI_MESSAGE).toContain('garcon-cli was not found on PATH');
    expect(MISSING_GARCON_CLI_MESSAGE.indexOf('$HOME/garcon'))
      .toBeLessThan(MISSING_GARCON_CLI_MESSAGE.indexOf('then /garcon'));
    expect(MISSING_GARCON_CLI_MESSAGE).toContain('stop and ask the user for the Garcon path');
    expect(MISSING_GARCON_CLI_MESSAGE).toContain('--garcon-path <absolute-path>');
  });
});
