#!/usr/bin/env python3
"""One fail-closed, clean-commit, two-build ABBA diagnostic; never auto-retry."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
ORDER = ('A', 'B', 'B', 'A')
TARGET = 'integration_test/computerraria_dynamic_profile_test.dart'
PLAN = ROOT/'tool/perf/viewport_cache_pair_plan.json'
WEB_GENERATED = ('world.js', 'world.wasm', 'player.js', 'player.wasm', 'manifest.json', 'circuit_rules.engine-provenance.json')


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''):
            digest.update(block)
    return digest.hexdigest()


def write(path, value):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(value, indent=2)+'\n')


def git(root, *args):
    return subprocess.check_output(['git', *args], cwd=root, text=True).strip()


def clean(root, commit):
    if git(root, 'rev-parse', 'HEAD') != commit or git(root, 'status', '--porcelain', '--untracked-files=normal'):
        raise ValueError('Requested checkout is not clean: '+str(root))


def inventory(root):
    result = {}
    for row in git(root, 'ls-files', '--stage').splitlines():
        stage, name = row.split('\t', 1)
        mode, _, index = stage.split()
        if index != '0' or mode not in ('100644', '100755'):
            raise ValueError('Non-regular or unmerged source: '+name)
        path = root/name
        if path.is_symlink() or not path.is_file():
            raise ValueError('Source is not a regular file: '+name)
        result[name] = {'sha256':sha(path), 'mode':mode}
    return result


def prepare(output, stage):
    output.mkdir(parents=True, exist_ok=False)
    stage.mkdir(parents=True, exist_ok=False)
    plan = json.loads(PLAN.read_text())
    if plan.get('publicationIdentityComplete') is not True:
        raise ValueError('Publisher has not finalized exact B provenance deltas')
    b = git(ROOT, 'rev-parse', 'HEAD')
    a = git(ROOT, 'rev-parse', 'HEAD^')
    if git(ROOT, 'rev-parse', 'HEAD^^') != plan['frozenBaseCommit']:
        raise ValueError('Required commit sequence is b3f2 -> common harness A -> candidate B')
    clean(ROOT, b)
    checkouts = {arm:{'commit':commit} for arm, commit in (('A',a),('B',b))}
    for arm in ('A','B'):
        for kind in ('native','wasm'):
            target = stage/(arm+'-'+kind)
            subprocess.run(['git','worktree','add','--detach',str(target),checkouts[arm]['commit']], cwd=ROOT, check=True)
            checkouts[arm][kind] = str(target)
    sources = {arm:inventory(Path(row['native'])) for arm,row in checkouts.items()}
    products = plan['originalProductFiles']
    if len(products) != 873 or any(sources['A'].get(name) != value for name,value in products.items()):
        raise ValueError('A changed the frozen original 873 product files or modes')
    if sources['A'].keys() != sources['B'].keys():
        raise ValueError('A/B must contain identical common test and source paths')
    actual = {name:sources['B'][name] for name in sources['A'] if sources['A'][name] != sources['B'][name]}
    expected = {name:{key:value[key] for key in ('sha256','mode')} for name,value in {
        **plan['candidateRuntimeChanges'], **plan['candidateProvenanceChanges']}.items()}
    if actual != expected:
        raise ValueError('A/B delta is not exactly the reviewed candidate + provenance manifest')
    if len(plan['candidateRuntimeChanges']) != 6:
        raise ValueError('Only the six reviewed candidate source changes are allowed')
    a_delta = set(git(ROOT,'diff','--name-only',plan['frozenBaseCommit'],a).splitlines())
    if a_delta != set(plan['commonHarnessPaths']):
        raise ValueError('A includes undeclared common harness changes')
    for arm, files in sources.items():
        write(output/(arm+'-all-sources.json'), files)
    state = {'schema':'abc.viewport-cache-checkouts.v1','checkouts':checkouts,'order':list(ORDER),
        'planSha256':sha(PLAN),'reviewedDelta':actual,'baseCommit':plan['frozenBaseCommit'],
        'environment':{'os':platform.platform(),'processors':os.cpu_count(),
            'githubRunId':os.environ.get('GITHUB_RUN_ID'),'githubRunAttempt':os.environ.get('GITHUB_RUN_ATTEMPT')}}
    write(output/'checkouts.json',state)
    shutil.copyfile(PLAN,output/'predeclared-plan.json')


def checkouts(output):
    return json.loads((output/'checkouts.json').read_text())['checkouts']


def build_profile(output):
    flutter = shutil.which('flutter')
    if not flutter:
        raise ValueError('Official CI Flutter setup required')
    for arm,row in checkouts(output).items():
        root = Path(row['native'])
        clean(root,row['commit'])
        env = dict(os.environ,ABC_PERF_COMMIT=row['commit'])
        defines = [f'--dart-define=PERF_COMMIT={row["commit"]}',
            f'--dart-define=PERF_CHECKED_OUT_HEAD={row["commit"]}',
            '--dart-define=PERF_WORKTREE_DIRTY=false','--dart-define=PERF_FLUTTER_VERSION=3.47.6',
            f'--dart-define=PERF_RENDERER={env["TERRA_PERF_RENDERER"]}',
            f'--dart-define=PERF_RUNNER={env["TERRA_PERF_RUNNER"]}']
        with (output/(arm+'-profile-build.log')).open('x') as log:
            subprocess.run([flutter,'--no-version-check','--suppress-analytics','build','linux','--no-pub','--profile',f'--target={TARGET}',*defines],cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=900,check=True)
        subprocess.run([sys.executable,'tool/perf/computerraria_provenance.py',
            '--artifact','build/linux/x64/profile/bundle/terraforge',
            '--artifact','build/linux/x64/profile/bundle/lib/libabc_engine.so',
            '--artifact','build/linux/x64/profile/bundle/lib/libapp.so',
            '--cmake-cache','build/linux/x64/profile/CMakeCache.txt',
            '--ninja-build','build/linux/x64/profile/build.ninja',
            '--output',str(output/(arm+'-profile-build.json'))],cwd=root,env=env,check=True)
        build = json.loads((output/(arm+'-profile-build.json')).read_text())
        if build['cmake'].get('ABC_PERF_COUNTERS') != 'OFF':
            raise ValueError('Profile uses production allocator-counter setting OFF')
        # Audit code binaries separately; no assets, fonts, WLDs or saved data.
        binary_output=output/'native'/arm
        binary_output.mkdir(parents=True,exist_ok=False)
        for name,relative in (('terraforge','terraforge'),
                              ('libapp.so','lib/libapp.so'),
                              ('libabc_engine.so','lib/libabc_engine.so')):
            artifact=root/'build/linux/x64/profile/bundle'/relative
            shutil.copyfile(artifact,binary_output/name)
            if sha(binary_output/name)!=build['artifacts'][name]['sha256']:
                raise ValueError('Audit binary copy differs from profile manifest')
        shutil.copyfile(output/(arm+'-profile-build.json'),binary_output/'build-provenance.json')
        clean(root,row['commit'])


def run_pair(output):
    rows = checkouts(output)
    status = {'schema':'abc.viewport-cache-pair-execution.v1','status':'running','order':list(ORDER),'runs':[],
        'invocationLimit':4,'profileBuildLimit':2,'rerunsAllowed':False,'automaticPromotion':False}
    write(output/'pair-execution.json',status)
    try:
        for index,arm in enumerate(ORDER,1):
            row = rows[arm]
            root = Path(row['native'])
            clean(root,row['commit'])
            target = output/f'{index:02}-{arm}'/'dynamic.json'
            tmp = root/'build/computerraria/tmp'/f'{index:02}-{arm}'
            tmp.mkdir(parents=True,exist_ok=False)
            env = dict(os.environ,ABC_PERF_COMMIT=row['commit'],
                ABC_DYNAMIC_PREBUILT_MANIFEST=str(output/(arm+'-profile-build.json')),
                COMPUTERRARIA_WLD=str(root/'build/public-computerraria/computerraria.wld'),
                COMPUTERRARIA_PONG=str(root/'test/fixtures/computerraria/pong.bin'),TMPDIR=str(tmp))
            status['runs'].append({'index':index,'arm':arm,'commit':row['commit'],'report':str(target.relative_to(output)),'status':'started'})
            write(output/'pair-execution.json',status)
            result = subprocess.run(['bash','tool/perf/computerraria_dynamic_profile.sh',str(target)],cwd=root,env=env,timeout=1260)
            status['runs'][-1].update(exitCode=result.returncode,status='passed' if result.returncode==0 else 'failed')
            write(output/'pair-execution.json',status)
            if result.returncode:
                raise ValueError('Fresh process failed; retaining all evidence and stopping without replacement')
            clean(root,row['commit'])
        summarize(output)
        status['status']='completed'
    except Exception as error:
        status.update(status='failed',failure=str(error))
        raise
    finally:
        write(output/'pair-execution.json',status)


def metric(values):
    import statistics
    if not values:
        return {'count':0,'median':None,'p95':None,'max':None,'raw':[]}
    ordered=sorted(values)
    return {'count':len(values),'median':statistics.median(ordered),
        'p95':ordered[int((len(ordered)-1)*.95)],'max':max(values),'raw':values}


def ordinal_frames(frames):
    result={}
    for row in frames:
        key=(row['physicalPulses'],row['mechanicalTicks'])
        if key in result:
            raise ValueError('Duplicate pulse/tick ordinal')
        result[key]=tuple(row[name] for name in ('recordsSha256','rgbaSha256','nativeTicks','netPulses','gatesFired'))
    return result


def summarize(output):
    execution=json.loads((output/'pair-execution.json').read_text())
    if [row['arm'] for row in execution['runs']] != list(ORDER) or any(row['status']!='passed' for row in execution['runs']):
        raise ValueError('No complete predeclared ABBA sequence')
    reports=[]
    rows=[]
    pids=[]
    for entry in execution['runs']:
        path=output/entry['report']
        data=json.loads(path.read_text())
        if data['status']!='passed' or data['runtime']['commit']!=entry['commit'] or data['runtime']['workingTreeDirty'] is not False:
            raise ValueError('Failed or misidentified fresh process')
        pids.append(data['runtime']['hostPid'])
        reports.append(data)
        on=next(mode for mode in data['modeResults'] if mode['mode']=='optimized')
        events=[e for trace in on['sessionCommandTraces'] for e in trace]
        compounds=[e for e in events if e['kind']=='production-command-and-pixels' and e.get('phase')=='timed-dynamic-15s' and e.get('status')=='completed']
        views=[]
        for n,event in enumerate(compounds):
            following=[e for e in events if e['kind']=='native-command' and e.get('words',[0,0])[1]==1 and e.get('status')=='completed' and e['startUs']>=event['endUs'] and (n+1==len(compounds) or e['startUs']<compounds[n+1]['startUs'])]
            if not following:
                raise ValueError('Compound batch lacks a subsequent viewport completion')
            views.append(min(following,key=lambda e:e['startUs']))
        if len(views)!=len(on['dynamicFrames']):
            raise ValueError('Dynamic frame and linked viewport counts differ')
        native=[e for e in events if e['kind']=='native-command' and e.get('status')=='completed' and e.get('phase')=='timed-dynamic-15s']
        process={'index':entry['index'],'arm':entry['arm'],'commit':entry['commit'],'hostPid':pids[-1],
            'reportSha256':sha(path),'derivedSha256':data['preparation']['derivedSha256'],
            'queryProbes':{mode['mode']:mode['viewportQueryProbes'] for mode in data['modeResults']},
            'dynamicBatches':len(compounds),'viewportWallUs':metric([e['endUs']-e['startUs'] for e in views]),
            'compoundWallUs':metric([e['endUs']-e['startUs'] for e in compounds]),
            'commandWallUs':{name:metric([e['endUs']-e['startUs'] for e in native if e.get('origin')==origin]) for name,origin in (
                ('clock128','test-external-clock'),('ticks6','production-batch-command'),('pixels','production-batch-pixels'))},
            'viewportNativeActiveBytes':metric([e['nativeActiveBytes'] for e in views]),
            'viewportNativePeakBytes':metric([e['nativePeakBytes'] for e in views]),
            'operations':data['operations'],'processRssAtCleanupBytes':data['processRssAtCleanupBytes'],
            'processLifetimePeakRssBytes':data['processLifetimePeakRssBytes']}
        rows.append(process)
    if len(set(pids))!=4:
        raise ValueError('Four distinct application host PIDs required')
    if len({row['preparation']['derivedSha256'] for row in reports})!=1:
        raise ValueError('Preparation input bytes differ across processes')
    matched=[]
    for mode_index in (0,1):
        modes=[report['modeResults'][mode_index] for report in reports]
        probe_hashes=set()
        for mode in modes:
            probes=mode['viewportQueryProbes']
            if [p['label'] for p in probes]!=['selected-roi-cold','selected-roi-warm-1','selected-roi-warm-2']:
                raise ValueError('Missing or reordered predeclared viewport probes')
            for probe in probes:
                if probe['recordCount']!=3072 or probe['wallUs']!=probe['endUs']-probe['startUs'] or probe['wallUs']<0:
                    raise ValueError('Malformed actual viewport probe')
                probe_hashes.add(probe['recordsSha256'])
        if len(probe_hashes)!=1:
            raise ValueError('Cold/warm selected viewport bytes differ across arms')
        fixed=[ordinal_frames(mode['fixedTrace']) for mode in modes]
        if any(value!=fixed[0] for value in fixed[1:]):
            raise ValueError('Fixed ordinal record/RGBA/work counters differ')
        for mode in modes:
            if [f['recordsSha256'] for f in mode['liveContinuation']] != [f['recordsSha256'] for f in mode['reopenedContinuation']]:
                raise ValueError('Save/reopen continuation differs')
        if mode_index==1:
            maps=[ordinal_frames(mode['dynamicFrames']) for mode in modes]
            common=set.intersection(*(set(value) for value in maps))
            if len(common)<2 or any(len({value[key] for value in maps})!=1 for key in common):
                raise ValueError('Same pulse/tick dynamic record/RGBA/work counters differ')
            matched.append({'mode':'optimized','commonOrdinals':[list(key) for key in sorted(common)],
                'unmatchedOrdinals':[[list(key) for key in sorted(set(value)-common)] for value in maps]})
        # Saved bytes are only cross-process comparable at identical electrical
        # ordinals; timed 15-second windows can complete different batch counts.
        groups={}
        for n,mode in enumerate(modes):
            ordinal=(len(mode.get('dynamicFrames',[])),mode['preSaveRgbaSha256'],mode['preSaveRamSha256'])
            groups.setdefault(ordinal,[]).append(n)
        for indexes in groups.values():
            if len({modes[n]['savedSha256'] for n in indexes})!=1:
                raise ValueError('Save bytes differ at equal logical state')
    deltas=[]
    for a,b in ((rows[0],rows[1]),(rows[3],rows[2])):
        av,bv=a['viewportWallUs']['median'],b['viewportWallUs']['median']
        deltas.append({'aProcess':a['index'],'bProcess':b['index'],'medianViewportRatioBOverA':bv/av})
    write(output/'pair-summary.json',{'schema':'abc.viewport-cache-pair-summary.v1','status':'passed-correctness',
        'processes':rows,'ordinalComparisons':matched,'predeclaredPairDeltas':deltas,
        'performanceConclusion':'Descriptive two-samples-per-arm signal only; no automatic acceptance or additional experiment.',
        'outlierPolicy':'All four processes and all operation/command/query raw values retained. No deletion, trimming, reruns, or replacement.',
        'limits':['No robust device FPS inference from two samples or llvmpipe.',
            'RSS operation endpoints/lifetime maximum and native active/peak have distinct scopes; never add them.',
            'No sustained memory plateau or steady-window RSS peak measured.',
            'Selected ROI cold means displaced tile cache, not cold OS I/O or process.',
            'Different timed batch counts are retained; only common pulse/tick ordinals are compared.',
            'RAM equality is the original passive 8704-lamp sample: 272 words / 1088 bytes, not all 368 KiB RAM.',
            'Visible observers remain ON at the same minimum 250ms interval; not observer-free.']})


def web_record(output, arm, phase):
    row=checkouts(output)[arm]
    root=Path(row['wasm'])
    current=inventory(root)
    if phase=='before':
        clean(root,row['commit'])
        write(output/(arm+'-wasm-before.json'),{'commit':row['commit'],'dirty':False,'sourceFiles':current})
    else:
        before=json.loads((output/(arm+'-wasm-before.json')).read_text())['sourceFiles']
        delta={name:current[name] for name in current if before.get(name)!=current[name]}
        allowed={'web/engine/'+name for name in WEB_GENERATED}
        if set(delta)-allowed:
            raise ValueError('WASM verification modified more than generated runtime artifacts')
        write(output/(arm+'-wasm-after.json'),{'commit':row['commit'],'dirty':bool(git(root,'status','--porcelain')),
            'sourceFiles':current,'generatedDelta':delta,'sourceWorktreePurpose':'generated-runtime-verification-only; not a clean product checkout',
            'testedJs':str(root/'web/engine/world.js'),'testedWasm':str(root/'web/engine/world.wasm')})
        target=output/'wasm'/arm
        target.mkdir(parents=True,exist_ok=False)
        for name in WEB_GENERATED:
            shutil.copyfile(root/'web/engine'/name,target/name)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=('prepare','build-profile','run','summarize','web-before','web-after'))
    parser.add_argument('output',type=Path)
    parser.add_argument('--stage',type=Path)
    parser.add_argument('--arm',choices=('A','B'))
    args=parser.parse_args()
    output=args.output.resolve()
    if args.action=='prepare':prepare(output,args.stage.resolve())
    elif args.action=='build-profile':build_profile(output)
    elif args.action=='run':run_pair(output)
    elif args.action=='summarize':summarize(output)
    else:web_record(output,args.arm,args.action.removeprefix('web-'))


if __name__=='__main__':main()
