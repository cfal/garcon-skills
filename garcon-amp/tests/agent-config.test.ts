import { describe, expect, test } from 'bun:test';
import {
  canonicalAgentSpec,
  canonicalAgentSpecList,
  levelFor,
  parseAgentSpec,
  parseAgentSpecList,
  providerFor,
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

  test('keeps packaged role defaults canonical and in registry order', () => {
    expect(ROLE_NAMES).toEqual(['oracle', 'finder', 'librarian', 'reporter']);
    const assignments = bundledDefaults.trimEnd().split('\n').map((assignment) => {
      const separator = assignment.indexOf('=');
      return {
        role: assignment.slice(0, separator),
        spec: assignment.slice(separator + 1),
      };
    });
    expect(assignments).toHaveLength(ROLE_NAMES.length);
    expect(assignments.map(({ role }) => role)).toEqual(ROLE_NAMES);
    for (const { spec } of assignments) {
      expect(canonicalAgentSpec(parseAgentSpec(spec))).toBe(spec);
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
});
