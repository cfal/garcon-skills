import path from 'node:path';
import { realpath, stat } from 'node:fs/promises';

export const MISSING_GARCON_CLI_MESSAGE =
  'no Garcon path was provided, garcon-cli was not found on PATH, and neither repository candidate was valid ($HOME/garcon, then /garcon); stop and ask the user for the Garcon path, then rerun with --garcon-path <absolute-path>';

export interface ResolvedGarconCli {
  readonly garconPath: string;
  readonly garconCliPath: string;
  readonly garconCliRunner: 'bun' | 'direct';
}

export function defaultGarconRootCandidates(home: string): readonly string[] {
  return [path.join(home, 'garcon'), '/garcon'];
}

export async function findGarconCliPath(garconPath: string): Promise<string | undefined> {
  for (const relativePath of ['cli/main', 'cli/main.ts']) {
    const candidate = path.join(garconPath, relativePath);
    try {
      if ((await stat(candidate)).isFile()) return candidate;
    } catch {
      continue;
    }
  }
  return undefined;
}

export async function discoverGarconRoot(
  candidates: readonly string[],
): Promise<ResolvedGarconCli | undefined> {
  for (const candidate of candidates) {
    try {
      const garconPath = await realpath(candidate);
      if (!(await stat(garconPath)).isDirectory()) continue;
      const garconCliPath = await findGarconCliPath(garconPath);
      if (garconCliPath !== undefined) {
        return { garconPath, garconCliPath, garconCliRunner: 'bun' };
      }
    } catch {
      continue;
    }
  }
  return undefined;
}

export async function resolveGarconCliExecutable(
  executablePath: string,
): Promise<ResolvedGarconCli | undefined> {
  try {
    const garconCliPath = path.resolve(executablePath);
    const executable = await stat(garconCliPath);
    if (!executable.isFile() || (executable.mode & 0o111) === 0) return undefined;
    return {
      garconPath: await realpath(path.dirname(garconCliPath)),
      garconCliPath,
      garconCliRunner: 'direct',
    };
  } catch {
    return undefined;
  }
}

export async function discoverGarconCli(
  executablePath: string | undefined,
  rootCandidates: readonly string[],
): Promise<ResolvedGarconCli | undefined> {
  if (executablePath !== undefined) {
    const executable = await resolveGarconCliExecutable(executablePath);
    if (executable !== undefined) return executable;
  }
  return discoverGarconRoot(rootCandidates);
}
