import path from 'node:path';
import { realpath, stat } from 'node:fs/promises';

export const MISSING_GARCON_ROOT_MESSAGE =
  'no Garcon path was provided and no valid repository was found at /garcon or $HOME/garcon; stop and ask the user for the Garcon path, then rerun with --garcon-path <absolute-path>';

export interface ResolvedGarconRoot {
  readonly garconPath: string;
  readonly garconCliPath: string;
}

export function defaultGarconRootCandidates(home: string): readonly string[] {
  return ['/garcon', path.join(home, 'garcon')];
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
): Promise<ResolvedGarconRoot | undefined> {
  for (const candidate of candidates) {
    try {
      const garconPath = await realpath(candidate);
      if (!(await stat(garconPath)).isDirectory()) continue;
      const garconCliPath = await findGarconCliPath(garconPath);
      if (garconCliPath !== undefined) return { garconPath, garconCliPath };
    } catch {
      continue;
    }
  }
  return undefined;
}
