import { describe, expect, test } from 'bun:test';

const skill = await Bun.file(new URL('../SKILL.md', import.meta.url)).text();

describe('Garcon Agent skill', () => {
  test('resolves the Garcon CLI in the required order', () => {
    const pathIndex = skill.indexOf('command -v garcon-cli');
    const homeIndex = skill.indexOf('"$HOME/garcon"', pathIndex);
    const rootIndex = skill.indexOf(' /garcon;', homeIndex);
    const askIndex = skill.indexOf('stop and ask the user for the Garcon repository path', rootIndex);

    expect(pathIndex).toBeGreaterThan(-1);
    expect(homeIndex).toBeGreaterThan(pathIndex);
    expect(rootIndex).toBeGreaterThan(homeIndex);
    expect(askIndex).toBeGreaterThan(rootIndex);
    expect(skill).toContain('"${GARCON_CLI[@]}" --version');
    expect(skill).not.toContain('bun /garcon/cli/main');
  });
});
