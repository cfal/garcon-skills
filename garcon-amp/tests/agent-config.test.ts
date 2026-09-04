import { describe, expect, test } from 'bun:test';
import {
  canonicalAgentSpec,
  canonicalAgentSpecList,
  levelFor,
  parseAgentSpec,
  parseAgentSpecList,
  parseAgentSpecWithAliases,
  parseSpecAliasName,
  parseSpecAliasTarget,
  providerFor,
  resolveAgentSpecAlias,
  ROLE_NAMES,
} from '../lib/agent-config.ts';

const bundledDefaults = await Bun.file(new URL('../defaults.conf', import.meta.url)).text();

describe('agent specifications', () => {
  test('parses and canonicalizes every supported grammar', () => {
    const cases = [
      {
        spec: 'codex:GPT-5.6-Sol:max',
        expected: { agent: 'codex', model: 'GPT-5.6-Sol', effort: 'max' },
        provider: '',
        level: 'max',
      },
      {
        spec: 'claude:opus-5:default',
        expected: { agent: 'claude', model: 'opus-5', effort: 'default' },
        provider: '',
        level: 'default',
      },
      {
        spec: 'pi:openai-codex:gpt_5.6.sol:xhigh',
        expected: { agent: 'pi', provider: 'openai-codex', model: 'gpt_5.6.sol', effort: 'xhigh' },
        provider: 'openai-codex',
        level: 'xhigh',
      },
      {
        spec: 'opencode:Anthropic.v2:claude-opus-5:max-plus',
        expected: {
          agent: 'opencode',
          provider: 'Anthropic.v2',
          model: 'claude-opus-5',
          variant: 'max-plus',
        },
        provider: 'Anthropic.v2',
        level: 'max-plus',
      },
    ] as const;

    for (const entry of cases) {
      const parsed = parseAgentSpec(entry.spec);
      expect(parsed).toEqual(entry.expected);
      expect(canonicalAgentSpec(parsed)).toBe(entry.spec);
      expect(providerFor(parsed)).toBe(entry.provider);
      expect(levelFor(parsed)).toBe(entry.level);
    }
  });

  test('keeps packaged profiles valid and in registry order', () => {
    expect(ROLE_NAMES).toEqual(['oracle', 'finder', 'librarian', 'reporter']);
    const lines = bundledDefaults.trimEnd().split('\n');
    const aliases = new Map(lines
      .filter((line) => line.startsWith('spec-alias:'))
      .map((line) => {
        const separator = line.indexOf('=');
        const name = line.slice('spec-alias:'.length, separator);
        return [name, parseSpecAliasTarget(line.slice(separator + 1))];
      }));
    const defaultProfile = lines.find((line) => line.startsWith('default-profile='))
      ?.slice('default-profile='.length);
    const profileHeaders = lines
      .map((line, index) => line.startsWith('[profile:') ? index : -1)
      .filter((index) => index !== -1);

    expect(defaultProfile).toBe('medium');
    expect(profileHeaders).toHaveLength(2);
    expect(lines).toContain(`[profile:${defaultProfile}]`);
    for (const headerIndex of profileHeaders) {
      const assignments = ROLE_NAMES.map((role, index) => {
        const assignment = lines[headerIndex + index + 1];
        const prefix = `${role}=`;
        expect(assignment.startsWith(prefix)).toBe(true);
        return { role, spec: assignment.slice(prefix.length) };
      });
      expect(assignments.map(({ role }) => role)).toEqual(ROLE_NAMES);
      for (const { spec } of assignments) {
        expect(canonicalAgentSpecList(parseAgentSpecList(spec, aliases))).not.toBe('');
      }
    }
  });

  test('parses canonical agent-spec lists without reordering reviewers', () => {
    const value = 'claude:opus-5:high,codex:gpt-5.6-sol:max,pi:openai:model:low';
    const configs = parseAgentSpecList(value);

    expect(configs.map(({ agent }) => agent)).toEqual(['claude', 'codex', 'pi']);
    expect(canonicalAgentSpecList(configs)).toBe(value);
    for (const invalid of [
      '',
      'codex:model:high,',
      ',codex:model:high',
      'codex:model:high,,claude:model:low',
      'codex:model:high,codex:model:high',
    ]) {
      expect(() => parseAgentSpecList(invalid)).toThrow();
    }
  });

  test('rejects malformed specifications', () => {
    const invalid = [
      '',
      'Codex:gpt-5.6-sol:max',
      'unknown:model:max',
      'codex:model',
      'codex:model:max:extra',
      'codex::max',
      'codex:model:off',
      'codex:model\nname:max',
      'codex:model,name:max',
      'claude:model',
      'claude:model:max:extra',
      'claude::max',
      'claude:model:minimal',
      'pi:provider:model',
      'pi:provider:model:high:extra',
      'pi::model:high',
      'pi:provider name:model:high',
      'pi:provider/name:model:high',
      'pi:provider::high',
      'pi:provider:model:turbo',
      'opencode:provider:model',
      'opencode:provider:model:max:extra',
      'opencode::model:max',
      'opencode:provider::max',
      'opencode:provider:model:',
      'opencode:provider:model:\n',
    ];

    for (const spec of invalid) {
      expect(() => parseAgentSpec(spec)).toThrow();
    }
  });

  test('validates and resolves single-pass spec aliases', () => {
    const aliases = new Map([
      ['k3', 'opencode:moonshotai:kimi-k3:high'],
      ['glm-5.3', 'opencode:zhipuai-coding-plan:glm-5.3'],
      ['nested', 'k3'],
    ]);

    expect(parseSpecAliasName('GLM_5.3-fast')).toBe('GLM_5.3-fast');
    for (const name of ['', '.hidden', 'contains space', 'codex', 'claude', 'pi', 'opencode']) {
      expect(() => parseSpecAliasName(name)).toThrow();
    }

    for (const target of [
      'codex:model',
      'codex:model:high',
      'claude:model',
      'claude:model:xhigh',
      'pi:provider:model',
      'pi:provider:model:high',
      'opencode:provider:model',
      'opencode:provider:model:fast',
    ]) {
      expect(parseSpecAliasTarget(target)).toBe(target);
    }
    for (const target of [
      '',
      'k3',
      'k3:high',
      'codex',
      'codex:model:invalid',
      'pi:provider',
      'pi:bad provider:model',
      'opencode:provider:model:variant:extra',
    ]) {
      expect(() => parseSpecAliasTarget(target)).toThrow();
    }

    expect(resolveAgentSpecAlias('k3', aliases)).toBe('opencode:moonshotai:kimi-k3:high');
    expect(resolveAgentSpecAlias('glm-5.3:max', aliases))
      .toBe('opencode:zhipuai-coding-plan:glm-5.3:max');
    expect(resolveAgentSpecAlias('GLM-5.3:max', aliases)).toBe('GLM-5.3:max');
    expect(resolveAgentSpecAlias('glm-5.3-extra:max', aliases)).toBe('glm-5.3-extra:max');
    expect(() => parseAgentSpecWithAliases('nested:high', aliases)).toThrow(
      'alias "nested" resolved to "k3:high"',
    );
    expect(canonicalAgentSpec(parseAgentSpecWithAliases('glm-5.3:max', aliases)))
      .toBe('opencode:zhipuai-coding-plan:glm-5.3:max');
    expect(() => parseAgentSpecList(
      'k3,opencode:moonshotai:kimi-k3:high',
      aliases,
    )).toThrow('duplicate after alias resolution');
  });
});
