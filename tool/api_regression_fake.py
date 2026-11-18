#!/usr/bin/python3
"""Fail-closed, persistent CLI double; only installed inside the isolated root."""
import json, pathlib, sys, fcntl
root = pathlib.Path('/work')
assert __import__('os').environ.get('HAMPANEL_ISOLATED') == '1'
a = sys.argv[1:]
with (root/'fake-commands.jsonl').open('a') as log:
    log.write(json.dumps(a)+'\n')
if (root/'fake-fail').exists():
    print('injected dependency failure', file=sys.stderr); sys.exit(42)
lock = (root/'fake.lock').open('w'); fcntl.flock(lock, fcntl.LOCK_EX)
p = root/'fake-state.json'
s = json.loads(p.read_text()) if p.exists() else dict(containers={}, network={}, volume={}, images={})
def emit(x): print(json.dumps(x))
def save(): p.write_text(json.dumps(s))
def fail(): print('missing or unsupported fake command: '+repr(a),file=sys.stderr); sys.exit(42)
if not a: fail()
c = a[0]
if c == 'version': print('27.0.0')
elif c == 'info': emit({'ServerVersion':'27.0.0','Containers':len(s['containers'])})
elif c == 'ps':
    for n,v in s['containers'].items(): emit(dict(ID=n,Names=n,Image=v['image'],State=v['state']))
elif c == 'run':
    n=a[a.index('--name')+1]; s['containers'][n]=dict(image=a[-1],state='running'); save(); print(n)
elif c=='inspect' and a[1:3]==['--format','{{.State.Running}}']:
    print(str(s['containers'][a[3]]['state']=='running').lower())
elif c=='exec' and a[1:]==['-it','fixture','/bin/sh']:
    print('fixture terminal ready')
elif c=='exec' and a[1] in s['containers']:
    fs=s['containers'][a[1]].setdefault('files',{})
    cmd=a[2:]; path=cmd[-1]
    if cmd[:3]==['supervisorctl','-c','/etc/hampanel/supervisord.conf'] and cmd[3:] in (['status'],['start','app']): print('app RUNNING')
    elif cmd[:-1]==['mkdir','-p','--']: fs[path]=None; save()
    elif cmd[:-1]==['cat','--'] and path in fs: sys.stdout.buffer.write(bytes.fromhex(fs[path]))
    elif cmd[:-2]==['mv','--'] and cmd[-2] in fs: fs[path]=fs.pop(cmd[-2]); save()
    elif cmd[:-1]==['rm','-rf','--'] and path in fs: del fs[path]; save()
    elif cmd[:-1]==['sh','-c','LC_ALL=C ls -la -- "$1"','sh'] and path in fs:
        for k,v in fs.items():
            if str(pathlib.PurePosixPath(k).parent)==path and v is not None: print('-rw-r--r-- 1 root root',len(v)//2,'Jan 1 00:00',pathlib.PurePosixPath(k).name)
    else: fail()
elif c=='cp' and len(a)==3:
    download=':' in a[1]; remote,local=(a[1],a[2]) if download else (a[2],a[1]); n,k=remote.split(':',1)
    tmp=pathlib.Path(local).resolve()
    if tmp.parent!=root/'data/tmp' or n not in s['containers']: fail()
    fs=s['containers'][n].setdefault('files',{})
    if download: tmp.write_bytes(bytes.fromhex(fs[k]))
    else: fs[k]=tmp.read_bytes().hex(); save()
elif c == 'inspect':
    out=[]
    for n in a[1:]:
        if n not in s['containers']: fail()
        v=s['containers'][n]; out.append(dict(Id=n,Name='/'+n,Image='sha256:abc',Config=dict(Image=v['image'],Env=[],Labels={}),State=dict(Status=v['state']),HostConfig={},NetworkSettings={}))
    emit(out)
elif c in ('start','stop','restart','pause','unpause','rm'):
    n=a[-1]
    if n not in s['containers']: fail()
    if c=='rm': del s['containers'][n]
    else: s['containers'][n]['state']={'stop':'exited','pause':'paused'}.get(c,'running')
    save(); print(n)
elif c=='rename':
    s['containers'][a[2]]=s['containers'].pop(a[1]); save()
elif c=='logs': print('fixture log line')
elif c=='stats': pass
elif c=='search': emit(dict(Name='alpine',Description='isolated fixture',StarCount='1',IsOfficial=True))
elif c=='rmi':
    if a[-1] not in s['images']: fail()
    del s['images'][a[-1]]; save()
elif c=='save':
    import io, tarfile
    with tarfile.open(a[a.index('-o')+1], 'w') as archive:
        data=b'isolated image fixture'; info=tarfile.TarInfo('fixture'); info.size=len(data); archive.addfile(info,io.BytesIO(data))
elif c=='load':
    import tarfile
    with tarfile.open(a[a.index('-i')+1]) as archive: archive.getmembers()
    s['images']['imported:latest']=True; save()
elif c=='build':
    s['images'][a[a.index('-t')+1]]=True; save(); print('fixture build complete')
elif (c=='image' and a[1]=='prune') or (c=='builder' and a[1]=='prune'):
    if c=='image': s['images'].clear(); save()
    print('fixture pruned')
elif c=='image' and a[1]=='inspect': emit([dict(Id='sha256:abc')])
elif c=='images':
    for n in s['images']: emit(dict(ID='sha256:abc',Repository=n,Tag='latest',Size='12MB'))
elif c in ('pull','tag','commit'):
    s['images'][a[-1]]=True; save(); print('sha256:abc')
elif c in ('push','login'): print('success')
elif c in ('network','volume'):
    sub=a[1]; bucket=s[c]
    if sub=='create':
        n=a[-1]; bucket[n]=dict(ID=n,Id=n,Name=n,Driver='bridge' if c=='network' else 'local',Scope='local',Labels={},Options={},IPAM={'Config':[]}); save(); print(n)
    elif sub=='ls':
        for v in bucket.values(): emit(v)
    elif sub=='inspect': emit([bucket[n] for n in a[2:] if n in bucket])
    elif sub=='rm':
        if a[-1] not in bucket: fail()
        del bucket[a[-1]]; save()
    elif sub=='prune': bucket.clear(); save(); print('pruned')
    else: fail()
elif c=='compose':
    if 'version' in a: print('Docker Compose version v2.0')
    elif '-p' in a and 'hampanel-nginx' in a and 'up' in a: s['nginx_up']=True; save()
    elif '-p' in a and 'hampanel-nginx' in a and 'ps' in a and s.get('nginx_up'): print('nginx Up 1 second')
    elif 'ls' in a or 'ps' in a: emit([])
    elif 'config' in a: print('services: {}')
    elif any(x in a for x in ('up','down','start','stop','restart','pull','logs')): print('compose fixture success')
    else: fail()
else: fail()
