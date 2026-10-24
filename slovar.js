// slovar.js — append or fix one entry in the voice replacement dictionary.
//
// The dictionary is plain text: "как услышал => как надо". The voice bridge reads
// it after every recognition and reloads it when the file changes, so a new word
// works from the next turn without restarting anything.
//
// Called by slovar.cmd (Node inside DSH Desktop):
//   slovar.cmd -Add "дипсик => DeepSeek"
//   slovar.cmd -Add дипсик=DeepSeek        (= and -> are accepted too)
//   slovar.cmd -Check                      entries, size, path
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const FILE = path.join(__dirname, 'slovar.txt');
const SPLIT = /\s*(?:=>|->|=)\s*/;

function readLines() {
  if (!fs.existsSync(FILE)) return { lines: [], bom: '' };
  let raw = fs.readFileSync(FILE, 'utf8');
  let bom = '';
  if (raw.charCodeAt(0) === 0xfeff) {
    bom = '\uFEFF';
    raw = raw.slice(1);
  }
  return { lines: raw.split(/\r\n|\n|\r/), bom };
}

function leftOf(line) {
  const trimmed = String(line).trim();
  if (trimmed === '' || trimmed.startsWith('#')) return '';
  const parts = trimmed.split(SPLIT);
  if (parts.length < 2) return '';
  return parts[0].trim().toLowerCase().replace(/\s+/g, ' ');
}

function normalize(entry) {
  const trimmed = String(entry).trim();
  if (trimmed === '') throw new Error('empty entry');
  const at = trimmed.search(/\s*(?:=>|->|=)\s*/);
  if (at <= 0) {
    throw new Error('entry needs "как слышу => как надо" (got: ' + trimmed + ')');
  }
  const match = trimmed.match(/\s*(?:=>|->|=)\s*/);
  const left = trimmed.slice(0, at).trim();
  const right = trimmed.slice(at + match[0].length).trim();
  if (left === '' || right === '') throw new Error('both sides are required');
  return { left, right, key: left.toLowerCase().replace(/\s+/g, ' ') };
}

function main() {
  const args = process.argv.slice(2);
  const action = (args[0] || '').toLowerCase();

  if (action === '-check' || action === '--check' || action === '') {
    const { lines } = readLines();
    let entries = 0;
    let words = 0;
    let longest = 0;
    for (const line of lines) {
      const key = leftOf(line);
      if (key === '') continue;
      entries++;
      const count = key.split(' ').length;
      if (count > words) words = count;
      if (line.trim().length > longest) longest = line.trim().length;
    }
    console.log('file       : ' + FILE);
    console.log('entries    : ' + String(entries));
    console.log('max words  : ' + String(words));
    console.log('longest    : ' + String(longest) + ' chars');
    return 0;
  }

  if (action !== '-add' && action !== '--add') {
    console.log('usage: slovar.cmd -Add "как слышу => как надо"   |   slovar.cmd -Check');
    return 1;
  }

  const entry = args.slice(1).join(' ');
  const { left, right, key } = normalize(entry);
  const { lines, bom } = readLines();

  let replaced = false;
  const next = [];
  for (const line of lines) {
    if (leftOf(line) === key) {
      if (!replaced) {
        next.push(left + ' => ' + right);
        replaced = true;
      }
      continue;
    }
    next.push(line);
  }
  if (!replaced) next.push(left + ' => ' + right);

  // collapse trailing blank lines, keep the file tidy
  while (next.length > 0 && next[next.length - 1].trim() === '') next.pop();
  fs.writeFileSync(FILE, bom + next.join('\r\n') + '\r\n', 'utf8');

  console.log((replaced ? 'updated    : ' : 'added      : ') + left + ' => ' + right);
  console.log('file       : ' + FILE);
  return 0;
}

try {
  process.exitCode = main();
} catch (error) {
  console.error('slovar.js: ' + String((error && error.message) || error));
  process.exitCode = 1;
}
