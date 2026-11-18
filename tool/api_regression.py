#!/usr/bin/env python3
"""Isolated mTLS API regression. Run only through api_regression_isolate.sh.
Every registered route appears in matrix.json; absent scenarios are NOT coverage.
"""
import http.client, json, os, pathlib, re, ssl, subprocess, time, urllib.parse
ROOT = pathlib.Path('/work')
assert os.environ.get('HAMPANEL_ISOLATED') == '1' and ROOT.is_dir()
OUT = ROOT / 'reports'; OUT.mkdir(exist_ok=True)
routes = re.findall(r'\.method = \.(\w+), \.pattern = "([^"]+)"', (ROOT/'routes.zig').read_text())
results = []
config = dict(listen='127.0.0.1', port=18443, data_dir='/work/data', tls_dir='/work/tls', enroll_file='/work/enroll.json', entry_prefix='/regression', container='docker', web_server='nginx')
(ROOT/'config.json').write_text(json.dumps(config))
env = dict(os.environ, PATH='/work/fake')
cmd = ['/work/hampaneld','init','--config','/work/config.json','--endpoint','127.0.0.1:18443','--san','127.0.0.1','--entry-prefix','/regression']
with (OUT/'init.log').open('w') as log:
    rc = subprocess.call(cmd, env=env, stdout=log, stderr=log)
(OUT/'commands.json').write_text(json.dumps([dict(command=cmd,exit_code=rc)]))
if rc: raise SystemExit(rc)
bundle=json.loads((ROOT/'enroll.json').read_text())
for key in ['ca_pem','client_cert_pem','client_key_pem']:
    (ROOT/key).write_text(bundle[key]); (ROOT/key).chmod(0o600)
ctx=ssl.create_default_context(cafile=str(ROOT/'ca_pem'))
ctx.load_cert_chain(str(ROOT/'client_cert_pem'),str(ROOT/'client_key_pem'))
def call(method,path,body=None):
    c=http.client.HTTPSConnection('127.0.0.1',18443,context=ctx,timeout=10)
    try:
        c.request(method,'/regression'+path,body=body if isinstance(body,bytes) else json.dumps(body) if body is not None else None,headers={'Content-Type':'application/octet-stream' if isinstance(body,bytes) else 'application/json'})
        r=c.getresponse(); raw=r.read()
        if 'application/json' in r.getheader('Content-Type', ''):
            return r.status,json.loads(raw)
        return r.status,{'raw_hex':raw.hex(), 'content_type':r.getheader('Content-Type', '')}
    finally: c.close()
def check(method,route,path,expected,body=None,predicate=lambda x: True,scenario='success'):
    try:
        status,data=call(method,path,body)
        ok=status==expected and bool(predicate(data))
        results.append(dict(method=method,route=route,scenario=scenario,status=status,expected=expected,passed=ok,response=data))
    except Exception as e: results.append(dict(method=method,route=route,scenario=scenario,passed=False,error=str(e)))
log=(OUT/'daemon.log').open('w')
p=subprocess.Popen(['/work/hampaneld','run','--config','/work/config.json'],env=env,stdout=log,stderr=log)
try:
    for _ in range(100):
        try: call('GET','/api/v1/health'); break
        except Exception: time.sleep(.1)
    for route in ['/health','/update','/docker/registries','/docker/notes']:
        check('GET','/api/v1'+route,'/api/v1'+route,200)
    fixture=ROOT/'a +#%中文.txt'; fixture.write_text('abcdefghij')
    path='/api/v1/files/content?'+urllib.parse.urlencode({'path':str(fixture),'max_bytes':4})
    check('GET','/api/v1/files/content',path,200,predicate=lambda d:d['content']=='abcd' and d['truncated'] and d['size']==10,scenario='URI-encoding-and-truncation')
    check('GET','/api/v1/files/content','/api/v1/files/content?path=%2Fwork%2Fabsent',404,scenario='missing')
    check('PUT','/api/v1/files/content','/api/v1/files/content',200,{'path':str(fixture),'content':'short'})
    check('GET','/api/v1/files/content','/api/v1/files/content?'+urllib.parse.urlencode({'path':str(fixture)}),200,predicate=lambda d:d['content']=='short' and not d['truncated'],scenario='write-roundtrip')
    for route in ['/docker/containers','/docker/images','/docker/info','/sites/reload']:
        method='POST' if route=='/sites/reload' else 'GET'
        check(method,'/api/v1'+route,'/api/v1'+route,502,scenario='dependency-failure')
    check('GET','/api/v1/docker/jobs/:id','/api/v1/docker/jobs/missing',404,scenario='missing')
    # Switch from fail-closed dependencies to the persistent engine double.
    for name in ('docker', 'podman'):
        target=ROOT/'fake'/name; target.unlink(); target.symlink_to('/work/fake-engine.py')
    def test(method, suffix, body=None, expected=200, predicate=lambda d: True, route=None, scenario='success'):
        full='/api/v1'+suffix
        check(method, '/api/v1'+(route or suffix.split('?')[0]), full, expected, body, predicate, scenario)
        return results[-1].get('response', {})
    for suffix in ('/docker/info','/docker/overview','/docker/containers','/docker/images','/docker/networks','/docker/volumes'):
        test('GET',suffix)
    test('POST','/docker/test-connection',predicate=lambda d:d['ok'])
    test('POST','/docker/containers',{'name':'fixture','image':'alpine:latest'},201,lambda d:d['ok'])
    test('GET','/docker/containers/fixture',route='/docker/containers/:id',predicate=lambda d:d['name']=='fixture')
    for action,state in [('stop','exited'),('start','running'),('pause','paused'),('unpause','running'),('restart','running')]:
        test('POST','/docker/containers/fixture/'+action,route='/docker/containers/:id/:action',predicate=lambda d:d['ok'])
        test('GET','/docker/containers/fixture',route='/docker/containers/:id',predicate=lambda d,s=state:d['state']==s)
    test('GET','/docker/containers/fixture/logs',route='/docker/containers/:id/logs',predicate=lambda d:'fixture log' in d['output'])
    test('POST','/docker/containers/fixture/commit',{'repository':'fixture'},route='/docker/containers/:id/commit',predicate=lambda d:d['ok'])
    for kind in ('networks','volumes'):
        test('POST','/docker/'+kind,{'name':'fixture'},predicate=lambda d:d['ok'])
        test('GET','/docker/'+kind,predicate=lambda d,k=kind:any(x['name']=='fixture' for x in d[k]))
        test('DELETE','/docker/'+kind+'/fixture',route='/docker/'+kind+'/:name',predicate=lambda d:d['ok'])
        test('GET','/docker/'+kind,predicate=lambda d,k=kind:not d[k])
        test('POST','/docker/'+kind+'/prune',predicate=lambda d:d['ok'])
    test('PUT','/docker/notes/fixture',{'note':'跨请求 note'},route='/docker/notes/:name')
    test('GET','/docker/notes',predicate=lambda d:any(x['note']=='跨请求 note' for x in d['notes']))
    reg=test('POST','/docker/registries',{'name':'fixture','host':'registry.example.com','username':'tester','secret':'fixture-secret'},201)
    if 'id' in reg:
        url='/docker/registries/'+reg['id']
        test('PUT',url,{'name':'changed','username':'tester'},route='/docker/registries/:id')
        test('POST',url+'/sync',route='/docker/registries/:id/sync',predicate=lambda d:d['ok'])
        test('GET','/docker/registries',predicate=lambda d:d['registries'][0]['has_secret'] and 'fixture-secret' not in json.dumps(d))
        (ROOT/'fake-fail').touch()
        test('POST',url+'/sync',route='/docker/registries/:id/sync',predicate=lambda d:not d['ok'],scenario='dependency-failure')
        (ROOT/'fake-fail').unlink()
        test('DELETE',url,route='/docker/registries/:id')
        test('GET','/docker/registries',predicate=lambda d:not d['registries'])
    for channel in ('nightly','stable','latest'):
        test('PUT','/update/config',{'channel':channel,'github_mirror':'https://example.com/'})
        test('GET','/update',predicate=lambda d,c=channel:d['channel']==c and d['github_mirror']=='https://example.com')
    test('PUT','/update/config',{'channel':'nightly','github_mirror':'invalid'},400,scenario='invalid')
    test('GET','/update',predicate=lambda d:d['channel']=='latest')
    yaml='services:\n  app:\n    image: alpine:latest\n'
    test('POST','/docker/compose',{'name':'fixture','content':yaml},201)
    test('GET','/docker/compose')
    test('GET','/docker/compose/fixture',route='/docker/compose/:name',predicate=lambda d:d['content']==yaml)
    test('PUT','/docker/compose/fixture',{'content':yaml+'# changed\n'},route='/docker/compose/:name')
    test('GET','/docker/compose/fixture',route='/docker/compose/:name',predicate=lambda d:'# changed' in d['content'])
    test('GET','/docker/compose/fixture/logs',route='/docker/compose/:name/logs')
    test('POST','/docker/compose/fixture/down',route='/docker/compose/:name/:action',predicate=lambda d:d['ok'])
    test('DELETE','/docker/compose/fixture',route='/docker/compose/:name')
    test('POST','/files/mkdir',{'path':'/work/lifecycle'})
    test('PUT','/files/content',{'path':'/work/lifecycle/a','content':'roundtrip'})
    test('GET','/files?path=/work/lifecycle',predicate=lambda d:any(x['name']=='a' for x in d['entries']))
    test('POST','/files/rename',{'from':'/work/lifecycle/a','to':'/work/lifecycle/b'})
    test('GET','/files/content?path=/work/lifecycle/b',predicate=lambda d:d['content']=='roundtrip')
    test('POST','/files/delete',{'paths':['/work/lifecycle/b']},predicate=lambda d:d['results'][0]['ok'])
    test('GET','/files/content?path=/work/lifecycle/b',expected=404,scenario='missing')
    for suffix in ('/runtimes','/runtimes/catalog','/docker/settings','/sites','/processes','/logs/sources','/audit','/store/apps','/store/packages','/store/nix','/software','/recycle','/notifications'):
        test('GET',suffix)
    runtime=test('POST','/runtimes',{'name':'regression-runtime','runtime':'php'},predicate=lambda d:d['ok'])
    if runtime.get('environment'):
        rid=runtime['environment']['id']; prefix='/runtimes/'+rid
        for suffix in ('/logs','/config','/extensions'):
            data=test('GET',prefix+suffix,route='/runtimes/:id'+suffix)
            if suffix=='/config' and data.get('files'):
                file=data['files'][0]
                test('PUT',prefix+suffix,{'file':file['path'],'content':file['content']+'\n; regression\n'},route='/runtimes/:id/config',predicate=lambda d:d['ok'])
                test('GET',prefix+suffix,route='/runtimes/:id/config',predicate=lambda d:any('; regression' in f['content'] for f in d['files']))
        for method,suffix in [('GET',''),('POST','/app/start')]:
            test(method,prefix+'/processes'+suffix,route='/runtimes/:id/processes'+('/:name/:action' if suffix else ''),predicate=lambda d:d['ok'] and 'app' in d['output'])
        for action in ('stop','start','restart','rebuild'):
            test('POST',prefix+'/'+action,route='/runtimes/:id/'+action,predicate=lambda d:d['ok'])
        test('PUT',prefix+'/extensions',{'extensions':[]},route='/runtimes/:id/extensions',predicate=lambda d:d['ok'])
        test('DELETE',prefix,route='/runtimes/:id',predicate=lambda d:d['removed'])
        test('GET',prefix+'/extensions',route='/runtimes/:id/extensions',expected=404,scenario='missing')
    # Persisted file versions and recycle operations use the real daemon/filesystem.
    test('GET','/files/download?path=/work/lifecycle',expected=400,scenario='invalid')
    version_path='/work/version-fixture'
    test('PUT','/files/content',{'path':version_path,'content':'before'})
    test('PUT','/files/content',{'path':version_path,'content':'after'})
    versions=test('GET','/files/versions?path='+version_path,predicate=lambda d:bool(d['versions']))
    if versions.get('versions'):
        vid=versions['versions'][0]['id']
        test('GET','/files/versions/content?'+urllib.parse.urlencode(dict(path=version_path,id=vid)),predicate=lambda d:d['content']=='before')
        test('POST','/files/versions/restore',dict(path=version_path,id=vid))
        test('GET','/files/content?path='+version_path,predicate=lambda d:d['content']=='before')
    test('GET','/files/download?path='+version_path,predicate=lambda d:bytes.fromhex(d['raw_hex'])==b'before')
    test('POST','/files/delete',{'paths':[version_path]})
    recycled=test('GET','/recycle')
    for entry in recycled.get('entries',[]):
        test('POST','/recycle/restore',{'id':entry['id']})
    test('POST','/files/delete',{'paths':[version_path]})
    for entry in test('GET','/recycle').get('entries',[]):
        test('POST','/recycle/delete',{'id':entry['id']})
    test('POST','/recycle/empty')
    test('PUT','/notifications',{})
    test('POST','/notifications/test',{'provider':'ntfy'},predicate=lambda d:not d['ok'],scenario='dependency-failure')
    for suffix in ('/system','/metrics','/host/settings','/ssh','/ssh/keys','/ssh/logging','/fail2ban','/waf','/waf/logs'):
        test('GET',suffix)
    test('PUT','/host/hosts',{'content':'127.0.0.1 localhost\n127.0.0.2 fixture\n'},predicate=lambda d:d['ok'])
    test('POST','/ssh/keys',{'user':'root','key':'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA fixture'},predicate=lambda d:d['ok'])
    test('GET','/ssh/keys',predicate=lambda d:len(d['keys'])==1)
    test('POST','/ssh/keys/delete',{'user':'root','index':0},predicate=lambda d:d['ok'])
    test('GET','/ssh/keys',predicate=lambda d:not d['keys'])
    for suffix in ('/host/hosts','/notifications'):
        test('PUT',suffix,{'content':'\u0000'} if suffix=='/host/hosts' else {'ntfy_enabled':True},400,scenario='invalid')
    test('POST','/host/ntp',{'enabled':True},expected=501,scenario='unsupported')
    test('POST','/host/grub',{'index':0},expected=409,scenario='missing')
    test('POST','/waf/install',expected=501,scenario='unsupported')
    test('POST','/waf/typesafe/key',{'api_key':'isolated-fixture-key'},expected=501,scenario='unsupported')
    test('DELETE','/waf/typesafe/key')
    test('GET','/docker/images/search?term=alpine',predicate=lambda d:d['results'][0]['name']=='alpine')
    def await_job(job):
        jid=job.get('job_id')
        if not jid: return
        for _ in range(100):
            status,data=call('GET','/api/v1/docker/jobs/'+jid)
            if data.get('status') in ('succeeded','failed','cancelled'): break
            time.sleep(.05)
        test('GET','/docker/jobs/'+jid,route='/docker/jobs/:id',predicate=lambda d:d['status']=='succeeded',scenario='job-completion')
        test('DELETE','/docker/jobs/'+jid,route='/docker/jobs/:id',predicate=lambda d:d['ok'] and not d['cancelled'],scenario='completed-job-cancel')
        return jid
    for action in ('pull','push','update','export'):
        jid=await_job(test('POST','/docker/images/'+action,{'reference':'alpine:latest'},202))
        if action=='export' and jid:
            test('GET','/docker/jobs/'+jid+'/download',route='/docker/jobs/:id/download',predicate=lambda d:len(bytes.fromhex(d['raw_hex']))==10240)
    test('POST','/docker/images/tag',{'source':'alpine:latest','target':'fixture:latest'})
    test('DELETE','/docker/images/fixture:latest',route='/docker/images/:id')
    for suffix,body in [('/docker/images/build',{'tag':'fixture:latest','context_path':'/work'}),('/docker/images/build/git',{'tag':'fixture:latest','url':'https://example.invalid/fixture.git'}),('/docker/images/prune',None),('/docker/build-cache/prune',None)]:
        await_job(test('POST',suffix,body,202))
    # Verify contracts against the real handler; doubles remain inside the namespace.
    def reject(method,route,path,status,code,body=None):
        test(method,path,body,status,lambda d:d.get('code')==code,route,
             {400:'invalid',404:'missing',409:'configuration-conflict',501:'unsupported',502:'dependency-failure'}[status])
    test('POST','/update/check',predicate=lambda d:d['current_version'] and not d['update_available'])
    for suffix in ('apply','schedule'):
        reject('POST','/update/'+suffix,'/update/'+suffix,409,'update_disabled')
    test('GET','/logs/tail?source=audit&lines=2',predicate=lambda d:d['path']=='sqlite:audit_log' and len(d['entries'])<=2)
    child=subprocess.Popen(['/usr/bin/python3','-c','import time; time.sleep(60)'])
    try:
        path='/processes/'+str(child.pid)
        test('GET',path,route='/processes/:pid',predicate=lambda d:d['pid']==child.pid)
        test('POST',path+'/kill',{'signal':'TERM'},route='/processes/:pid/kill',predicate=lambda d:d['ok'] and child.wait(timeout=3)==-15)
    finally:
        if child.poll() is None: child.kill()
        child.wait()
    blob=b'fixture\x00\xff'
    test('POST','/files/upload?path=/work/upload.bin',blob,predicate=lambda d:(ROOT/'upload.bin').read_bytes()==blob)
    adopt=ROOT/'compose.yaml'; adopt.write_text(yaml)
    test('POST','/docker/compose/adopt',{'name':'adopted','config_files':[str(adopt)]},201,lambda d:d['adopted'] and d['managed'])
    slug='/store/apps/nginx'; template='/store/apps/:slug'
    for method,suffix in [('GET',''),('POST','/deploy'),('POST','/stop'),('POST','/start'),('GET','/logs'),('DELETE','')]:
        test(method,slug+suffix,route=template+suffix,predicate=lambda d:d['app']['slug']=='nginx' if 'app' in d else d['ok'])
    for suffix in ('/host/swap','/host/swap-device','/ssh/config','/waf/config','/fail2ban/config'):
        reject('POST',suffix,suffix,400,'bad_request',{})
    for suffix in ('ban','unban'):
        path='/fail2ban/'+suffix; reject('POST',path,path,400,'bad_request',{'jail':'sshd'})
    for method,route,path,status,code,body in [
        ('POST','/sites','/sites',400,'bad_name',{'name':''}),
        ('POST','/cron','/cron',400,'bad_schedule',{'schedule':'hourly','command':'true'}),
        ('POST','/cron/delete','/cron/delete',400,'bad_id',{'id':''}),
        ('POST','/firewall/rules','/firewall/rules',400,'bad_port',{'port':'abc'}),
        ('POST','/firewall/rules/delete','/firewall/rules/delete',400,'bad_id',{'id':''}),
        ('POST','/services/:name/:action','/services/fixture.service/unknown',400,'bad_action',None),
        ('PUT','/services/:name/config','/services/fixture.service/config',400,'bad_request',{}),
        ('GET','/runtimes/catalog/:runtime/tags','/runtimes/catalog/missing/tags',404,'not_found',None),
        ('POST','/software/:id/initialize','/software/missing/initialize',404,'unknown_software',None),
        ('POST','/store/packages/custom','/store/packages/custom',400,'bad_request',{}),
        ('POST','/store/packages/:id/install','/store/packages/missing/install',404,'unknown_tool',None),
    ]: reject(method,route,path,status,code,body)
    for method,suffix,body in [('GET','',None),('DELETE','',None),('POST','/toggle',{'enabled':False}),('POST','/certificate',None),('POST','/basic-auth',{'users':[]}),('GET','/logs',None)]:
        reject(method,'/sites/:name'+suffix,'/sites/missing'+suffix,404,'not_found',body)
    reject('POST','/waf/start','/waf/start',409,'not_installed')
    test('POST','/waf/stop',predicate=lambda d:d['ok'])
    for suffix in ('build','run'):
        test('POST','/store/nix/'+suffix,{'target':'hello'},502,lambda d:not d['ok'] and 'fake dependency unavailable' in d['output'],scenario='dependency-failure')
    import io, tarfile
    archive=io.BytesIO()
    with tarfile.open(fileobj=archive,mode='w') as tar:
        data=b'FROM scratch\n'; info=tarfile.TarInfo('Dockerfile'); info.size=len(data); tar.addfile(info,io.BytesIO(data))
    await_job(test('POST','/docker/images/import',archive.getvalue(),202))
    await_job(test('POST','/docker/images/build/upload?tag=fixture:uploaded',archive.getvalue(),202))
    test('DELETE','/update/schedule',predicate=lambda d:d['ok'] and not d['scheduled'])
    reject('PUT','/docker/settings','/docker/settings',501,'unsupported',{'restart':False,'experimental':True})
    reject('POST','/docker/restart','/docker/restart',501,'unsupported')
    test('POST','/store/packages/refresh',expected=502,predicate=lambda d:not d['ok'],scenario='dependency-failure')
    reject('GET','/services','/services',502,'services_failed')
    reject('GET','/services/:name/config','/services/fixture.service/config',404,'not_found')
    reject('GET','/services/:name/logs','/services/fixture.service/logs',502,'logs_failed')
    test('GET','/firewall',predicate=lambda d:'rules' in d)
    test('GET','/cron',predicate=lambda d:d['entries']==[])
    reject('PUT','/sites/:name','/sites/missing',404,'not_found',{})
    reject('POST','/ssh/logging','/ssh/logging',400,'bad_request',{})
    reject('GET','/ssh/logs','/ssh/logs?source=absent',400,'bad_input')
    test('POST','/docker/containers/fixture/recreate',{'name':'fixture','image':'alpine:latest'},route='/docker/containers/:id/recreate',predicate=lambda d:d['ok'])
    def container_file(method,suffix,body=None,predicate=lambda d:d['ok']):
        return test(method,'/docker/containers/fixture/files'+suffix,body,predicate=predicate,route='/docker/containers/:id/files'+suffix.split('?')[0])
    container_file('POST','/mkdir',{'path':'/sample'})
    container_file('PUT','/content',{'path':'/sample/a','content':'alpha'})
    container_file('GET','?path=/sample',predicate=lambda d:any(e['name']=='a' for e in d['entries']))
    container_file('GET','/content?path=/sample/a',predicate=lambda d:d['content']=='alpha')
    container_file('POST','/rename',{'from':'/sample/a','to':'/sample/b'})
    container_file('POST','/upload?path=/sample/b',blob)
    container_file('GET','/download?path=/sample/b',predicate=lambda d:d['raw_hex']==blob.hex())
    container_file('POST','/delete',{'paths':['/sample/b']},lambda d:d['results'][0]['ok'])
    container_file('GET','?path=/sample',predicate=lambda d:not d['entries'])
    # A real TLS + RFC6455 handshake (not a parameter-validation substitute).
    import socket, base64, hashlib
    for route,path in [('/api/v1/terminal/ws','/api/v1/terminal/ws'),('/api/v1/docker/containers/:id/terminal/ws','/api/v1/docker/containers/fixture/terminal/ws')]:
        try:
            with ctx.wrap_socket(socket.create_connection((config['listen'],18443),timeout=10),server_hostname=config['listen']) as ws:
                key=base64.b64encode(os.urandom(16)).decode()
                ws.sendall(('GET /regression'+path+' HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: '+key+'\r\n\r\n').encode())
                response=b''
                while b'\r\n\r\n' not in response:
                    chunk=ws.recv(4096)
                    if not chunk: break
                    response+=chunk
                accept=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
                ok=b' 101 ' in response.split(b'\r\n')[0] and accept in response
                results.append(dict(method='GET',route=route,scenario='websocket-handshake',passed=ok,response=response.decode(errors='replace')))
                if ok: ws.sendall(b'\x88\x80\x00\x00\x00\x00')
        except Exception as e:
            results.append(dict(method='GET',route=route,scenario='websocket-handshake',passed=False,error=str(e)))
    test('GET','/waf/geo/catalog',expected=502,scenario='dependency-failure')
    (ROOT/'fake-fail').touch()
    for suffix in ('/docker/networks','/docker/volumes','/docker/overview'):
        test('GET',suffix,expected=502,scenario='dependency-failure')
    (ROOT/'fake-fail').unlink()
finally:
    p.terminate()
    try: p.wait(timeout=10)
    except subprocess.TimeoutExpired: p.kill(); p.wait()
    log.close()
    (OUT/'results.json').write_text(json.dumps(results,indent=2,ensure_ascii=False))
    matrix=[dict(method=m,route=r,tests=[x for x in results if x['method']==m and x['route']==r],missing_scenarios=[s for s in ['success','invalid','missing','dependency-failure','websocket-handshake'] if (s!='websocket-handshake' or r.endswith('/ws')) and not any(x['method']==m and x['route']==r and x['scenario']==s for x in results)]) for m,r in routes]
    (OUT/'matrix.json').write_text(json.dumps(matrix,indent=2,ensure_ascii=False))
    print(json.dumps(dict(routes=len(routes),passed=sum(x['passed'] for x in results),failed=sum(not x['passed'] for x in results),uncovered_routes=sum(not x['tests'] for x in matrix))))
raise SystemExit(int(any(not x['passed'] for x in results) or any(not row['tests'] for row in matrix)))
