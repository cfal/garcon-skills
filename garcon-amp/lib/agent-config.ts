export const ROLE_NAMES = ['oracle', 'finder', 'librarian', 'reporter'] as const;

const AGENT_NAMES = ['codex', 'claude', 'pi', 'opencode'] as const;
const RESERVED_SPEC_ALIAS_NAMES = new Set<string>(AGENT_NAMES);

export type RoleName = (typeof ROLE_NAMES)[number];

const CODEX_EFFORTS = ['default', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'] as const;
const CLAUDE_EFFORTS = ['default', 'low', 'medium', 'high', 'xhigh', 'max'] as const;
const PI_EFFORTS = ['default', 'off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'] as const;

type CodexEffort = (typeof CODEX_EFFORTS)[number];
type ClaudeEffort = (typeof CLAUDE_EFFORTS)[number];
type PiEffort = (typeof PI_EFFORTS)[number];

export type AgentConfig =
  | { agent: 'codex'; model: string; effort: CodexEffort }
  | { agent: 'claude'; model: string; effort: ClaudeEffort }
  | { agent: 'pi'; provider: string; model: string; effort: PiEffort }
  | { agent: 'opencode'; provider: string; model: string; variant: string };

export type SpecAliasMap = ReadonlyMap<string, string>;

function assertValue(kind: string, value: string) {
  if (!value || /[:,\u0000\r\n]/.test(value)) throw new Error(`invalid ${kind}`);
}

function assertProvider(provider: string) {
  if (!/^[A-Za-z0-9._-]+$/.test(provider)) throw new Error('invalid provider');
}

function parseLevel<const T extends readonly string[]>(kind: string, value: string, allowed: T): T[number] {
  if (!allowed.includes(value as T[number])) throw new Error(`invalid ${kind}: ${value || '<empty>'}`);
  return value as T[number];
}

export function parseAgentSpec(spec: string): AgentConfig {
  const fields = spec.split(':');
  const agent = fields[0];

  switch (agent) {
    case 'codex': {
      if (fields.length !== 3) throw new Error('codex requires model and effort');
      const model = fields[1]!;
      assertValue('model', model);
      return { agent, model, effort: parseLevel('codex effort', fields[2]!, CODEX_EFFORTS) };
    }
    case 'claude': {
      if (fields.length !== 3) throw new Error('claude requires model and effort');
      const model = fields[1]!;
      assertValue('model', model);
      return { agent, model, effort: parseLevel('claude effort', fields[2]!, CLAUDE_EFFORTS) };
    }
    case 'pi': {
      if (fields.length !== 4) throw new Error('pi requires provider, model, and effort');
      const provider = fields[1]!;
      const model = fields[2]!;
      assertProvider(provider);
      assertValue('model', model);
      return { agent, provider, model, effort: parseLevel('pi effort', fields[3]!, PI_EFFORTS) };
    }
    case 'opencode': {
      if (fields.length !== 4) throw new Error('opencode requires provider, model, and variant');
      const provider = fields[1]!;
      const model = fields[2]!;
      const variant = fields[3]!;
      assertProvider(provider);
      assertValue('model', model);
      assertValue('opencode variant', variant);
      return { agent, provider, model, variant };
    }
    default:
      throw new Error(`unsupported agent: ${agent || '<empty>'}`);
  }
}

export function parseSpecAliasName(name: string) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name)) {
    throw new Error(`invalid spec alias name: ${name || '<empty>'}`);
  }
  if (RESERVED_SPEC_ALIAS_NAMES.has(name)) {
    throw new Error(`reserved spec alias name: ${name}`);
  }
  return name;
}

export function parseSpecAliasTarget(target: string) {
  try {
    return canonicalAgentSpec(parseAgentSpec(target));
  } catch {
    const fields = target.split(':');
    const agent = fields[0];

    switch (agent) {
      case 'codex':
      case 'claude':
        if (fields.length !== 2) break;
        assertValue('model', fields[1]!);
        return target;
      case 'pi':
      case 'opencode':
        if (fields.length !== 3) break;
        assertProvider(fields[1]!);
        assertValue('model', fields[2]!);
        return target;
    }
  }
  throw new Error('spec alias target must be a complete agent spec or omit only its final level');
}

export function resolveAgentSpecAlias(spec: string, aliases: SpecAliasMap) {
  const separator = spec.indexOf(':');
  const name = separator === -1 ? spec : spec.slice(0, separator);
  const target = aliases.get(name);
  return target === undefined ? spec : `${target}${spec.slice(name.length)}`;
}

export function parseAgentSpecWithAliases(spec: string, aliases: SpecAliasMap) {
  const resolved = resolveAgentSpecAlias(spec, aliases);
  try {
    return parseAgentSpec(resolved);
  } catch (error) {
    if (resolved !== spec) {
      const separator = spec.indexOf(':');
      const name = separator === -1 ? spec : spec.slice(0, separator);
      throw new Error(`alias "${name}" resolved to "${resolved}": ${error.message}`);
    }
    throw error;
  }
}

export function canonicalAgentSpec(config: AgentConfig) {
  switch (config.agent) {
    case 'codex':
    case 'claude':
      return `${config.agent}:${config.model}:${config.effort}`;
    case 'pi':
      return `${config.agent}:${config.provider}:${config.model}:${config.effort}`;
    case 'opencode':
      return `${config.agent}:${config.provider}:${config.model}:${config.variant}`;
  }
}

export function parseAgentSpecList(value: string, aliases?: SpecAliasMap) {
  const specs = value.split(',');
  if (specs.some((spec) => spec === '')) {
    throw new Error('agent spec list contains an empty entry');
  }

  const configs = aliases === undefined
    ? specs.map(parseAgentSpec)
    : specs.map((spec) => parseAgentSpecWithAliases(spec, aliases));
  const canonicalSpecs = configs.map(canonicalAgentSpec);
  if (new Set(canonicalSpecs).size !== canonicalSpecs.length) {
    const changed = specs.some((spec, index) => spec !== canonicalSpecs[index]);
    throw new Error(`agent spec list contains a duplicate${changed ? ' after alias resolution' : ''}`);
  }
  return configs;
}

export function canonicalAgentSpecList(configs: readonly AgentConfig[]) {
  return configs.map(canonicalAgentSpec).join(',');
}

export function providerFor(config: AgentConfig) {
  return 'provider' in config ? config.provider : '';
}

export function levelFor(config: AgentConfig) {
  return config.agent === 'opencode' ? config.variant : config.effort;
}
