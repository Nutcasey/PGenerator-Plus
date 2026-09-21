#!/usr/bin/env python3
"""Host-side SDR 2.3% experiment. Requires Python 3.12, Perl, SSH and an idle Pi.

Reuses production target, Delta E ITP and correction-gain math. Each LUT write
ends calibration before measuring. Only rows between the 2% and 2.7% anchors
can change; all other table values are checked against the saved snapshot.
"""
import argparse
import datetime
import hashlib
import json
import math
from pathlib import Path
import selectors
import shlex
import signal
import subprocess
import time
import urllib.request

HERE = Path(__file__).resolve().parent
ACTIVE = {'starting', 'running', 'completing', 'stopping', 'paused', 'interrupted', 'cleanup_failed'}
SIGNAL_KEYS = ('max_bpc', 'color_format', 'rgb_quant_range', 'mode_idx', 'eotf', 'is_sdr', 'is_hdr', 'dv_status')
# Code 84 addresses native table row 21. Its neighbouring calibrated anchors
# are code 82 / row 19 and code 88 / row 26; these are fixed boundaries.
# Table outputs use 15 bits, independently of the 10-bit HDMI input codes.
LOW, NODE, HIGH = 19, 21, 26
LOCK = '/tmp/meter_diagnostic_read.lock'


class ApiRejected(RuntimeError):
    """An explicit API error, distinct from an ambiguous transport failure."""


def validate_curve(curve):
    # LG stores complete channels consecutively, rather than interleaved RGB.
    # Reject floats instead of silently quantizing a malformed source snapshot.
    # Only the edited region must be monotone; the rest stays byte-for-byte.
    if len(curve) != 3072 or any(type(v) is not int or not 0 <= v <= 32767 for v in curve):
        raise ValueError('Expected a 3072-value 15-bit RGB correction curve')
    for ch in range(3):
        values = curve[ch*1024+LOW:ch*1024+HIGH+1]
        if any(a > b for a, b in zip(values, values[1:])):
            raise ValueError('Saved shadow region is not monotone')


def localized_curve(baseline, current, moves):
    """Triangular change bounded by two fixed neighbouring calibrated anchors."""
    result = list(current)
    # Avoid the production full-curve spline fitter in this isolated experiment.
    # Its global interpolation could alter previously calibrated anchors.
    # Taper the local change and clamp against the two unchanged boundaries.
    for ch, move in enumerate(moves):
        base = ch*1024
        for row in range(LOW+1, HIGH):
            weight = (row-LOW)/(NODE-LOW) if row <= NODE else (HIGH-row)/(HIGH-NODE)
            result[base+row] = round(current[base+row]+move*weight)
        for row in range(LOW+1, HIGH):
            result[base+row] = max(result[base+row-1], min(result[base+HIGH], result[base+row]))
    assert_preserved(baseline, result)
    validate_curve(result)
    return result


def assert_preserved(baseline, curve):
    if len(curve) != 3072 or any(a != b for i, (a,b) in enumerate(zip(baseline,curve))
                                 if not LOW < i % 1024 < HIGH):
        raise ValueError('An update changed a protected table entry')


def mean_xyz(samples):
    # Average linear physical measurements before applying the nonlinear metric.
    # Averaging Delta E values would describe a different quantity.
    if not samples:
        raise ValueError('No samples')
    return {key: sum(float(s[key]) for s in samples)/len(samples) for key in ('X','Y','Z')}


def production_math(code, reading, white, gamma, black=0):
    # Keep the experimental optimizer separate from target/metric definitions.
    # The Perl adapter imports the deployed worker's numerical implementation.
    request = dict(code=code, reading=reading, white=white, gamma=gamma, black=black)
    result = subprocess.run(['perl', str(HERE/'sdr_patch_math.pl')], input=json.dumps(request),
                            text=True, capture_output=True, check=True, timeout=20)
    value = json.loads(result.stdout)
    if not isinstance(value.get('delta_e'), (float,int)) or not math.isfinite(value['delta_e']):
        raise ValueError('Production math did not return a finite delta E')
    return value


class Harness:
    def __init__(self, args):
        self.args = args
        self.snapshot = json.loads(args.snapshot.read_text())
        self.baseline = self.snapshot['sdr_1d_dpg_data']
        validate_curve(self.baseline)
        if self.snapshot.get('status') != 'complete' or not self.snapshot.get('final_1d_lut_upload_verified'):
            raise ValueError('A completed, verified SDR snapshot is required')
        if self.snapshot.get('signal_mode') != 'sdr':
            raise ValueError('Only SDR snapshots are supported')
        self.mode = self.snapshot['picture_mode']
        self.gamma = self.snapshot['target_gamma']
        self.tv_input = self.snapshot.get('tv_input')
        # The source input must come from the archived run, not today's TV state.
        # Otherwise a context mismatch could silently overwrite another preset.
        if self.tv_input not in ('hdmi1','hdmi2','hdmi3','hdmi4'):
            raise ValueError('Snapshot must record its original HDMI input')
        self.run = 'shadow-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%d-%H%M%S')
        self.out = args.output/self.run
        self.out.mkdir(parents=True, exist_ok=False)
        self.started = time.monotonic()
        self.number = 0
        self.owner = None
        self.claimed = False
        self.meter_owned = False
        self.meter_uncertain = False
        self.protection_pending = False
        self.stop_requested = False
        self.current = list(self.baseline)
        self.ssh = ['ssh','-i',str(args.key.expanduser()),'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',
                    '-o','ConnectTimeout=10','root@'+args.host]
        self.save('baseline.json', self.snapshot)

    def save(self, name, value):
        (self.out/name).write_text(json.dumps(value,indent=2)+'\n')

    def event(self, event, **fields):
        # Wall time correlates appliance logs; monotonic time measures waits.
        # Physical readings live in the artifact, while stdout stays concise.
        record = dict(utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                      elapsed_s=round(time.monotonic()-self.started,3),run=self.run,
                      stage=getattr(self,'stage','preflight'),event=event,**fields)
        with (self.out/'events.jsonl').open('a') as stream:
            stream.write(json.dumps(record,sort_keys=True)+'\n')

    def api(self, path, payload=None, timeout=100):
        data = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request('http://'+self.args.host+path,data=data,
                                         headers={'Content-Type':'application/json'})
        with urllib.request.urlopen(request,timeout=timeout) as response:
            result = json.load(response)
        if result.get('status') == 'error':
            raise ApiRejected(path+': '+result.get('message','error'))
        return result

    def remote(self, source):
        return subprocess.check_output(self.ssh+['python3 -c '+shlex.quote(source)],text=True,timeout=25).strip()

    def idle(self):
        # A completed worker alone is insufficient: its enclosing automation
        # may still be saving settings or restoring panel protection.
        activity = self.api('/api/automation/runs/current',timeout=20)
        run = activity.get('run') or {}
        if activity.get('execution') or run.get('status') in ACTIVE or run.get('cleanup_required'):
            raise RuntimeError('Automation still owns the setup')
        for path in ('/api/meter/lg-autocal/status','/api/meter/lg-3d-autocal/status','/api/meter/series/status'):
            if self.api(path,timeout=20).get('status') in ACTIVE:
                raise RuntimeError('A calibration or measurement is still active')
        status = self.api('/api/lg/status',timeout=20)
        if status.get('calibration_mode') is not False:
            raise RuntimeError('Calibration exit is not confirmed')
        return status

    def context(self):
        # Ask for the live input and picture mode together. /api/lg/status does
        # not expose the input, and cached calibration mode names are unsuitable.
        self.idle()
        response=self.api('/api/lg/picture-settings',dict(keys=['pictureMode'],include_current_input=True,
                          ignore_calibration_picture_mode=True),timeout=90)
        if response.get('current_input') != self.tv_input:
            raise RuntimeError('TV input changed during diagnostic')
        config = self.api('/api/config',timeout=20)
        actual = {key:config.get(key) for key in SIGNAL_KEYS}
        if actual != self.signal:
            raise RuntimeError('Signal changed during diagnostic')
        settings = response.get('picture_settings') or {}
        if settings.get('pictureMode') != self.mode:
            raise RuntimeError('TV picture mode changed')

    def meter_free(self):
        state=self.api('/api/meter/read/result',timeout=20)
        if state.get('status') in {'starting','measuring','running','awaiting_ready','setup','setup_busy'} or state.get('awaiting_ready'):
            raise RuntimeError('Another meter request is active')
        # A ready session may be idle between reads but still owns the USB meter.
        source="""import os,subprocess
p='/tmp/meter_session.pid'
alive=False
if os.path.exists(p):
 try:os.kill(int(open(p).read().strip()),0);alive=True
 except (OSError,ValueError):pass
print('busy' if alive or any(subprocess.call(['pgrep','-x',name],stdout=subprocess.DEVNULL)==0 for name in ('spotread','spotread_sim')) else 'free')"""
        if self.remote(source) != 'free':
            raise RuntimeError('An existing meter session owns the instrument')

    def acquire(self):
        # Holding the same flock as automation start prevents a concurrent queue
        # launch. The persistent diagnostic file separately owns meter requests.
        # The controller must acknowledge READY before it can make TV changes.
        # Without that acknowledgement the remote helper releases both locks.
        # After acknowledgement, losing SSH must retain ownership for cleanup.
        source = '''import fcntl,os,select,signal,sys,time
signal.signal(signal.SIGHUP,signal.SIG_IGN)
f=open('/var/lib/PGenerator/automation/execution.lock','a')
fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
p=%r; token=%r
fd=os.open(p,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o644)
os.write(fd,token.encode()); os.close(fd)
        print('READY '+str(os.getpid()));sys.stdout.flush()
if not select.select([sys.stdin],[],[],30)[0] or sys.stdin.readline().strip()!='claim':
 if open(p).read()==token:os.unlink(p)
 sys.exit(1)
for line in sys.stdin:
 if line.strip()=='release' and open(p).read()==token:
  os.unlink(p);sys.exit(0)
# Cleanup failed or the controller disconnected: keep ownership for recovery.
while os.path.exists(p):time.sleep(5)
''' % (LOCK,self.run)
        self.owner = subprocess.Popen(self.ssh+['python3 -u -c '+shlex.quote(source)],
                                      stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        # The SSH connection itself has a bounded connect timeout.
        selector=selectors.DefaultSelector()
        selector.register(self.owner.stdout,selectors.EVENT_READ)
        if not selector.select(20):
            self.owner.terminate()
            raise RuntimeError('Diagnostic ownership acquisition timed out')
        selector.close()
        ready = self.owner.stdout.readline().strip()
        if not ready.startswith('READY '):
            raise RuntimeError('Could not acquire diagnostic ownership: '+self.owner.stderr.read())
        self.claimed = True
        self.owner.stdin.write('claim\n');self.owner.stdin.flush()
        self.event('ownership_acquired',remote_pid=int(ready.split()[1]))

    def guard(self):
        # These checks bound experimental work, never the mandatory cleanup.
        # The signal handler sets a flag so cleanup still runs on Ctrl-C.
        if self.stop_requested:
            raise RuntimeError('Stop requested')
        if time.monotonic()-self.started > self.args.minutes*60:
            raise RuntimeError('Experiment time budget reached')
        if self.owner is None or self.owner.poll() is not None:
            raise RuntimeError('Diagnostic ownership connection was lost')

    def condition(self):
        # The same 25% legal-range window precedes every physical sample.
        # A fixed history reduces sensitivity to the previous patch's luminance.
        self.guard()
        self.api('/api/pattern',dict(name='patch',r=283,g=283,b=283,input_max=1023,size=10,
                                   signal_mode='sdr',signal_range='1',transport_signal_range='1'))
        time.sleep(5)

    def measure_one(self, code):
        # The appliance deliberately closes a failed USB session and asks its
        # caller to retry. Bound clean restarts; never turn a failure into data.
        for attempt in range(3):
            try:
                return self._measure_one(code)
            except ApiRejected as exc:
                if 'meter session closed for clean retry' not in str(exc).lower() or attempt==2:
                    raise
                self.event('meter_retry',code=code,attempt=attempt+1,reason=str(exc))
                print('Meter communication failed; restarting session for retry {}/2'.format(attempt+1),flush=True)
                stopped=self.api('/api/meter/session/stop',{},timeout=30)
                if stopped.get('status')!='ok':raise RuntimeError('Meter retry cleanup failed')
                self.meter_owned=False
                self.meter_free()
                self.condition()

    def _measure_one(self, code):
        self.guard()
        self.number += 1
        request_id = self.run+'-'+str(self.number)
        # This is one physical read. Multi-sample averaging happens locally,
        # where individual measurements remain available for noise assessment.
        payload = dict(display_type=self.meter['display_type'],ccss_override=self.meter['ccss_override'],
                       measurement_meter_port='1',measurement_meter_usb_id='0765:5020',observer='1931_2',
                       refresh_rate=self.meter.get('refresh_rate',''),pattern_provider='local',
                       patch_r=code,patch_g=code,patch_b=code,patch_input_max=1023,patch_size=10,
                       delay_ms=1800,read_timeout=90,signal_mode='sdr',signal_range='1',transport_signal_range='1',
                       patch_ire=(code-64)/959*109,patch_name='shadow_test_'+str(code),request_id=request_id,
                       low_light={'enabled':False,'mode':'off'},requested_sample_count=1)
        self.event('measurement_requested',operation=request_id,code=code)
        try:
            accepted = self.api('/api/meter/read',payload)
        except ApiRejected:
            raise
        except Exception:
            # A transport error cannot establish whether the server started.
            # Preserve this uncertainty for cleanup instead of guessing ownership.
            self.meter_uncertain=True
            raise
        if accepted.get('status') != 'measuring':
            self.meter_uncertain=True
            raise RuntimeError('Meter did not accept measurement')
        self.meter_owned=True
        self.meter_uncertain=False
        deadline = time.monotonic()+120
        while time.monotonic() < deadline:
            self.guard()
            result = self.api('/api/meter/read/result',timeout=15)
            if result.get('status') in ('ok','complete') and result.get('request_id') == request_id:
                # The result endpoint is shared and may retain an older reading.
                # Both the request identifier and emitted codes must match.
                rows=result.get('readings') or []
                if len(rows)!=1:
                    raise RuntimeError('Expected one physical meter sample')
                row=rows[0]
                if row.get('request_id') != request_id or row.get('sample_count')!=1 or (row.get('synthetic_black') and code!=64) or any(row.get(k)!=code for k in ('r_code','g_code','b_code')):
                    raise RuntimeError('Measurement provenance mismatch')
                if row.get('synthetic_black'):
                    # The appliance labels its normalized true-black display
                    # value synthetic. Retain the instrument's raw XYZ instead.
                    if not all('raw_'+k in row for k in ('X','Y','Z')):
                        raise RuntimeError('True-black reading has no physical XYZ')
                    row={**row,**{k:row['raw_'+k] for k in ('X','Y','Z')}}
                if not all(math.isfinite(float(row[k])) for k in ('X','Y','Z')) or (code>64 and row['Y']<=0):
                    raise RuntimeError('Unusable meter measurement')
                self.event('measured',operation=request_id,code=code,reading=row)
                return row
            if result.get('awaiting_ready') or result.get('status')=='setup':
                raise RuntimeError('Meter requires physical setup')
            time.sleep(.4)
        raise RuntimeError('Meter measurement deadline exceeded')

    def measure(self, code, count=3):
        samples=[]
        for _ in range(count):
            self.condition()
            samples.append(self.measure_one(code))
        reading=mean_xyz(samples)
        result=production_math(code,reading,self.white,self.gamma,self.black)
        individual=[production_math(code,s,self.white,self.gamma,self.black)['delta_e'] for s in samples]
        result.update(reading=reading,individual_delta_e=individual,code=code,sample_count=count)
        self.event('batch_measured',**result)
        print('{} code={} dE={:.4f} Y={:.7f}; samples={}'.format(self.stage,code,result['delta_e'],reading['Y'],
                                                              ','.join('{:.3f}'.format(x) for x in individual)),flush=True)
        return result

    def upload(self, curve, label):
        # The helper owns CAL_START and CAL_END on the same TV connection.
        # Its acknowledgement proves acceptance, not a readback of every value.
        # Subsequent optical measurements establish the installed curve's effect.
        self.guard()
        self.context()
        assert_preserved(self.baseline,curve)
        validate_curve(curve)
        self.save(label+'-curve.json',curve)
        self.event('lut_requested',label=label,sha256=hashlib.sha256(json.dumps(curve).encode()).hexdigest(),
                   target_codes=[curve[ch*1024+NODE] for ch in range(3)])
        result=self.api('/api/lg/1d-dpg/upload',dict(picture_mode=self.mode,signal_mode='sdr',ddc_layout='sdr26',
                      tv_input=self.tv_input,expected_tv_input=self.tv_input,dpg_data=curve,helper_timeout=75,
                      keep_calibration_mode=False,calibration_mode_active=False),timeout=100)
        self.event('lut_response',label=label,status=result.get('status'),uploaded=result.get('dpg_uploaded'),
                   calibration_mode=result.get('calibration_mode'),message=result.get('message'))
        if result.get('status')!='ok' or not result.get('dpg_uploaded') or result.get('calibration_mode') is not False:
            raise RuntimeError('LUT write or calibration exit was not confirmed')
        self.current=list(curve)
        time.sleep(3)
        self.idle()

    def execute(self):
        self.idle()
        self.meter_free()
        self.acquire()
        self.idle()
        self.meter_free()
        meter_status=self.api('/api/meter/status',timeout=90)
        if meter_status.get('simulated') or str(meter_status.get('port_num',meter_status.get('port')))!='1' or meter_status.get('usb_id')!='0765:5020':
            raise RuntimeError('The expected physical i1Display Pro Plus is not selected')
        config=self.api('/api/config')
        self.signal={key:config.get(key) for key in SIGNAL_KEYS}
        if any(str(config.get(key)) != value for key,value in {'max_bpc':'10','color_format':'1','rgb_quant_range':'1','is_sdr':'1'}.items()):
            raise RuntimeError('This harness requires SDR limited YCbCr 4:4:4 10-bit')
        self.context()
        self.meter=self.api('/api/meter/settings')
        if 'settings' in self.meter:self.meter=self.meter['settings']
        if not self.meter.get('ccss_override') or not self.meter.get('display_type'):
            raise RuntimeError('Meter correction/settings unavailable')
        self.event('preflight',picture_mode=self.mode,tv_input=self.tv_input,signal=self.signal,
                   target_delta_e=self.args.target,formula='deitp',gamma=self.gamma,protected_rows=[LOW,HIGH],
                   renderer_expected=self.args.renderer_sha)
        actual=self.remote("import hashlib;print(hashlib.sha256(open('/usr/sbin/PGeneratord','rb').read()).hexdigest())")
        if actual != self.args.renderer_sha:raise RuntimeError('Unexpected renderer build')
        # Record the restoration obligation before any request can reach the TV.
        self.protection_pending=True
        self.save('cleanup.json',{'panel_protection_restore_pending':True})
        result=self.api('/api/lg/panel-protection',{'enable':False,'picture_mode':self.mode,'signal_mode':'sdr','tv_input':self.tv_input})
        if result.get('status')!='ok':raise RuntimeError('Panel protection disable was not accepted')
        self.event('panel_protection_disable_accepted',verification='sent-unverified')
        self.stage='baseline'
        self.upload(self.baseline,'baseline')
        self.condition()
        black=self.measure_one(64)
        self.black=black['Y']
        # The worker's /109 normalization uses peak code 1023 as its reference.
        # Legal 100% white at code 940 would require a different normalization.
        # Fix this fresh reference for the whole experiment; do not move targets
        # in response to a candidate's own measurement error.
        whites=[]
        for _ in range(2):
            self.condition();whites.append(self.measure_one(1023))
        self.white=mean_xyz(whites)['Y']
        if self.white<=0:raise RuntimeError('Invalid white reference')
        saved_white=self.snapshot.get('sdr_1d_dpg_white_ref',0)
        if not saved_white or abs(self.white/saved_white-1)>.05:
            raise RuntimeError('White reference differs from the snapshot by more than 5%; investigate context before adjusting')
        self.event('reference_measured',white_y=self.white,black_y=self.black,snapshot_white_y=self.snapshot.get('sdr_1d_dpg_white_ref'))
        self.before={code:self.measure(code,2) for code in (82,88,92)}
        best=None
        best_curve=list(self.current)
        scaling=0.7
        holdouts=[]
        for iteration in range(self.args.iterations):
            self.stage='optimize-'+str(iteration+1)
            observed=self.measure(84,3)
            if best is None or observed['delta_e'] < best['delta_e']:
                best=observed;best_curve=list(self.current)
                self.save('best.json',dict(measurement=best,curve=best_curve))
            if observed['delta_e'] < self.args.target:
                # Crossing the threshold during optimization only nominates a
                # candidate. Fresh batches decide whether it can be accepted.
                self.stage='independent-verification'
                holdouts=[self.measure(84,3),self.measure(84,3)]
                if all(x['delta_e'] < self.args.target for x in holdouts):
                    best_curve=list(self.current)
                    break
                observed=max(holdouts,key=lambda x:x['delta_e'])
            if iteration+1 == self.args.iterations:break
            if observed['delta_e'] > best['delta_e']*1.1 and self.current != best_curve:
                scaling=max(.15,scaling*.5)
                self.upload(best_curve,'restore-'+str(iteration+1))
                observed=best
            moves=[]
            # Approximate the local panel response with a damped gamma update.
            # Bound each channel move; optical feedback determines whether the
            # approximation helped, and worse candidates reduce the step size.
            for ch,gain in enumerate(observed['gains']):
                value=self.current[ch*1024+NODE]
                delta=round(value*(gain**(1/2.2)-1)*scaling)
                moves.append(max(-40,min(40,delta)))
            if not any(moves):
                self.event('integer_resolution_reached');break
            candidate=localized_curve(self.baseline,self.current,moves)
            if candidate==self.current:break
            self.upload(candidate,'iteration-'+str(iteration+1))
        self.stage='final-verification'
        if self.current!=best_curve:self.upload(best_curve,'best-final')
        # Holdouts must describe the installed curve, not an earlier candidate.
        verification=[self.measure(84,3),self.measure(84,3)]
        after={code:self.measure(code,2) for code in (82,88,92)}
        guard_ok=all(after[c]['delta_e'] <= self.before[c]['delta_e']+.3 and
                     abs(after[c]['reading']['Y']/self.before[c]['reading']['Y']-1) <= .05 for c in after)
        passed=all(x['delta_e']<self.args.target for x in verification) and guard_ok
        # Record actual averages and individual errors even when the test fails.
        # An optimization minimum alone must never be reported as a pass.
        report=dict(passed=passed,target_delta_e=self.args.target,best_optimization=best,verification=verification,
                    neighbours_before=self.before,neighbours_after=after,neighbours_passed=guard_ok,
                    curve=self.current,white_y=self.white,black_y=self.black,
                    scope='2.3% with saved rest-of-curve; committed-state optical measurements')
        self.save('result.json',report)
        print('RESULT '+json.dumps({k:report[k] for k in ('passed','target_delta_e','neighbours_passed')}),flush=True)
        return passed

    def cleanup(self):
        self.stage='cleanup'
        if not self.claimed:return
        failures=[]
        # Cleanup must remain available after the experiment budget or Ctrl-C.
        # Leave the current correction curve, signal and picture mode in place.
        # TPC/GSR restoration is acknowledged, not independently readable here.
        for path,payload in ([('/api/meter/session/stop',{})] if self.meter_owned else []):
            try:
                result=self.api(path,payload,timeout=30)
                if result.get('status')!='ok':raise RuntimeError('Stop rejected')
                self.meter_uncertain=False
            except Exception as exc:failures.append(str(exc))
        if self.meter_uncertain:
            failures.append('Meter request acceptance is unknown; retain ownership for recovery')
        try:
            status=self.api('/api/lg/status')
            if status.get('calibration_mode') is not False:
                raise RuntimeError('Calibration exit unconfirmed; do not send a blind second CAL_END')
        except Exception as exc:failures.append(str(exc))
        # Restoration and meter release are independent cleanup obligations.
        # A failed status read must not leave panel protection disabled.
        try:
            if self.protection_pending:
                result=self.api('/api/lg/panel-protection',{'enable':True},timeout=90)
                if result.get('status')!='ok':raise RuntimeError('Panel protection restoration rejected')
                self.protection_pending=False
                self.event('panel_protection_restore_accepted',verification='sent-unverified')
        except Exception as exc:failures.append(str(exc))
        try:
            if self.remote("import subprocess;print(0 if any(subprocess.call(['pgrep','-x',name],stdout=subprocess.DEVNULL)==0 for name in ('spotread','spotread_sim')) else 1)")!='1':
                raise RuntimeError('Meter process remains')
            self.api('/api/pattern',{'name':'stop','only_if_unowned':True,'signal_mode':'sdr','signal_range':'1','transport_signal_range':'1'})
        except Exception as exc:failures.append(str(exc))
        self.save('cleanup.json',{'failures':failures,'panel_protection_restore_pending':self.protection_pending})
        if failures:
            self.event('cleanup_failed',failures=failures,ownership_retained=True)
            self.owner.stdin.close()
            raise RuntimeError('Cleanup failed; diagnostic ownership retained: '+'; '.join(failures))
        self.owner.stdin.write('release\n');self.owner.stdin.flush()
        self.owner.wait(timeout=15)
        self.claimed=False
        self.event('cleanup_complete',meter_released=True,calibration_mode=False)
        print('Cleanup complete; current signal and picture mode retained',flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host',required=True)
    parser.add_argument('--snapshot',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--key',type=Path,default=Path('~/.ssh/id_ed25519_pgenerator'))
    parser.add_argument('--renderer-sha',required=True)
    parser.add_argument('--target',type=float,default=.2)
    parser.add_argument('--iterations',type=int,default=12)
    parser.add_argument('--minutes',type=float,default=25)
    args=parser.parse_args()
    if not 0<args.target<=.2 or not 1<=args.iterations<=20 or not 1<=args.minutes<=60:
        parser.error('Require 0 < target <= .2, 1..20 iterations and 1..60 minutes')
    harness=Harness(args)
    for sig in (signal.SIGINT,signal.SIGTERM):
        signal.signal(sig,lambda *_:setattr(harness,'stop_requested',True))
    passed=False
    try:
        passed=harness.execute()
    except Exception as exc:
        harness.event('failed',message=str(exc))
        harness.save('failure.json',dict(passed=False,message=str(exc),stage=getattr(harness,'stage','preflight'),
                                        installed_curve=harness.current))
        print('FAILED: '+str(exc),flush=True)
    finally:
        harness.cleanup()
    return 0 if passed else 1


if __name__=='__main__':
    raise SystemExit(main())
