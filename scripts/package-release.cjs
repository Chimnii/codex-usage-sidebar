'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..');
const ROOTS=['.github','.gitattributes','.gitignore','LICENSE','LICENSES','README.md','THIRD_PARTY_NOTICES.md','docs','patcher','collector','tweak','scripts','tests','package.json','package-lock.json','runtime.lock.json','Setup.cmd','Launch.cmd','Update.cmd','Restore.cmd','Uninstall.cmd'];
function listPublicFiles(base=root) {
  const files=[];
  function walk(rel) {
    const stat=fs.lstatSync(path.join(base,rel));if(stat.isSymbolicLink())throw Error('Release input cannot be a link: '+rel);
    if(stat.isDirectory())for(const name of fs.readdirSync(path.join(base,rel)).sort())walk(path.join(rel,name));
    else files.push(rel.replaceAll('\\','/'));
  }
  ROOTS.forEach(walk);return files.sort();
}
function auditFile(relative,text,base=root) {
  if(/(?:^|\/)(?:\.local|node_modules|\.git)(?:\/|$)|\.(?:exe|dll|asar|lnk|log|zip|tgz)$/i.test(relative))throw Error('Generated/private release file: '+relative);
  const normalized=text.replaceAll('\\\\','\\').replaceAll('\\','/').toLowerCase();
  for(const privatePath of [base,process.env.USERPROFILE].filter(Boolean)) {
    if(normalized.includes(privatePath.replaceAll('\\','/').toLowerCase()))throw Error('Personal path in '+relative);
  }
  if(/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\b(?:ghp_|github_pat_|sk-ant-)[A-Za-z0-9_-]{24,}/.test(text))throw Error('Credential-shaped content in '+relative);
}
function build() {
  const pkg=require('../package.json');
  if(require('../tweak/manifest.json').version!==pkg.version)throw Error('Version mismatch');
  const files=listPublicFiles();
  for(const rel of files)auditFile(rel,fs.readFileSync(path.join(root,rel),'utf8'));
  const releases=path.join(root,'.local/releases');fs.mkdirSync(releases,{recursive:true});
  const destination=fs.mkdtempSync(path.join(releases,pkg.version+'-'));
  const source=path.join(destination,'codex-usage-sidebar');fs.mkdirSync(source);
  const manifest=[];
  for(const rel of files){const contents=fs.readFileSync(path.join(root,rel));const to=path.join(source,rel);fs.mkdirSync(path.dirname(to),{recursive:true});fs.writeFileSync(to,contents);manifest.push({path:rel,sha256:crypto.createHash('sha256').update(contents).digest('hex')});}
  fs.writeFileSync(path.join(source,'release-manifest.json'),JSON.stringify({version:pkg.version,files:manifest},null,2));
  const zip=path.join(destination,'codex-usage-sidebar-'+pkg.version+'.zip');
  const p=spawnSync('tar.exe',['-a','-cf',zip,'-C',destination,'codex-usage-sidebar'],{stdio:'inherit'});
  if(p.status!==0)throw Error('Could not create release archive');
  const hash=crypto.createHash('sha256').update(fs.readFileSync(zip)).digest('hex');
  fs.writeFileSync(path.join(destination,'SHA256SUMS.txt'),hash+'  '+path.basename(zip)+'\n');
  const report={version:pkg.version,source,zip,sha256:hash,fileCount:files.length};
  fs.writeFileSync(path.join(releases,'latest.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));return report;
}
if(require.main===module){try{build()}catch(e){console.error(e.message);process.exitCode=1;}}
module.exports={listPublicFiles,auditFile,build};
