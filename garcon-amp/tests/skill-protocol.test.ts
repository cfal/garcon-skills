import { describe, expect, test } from 'bun:test';
import path from 'node:path';
import {
  defaultGarconRootCandidates,
  discoverGarconRoot,
} from '../lib/garcon-path.ts';

const skill = await Bun.file(new URL('../SKILL.md', import.meta.url)).text();
const openAiMetadata = await Bun.file(new URL('../agents/openai.yaml', import.meta.url)).text();

const requestMarker = '<garcon-get-chat-id />';
const disclosureEnvelope = '<garcon-chat-id>[0-9]{16}</garcon-chat-id>';
const discoveryNoticeTitle = 'Chat ID auto-discovery';

function exportedString(source: string, name: string): string {
  const match = source.match(new RegExp(`export const ${name} = (["'])(.*?)\\1;`));
  if (match === null) throw new Error(`Garcon protocol constant not found: ${name}`);
  return match[2];
}

describe('skill activation protocol', () => {
  test('keeps chat-ID discovery exact, single-shot, and fail-closed', () => {
    const discoveryStart = skill.indexOf('Setup needs a verified 16-digit Garcon chat ID');
    const discoveryEnd = skill.indexOf('`--garcon-path` is optional.');
    const discovery = skill.slice(discoveryStart, discoveryEnd);

    expect(discoveryStart).toBeGreaterThan(-1);
    expect(discoveryEnd).toBeGreaterThan(discoveryStart);
    expect(skill.split(requestMarker)).toHaveLength(2);
    for (const requiredPhrase of [
      disclosureEnvelope,
      'as the entire assistant text message',
      'never in reasoning',
      'surrounding whitespace, prose, or formatting',
      'then end the turn',
      'at most once across',
      'direct control continuation',
      'Do not call a tool, delay, or poll',
      'starts one direct control run',
      "provider's optional steering preamble",
      "this skill's intact packet from a successful setup call",
      'if both exist and disagree, stop and ask',
    ]) {
      expect(discovery).toContain(requiredPhrase);
    }
    for (const obsoletePhrase of ['two seconds', 'tool boundary']) {
      expect(discovery).not.toContain(obsoletePhrase);
    }
    expect(new TextEncoder().encode(discovery).byteLength).toBeLessThanOrEqual(1_400);

    const disclosureIndex = discovery.indexOf('The fresh disclosure for this activation is authoritative');
    const userIndex = discovery.indexOf('an explicit current-chat user ID');
    const packetIndex = discovery.indexOf('then the trusted packet');
    expect(disclosureIndex).toBeGreaterThan(-1);
    expect(userIndex).toBeGreaterThan(disclosureIndex);
    expect(packetIndex).toBeGreaterThan(userIndex);
  });

  test('advertises activation without requiring a known chat ID', () => {
    expect(skill).not.toContain('when the current Garcon chat ID has been provided');
    expect(openAiMetadata).toContain('Discover and validate the current Garcon chat ID');
    expect(openAiMetadata).not.toContain('with the current Garcon chat ID');
  });

  test('matches installed Garcon protocol constants when available', async () => {
    const home = process.env.HOME ?? '/nonexistent-home';
    const root = await discoverGarconRoot(defaultGarconRootCandidates(home));
    let installedMarker = requestMarker;
    let installedEnvelope = disclosureEnvelope;
    let installedNoticeTitle = discoveryNoticeTitle;

    if (root !== undefined) {
      const commandFile = Bun.file(path.join(
        root.garconPath,
        'common/garcon-commands.ts',
      ));
      if (await commandFile.exists()) {
        installedMarker = exportedString(
          await commandFile.text(),
          'GARCON_GET_CHAT_ID',
        );
      }
      const disclosureFile = Bun.file(path.join(
        root.garconPath,
        'common/chat-id-discovery.ts',
      ));
      if (await disclosureFile.exists()) {
        const source = await disclosureFile.text();
        installedNoticeTitle = exportedString(source, 'CHAT_ID_DISCOVERY_NOTICE_TITLE');
        installedEnvelope = [
          exportedString(source, 'CHAT_ID_DISCLOSURE_OPEN'),
          '[0-9]{16}',
          exportedString(source, 'CHAT_ID_DISCLOSURE_CLOSE'),
        ].join('');
      }
    }

    expect(requestMarker).toBe(installedMarker);
    expect(disclosureEnvelope).toBe(installedEnvelope);
    expect(skill).toContain(installedNoticeTitle);
  });
});
