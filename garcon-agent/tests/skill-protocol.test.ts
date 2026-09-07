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

  test('uses explicit lifecycle commands', () => {
    const startSection = skill.slice(
      skill.indexOf('## Start Chat'),
      skill.indexOf('## Resume Chat'),
    );
    const resumeSection = skill.slice(
      skill.indexOf('## Resume Chat'),
      skill.indexOf('## Resume Chat Asynchronously'),
    );
    const resumeAsyncSection = skill.slice(
      skill.indexOf('## Resume Chat Asynchronously'),
      skill.indexOf('## Return The Result'),
    );

    expect(startSection.split('\n')).toContain('  start \\');
    expect(resumeSection.split('\n')).toContain('  resume "$CHAT_ID" \\');
    expect(resumeSection).not.toContain('--resume');
    expect(resumeAsyncSection.split('\n')).toContain('  resume-async "$CHAT_ID" \\');
    expect(resumeAsyncSection).not.toContain('send-async');
    expect(skill).toContain('turn id: <turn-id>');
  });
});
