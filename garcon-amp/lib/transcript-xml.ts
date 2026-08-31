import path from 'node:path';
import { createReadStream } from 'node:fs';
import { lstat } from 'node:fs/promises';

const XML_DECLARATION = '<?xml version="1.0" encoding="UTF-8"?>';
const MAX_STRUCTURAL_TAG_CODE_UNITS = 1024 * 1024;
const ATTRIBUTE = / ([a-z][a-z0-9-]*)="([^"]*)"/gy;
const NAME = /^[a-z][a-z0-9-]*$/;
const KNOWN_TRANSCRIPT_ENTRY_TAGS = new Set([
  'user',
  'assistant',
  'reasoning',
  'tool-call',
  'tool-result',
  'notice',
  'cli-row',
  'handoff',
  'permission',
  'compaction',
  'error',
  'run-ended',
]);
const KNOWN_HANDOFF_ENTRY_TAGS = new Set([
  'user',
  'assistant',
  'compaction',
  'tool-call',
  'handoff',
  'notice',
]);
const KNOWN_TRANSCRIPT_METADATA_TAGS = new Set(['chat', 'omitted']);
const KNOWN_HANDOFF_METADATA_TAGS = new Set(['chat', 'fixed-fold-excluded']);

export type GarconXmlDocumentKind = 'transcript-export' | 'handoff-artifact';
export type GarconXmlAreaKind = 'text' | 'field' | 'attribute';

export interface GarconXmlEntry {
  readonly tag: string;
  readonly ordinal: number;
  readonly attributes: ReadonlyMap<string, string>;
}

export interface GarconXmlArea {
  readonly kind: GarconXmlAreaKind;
  readonly name: string;
}

export interface GarconXmlGap {
  readonly afterOrdinal?: number;
  readonly beforeOrdinal?: number;
  readonly omittedEntries: number;
}

export interface GarconXmlMetadata {
  readonly tag: string;
  readonly attributes: ReadonlyMap<string, string>;
}

export interface GarconXmlDocument {
  readonly kind: GarconXmlDocumentKind;
  readonly rootAttributes: ReadonlyMap<string, string>;
  readonly metadata: readonly GarconXmlMetadata[];
  readonly gaps: readonly GarconXmlGap[];
  readonly entryCount: number;
  readonly firstOrdinal?: number;
  readonly lastOrdinal?: number;
  readonly unknownEntryTags: readonly string[];
  readonly unknownMetadataTags: readonly string[];
  readonly crossKindStructures: readonly string[];
}

export interface GarconXmlVisitor {
  readonly onRoot?: (
    kind: GarconXmlDocumentKind,
    attributes: ReadonlyMap<string, string>,
  ) => void;
  readonly onMetadata?: (metadata: GarconXmlMetadata) => void;
  readonly onGap?: (gap: GarconXmlGap) => void;
  readonly onEntryStart?: (entry: GarconXmlEntry) => void;
  readonly onAreaStart?: (entry: GarconXmlEntry, area: GarconXmlArea) => void;
  readonly onAreaText?: (entry: GarconXmlEntry, area: GarconXmlArea, text: string) => void;
  readonly onAreaEnd?: (entry: GarconXmlEntry, area: GarconXmlArea) => void;
  readonly onEntryEnd?: (entry: GarconXmlEntry) => void;
}

export interface GarconXmlScanOptions {
  readonly chunkSize?: number;
}

export class GarconXmlDocumentError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'GarconXmlDocumentError';
  }
}

export class GarconXmlInputError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'GarconXmlInputError';
  }
}

interface ParsedTag {
  readonly name: string;
  readonly attributes: ReadonlyMap<string, string>;
  readonly closing: boolean;
  readonly selfClosing: boolean;
}

class StreamCursor {
  private readonly iterator: AsyncIterator<Uint8Array>;
  private readonly decoder = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });
  private buffer = '';
  private ended = false;

  constructor(filePath: string, chunkSize: number) {
    this.iterator = createReadStream(filePath, { highWaterMark: chunkSize })[Symbol.asyncIterator]();
  }

  private async fill(): Promise<void> {
    if (this.ended) return;
    let next: IteratorResult<Uint8Array>;
    try {
      next = await this.iterator.next();
    } catch (error) {
      throw new GarconXmlInputError(
        `cannot read XML file: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
    try {
      if (next.done) {
        this.buffer += this.decoder.decode();
        this.ended = true;
      } else {
        this.buffer += this.decoder.decode(next.value, { stream: true });
      }
    } catch (error) {
      throw new GarconXmlDocumentError(`invalid UTF-8: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  async startsWith(value: string): Promise<boolean> {
    while (!this.ended && this.buffer.length < value.length) await this.fill();
    return this.buffer.startsWith(value);
  }

  async expect(value: string, description = JSON.stringify(value)): Promise<void> {
    while (!this.ended && this.buffer.length < value.length) await this.fill();
    if (!this.buffer.startsWith(value)) {
      throw new GarconXmlDocumentError(`expected ${description}`);
    }
    this.buffer = this.buffer.slice(value.length);
  }

  async readLine(): Promise<string | null> {
    for (;;) {
      const newline = this.buffer.indexOf('\n');
      if (newline >= 0) {
        if (newline > MAX_STRUCTURAL_TAG_CODE_UNITS) {
          throw new GarconXmlDocumentError('structural line exceeds the supported size');
        }
        const line = this.buffer.slice(0, newline);
        this.buffer = this.buffer.slice(newline + 1);
        return line;
      }
      if (this.buffer.length > MAX_STRUCTURAL_TAG_CODE_UNITS) {
        throw new GarconXmlDocumentError('structural line exceeds the supported size');
      }
      if (this.ended) {
        if (this.buffer === '') return null;
        throw new GarconXmlDocumentError('document does not end with a newline');
      }
      await this.fill();
    }
  }

  async readIndentedTag(indent: number): Promise<string> {
    await this.expect(`${' '.repeat(indent)}<`, `a canonical ${indent}-space structural tag`);
    for (;;) {
      const end = this.buffer.indexOf('>');
      const newline = this.buffer.indexOf('\n');
      if (newline >= 0 && (end < 0 || newline < end)) {
        throw new GarconXmlDocumentError('structural tag contains an unescaped newline');
      }
      if (end >= 0) {
        if (end > MAX_STRUCTURAL_TAG_CODE_UNITS) {
          throw new GarconXmlDocumentError('structural tag exceeds the supported size');
        }
        const tag = this.buffer.slice(0, end);
        this.buffer = this.buffer.slice(end + 1);
        return tag;
      }
      if (this.buffer.length > MAX_STRUCTURAL_TAG_CODE_UNITS) {
        throw new GarconXmlDocumentError('structural tag exceeds the supported size');
      }
      if (this.ended) throw new GarconXmlDocumentError('unterminated structural tag');
      await this.fill();
    }
  }

  async streamUntil(close: string, onText: (text: string) => void): Promise<void> {
    const retained = close.length - 1;
    for (;;) {
      const end = this.buffer.indexOf(close);
      if (end >= 0) {
        const text = this.buffer.slice(0, end);
        rejectRawMarkup(text);
        if (text !== '') onText(text);
        this.buffer = this.buffer.slice(end + close.length);
        return;
      }
      if (this.ended) throw new GarconXmlDocumentError(`unterminated ${close.slice(0, -1)}`);
      const emitLength = this.buffer.length - retained;
      if (emitLength > 0) {
        const text = this.buffer.slice(0, emitLength);
        rejectRawMarkup(text);
        if (text !== '') onText(text);
        this.buffer = this.buffer.slice(emitLength);
      }
      await this.fill();
    }
  }

  async assertEnd(): Promise<void> {
    while (!this.ended) await this.fill();
    if (this.buffer !== '') throw new GarconXmlDocumentError('unexpected content after document root');
  }
}

class EntityDecoder {
  private carry = '';

  constructor(private readonly onText: (text: string) => void) {}

  push(raw: string): void {
    const value = this.carry + raw;
    this.carry = '';
    let output = '';
    for (let index = 0; index < value.length;) {
      if (value[index] !== '&') {
        const next = value.indexOf('&', index);
        output += value.slice(index, next < 0 ? value.length : next);
        index = next < 0 ? value.length : next;
        continue;
      }
      const end = value.indexOf(';', index + 1);
      if (end < 0) {
        this.carry = value.slice(index);
        if (this.carry.length > 32) throw new GarconXmlDocumentError('invalid XML entity');
        break;
      }
      const entity = value.slice(index + 1, end);
      output += decodeEntity(entity);
      index = end + 1;
    }
    if (output !== '') this.onText(output);
  }

  finish(): void {
    if (this.carry !== '') throw new GarconXmlDocumentError('unterminated XML entity');
  }
}

export async function scanCanonicalGarconXml(
  filePath: string,
  visitor: GarconXmlVisitor = {},
  options: GarconXmlScanOptions = {},
): Promise<GarconXmlDocument> {
  await requireReadableRegularFile(filePath);
  const chunkSize = options.chunkSize ?? 64 * 1024;
  if (!Number.isSafeInteger(chunkSize) || chunkSize < 1 || chunkSize > 16 * 1024 * 1024) {
    throw new GarconXmlDocumentError('invalid scanner chunk size');
  }
  const cursor = new StreamCursor(filePath, chunkSize);
  if (await cursor.readLine() !== XML_DECLARATION) {
    throw new GarconXmlDocumentError(`first line must be ${XML_DECLARATION}`);
  }
  const rootLine = await cursor.readLine();
  if (rootLine === null || !rootLine.startsWith('<') || !rootLine.endsWith('>')) {
    throw new GarconXmlDocumentError('missing document root');
  }
  const root = parseTag(rootLine.slice(1, -1));
  if (root.closing || root.selfClosing || !isDocumentKind(root.name)) {
    throw new GarconXmlDocumentError('unsupported document root');
  }
  if (root.attributes.get('version') !== '1') {
    throw new GarconXmlDocumentError('unsupported document version');
  }
  visitor.onRoot?.(root.name, root.attributes);

  const metadata: GarconXmlMetadata[] = [];
  const recognizedMetadataTags = knownMetadataTags(root.name);
  const unknownMetadataTags = new Set<string>();
  let entriesOpen = false;
  for (;;) {
    const line = await cursor.readLine();
    if (line === null) throw new GarconXmlDocumentError('document ended before entries');
    if (line === '  <entries>') {
      entriesOpen = true;
      break;
    }
    if (line === '  <entries/>') break;
    if (!line.startsWith('  <') || !line.endsWith('>')) {
      throw new GarconXmlDocumentError('invalid document metadata');
    }
    const parsed = parseTag(line.slice(3, -1));
    if (parsed.closing || !parsed.selfClosing) {
      throw new GarconXmlDocumentError(`unsupported metadata element: ${parsed.name}`);
    }
    if (
      recognizedMetadataTags.has(parsed.name)
      && metadata.some((entry) => entry.tag === parsed.name)
    ) {
      throw new GarconXmlDocumentError(`duplicate metadata element: ${parsed.name}`);
    }
    if (!recognizedMetadataTags.has(parsed.name)) unknownMetadataTags.add(parsed.name);
    const item: GarconXmlMetadata = { tag: parsed.name, attributes: parsed.attributes };
    metadata.push(item);
    visitor.onMetadata?.(item);
  }
  if (metadata[0]?.tag !== 'chat') {
    throw new GarconXmlDocumentError('chat metadata must be the first document element');
  }

  const gaps: GarconXmlGap[] = [];
  let entryCount = 0;
  let firstOrdinal: number | undefined;
  let lastOrdinal: number | undefined;
  const recognizedEntryTags = knownEntryTags(root.name);
  const unknownEntryTags = new Set<string>();
  const crossKindStructures = new Set<string>();
  let pendingGap: GarconXmlGap | undefined;
  if (entriesOpen) {
    for (;;) {
      if (await cursor.startsWith('  </entries>\n')) {
        await cursor.expect('  </entries>\n');
        break;
      }
      const parsed = parseTag(await cursor.readIndentedTag(4));
      if (parsed.closing) throw new GarconXmlDocumentError('unexpected entry close');
      if (parsed.name === 'gap') {
        if (!parsed.selfClosing) throw new GarconXmlDocumentError('gap must be self-closing');
        if (root.name !== 'handoff-artifact') crossKindStructures.add('gap');
        await cursor.expect('\n', 'a newline after gap');
        if (pendingGap !== undefined) throw new GarconXmlDocumentError('consecutive gaps are invalid');
        const gap = parseGap(parsed.attributes);
        if (gap.afterOrdinal !== undefined && gap.afterOrdinal !== lastOrdinal) {
          throw new GarconXmlDocumentError('gap after-ordinal does not match the preceding entry');
        }
        pendingGap = gap;
        gaps.push(gap);
        visitor.onGap?.(gap);
        continue;
      }
      if (!recognizedEntryTags.has(parsed.name)) unknownEntryTags.add(parsed.name);
      const ordinal = positiveInteger(parsed.attributes.get('ordinal'), 'entry ordinal');
      if (lastOrdinal !== undefined && ordinal <= lastOrdinal) {
        throw new GarconXmlDocumentError('entry ordinals must be strictly increasing');
      }
      if (pendingGap?.beforeOrdinal !== undefined && pendingGap.beforeOrdinal !== ordinal) {
        throw new GarconXmlDocumentError('gap before-ordinal does not match the following entry');
      }
      pendingGap = undefined;
      firstOrdinal ??= ordinal;
      lastOrdinal = ordinal;
      entryCount += 1;
      const entry: GarconXmlEntry = {
        tag: parsed.name,
        ordinal,
        attributes: parsed.attributes,
      };
      visitor.onEntryStart?.(entry);
      for (const [name, value] of parsed.attributes) {
        if (name === 'ordinal') continue;
        emitWholeArea(visitor, entry, { kind: 'attribute', name }, value);
      }
      await cursor.expect('\n', 'a newline after entry opening');
      if (!parsed.selfClosing) {
        await scanEntryBody(cursor, root.name, entry, visitor, crossKindStructures);
      }
      visitor.onEntryEnd?.(entry);
    }
  }
  if (pendingGap?.beforeOrdinal !== undefined) {
    throw new GarconXmlDocumentError('terminal gap cannot declare before-ordinal');
  }
  await cursor.expect(`</${root.name}>\n`, 'the matching document close');
  await cursor.assertEnd();
  return {
    kind: root.name,
    rootAttributes: root.attributes,
    metadata,
    gaps,
    entryCount,
    ...(firstOrdinal === undefined ? {} : { firstOrdinal }),
    ...(lastOrdinal === undefined ? {} : { lastOrdinal }),
    unknownEntryTags: [...unknownEntryTags],
    unknownMetadataTags: [...unknownMetadataTags],
    crossKindStructures: [...crossKindStructures],
  };
}

async function scanEntryBody(
  cursor: StreamCursor,
  kind: GarconXmlDocumentKind,
  entry: GarconXmlEntry,
  visitor: GarconXmlVisitor,
  crossKindStructures: Set<string>,
): Promise<void> {
  let textSeen = false;
  let fieldSeen = false;
  let imagesSeen = false;
  for (;;) {
    if (await cursor.startsWith(`    </${entry.tag}>\n`)) {
      await cursor.expect(`    </${entry.tag}>\n`);
      return;
    }
    const child = parseTag(await cursor.readIndentedTag(6));
    if (child.closing || child.selfClosing) {
      throw new GarconXmlDocumentError(`invalid child in entry #${entry.ordinal}`);
    }
    if (child.name === 'text') {
      if (textSeen || fieldSeen || imagesSeen || child.attributes.size > 0) {
        throw new GarconXmlDocumentError(`invalid text element in entry #${entry.ordinal}`);
      }
      textSeen = true;
      const area = { kind: 'text', name: 'text' } as const;
      await scanTextArea(cursor, entry, area, visitor, 'text');
      continue;
    }
    if (child.name === 'field') {
      if (imagesSeen || !child.attributes.has('name')) {
        throw new GarconXmlDocumentError(`invalid field element in entry #${entry.ordinal}`);
      }
      if (kind !== 'transcript-export') crossKindStructures.add('field');
      fieldSeen = true;
      const area = { kind: 'field', name: child.attributes.get('name')! } as const;
      for (const [name, value] of child.attributes) {
        if (name === 'name') continue;
        emitWholeArea(visitor, entry, { kind: 'attribute', name: `field.${area.name}.${name}` }, value);
      }
      await scanTextArea(cursor, entry, area, visitor, 'field');
      continue;
    }
    if (child.name === 'images') {
      if (imagesSeen) {
        throw new GarconXmlDocumentError(`invalid images element in entry #${entry.ordinal}`);
      }
      if (kind !== 'transcript-export') crossKindStructures.add('images');
      imagesSeen = true;
      for (const [name, value] of child.attributes) {
        emitWholeArea(visitor, entry, { kind: 'attribute', name: `images.${name}` }, value);
      }
      await cursor.expect('\n', 'a newline after images opening');
      await scanImages(cursor, entry, visitor);
      continue;
    }
    throw new GarconXmlDocumentError(`unsupported child element in entry #${entry.ordinal}`);
  }
}

async function scanTextArea(
  cursor: StreamCursor,
  entry: GarconXmlEntry,
  area: GarconXmlArea,
  visitor: GarconXmlVisitor,
  tag: 'text' | 'field',
): Promise<void> {
  visitor.onAreaStart?.(entry, area);
  const decoder = new EntityDecoder((text) => visitor.onAreaText?.(entry, area, text));
  await cursor.streamUntil(`</${tag}>\n`, (raw) => decoder.push(raw));
  decoder.finish();
  visitor.onAreaEnd?.(entry, area);
}

async function scanImages(
  cursor: StreamCursor,
  entry: GarconXmlEntry,
  visitor: GarconXmlVisitor,
): Promise<void> {
  for (;;) {
    if (await cursor.startsWith('      </images>\n')) {
      await cursor.expect('      </images>\n');
      return;
    }
    const image = parseTag(await cursor.readIndentedTag(8));
    if (image.closing || !image.selfClosing || image.name !== 'image') {
      throw new GarconXmlDocumentError(`invalid image metadata in entry #${entry.ordinal}`);
    }
    await cursor.expect('\n', 'a newline after image metadata');
    for (const [name, value] of image.attributes) {
      emitWholeArea(visitor, entry, { kind: 'attribute', name: `image.${name}` }, value);
    }
  }
}

function emitWholeArea(
  visitor: GarconXmlVisitor,
  entry: GarconXmlEntry,
  area: GarconXmlArea,
  value: string,
): void {
  visitor.onAreaStart?.(entry, area);
  if (value !== '') visitor.onAreaText?.(entry, area, value);
  visitor.onAreaEnd?.(entry, area);
}

function parseTag(value: string): ParsedTag {
  const closing = value.startsWith('/');
  if (closing) {
    const name = value.slice(1);
    if (!NAME.test(name)) throw new GarconXmlDocumentError('invalid closing tag');
    return { name, attributes: new Map(), closing: true, selfClosing: false };
  }
  const selfClosing = value.endsWith('/');
  const content = selfClosing ? value.slice(0, -1) : value;
  const space = content.indexOf(' ');
  const name = space < 0 ? content : content.slice(0, space);
  if (!NAME.test(name)) throw new GarconXmlDocumentError('invalid element name');
  const attributes = parseAttributes(space < 0 ? '' : content.slice(space));
  return { name, attributes, closing: false, selfClosing };
}

function parseAttributes(value: string): ReadonlyMap<string, string> {
  const attributes = new Map<string, string>();
  let index = 0;
  while (index < value.length) {
    ATTRIBUTE.lastIndex = index;
    const match = ATTRIBUTE.exec(value);
    if (match === null || match.index !== index) {
      throw new GarconXmlDocumentError('invalid canonical attribute syntax');
    }
    if (attributes.has(match[1])) throw new GarconXmlDocumentError(`duplicate attribute: ${match[1]}`);
    if (/[<>\t\r]/.test(match[2])) {
      throw new GarconXmlDocumentError('unescaped character in canonical attribute');
    }
    attributes.set(match[1], decodeXmlValue(match[2]));
    index = ATTRIBUTE.lastIndex;
  }
  return attributes;
}

function decodeXmlValue(value: string): string {
  let output = '';
  const decoder = new EntityDecoder((text) => { output += text; });
  decoder.push(value);
  decoder.finish();
  return output;
}

function decodeEntity(entity: string): string {
  switch (entity) {
    case 'amp': return '&';
    case 'lt': return '<';
    case 'gt': return '>';
    case 'quot': return '"';
    case 'apos': return "'";
  }
  let codePoint: number;
  if (/^#[0-9]+$/.test(entity)) codePoint = Number.parseInt(entity.slice(1), 10);
  else if (/^#x[0-9a-fA-F]+$/.test(entity)) codePoint = Number.parseInt(entity.slice(2), 16);
  else throw new GarconXmlDocumentError(`unsupported XML entity: &${entity};`);
  if (!isXmlCodePoint(codePoint)) throw new GarconXmlDocumentError('invalid numeric XML entity');
  return String.fromCodePoint(codePoint);
}

function isXmlCodePoint(value: number): boolean {
  return value === 0x9
    || value === 0xa
    || value === 0xd
    || (value >= 0x20 && value <= 0xd7ff)
    || (value >= 0xe000 && value <= 0xfffd)
    || (value >= 0x10000 && value <= 0x10ffff);
}

function parseGap(attributes: ReadonlyMap<string, string>): GarconXmlGap {
  for (const name of attributes.keys()) {
    if (name !== 'after-ordinal' && name !== 'before-ordinal' && name !== 'omitted-entries') {
      throw new GarconXmlDocumentError(`unsupported gap attribute: ${name}`);
    }
  }
  const afterOrdinal = optionalPositiveInteger(attributes.get('after-ordinal'), 'gap after-ordinal');
  const beforeOrdinal = optionalPositiveInteger(attributes.get('before-ordinal'), 'gap before-ordinal');
  const omittedEntries = positiveInteger(attributes.get('omitted-entries'), 'gap omitted-entries');
  if (afterOrdinal !== undefined && beforeOrdinal !== undefined && afterOrdinal >= beforeOrdinal) {
    throw new GarconXmlDocumentError('gap ordinal bounds are invalid');
  }
  return {
    ...(afterOrdinal === undefined ? {} : { afterOrdinal }),
    ...(beforeOrdinal === undefined ? {} : { beforeOrdinal }),
    omittedEntries,
  };
}

function positiveInteger(value: string | undefined, description: string): number {
  if (value === undefined || !/^[1-9][0-9]*$/.test(value)) {
    throw new GarconXmlDocumentError(`${description} must be a positive integer`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) throw new GarconXmlDocumentError(`${description} is too large`);
  return parsed;
}

function optionalPositiveInteger(value: string | undefined, description: string): number | undefined {
  return value === undefined ? undefined : positiveInteger(value, description);
}

function knownEntryTags(kind: GarconXmlDocumentKind): ReadonlySet<string> {
  return kind === 'transcript-export' ? KNOWN_TRANSCRIPT_ENTRY_TAGS : KNOWN_HANDOFF_ENTRY_TAGS;
}

function isDocumentKind(value: string): value is GarconXmlDocumentKind {
  return value === 'transcript-export' || value === 'handoff-artifact';
}

function knownMetadataTags(kind: GarconXmlDocumentKind): ReadonlySet<string> {
  return kind === 'transcript-export'
    ? KNOWN_TRANSCRIPT_METADATA_TAGS
    : KNOWN_HANDOFF_METADATA_TAGS;
}

function rejectRawMarkup(value: string): void {
  if (value.includes('<') || value.includes('>')) {
    throw new GarconXmlDocumentError('unescaped markup in entry content');
  }
  if (value.includes('\r')) throw new GarconXmlDocumentError('raw carriage return in entry content');
}

async function requireReadableRegularFile(filePath: string): Promise<void> {
  if (!path.isAbsolute(filePath)) throw new GarconXmlInputError('XML path must be absolute');
  let info;
  try {
    info = await lstat(filePath);
  } catch (error) {
    throw new GarconXmlInputError(`cannot read XML file: ${error instanceof Error ? error.message : String(error)}`);
  }
  if (!info.isFile() || info.isSymbolicLink()) {
    throw new GarconXmlInputError('XML path must be a regular non-symlink file');
  }
}
