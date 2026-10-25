'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { pipeline } = require('node:stream/promises');
const sha = data => crypto.createHash('sha256').update(data).digest('hex');

function readExact(fd, buffer, position) {
  let done = 0;
  while (done < buffer.length) {
    const n = fs.readSync(fd, buffer, done, buffer.length - done, position + done);
    if (!n) throw Error('Unexpected end of ASAR');
    done += n;
  }
}

function readArchive(file, asar) {
  const fd = fs.openSync(file, 'r');
  let prefix, headerBuffer;
  try {
    prefix = Buffer.alloc(16); readExact(fd, prefix, 0);
    const size = prefix.readUInt32LE(4), jsonSize = prefix.readUInt32LE(12);
    if (prefix.readUInt32LE(0) !== 4 || size < 8 || size > 64 * 1024 * 1024 || size % 4 || prefix.readUInt32LE(8) !== size - 4 || jsonSize > size - 8 || jsonSize < 2 || size - 8 - jsonSize > 3) throw Error('Unsupported ASAR pickle header');
    headerBuffer = Buffer.alloc(jsonSize); readExact(fd, headerBuffer, 16);
    const header = JSON.parse(headerBuffer.toString('utf8'));
    const raw = asar.getRawHeader(file);
    if (raw.headerString !== headerBuffer.toString('utf8') || raw.headerSize !== size) throw Error('ASAR reader disagreement');
    const dataOffset = 8 + size, sizeOnDisk = fs.fstatSync(fd).size;
    const files = flatten(header);
    for (const entry of files) {
      const n = entry.node;
      if (n.link !== undefined) { validateRelative(n.link); continue; }
      if (!Number.isSafeInteger(n.size) || n.size < 0) throw Error(`Invalid ASAR file size: ${entry.path}`);
      if (!n.unpacked) {
        if (typeof n.offset !== 'string' || !/^\d+$/.test(n.offset)) throw Error(`Invalid ASAR offset: ${entry.path}`);
        const offset = Number(n.offset);
        if (!Number.isSafeInteger(offset) || offset < 0 || dataOffset + offset + n.size > sizeOnDisk) throw Error(`ASAR range outside file: ${entry.path}`);
      }
    }
    return { file, header, headerHash: sha(headerBuffer), dataOffset, payloadLength: sizeOnDisk - dataOffset, files, size: sizeOnDisk };
  } finally { fs.closeSync(fd); }
}

function validateRelative(value) {
  if (typeof value !== 'string' || !value || value.startsWith('/') || value.includes('\\') || value.includes(':') || value.includes('\0') || value.split('/').some(s => !s || s === '.' || s === '..' || /[. ]$/.test(s))) throw Error(`Unsafe archive path: ${String(value)}`);
  return value;
}

function flatten(header) {
  const out = [];
  function visit(node, prefix, depth) {
    if (depth > 100 || !node || typeof node !== 'object' || !node.files || typeof node.files !== 'object' || Array.isArray(node.files)) throw Error('Invalid ASAR directory tree');
    const names = new Set();
    for (const [name, child] of Object.entries(node.files)) {
      const rel = prefix ? `${prefix}/${name}` : name;
      validateRelative(rel);
      if (name.includes('/')) throw Error('Archive component contains slash');
      const folded = name.toLowerCase();
      if (names.has(folded)) throw Error('Case-colliding archive names');
      names.add(folded);
      if (!child || typeof child !== 'object' || Array.isArray(child)) throw Error('Invalid archive file node');
      if (child.files) visit(child, rel, depth + 1);
      else out.push({ path: rel, node: child });
    }
  }
  visit(header, '', 0);
  return out;
}

function readMember(archive, rel) {
  const entry = archive.files.find(e => e.path === rel);
  if (!entry || entry.node.link || entry.node.unpacked) throw Error(`Required member is missing or not packed: ${rel}`);
  if (entry.node.size > 32 * 1024 * 1024) throw Error(`Patch candidate too large: ${rel}`);
  const fd = fs.openSync(archive.file, 'r'), data = Buffer.alloc(entry.node.size);
  try { readExact(fd, data, archive.dataOffset + Number(entry.node.offset)); }
  finally { fs.closeSync(fd); }
  if (entry.node.integrity && (entry.node.integrity.algorithm !== 'SHA256' || entry.node.integrity.hash !== sha(data))) throw Error(`ASAR member integrity mismatch: ${rel}`);
  return data;
}

function makeHeader(header) {
  const json = Buffer.from(JSON.stringify(header)), padded = Math.ceil(json.length / 4) * 4;
  const buffer = Buffer.alloc(16 + padded);
  buffer.writeUInt32LE(4, 0); buffer.writeUInt32LE(8 + padded, 4);
  buffer.writeUInt32LE(4 + padded, 8); buffer.writeUInt32LE(json.length, 12);
  json.copy(buffer, 16);
  return { buffer, headerHash: sha(json) };
}

function integrity(data, blockSize = 4 * 1024 * 1024) {
  const blocks = [];
  for (let i = 0; i < data.length; i += blockSize) blocks.push(sha(data.subarray(i, i + blockSize)));
  if (!data.length || data.length % blockSize === 0) blocks.push(sha(Buffer.alloc(0)));
  return { algorithm: 'SHA256', hash: sha(data), blockSize, blocks };
}

async function rebuild(archive, replacements, output) {
  const header = JSON.parse(JSON.stringify(archive.header));
  let offset = archive.payloadLength;
  for (const [rel, data] of replacements) {
    validateRelative(rel);
    const parts = rel.split('/'), name = parts.pop();
    let parent = header;
    for (const part of parts) { parent = parent.files[part]; if (!parent?.files) throw Error('Replacement directory absent'); }
    const before = parent.files[name];
    if (before?.unpacked || before?.link || before?.files) throw Error('Cannot replace unpacked/link/directory member');
    parent.files[name] = { ...before, size: data.length, offset: String(offset), integrity: integrity(data) };
    offset += data.length;
  }
  const encoded = makeHeader(header);
  fs.writeFileSync(output, encoded.buffer, { flag: 'wx' });
  if (archive.payloadLength) await pipeline(fs.createReadStream(archive.file, { start: archive.dataOffset, highWaterMark: 1024 * 1024 }), fs.createWriteStream(output, { flags: 'a', highWaterMark: 1024 * 1024 }));
  for (const data of replacements.values()) fs.appendFileSync(output, data);
  const fd = fs.openSync(output, 'r+'); try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  return { headerHash: encoded.headerHash, header, dataOffset: encoded.buffer.length };
}

async function hashFile(file, start, end) {
  const hash = crypto.createHash('sha256');
  for await (const chunk of fs.createReadStream(file, { highWaterMark: 1024 * 1024, ...(start === undefined ? {} : { start, end }) })) hash.update(chunk);
  return hash.digest('hex');
}

module.exports = { sha, readArchive, readMember, flatten, validateRelative, makeHeader, rebuild, hashFile };
