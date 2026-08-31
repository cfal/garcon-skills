import { afterEach, describe, expect, test } from 'bun:test';
import { mkdtemp, rm, stat, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {
  scanCanonicalGarconXml,
  type GarconXmlArea,
  type GarconXmlEntry,
} from '../lib/transcript-xml.ts';

const cliPath = path.resolve(import.meta.dir, '..', 'transcript-query');
const temporaryDirectories: string[] = [];

interface CliResult {
  readonly exitCode: number;
  readonly stdout: string;
  readonly stderr: string;
}

async function temporaryDirectory(): Promise<string> {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'transcript-query-test-'));
  temporaryDirectories.push(directory);
  return directory;
}

async function fixture(name: string, content: string): Promise<string> {
  const directory = await temporaryDirectory();
  const filePath = path.join(directory, name);
  await writeFile(filePath, content);
  return filePath;
}

async function runCli(...args: string[]): Promise<CliResult> {
  const process = Bun.spawn([cliPath, ...args], { stdout: 'pipe', stderr: 'pipe' });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(process.stdout).text(),
    new Response(process.stderr).text(),
    process.exited,
  ]);
  return { exitCode, stdout, stderr };
}

function transcript(entries: string, metadata = ''): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<transcript-export version="1">
  <chat id="1111222233334444" title="Fixture" agent="codex"/>
${metadata}  <entries>
${entries}  </entries>
</transcript-export>
`;
}

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map(
    (directory) => rm(directory, { recursive: true, force: true }),
  ));
});

describe('canonical Garcon transcript XML scanner', () => {
  test('streams decoded areas without confusing escaped markup for entries', async () => {
    const filePath = await fixture('transcript.xml', transcript(`    <user ordinal="2" origin="cli" title="A &amp; B">
      <text>line one
line two &amp; &lt;assistant ordinal="99999"&gt; &amp;#65;</text>
      <images bodies-omitted="true">
        <image name="screen &amp; shot" media-type="image/png" encoded-bytes="42"/>
      </images>
    </user>
    <tool-call ordinal="7" type="bash-tool-use" tool-id="tool-&quot;x&quot;&amp;y">
      <field name="command" encoding="json">printf &quot;ok&quot;</field>
    </tool-call>
    <run-ended ordinal="9"/>
`));
    const openings: Array<readonly [number, string]> = [];
    const areas: Array<{ readonly ordinal: number; readonly area: string; text: string }> = [];
    let active: { readonly entry: GarconXmlEntry; readonly area: GarconXmlArea; text: string } | undefined;
    const document = await scanCanonicalGarconXml(filePath, {
      onEntryStart(entry) {
        openings.push([entry.ordinal, entry.tag]);
      },
      onAreaStart(entry, area) {
        active = { entry, area, text: '' };
      },
      onAreaText(_entry, _area, text) {
        if (active) active.text += text;
      },
      onAreaEnd() {
        if (!active) return;
        areas.push({
          ordinal: active.entry.ordinal,
          area: `${active.area.kind}:${active.area.name}`,
          text: active.text,
        });
        active = undefined;
      },
    }, { chunkSize: 7 });

    expect(document.entryCount).toBe(3);
    expect(document.firstOrdinal).toBe(2);
    expect(document.lastOrdinal).toBe(9);
    expect(openings).toEqual([[2, 'user'], [7, 'tool-call'], [9, 'run-ended']]);
    expect(areas).toContainEqual({ ordinal: 2, area: 'attribute:title', text: 'A & B' });
    expect(areas).toContainEqual({
      ordinal: 2,
      area: 'text:text',
      text: 'line one\nline two & <assistant ordinal="99999"> &#65;',
    });
    expect(areas).toContainEqual({
      ordinal: 2,
      area: 'attribute:image.name',
      text: 'screen & shot',
    });
    expect(areas).toContainEqual({
      ordinal: 2,
      area: 'attribute:images.bodies-omitted',
      text: 'true',
    });
    expect(areas).toContainEqual({ ordinal: 7, area: 'attribute:tool-id', text: 'tool-"x"&y' });
    expect(areas).toContainEqual({
      ordinal: 7,
      area: 'attribute:field.command.encoding',
      text: 'json',
    });
  });

  test('accepts handoff metadata in arbitrary attribute order and preserves gaps', async () => {
    const filePath = await fixture('handoff.xml', `<?xml version="1.0" encoding="UTF-8"?>
<handoff-artifact source-entries="3" version="1" fold="handoff-v1" chat-id="1111222233334444">
  <chat agent="codex" title="Fixture"/>
  <fixed-fold-excluded diagnostics="1"/>
  <entries>
    <user origin="cli" ordinal="2">
      <text>first</text>
    </user>
    <gap omitted-entries="1" after-ordinal="2" before-ordinal="8"/>
    <assistant abridged="true" ordinal="8">
      <text>last</text>
    </assistant>
  </entries>
</handoff-artifact>
`);
    const document = await scanCanonicalGarconXml(filePath, {}, { chunkSize: 5 });
    expect(document.kind).toBe('handoff-artifact');
    expect(document.rootAttributes.get('fold')).toBe('handoff-v1');
    expect(document.gaps).toEqual([{ afterOrdinal: 2, beforeOrdinal: 8, omittedEntries: 1 }]);
  });

  test('accepts and reports structurally valid renderer extensions', async () => {
    const filePath = await fixture('extended.xml', transcript(`    <future-event2 ordinal="2">
      <text>future body</text>
    </future-event2>
`, '  <future-metadata schema="2"/>\n'));
    const document = await scanCanonicalGarconXml(filePath);
    expect(document.unknownEntryTags).toEqual(['future-event2']);
    expect(document.unknownMetadataTags).toEqual(['future-metadata']);

    const result = await runCli('doc', filePath);
    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain('future-metadata\tattribute:schema=2');
    expect(result.stdout).toContain('unknown-entry-tags=1');
    expect(result.stdout).toContain('unknown-metadata-tags=1');
    expect(result.stdout).toContain('gaps=0\tshown=3\ttruncated=false');
    const filtered = await runCli('entries', filePath, '--kind', 'future-event2');
    expect(filtered.exitCode).toBe(0);
    expect(filtered.stdout).toContain('#2\tfuture-event2');
  });

  test('accepts and reports current body structures across document kinds', async () => {
    const handoffPath = await fixture('handoff-fields.xml', `<?xml version="1.0" encoding="UTF-8"?>
<handoff-artifact version="1" chat-id="1111222233334444">
  <chat title="Fixture" agent="codex"/>
  <entries>
    <tool-call ordinal="2">
      <field name="command">printf ok</field>
      <images bodies-omitted="true">
        <image name="screen" media-type="image/png" encoded-bytes="42"/>
      </images>
    </tool-call>
  </entries>
</handoff-artifact>
`);
    const handoff = await scanCanonicalGarconXml(handoffPath);
    expect(handoff.crossKindStructures).toEqual(['field', 'images']);
    const handoffResult = await runCli('show', handoffPath, '--ordinal', '2');
    expect(handoffResult.exitCode).toBe(0);
    expect(handoffResult.stdout).toContain('field:command\tprintf ok');
    expect(handoffResult.stdout).toContain('cross-kind-structures=2');

    const transcriptPath = await fixture('transcript-gap.xml', transcript(`    <user ordinal="2"/>
    <gap omitted-entries="1" after-ordinal="2" before-ordinal="8"/>
    <assistant ordinal="8"/>
`));
    const transcriptDocument = await scanCanonicalGarconXml(transcriptPath);
    expect(transcriptDocument.crossKindStructures).toEqual(['gap']);
    expect(transcriptDocument.gaps).toHaveLength(1);
  });

  test('rejects malformed or noncanonical documents before returning a model-visible result', async () => {
    const cases = [
      ['unknown-root.xml', `${transcript('    <assistant ordinal="2"/>\n').replace('transcript-export', 'other-export')}`],
      ['missing-chat.xml', `<?xml version="1.0" encoding="UTF-8"?>\n<transcript-export version="1">\n  <entries/>\n</transcript-export>\n`],
      ['raw-markup.xml', transcript('    <assistant ordinal="2">\n      <text>raw > text</text>\n    </assistant>\n')],
      ['bad-entity.xml', transcript('    <assistant ordinal="2">\n      <text>&bogus;</text>\n    </assistant>\n')],
      ['raw-attribute.xml', transcript('    <assistant ordinal="2" title="raw<TAG>"/>\n')],
      ['decreasing.xml', transcript('    <assistant ordinal="8"/>\n    <assistant ordinal="2"/>\n')],
      ['bad-indent.xml', transcript('   <assistant ordinal="2"/>\n')],
      ['truncated.xml', transcript('    <assistant ordinal="2">\n      <text>unfinished\n')],
      ['bom.xml', `\uFEFF${transcript('    <assistant ordinal="2"/>\n')}`],
    ] as const;

    for (const [name, content] of cases) {
      const filePath = await fixture(name, content);
      const result = await runCli('entries', filePath);
      expect(result.exitCode).toBe(2);
      expect(result.stdout).toBe('');
      expect(result.stderr).toContain('rejected document');
    }
  });
});

describe('transcript-query CLI', () => {
  test('classifies path and draft IO failures as correctable input errors', async () => {
    const inputDirectory = await temporaryDirectory();
    const missingPath = path.join(inputDirectory, 'missing.xml');
    const relative = await runCli('doc', './missing.xml');
    expect(relative.exitCode).toBe(3);
    expect(relative.stdout).toBe('');
    expect(relative.stderr).toContain('XML path must be absolute');

    const missing = await runCli('doc', missingPath);
    expect(missing.exitCode).toBe(3);
    expect(missing.stderr).not.toContain('rejected document');

    const filePath = await fixture('audit-input.xml', transcript('    <assistant ordinal="2"/>\n'));
    const symlinkPath = path.join(inputDirectory, 'linked.xml');
    await symlink(filePath, symlinkPath);
    for (const invalidPath of [inputDirectory, symlinkPath]) {
      const result = await runCli('doc', invalidPath);
      expect(result.exitCode).toBe(3);
      expect(result.stderr).toContain('regular non-symlink file');
    }

    const invalidPath = await fixture('invalid-before-draft.xml', 'not XML\n');
    const draft = await runCli(
      'audit', invalidPath, '--draft', path.join(path.dirname(filePath), 'missing.md'),
    );
    expect(draft.exitCode).toBe(3);
    expect(draft.stderr).toContain('cannot read --draft');
  });

  test('search returns owning ordinals for hostile and chunk-spanning literals', async () => {
    const hostile = `x") or contains(string(.),"DUPLICATE`;
    const padding = 'a'.repeat(70_000);
    const filePath = await fixture('search.xml', transcript(`    <assistant ordinal="42">
      <text>DUPLICATE_NEEDLE primary</text>
    </assistant>
    <cli-row ordinal="300" origin="cli" title="Oracle response">
      <text>DUPLICATE_NEEDLE derived &lt;assistant ordinal="99999"&gt;</text>
    </cli-row>
    <assistant ordinal="742">
      <text>${padding}before&amp;after approved</text>
    </assistant>
`));

    const duplicates = await runCli('search', filePath, '--literal', 'DUPLICATE_NEEDLE');
    expect(duplicates.exitCode).toBe(0);
    expect(duplicates.stdout).toContain('#42\tassistant\ttext');
    expect(duplicates.stdout).toContain('#300\tcli-row\ttext');
    expect(duplicates.stdout).not.toContain('#99999\t');

    const boundary = await runCli('search', filePath, '--literal', 'before&after', '--snippet', '20');
    expect(boundary.stdout).toContain('#742\tassistant\ttext');
    expect(boundary.stdout).toContain('before&after approved');

    const injection = await runCli('search', filePath, '--literal', hostile);
    expect(injection.exitCode).toBe(0);
    expect(injection.stdout).toContain('matches=0');
    expect(injection.stdout).not.toMatch(/^#/m);
  });

  test('matches exact decoded attributes and emits paired duplicate tool IDs chronologically', async () => {
    const filePath = await fixture('tools.xml', transcript(`    <tool-call ordinal="7" type="bash-tool-use" tool-id="tool-&quot;alpha&quot;&amp;x">
      <field name="command">first</field>
    </tool-call>
    <tool-call ordinal="8" type="bash-tool-use" tool-id="tool-&quot;alpha&quot;&amp;x">
      <field name="command">retry</field>
    </tool-call>
    <tool-result ordinal="9" tool-id="tool-&quot;alpha&quot;&amp;x">
      <field name="output">done &amp; verified</field>
    </tool-result>
`));
    const result = await runCli('tool-id', filePath, '--id', 'tool-"alpha"&x');
    expect(result.exitCode).toBe(0);
    expect(result.stdout.match(/^#(?:7|8|9)\t[^\n]+\tentry/gm)?.map((row) => row.split('\t')[0])).toEqual([
      '#7', '#8', '#9',
    ]);
    expect(result.stdout).toContain('done & verified');
    expect(result.stdout).not.toContain('&amp;');

    const absent = await runCli('tool-id', filePath, '--id', 'missing-id');
    expect(absent.exitCode).toBe(4);
    expect(absent.stdout).toContain('matched=0\tshown=0\tmissing=1');
  });

  test('lists gaps without line coordinates and bounds shown entry content', async () => {
    const filePath = await fixture('handoff.xml', `<?xml version="1.0" encoding="UTF-8"?>
<handoff-artifact version="1" fold="handoff-v1" chat-id="1111222233334444">
  <chat title="Fixture" agent="codex"/>
  <entries>
    <user ordinal="2"><text>invalid compact shape</text></user>
  </entries>
</handoff-artifact>
`);
    const rejected = await runCli('entries', filePath);
    expect(rejected.exitCode).toBe(2);
    expect(rejected.stdout).toBe('');

    const validPath = await fixture('valid-handoff.xml', `<?xml version="1.0" encoding="UTF-8"?>
<handoff-artifact version="1" chat-id="1111222233334444">
  <chat title="Fixture" agent="codex"/>
  <entries>
    <user ordinal="2">
      <text>0123456789\nsecond line</text>
    </user>
    <gap after-ordinal="2" before-ordinal="8" omitted-entries="3"/>
    <assistant ordinal="8" abridged="true"/>
  </entries>
</handoff-artifact>
`);
    const entries = await runCli('entries', validPath);
    expect(entries.exitCode).toBe(0);
    expect(entries.stdout).toContain('gap\tafter-ordinal=2\tbefore-ordinal=8\tomitted-entries=3');
    expect(entries.stdout).not.toMatch(/line[-=]/i);
    const firstPage = await runCli('entries', validPath, '--from', '1', '--to', '2');
    const secondPage = await runCli('entries', validPath, '--from', '3', '--to', '10');
    expect(firstPage.stdout).not.toContain('gap\tafter-ordinal=2');
    expect(secondPage.stdout).toContain('gap\tafter-ordinal=2');
    const limitedFirstPage = await runCli('entries', validPath, '--from', '1', '--limit', '1');
    const limitedSecondPage = await runCli('entries', validPath, '--from', '3', '--limit', '1');
    expect(limitedFirstPage.stdout).not.toContain('gap\tafter-ordinal=2');
    expect(limitedSecondPage.stdout).toContain('gap\tafter-ordinal=2');

    const unanchoredPath = await fixture('unanchored-gap.xml', `<?xml version="1.0" encoding="UTF-8"?>
<handoff-artifact version="1" chat-id="1111222233334444">
  <chat title="Fixture" agent="codex"/>
  <entries>
    <gap omitted-entries="5"/>
  </entries>
</handoff-artifact>
`);
    const unanchored = await runCli('entries', unanchoredPath, '--from', '100', '--to', '200');
    expect(unanchored.stdout).toContain('gap\tomitted-entries=5');
    const shown = await runCli(
      'show', validPath, '--ordinal', '2', '--part', 'text', '--offset', '5', '--max-chars', '4',
    );
    expect(shown.stdout).toContain('#2\tuser\ttext\t5678\tclipped=true');
  });

  test('audits draft endpoints and reserves hash coordinates for verified ordinals', async () => {
    const filePath = await fixture('audit.xml', transcript(`    <user ordinal="2"/>
    <assistant ordinal="42"/>
    <assistant ordinal="742"/>
`));
    const draftPath = await fixture(
      'draft.md',
      [
        'Valid [1111222233334444#742], [#2-#42], and [1111222233334444#2].',
        'Bad [#9002] and [#21966].',
        'Foreign [9999888877776666#5] and [9999888877776666#6].',
      ].join(' '),
    );
    const result = await runCli('audit', filePath, '--draft', draftPath);
    expect(result.exitCode).toBe(4);
    expect(result.stdout).toContain('#2\tpresent\tuser');
    expect(result.stdout).toContain('#42\tpresent\tassistant');
    expect(result.stdout).toContain('#742\tpresent\tassistant');
    expect(result.stdout).toContain('ordinal=9002\tabsent\tabove-last-ordinal');
    expect(result.stdout).toContain('ordinal=21966\tabsent\tabove-last-ordinal');
    expect(result.stdout).not.toContain('#9002\t');
    expect(result.stdout).not.toContain('#21966\t');
    expect(result.stdout).toContain('foreign-citations=2');
    expect(result.stdout.match(/^#\d+\tpresent\t[a-z-]+$/gm)).toEqual([
      '#742\tpresent\tassistant',
      '#2\tpresent\tuser',
      '#42\tpresent\tassistant',
    ]);
  });

  test('deduplicates repeated draft citations before scanning entries', async () => {
    const filePath = await fixture('repeated-audit.xml', transcript('    <assistant ordinal="2"/>\n'));
    const draftPath = await fixture('repeated-draft.md', Array(100_000).fill('[#2]').join(' '));
    const result = await runCli('audit', filePath, '--draft', draftPath);
    expect(result.exitCode).toBe(0);
    expect(result.stdout.match(/^#2\tpresent\tassistant$/gm)).toHaveLength(1);
    expect(result.stdout).toContain(
      'audited=1\tmissing=0\tforeign-citations=0\tunparsed-citations=0\ttruncated=false',
    );
  });

  test('bounds distinct draft citation endpoints before scanning entries', async () => {
    const filePath = await fixture('bounded-audit.xml', transcript('    <assistant ordinal="2"/>\n'));
    const draftPath = await fixture(
      'bounded-draft.md',
      Array.from({ length: 10_001 }, (_, index) => `[#${index + 1}]`).join(' '),
    );
    const result = await runCli('audit', filePath, '--draft', draftPath);
    expect(result.exitCode).toBe(3);
    expect(result.stdout).toBe('');
    expect(result.stderr).toContain('audit exceeds 10000 distinct citation endpoints');
  });

  test('fails citation audit on malformed bracketed ordinal forms', async () => {
    const filePath = await fixture('audit-format.xml', transcript(`    <assistant ordinal="2"/>
    <assistant ordinal="7"/>
`));
    const draftPath = await fixture(
      'malformed-draft.md',
      'Valid [#2]. Invalid [#7, #404], [#3–#404], [see #406], [issue #12], [#0], and [#999999999999999999999].',
    );
    const result = await runCli('audit', filePath, '--draft', draftPath);
    expect(result.exitCode).toBe(4);
    expect(result.stdout).toContain('#2\tpresent\tassistant');
    expect(result.stdout).toContain('citation\tunparsed\t[#7, #404]');
    expect(result.stdout).toContain('citation\tunparsed\t[issue #12]');
    expect(result.stdout).toContain('unparsed-citations=6');
    expect(result.stdout).not.toContain('#404\tpresent');
  });

  test('marks cell-level clipping when requested content exceeds the TSV cell bound', async () => {
    const filePath = await fixture('cell-clipping.xml', transcript(`    <assistant ordinal="2">
      <text>${'x'.repeat(12_000)}</text>
    </assistant>
`));
    const result = await runCli('show', filePath, '--ordinal', '2', '--max-chars', '50000');
    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain('…[cell-clipped]\tclipped=true');
  });

  test('scans a large final-entry match with bounded output', async () => {
    const entries = Array.from({ length: 10_000 }, (_, index) => {
      const ordinal = index + 1;
      return `    <assistant ordinal="${ordinal}">\n      <text>entry ${ordinal}${ordinal === 10_000 ? ' FINAL_TARGET' : ''} ${'x'.repeat(128)}</text>\n    </assistant>\n`;
    }).join('');
    const filePath = await fixture('large.xml', transcript(entries));
    const result = await runCli('search', filePath, '--literal', 'FINAL_TARGET', '--snippet', '20');
    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain('#10000\tassistant\ttext');
    expect(result.stdout.length).toBeLessThan(1_000);
    expect((await stat(filePath)).size).toBeGreaterThan(1_000_000);
  });

  test('hard-caps output from entries with many large fields', async () => {
    const fields = Array.from({ length: 100 }, (_, index) => (
      `      <field name="field-${index}">${'x'.repeat(4_000)}</field>\n`
    )).join('');
    const filePath = await fixture('large-output.xml', transcript(`    <tool-call ordinal="42" type="bash-tool-use">
${fields}    </tool-call>
`));
    const result = await runCli(
      'show', filePath, '--ordinal', '42', '--max-chars', '4000', '--max-lines', '1000',
    );
    expect(result.exitCode).toBe(0);
    expect(Buffer.byteLength(result.stdout)).toBeLessThanOrEqual(64 * 1024);
    expect(result.stdout).toContain('missing=0\ttruncated=true');
    expect(result.stdout).toContain('summary\tentries=1');
  });

  test('returns an entry-row prefix once the output byte budget is exhausted', async () => {
    const oversizedAttributes = Array.from({ length: 10 }, (_, index) => (
      ` value-${index}="${'x'.repeat(8_000)}"`
    )).join('');
    const entries = [
      '    <assistant ordinal="1"/>\n',
      '    <assistant ordinal="2"/>\n',
      `    <assistant ordinal="3"${oversizedAttributes}/>\n`,
      '    <assistant ordinal="4"/>\n',
      '    <assistant ordinal="5"/>\n',
    ].join('');
    const filePath = await fixture('large-attributes.xml', transcript(entries));
    const result = await runCli('entries', filePath, '--limit', '5');
    expect(result.exitCode).toBe(0);
    expect(Buffer.byteLength(result.stdout)).toBeLessThanOrEqual(64 * 1024);
    expect(result.stdout.match(/^#\d+/gm)).toEqual(['#1', '#2']);
    expect(result.stdout).toContain('matched=5\tshown=2\ttruncated=true');
  });

  test('does not emit later entry openings after a show row exhausts the byte budget', async () => {
    const entries = Array.from({ length: 20 }, (_, index) => (
      `    <assistant ordinal="${index + 1}">\n      <text>${'x'.repeat(4_000)}</text>\n    </assistant>\n`
    )).join('');
    const filePath = await fixture('large-show.xml', transcript(entries));
    const result = await runCli(
      'show', filePath, '--range', '1-20', '--limit', '20', '--max-chars', '4000',
    );
    expect(result.exitCode).toBe(0);
    expect(Buffer.byteLength(result.stdout)).toBeLessThanOrEqual(64 * 1024);
    const rows = result.stdout.trimEnd().split('\n').map((line) => line.split('\t'));
    const openings = rows
      .filter((cells) => cells[2] === 'entry')
      .map((cells) => Number(cells[0].slice(1)));
    const bodies = new Set(
      rows.filter((cells) => cells[2] === 'text').map((cells) => Number(cells[0].slice(1))),
    );
    const firstOpeningWithoutBody = openings.find((ordinal) => !bodies.has(ordinal));
    expect(firstOpeningWithoutBody).toBeDefined();
    expect(openings.at(-1)).toBe(firstOpeningWithoutBody);
    expect(result.stdout).toContain(`shown=${openings.length}\tmissing=0\ttruncated=true`);
  });

  test('agrees with xmllint ordinals for an XPath-safe literal when available', async () => {
    if (Bun.which('xmllint') === null) return;
    const filePath = await fixture('differential.xml', transcript(`    <user ordinal="2"><text>invalid</text></user>
`));
    const invalid = await runCli('search', filePath, '--literal', 'invalid');
    expect(invalid.exitCode).toBe(2);

    const validPath = await fixture('valid-differential.xml', transcript(`    <user ordinal="2">
      <text>SAFE_LITERAL</text>
    </user>
    <assistant ordinal="9">
      <text>SAFE_LITERAL again</text>
    </assistant>
`));
    const ours = await runCli('search', validPath, '--literal', 'SAFE_LITERAL');
    const xmllint = Bun.spawn([
      'xmllint', '--xpath',
      '/transcript-export/entries/*[contains(string(.), "SAFE_LITERAL")]/@ordinal',
      validPath,
    ], { stdout: 'pipe', stderr: 'pipe' });
    const xmlOutput = await new Response(xmllint.stdout).text();
    expect(await xmllint.exited).toBe(0);
    const oursOrdinals = [...ours.stdout.matchAll(/^#(\d+)\t/gm)].map((match) => Number(match[1]));
    const xmlOrdinals = [...xmlOutput.matchAll(/ordinal="(\d+)"/g)].map((match) => Number(match[1]));
    expect(oursOrdinals).toEqual(xmlOrdinals);
  });
});
