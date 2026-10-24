// word.js — read and edit Word (.docx) documents without Word and without
// installing anything.
//
// Why not the obvious tools on this host:
//   * PowerShell here is 2.0 on the .NET 2.0 CLR: System.IO.Compression
//     .ZipArchive (.NET 4.5) does not exist, so a .docx cannot be opened as a
//     ZIP from PowerShell.
//   * Word COM (Office 2007 is installed) blocks on a modal dialog when it runs
//     invisible on this machine — a helper that hangs is worse than none.
// So this file implements the little bit of ZIP that a .docx needs, on Node
// (the runtime inside DSH Desktop), and edits word/document.xml in place.
//
// A .docx is a ZIP: [Content_Types].xml, _rels/.rels, word/document.xml, plus
// whatever else Word put there (styles, media, headers). All entries other than
// word/document.xml are copied through byte-for-byte, so styles, images and
// numbering survive.
//
// CLI (called by word.cmd):
//   word.js -Action info    -Path f.docx
//   word.js -Action read    -Path f.docx
//   word.js -Action write   -Path f.docx -TextFile t.txt | -Text "text"
//   word.js -Action append  -Path f.docx -TextFile t.txt | -Text "text"
//   word.js -Action replace -Path f.docx -Find a -ReplaceWith b
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

const STORE = 0;
const DEFLATE = 8;

// --- crc32 ------------------------------------------------------------------
const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[i] = c;
  }
  return table;
})();

function crc32(buf) {
  if (typeof zlib.crc32 === 'function') return zlib.crc32(buf) >>> 0;
  let c = -1;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}

// --- zip read ---------------------------------------------------------------
function readZip(buf) {
  let eocd = -1;
  for (let i = buf.length - 22; i >= 0 && i >= buf.length - 66000; i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error('not a ZIP package (no end of central directory)');

  const count = buf.readUInt16LE(eocd + 10);
  let offset = buf.readUInt32LE(eocd + 16);
  const entries = [];

  for (let i = 0; i < count; i++) {
    if (buf.readUInt32LE(offset) !== 0x02014b50) throw new Error('bad central directory entry');
    const method = buf.readUInt16LE(offset + 10);
    const crc = buf.readUInt32LE(offset + 16);
    const compSize = buf.readUInt32LE(offset + 20);
    const rawSize = buf.readUInt32LE(offset + 24);
    const nameLen = buf.readUInt16LE(offset + 28);
    const extraLen = buf.readUInt16LE(offset + 30);
    const commentLen = buf.readUInt16LE(offset + 32);
    const localOffset = buf.readUInt32LE(offset + 42);
    const name = buf.toString('utf8', offset + 46, offset + 46 + nameLen);

    if (buf.readUInt32LE(localOffset) !== 0x04034b50) throw new Error('bad local header for ' + name);
    const localNameLen = buf.readUInt16LE(localOffset + 26);
    const localExtraLen = buf.readUInt16LE(localOffset + 28);
    const dataStart = localOffset + 30 + localNameLen + localExtraLen;
    const raw = buf.subarray(dataStart, dataStart + compSize);
    const data = method === DEFLATE ? zlib.inflateRawSync(raw) : Buffer.from(raw);

    entries.push({ name, data, crc, rawSize });
    offset += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}

// --- zip write --------------------------------------------------------------
function dosTime(date) {
  const year = Math.max(1980, date.getFullYear());
  const time = (date.getHours() << 11) | (date.getMinutes() << 5) | Math.floor(date.getSeconds() / 2);
  const day = ((year - 1980) << 9) | ((date.getMonth() + 1) << 5) | date.getDate();
  return { time, day };
}

function writeZip(entries) {
  const chunks = [];
  const central = [];
  let offset = 0;
  const stamp = dosTime(new Date());

  for (const entry of entries) {
    const nameBuf = Buffer.from(entry.name, 'utf8');
    const crc = crc32(entry.data);
    const deflated = zlib.deflateRawSync(entry.data, { level: 6 });
    const useDeflate = deflated.length < entry.data.length;
    const payload = useDeflate ? deflated : entry.data;
    const method = useDeflate ? DEFLATE : STORE;

    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4); // version needed
    local.writeUInt16LE(0x0800, 6); // UTF-8 names
    local.writeUInt16LE(method, 8);
    local.writeUInt16LE(stamp.time, 10);
    local.writeUInt16LE(stamp.day, 12);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(payload.length, 18);
    local.writeUInt32LE(entry.data.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    local.writeUInt16LE(0, 28);

    chunks.push(local, nameBuf, payload);

    const centralEntry = Buffer.alloc(46);
    centralEntry.writeUInt32LE(0x02014b50, 0);
    centralEntry.writeUInt16LE(20, 4); // version made by
    centralEntry.writeUInt16LE(20, 6); // version needed
    centralEntry.writeUInt16LE(0x0800, 8);
    centralEntry.writeUInt16LE(method, 10);
    centralEntry.writeUInt16LE(stamp.time, 12);
    centralEntry.writeUInt16LE(stamp.day, 14);
    centralEntry.writeUInt32LE(crc, 16);
    centralEntry.writeUInt32LE(payload.length, 20);
    centralEntry.writeUInt32LE(entry.data.length, 24);
    centralEntry.writeUInt16LE(nameBuf.length, 28);
    centralEntry.writeUInt16LE(0, 30); // extra
    centralEntry.writeUInt16LE(0, 32); // comment
    centralEntry.writeUInt16LE(0, 34); // disk
    centralEntry.writeUInt16LE(0, 36); // internal attrs
    centralEntry.writeUInt32LE(0, 38); // external attrs
    centralEntry.writeUInt32LE(offset, 42);
    central.push(centralEntry, nameBuf);

    offset += local.length + nameBuf.length + payload.length;
  }

  const centralStart = offset;
  let centralSize = 0;
  for (const part of central) centralSize += part.length;

  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(0, 4);
  end.writeUInt16LE(0, 6);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralSize, 12);
  end.writeUInt32LE(centralStart, 16);
  end.writeUInt16LE(0, 20);

  return Buffer.concat([...chunks, ...central, end]);
}

// --- document.xml helpers ---------------------------------------------------
function escapeXml(text) {
  return String(text)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function unescapeXml(text) {
  return String(text)
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (m, d) => String.fromCharCode(Number(d)))
    .replace(/&amp;/g, '&');
}

function paragraphText(xmlFragment) {
  let text = '';
  const re = /<w:t[^>]*>([\s\S]*?)<\/w:t>/g;
  let m;
  while ((m = re.exec(xmlFragment)) !== null) text += m[1];
  return unescapeXml(text);
}

function documentParagraphs(xml) {
  const out = [];
  const parts = xml.split('</w:p>');
  for (const part of parts) {
    if (part.indexOf('<w:t') < 0) continue;
    out.push(paragraphText(part));
  }
  return out;
}

function paragraphXml(text) {
  return (
    '<w:p><w:r><w:t xml:space="preserve">' + escapeXml(text) + '</w:t></w:r></w:p>'
  );
}

function newDocumentXml(paragraphs) {
  return (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
    '<w:body>' +
    paragraphs.map(paragraphXml).join('') +
    '<w:sectPr/></w:body></w:document>'
  );
}

const CONTENT_TYPES =
  '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
  '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
  '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
  '<Default Extension="xml" ContentType="application/xml"/>' +
  '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
  '</Types>';

const ROOT_RELS =
  '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
  '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
  '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
  '</Relationships>';

// --- CLI --------------------------------------------------------------------
function parseArgs(argv) {
  const options = { action: 'info', path: '', textFile: '', text: '', find: '', replaceWith: '', outFile: '' };
  for (let i = 0; i < argv.length; i++) {
    const key = String(argv[i] || '').toLowerCase();
    const value = argv[i + 1];
    if (key === '-action') { options.action = String(value || 'info').toLowerCase(); i++; }
    else if (key === '-path') { options.path = String(value || ''); i++; }
    else if (key === '-textfile') { options.textFile = String(value || ''); i++; }
    else if (key === '-text') { options.text = String(value || ''); i++; }
    else if (key === '-find') { options.find = String(value || ''); i++; }
    else if (key === '-replacewith') { options.replaceWith = String(value || ''); i++; }
    else if (key === '-outfile') { options.outFile = String(value || ''); i++; }
    else if (key === '-help' || key === '/?' || key === '--help') { options.action = 'help'; }
  }
  return options;
}

function helpText() {
  return [
    'word.js - read and edit .docx without Word (ZIP + OOXML, no installs)',
    '',
    '  -Action info    -Path f.docx                  file facts',
    '  -Action read    -Path f.docx                  print document text',
    '  -Action read    -Path f.docx -OutFile t.txt   write text as UTF-8 to t.txt',
    '  -Action write   -Path f.docx -TextFile t.txt  create/replace: one line = one paragraph',
    '  -Action write   -Path f.docx -Text "text"     same, from the command line',
    '  -Action append  -Path f.docx -TextFile t.txt  add paragraphs at the end',
    '  -Action replace -Path f.docx -Find "a" -ReplaceWith "b"',
    '                                                replace in body, headers, footers',
    '',
    'TextFile is UTF-8 (BOM optional). Styles, images and other parts are copied',
    'through untouched; only word/document.xml is rewritten. The console shows',
    'non-ASCII text as garbage (OEM code page), so read with -OutFile.',
  ].join('\n');
}

function readLines(options) {
  if (options.textFile !== '') {
    if (!fs.existsSync(options.textFile)) throw new Error('text file not found: ' + options.textFile);
    let raw = fs.readFileSync(options.textFile, 'utf8');
    raw = raw.replace(/^\uFEFF/, '');
    return raw.split(/\r\n|\n|\r/);
  }
  if (options.text !== '') return options.text.split(/\r\n|\n|\r/);
  throw new Error('give -TextFile or -Text');
}

function loadEntries(file) {
  if (!fs.existsSync(file)) throw new Error('not found: ' + file);
  return readZip(fs.readFileSync(file));
}

function entryOf(entries, name) {
  return entries.find((entry) => entry.name === name);
}

function setEntry(entries, name, text) {
  const data = Buffer.from(text, 'utf8');
  const existing = entryOf(entries, name);
  if (existing === undefined) entries.push({ name, data });
  else existing.data = data;
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const action = options.action;
  const target = options.path === '' ? '' : path.resolve(options.path);

  if (action === 'help' || (action === 'info' && target === '')) {
    console.log(helpText());
    return 0;
  }
  if (target === '') throw new Error('-Path is required');

  if (action === 'info') {
    const stat = fs.statSync(target);
    const entries = loadEntries(target);
    const xml = entryOf(entries, 'word/document.xml');
    const paragraphs = xml === undefined ? [] : documentParagraphs(xml.data.toString('utf8'));
    const words = paragraphs.reduce((sum, p) => sum + p.split(/\s+/).filter(Boolean).length, 0);
    console.log('path       : ' + target);
    console.log('size       : ' + String(stat.size) + ' bytes');
    console.log('modified   : ' + stat.mtime.toISOString().slice(0, 16).replace('T', ' '));
    console.log('parts      : ' + String(entries.length));
    console.log('paragraphs : ' + String(paragraphs.length));
    console.log('words      : ' + String(words));
    return 0;
  }

  if (action === 'read') {
    const entries = loadEntries(target);
    const xml = entryOf(entries, 'word/document.xml');
    if (xml === undefined) throw new Error('no word/document.xml in ' + target);
    const paragraphs = documentParagraphs(xml.data.toString('utf8'));
    // The console on this host decodes stdout as an OEM code page, so Russian
    // text comes out as garbage there. -OutFile writes UTF-8 instead and prints
    // an ASCII receipt, which is what an agent should read with its read tool.
    if (options.outFile !== '') {
      const outPath = path.resolve(options.outFile);
      fs.writeFileSync(outPath, paragraphs.join('\r\n'), 'utf8');
      console.log('text       : ' + outPath);
      console.log('paragraphs : ' + String(paragraphs.length));
      console.log('chars      : ' + String(paragraphs.join('\r\n').length));
      return 0;
    }
    for (const paragraph of paragraphs) console.log(paragraph);
    return 0;
  }

  if (action === 'write') {
    const lines = readLines(options);
    const entries = [
      { name: '[Content_Types].xml', data: Buffer.from(CONTENT_TYPES, 'utf8') },
      { name: '_rels/.rels', data: Buffer.from(ROOT_RELS, 'utf8') },
      { name: 'word/document.xml', data: Buffer.from(newDocumentXml(lines), 'utf8') },
    ];
    fs.writeFileSync(target, writeZip(entries));
    console.log('written    : ' + target);
    console.log('paragraphs : ' + String(lines.length));
    return 0;
  }

  if (action === 'append') {
    const lines = readLines(options);
    const entries = loadEntries(target);
    const xml = entryOf(entries, 'word/document.xml');
    if (xml === undefined) throw new Error('no word/document.xml in ' + target);
    let text = xml.data.toString('utf8');
    const added = lines.map(paragraphXml).join('');
    const sect = text.lastIndexOf('<w:sectPr');
    if (sect >= 0) text = text.slice(0, sect) + added + text.slice(sect);
    else if (text.indexOf('</w:body>') >= 0) text = text.replace('</w:body>', added + '</w:body>');
    else throw new Error('document.xml has no body');
    setEntry(entries, 'word/document.xml', text);
    fs.writeFileSync(target, writeZip(entries));
    console.log('appended   : ' + target);
    console.log('paragraphs : ' + String(lines.length));
    return 0;
  }

  if (action === 'replace') {
    if (options.find === '') throw new Error('-Find is required');
    const entries = loadEntries(target);
    const names = entries
      .map((entry) => entry.name)
      .filter((name) => name === 'word/document.xml' || /^word\/(header|footer)\d*\.xml$/.test(name));
    let changed = 0;

    for (const name of names) {
      const entry = entryOf(entries, name);
      if (entry === undefined) continue;
      let text = entry.data.toString('utf8');
      if (text.indexOf(options.find) < 0) {
        // The words may be split across runs: rewrite the touched paragraphs as
        // single runs (the paragraph style survives, run-level formatting does not).
        const parts = text.split(/(?<=<\/w:p>)/);
        let touched = false;
        for (let i = 0; i < parts.length; i++) {
          if (parts[i].indexOf('<w:t') < 0) continue;
          const plain = paragraphText(parts[i]);
          if (plain.indexOf(options.find) < 0) continue;
          const replaced = plain.split(options.find).join(options.replaceWith);
          const open = parts[i].indexOf('<w:p');
          const close = parts[i].indexOf('>', open);
          if (open < 0 || close < 0) continue;
          parts[i] = parts[i].slice(0, close + 1) + paragraphXml(replaced).slice(5);
          touched = true;
          changed++;
        }
        if (touched) setEntry(entries, name, parts.join(''));
      } else {
        text = text.split(options.find).join(escapeXml(options.replaceWith));
        setEntry(entries, name, text);
        changed++;
      }
    }
    if (changed === 0) throw new Error('text not found: ' + options.find);
    fs.writeFileSync(target, writeZip(entries));
    console.log('replaced   : ' + String(changed) + ' place(s) in ' + target);
    return 0;
  }

  throw new Error('unknown action: ' + action);
}

try {
  process.exitCode = main();
} catch (error) {
  console.error('word.js: ' + String((error && error.message) || error));
  process.exitCode = 1;
}
