import { describe, expect, test } from 'bun:test';
import path from 'node:path';

const skill = await Bun.file(new URL('../SKILL.md', import.meta.url)).text();
const metadata = await Bun.file(new URL('../agents/openai.yaml', import.meta.url)).text();
const adversarial = await Bun.file(new URL('../../adversarial-chat/SKILL.md', import.meta.url)).text();

const sendPrefix = '<garcon-send-message';
const sendClose = '</garcon-send-message>';
const messageOpen = '<garcon-message>';
const messageClose = '</garcon-message>';

async function installedProtocolSource(): Promise<string | undefined> {
  const home = process.env.HOME ?? '/nonexistent-home';
  for (const root of ['/garcon', path.join(home, 'garcon')]) {
    const file = Bun.file(path.join(root, 'common/garcon-commands.ts'));
    if (await file.exists()) return file.text();
  }
  return undefined;
}

describe('Garcon message skill protocol', () => {
  test('uses only the in-band message command', () => {
    expect(skill).toContain(
      '<garcon-send-message to="<TARGET_CHAT_ID>[, <TARGET_CHAT_ID>...]" hide-sender="false">',
    );
    expect(skill).toContain('<garcon-message from="<SOURCE_CHAT_ID>">');
    expect(skill).toContain('1–16 unique, valid 16-digit target chat IDs');
    expect(skill).toContain('at most 61,440 UTF-8 bytes');
    expect(skill).toContain('never ask for the caller\'s chat ID or invoke the Garcon CLI');
    expect(skill).not.toContain('/garcon/cli/main');
    expect(skill).not.toContain('send-async');
    expect(skill).not.toContain('--allow-steer');
    expect(skill).not.toContain('CALLING_CHAT_ID');
  });

  test('uses the garcon-message name in metadata and consumers', () => {
    expect(metadata).toContain('$garcon-message');
    expect(metadata).not.toContain('$garcon-msg');
    expect(metadata).not.toContain('$garcon-chat');
    expect(adversarial).toContain('a `garcon-message` live review');
    expect(adversarial).not.toContain('`garcon-msg`');
    expect(adversarial).not.toContain('`garcon-chat`');
    expect(adversarial).not.toContain("If you don't know your own chat ID");
  });

  test('matches installed Garcon command constants when available', async () => {
    const source = await installedProtocolSource();
    if (source === undefined) return;

    expect(source).toContain(`export const GARCON_SEND_MESSAGE_PREFIX = '${sendPrefix}';`);
    expect(source).toContain(`export const GARCON_SEND_MESSAGE_CLOSE = '${sendClose}';`);
    expect(source).toContain(`export const GARCON_MESSAGE_OPEN = '${messageOpen}';`);
    expect(source).toContain(`export const GARCON_MESSAGE_CLOSE = '${messageClose}';`);
    expect(source).toContain('export const MAX_GARCON_MESSAGE_RECIPIENTS = 16;');
    expect(source).toContain('export const GARCON_MESSAGE_BODY_MAX_BYTES = 60 * 1024;');
  });
});
