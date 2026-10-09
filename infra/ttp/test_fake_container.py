"""Real local Docker boundary; owns and removes only its generated test container."""
import json
import os
import secrets
import subprocess
import uuid

name = 'ttp-qscen-' + uuid.uuid4().hex[:12]
image = os.environ.get('TTP_TEST_IMAGE', 'ttp-fake:qscen-local')
token = 'synthetic_' + secrets.token_hex(32)
env = {**os.environ, 'INCLUIR_PRINT_SERVICE_TOKEN': token}


def docker(*args, stdin=None):
    result = subprocess.run(['docker', *args], input=stdin, capture_output=True,
                            text=True, env=env, timeout=60)
    # Error output is not surfaced blindly: docker inspect/env/logs can hold tokens.
    if result.returncode:
        raise RuntimeError('docker command failed: ' + args[0] + ', exit=' + str(result.returncode))
    return result.stdout


try:
    docker('run', '-d', '--rm', '--name', name, '--memory=256m', '--cpus=.5',
           '--pids-limit=64', '--read-only', '--cap-drop=ALL',
           '--security-opt=no-new-privileges', '--env', 'INCLUIR_PRINT_SERVICE_TOKEN', image)
    output = docker('exec', '-i', name, 'node', '--input-type=module', stdin=r'''
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
const service='http://127.0.0.1:4001', admin='http://127.0.0.1:4002';
let ready=false;
for(let i=0;i<100;i++) {try {ready=(await fetch(service+'/healthz')).ok;if(ready)break;}catch{}await new Promise(r=>setTimeout(r,50));}
assert.ok(ready);assert.equal(process.getuid(),10001);assert.equal(existsSync('/app/.git'),false);
const auth={Authorization:'Bearer '+process.env.INCLUIR_PRINT_SERVICE_TOKEN};
const post=async(path,value)=>{const r=await fetch(admin+path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(value)});assert.equal(r.status,200);return r.json();};
const initial=await (await fetch(admin+'/status')).json();
const original=await (await fetch(admin+'/manifest')).json();
assert.equal(original.source_sha,'270224676d61431c2d26a8e20ec911c328a1f5f3');
const prefix='/api/print-portal/v2';
const get=async path=>{const r=await fetch(service+prefix+path,{headers:auth});assert.equal(r.status,200);return r.json();};
let state=initial;
const seedHashes={};
for (const scenario of ['flow','cancel','empty-history']) {
  state=await post('/reset',{boot_id:state.boot_id,generation:state.generation,trial_id:'container-'+scenario,scenario});
  const stamp={boot_id:state.boot_id,generation:state.generation,trial_id:state.trial_id};
  seedHashes[scenario]=state.seed_sha256;
  await post('/start',stamp);
  const page=await get('/batches');assert.equal(page.items.length,1);
  const detail=(await get('/batches/'+page.items[0].id)).batch;
  for(const item of detail.items) {
    for(const file of [...item.jobs.map(j=>j.file),...(item.generalInstructions?.files??[])]) {
      const r=await fetch(service+prefix+'/batches/'+detail.id+'/orders/'+item.orderId+'/files/'+file.id,{headers:auth});
      assert.equal(r.status,200);const bytes=Buffer.from(await r.arrayBuffer());
      assert.equal(bytes.length,file.bytes);assert.equal(createHash('sha256').update(bytes).digest('hex'),file.sha256);
    }
  }
  if(scenario==='cancel') {
    await post('/checkpoint',{...stamp,event:'cancel'});
    assert.deepEqual((await (await fetch(admin+'/manifest')).json()).checkpoints,['cancel']);
    const next=(await get('/batches/open')).batch;
    assert.equal(next.items.length,2);assert.equal(next.items[0].previouslyCancelledIn,'LOT-0001');
  }
  if(scenario==='empty-history') {
    assert.equal((await get('/batches/open')).batch,null);
    assert.equal((await get('/monthly-closes/2026-09')).close.expectedTotalCents,46900);
  }
  state=await post('/finish',stamp);
}
const badOrigin=await fetch(admin+'/status',{headers:{Origin:'http://untrusted.test'}});assert.equal(badOrigin.status,403);
assert.equal((await fetch(service+'/__ttp/status')).status,404);
const v1=await fetch(service+'/api/print-portal/v1/orders',{headers:auth});assert.equal(v1.status,200);
assert.equal(v1.headers.get('X-TTP-Fixture-SHA256'),'9d1ab88ca294c4a446cce579e21a538e6a78f430b45770a71022c0a344093f6d');
console.log(JSON.stringify({source_sha:original.source_sha,bundle_sha256:original.bundle_sha256,scenarios:seedHashes,uid:process.getuid(),v1_unchanged:true}));
''')
    evidence = json.loads(output)
    assert docker('port', name).strip() == ''
    ip = docker('inspect', '--format', '{{.NetworkSettings.Networks.bridge.IPAddress}}', name).strip()
    # A second network namespace reaches service4001, but cannot reach loopback admin4002.
    docker('run', '--rm', '--entrypoint', 'node', image, '-e',
           "const ip=process.argv[1];fetch('http://'+ip+':4001/healthz').then(r=>{if(!r.ok)throw Error('service');return fetch('http://'+ip+':4002/status',{signal:AbortSignal.timeout(2000)}).then(()=>process.exit(1),()=>process.exit(0))}).catch(()=>process.exit(2))", ip)
    logs = docker('logs', name)
    assert token not in logs
    evidence.update({'admin_external_connection': 'refused', 'published_ports': [],
                     'image_id': docker('image', 'inspect', '--format', '{{.Id}}', image).strip()})
    print(json.dumps(evidence, sort_keys=True))
finally:
    subprocess.run(['docker', 'stop', '--time=5', name], capture_output=True, timeout=20)
