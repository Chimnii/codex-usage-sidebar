'use strict';

// Locate the Electron integrity JSON through PE resource directories. Never
// search/replace arbitrary hex strings and never change Electron fuse bytes.
function locateIntegrity(buffer, expectedHeaderHash) {
  const need = (offset, length, label) => {
    if (!Number.isSafeInteger(offset) || offset < 0 || offset + length > buffer.length) throw Error(`Invalid PE bounds: ${label}`);
  };
  need(0, 64, 'DOS');
  if (buffer.toString('ascii', 0, 2) !== 'MZ') throw Error('Executable is not PE/MZ');
  const pe = buffer.readUInt32LE(60);
  need(pe, 24, 'COFF');
  if (buffer.toString('ascii', pe, pe + 4) !== 'PE\0\0') throw Error('Invalid PE signature');
  const count = buffer.readUInt16LE(pe + 6), optionalSize = buffer.readUInt16LE(pe + 20), optional = pe + 24;
  need(optional, optionalSize, 'optional header');
  const magic = buffer.readUInt16LE(optional);
  const directory = magic === 0x20b ? optional + 112 : magic === 0x10b ? optional + 96 : -1;
  if (directory < 0 || directory + 24 > optional + optionalSize) throw Error('Unsupported PE optional header');
  const directoryCountOffset = magic === 0x20b ? optional + 108 : optional + 92;
  if (buffer.readUInt32LE(directoryCountOffset) < 3) throw Error('PE has no resource directory');
  const resourceRva = buffer.readUInt32LE(directory + 16), resourceSize = buffer.readUInt32LE(directory + 20);
  if (!resourceRva || resourceSize < 16) throw Error('PE resource directory missing');
  const sections = [];
  for (let i = 0; i < count; i++) {
    const o = optional + optionalSize + 40 * i;
    need(o, 40, 'section');
    sections.push({ rva: buffer.readUInt32LE(o + 12), length: buffer.readUInt32LE(o + 16), offset: buffer.readUInt32LE(o + 20) });
  }
  function map(rva, size) {
    const candidates = sections.filter(s => rva >= s.rva && rva + size <= s.rva + s.length);
    if (candidates.length !== 1) throw Error('Ambiguous/unmapped PE resource RVA');
    const result = candidates[0].offset + rva - candidates[0].rva;
    need(result, size, 'mapped resource');
    return result;
  }
  const base = map(resourceRva, resourceSize);
  function within(relative, size) {
    if (relative < 0 || relative + size > resourceSize) throw Error('PE resource tree escapes resource directory');
    return base + relative;
  }
  function entries(relative) {
    const o = within(relative, 16);
    const length = buffer.readUInt16LE(o + 12) + buffer.readUInt16LE(o + 14);
    if (length > 4096) throw Error('Excessive PE resource entries');
    within(relative + 16, length * 8);
    return Array.from({ length }, (_, i) => {
      const e = o + 16 + i * 8, nameRaw = buffer.readUInt32LE(e), target = buffer.readUInt32LE(e + 4);
      let name = nameRaw;
      if (nameRaw & 0x80000000) {
        const no = within(nameRaw & 0x7fffffff, 2), chars = buffer.readUInt16LE(no);
        within((nameRaw & 0x7fffffff) + 2, chars * 2);
        name = buffer.toString('utf16le', no + 2, no + 2 + chars * 2);
      }
      return { name, directory: !!(target & 0x80000000), relative: target & 0x7fffffff };
    });
  }
  function one(list, name) {
    const found = list.filter(e => e.name === name);
    if (found.length !== 1) throw Error(`Missing or ambiguous PE resource ${name}`);
    return found[0];
  }
  const type = one(entries(0), 'INTEGRITY');
  if (!type.directory) throw Error('INTEGRITY resource is not a directory');
  const name = one(entries(type.relative), 'ELECTRONASAR');
  if (!name.directory) throw Error('ELECTRONASAR resource is not a directory');
  const languages = entries(name.relative);
  if (languages.length !== 1 || languages[0].directory) throw Error('Ambiguous Electron integrity language resource');
  const data = within(languages[0].relative, 16), rva = buffer.readUInt32LE(data), size = buffer.readUInt32LE(data + 4);
  if (size > 1024 * 1024) throw Error('Excessive Electron integrity JSON');
  const offset = map(rva, size), bytes = buffer.subarray(offset, offset + size);
  let parsed;
  try { parsed = JSON.parse(bytes.toString('utf8').replace(/\0+$/, '')); }
  catch { throw Error('Invalid Electron integrity JSON resource'); }
  if (!Array.isArray(parsed)) throw Error('Unsupported Electron integrity JSON schema');
  const matches = parsed.filter(entry => entry && typeof entry.file === 'string' && entry.file.replace(/\\/g, '/').toLowerCase() === 'resources/app.asar');
  if (matches.length !== 1 || matches[0].alg !== 'SHA256' || !/^[a-f0-9]{64}$/.test(matches[0].value || '')) throw Error('Missing/ambiguous SHA256 app.asar integrity entry');
  if (matches[0].value !== expectedHeaderHash) throw Error('EXE integrity digest does not match input ASAR header');
  const needle = Buffer.from(expectedHeaderHash, 'ascii'), at = bytes.indexOf(needle);
  if (at < 0 || bytes.indexOf(needle, at + 1) >= 0) throw Error('Ambiguous digest in integrity resource');
  return { resource: 'INTEGRITY/ELECTRONASAR', resourceOffset: offset, resourceSize: size, hashOffset: offset + at, oldHeaderHash: expectedHeaderHash, language: languages[0].name };
}

function patchIntegrity(buffer, info, newHeaderHash) {
  if (!/^[a-f0-9]{64}$/.test(newHeaderHash)) throw Error('Invalid new ASAR header hash');
  if (buffer.toString('ascii', info.hashOffset, info.hashOffset + 64) !== info.oldHeaderHash) throw Error('EXE changed since preflight');
  const output = Buffer.from(buffer);
  output.write(newHeaderHash, info.hashOffset, 64, 'ascii');
  const verified = locateIntegrity(output, newHeaderHash);
  if (verified.hashOffset !== info.hashOffset) throw Error('Integrity resource moved unexpectedly');
  if (!buffer.subarray(0, info.hashOffset).equals(output.subarray(0, info.hashOffset)) || !buffer.subarray(info.hashOffset + 64).equals(output.subarray(info.hashOffset + 64))) throw Error('EXE modifications escaped integrity field');
  return output;
}

module.exports = { locateIntegrity, patchIntegrity };
