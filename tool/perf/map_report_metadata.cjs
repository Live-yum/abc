const fs=require('node:fs'),crypto=require('node:crypto'),{execFileSync}=require('node:child_process');
function command(name,args){try{return execFileSync(name,args,{encoding:'utf8',stdio:['ignore','pipe','ignore']}).trim();}catch{return null;}}
function metadata(artifacts=[]){
  const commit=command('git',['rev-parse','HEAD']),status=command('git',['status','--porcelain','--untracked-files=normal']);
  return {source:{commit:process.env.ABC_PERF_COMMIT||process.env.GITHUB_SHA||commit||'unknown',worktreeCommit:commit||'unknown',dirty:status===null?'unknown':!!status.length,
    commitSource:process.env.ABC_PERF_COMMIT?'ABC_PERF_COMMIT':process.env.GITHUB_SHA?'GITHUB_SHA':commit?'git':'unknown'},
    toolchain:{node:process.versions.node,v8:process.versions.v8,flutterPinned:fs.existsSync('.flutter-version')?fs.readFileSync('.flutter-version','utf8').trim():'unknown',
      artifacts:artifacts.map(([id,file])=>{const b=fs.readFileSync(file);return {id,bytes:b.length,sha256:crypto.createHash('sha256').update(b).digest('hex')};})}};
}
module.exports={metadata};
