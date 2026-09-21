#!/usr/bin/perl
# Resume must tell "the TV is free" apart from "a rival owns the TV".
#
# The 21 Sep 2026 batch (20260921-132032-9a7b8e) hit a fatal AutoCal error in
# its SDR job. Failure cleanup ran to completion -- workers stopped, meter
# released, calibration exit confirmed -- and RELEASED the execution claim by
# deleting execution.json, but left the run status=interrupted (resumable).
# Resume then read the missing claim, saw ref($execution) ne 'HASH', and
# emitted the rival message "Another run owns the TV; this run cannot resume."
# No other run owned the TV; the claim was simply gone. Because cleanup deletes
# the claim while leaving the run resumable, the owner-check could never pass:
# a dead end by construction.
#
# The fix distinguishes an absent claim (re-acquire the free TV and resume)
# from a genuinely competing active run (keep blocking with the rival message),
# and re-acquires the claim atomically so two racing Resumes cannot both seize
# the single TV worker. These are the properties that keep that working.
use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
require "$Bin/../usr/share/PGenerator/webui.pm";

my $dir="$Bin/../usr/share/PGenerator";
ok(defined &main::webui_automation_resume_claim_decision,'the resume claim decision is a named sub');
ok(defined &main::webui_automation_reconnect_for_resume,'reconnect_for_resume is present');

# --- The pure ownership decision: absent and self are 'ok', a rival is 'rival'.
my $run={id=>'run-a',token=>'tok-a'};
is(&main::webui_automation_resume_claim_decision(undef,$run),'ok',
 'an absent claim (undef) is free to re-acquire, not a rival');
is(&main::webui_automation_resume_claim_decision({owner=>'automation',run_id=>'run-a',token=>'tok-a',status=>'starting'},$run),'ok',
 "a run's own active claim is ok to re-acquire");
is(&main::webui_automation_resume_claim_decision({owner=>'automation',run_id=>'run-b',token=>'tok-b',status=>'running'},$run),'rival',
 'a different active run is a rival');
is(&main::webui_automation_resume_claim_decision({owner=>'automation',run_id=>'run-b',token=>'tok-b',status=>'complete'},$run),'rival',
 'a foreign claim is a rival whatever its status -- only an absent claim is free');
is(&main::webui_automation_resume_claim_decision({owner=>'automation',run_id=>'run-b',token=>'tok-b'},$run),'rival',
 'a foreign claim with no status field still blocks (the preflight guarantee)');
is(&main::webui_automation_resume_claim_decision({owner=>'automation',run_id=>'run-a',token=>'tok-a',status=>'running'},{id=>'run-a'}),'rival',
 'a run without its token cannot claim ownership');

# --- reconnect_for_resume: an absent claim reconnects; a rival is turned away
#     before the TV is ever consulted.
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
PGAutomation::ensure_store();
my $execution_path=PGAutomation::base_dir().'/execution.json';
local *main::_log=sub {};
my $tv_calls=0;
local *main::webui_lg_status_json=sub { $tv_calls++; return '{"connected":1}'; };

unlink($execution_path);
$tv_calls=0;
my $free=&main::webui_automation_reconnect_for_resume({id=>'run-a',token=>'tok-a',status=>'interrupted'});
is($free->{status},'ok','a released claim lets the interrupted run reconnect to the free TV');
is($tv_calls,1,'and the TV was actually consulted for the free case');

PGAutomation::write_json_atomic($execution_path,{owner=>'automation',run_id=>'run-b',token=>'tok-b',status=>'running'});
$tv_calls=0;
my $blocked=&main::webui_automation_reconnect_for_resume({id=>'run-a',token=>'tok-a',status=>'interrupted'});
is($blocked->{error_code},'automation-owner-mismatch','a rival active claim is still refused');
like($blocked->{message},qr/Another run owns the TV/,'with the rival message');
is($tv_calls,0,'and a rival is turned away before the TV is consulted');

# --- webui_automation_control('resume'): the incident, the rival, and the
#     legitimate paused resume, end to end.
local *main::webui_automation_reap_dead_runner=sub { 0 };
local *main::webui_automation_cleanup_required=sub { 0 };  # its own suite covers detection
local *main::webui_automation_readiness_data=sub {{ready=>1}};
my $launches=0;
local *main::webui_automation_launch_runner=sub { $launches++; return 1; };

sub save_run {
 my ($id,%extra)=@_;
 make_path(PGAutomation::run_dir($id));
 PGAutomation::write_json_atomic(PGAutomation::run_dir($id).'/run.json',
  {id=>$id,token=>"tok-$id",status=>'interrupted',items=>[{name=>'SDR',status=>'queued'}],%extra});
}

# (a) The incident: interrupted, cleanup done, claim absent. Resume must NOT
#     report a rival, must re-acquire the free claim, and must launch.
save_run('inc');
unlink($execution_path);
$launches=0;
my $a=PGAutomation::decode_json(&main::webui_automation_control('inc','resume'));
isnt($a->{error_code}||'','automation-owner-mismatch','a released claim is not reported as a rival owner');
is($a->{status},'ok','the interrupted run resumes');
is($launches,1,'the resumed runner is launched');
my $claim=PGAutomation::read_json_file($execution_path);
is($claim->{run_id},'inc','the freed claim is re-acquired by the resuming run');
is($claim->{token},'tok-inc','with its own token');

# (b) A genuinely different active run owns the TV: still blocked, and its
#     claim is left untouched.
save_run('mine');
PGAutomation::write_json_atomic($execution_path,{owner=>'automation',run_id=>'other',token=>'tok-other',status=>'running'});
$launches=0;
my $b=PGAutomation::decode_json(&main::webui_automation_control('mine','resume'));
is($b->{error_code},'automation-owner-mismatch','a rival active claim still blocks Resume');
like($b->{message},qr/Another run owns the TV/,'with the rival message');
is($launches,0,'no runner is launched for a blocked resume');
is(PGAutomation::read_json_file($execution_path)->{run_id},'other','the rival claim is not overwritten');

# (b2) The race guard: reconnect saw a free TV, but a second Resume claimed it
#      before control_body took the lock. The atomic re-acquire must refuse to
#      overwrite the rival and leave this run recoverable.
{
 local *main::webui_automation_reconnect_for_resume=sub {{status=>'ok'}};  # reconnect passed on a then-free claim
 save_run('racer');
 PGAutomation::write_json_atomic($execution_path,{owner=>'automation',run_id=>'winner',token=>'tok-winner',status=>'starting'});
 $launches=0;
 my $race=PGAutomation::decode_json(&main::webui_automation_control('racer','resume'));
 is($race->{error_code},'automation-owner-mismatch','a claim taken during the race is not overwritten');
 is($launches,0,'and the losing resume launches no runner');
 is(PGAutomation::read_json_file($execution_path)->{run_id},'winner','the winner keeps the claim');
 is(PGAutomation::read_json_file(PGAutomation::run_dir('racer').'/run.json')->{status},'interrupted',
  'the losing run is left interrupted, still recoverable');
}

# (b3) If the run.json revert after a lost claim itself fails to write, the run
#      must not be silently stranded at status=starting. The caller is told the
#      state is uncertain and to Stop, not handed the clean rival message.
{
 local *main::webui_automation_reconnect_for_resume=sub {{status=>'ok'}};
 local *main::webui_automation_write_locked=sub {
  my ($path,$data)=@_;
  return (0,'simulated disk full') if(($data->{status}||'') ne 'starting');  # only the revert write fails
  return (1,'');
 };
 save_run('stuck');
 PGAutomation::write_json_atomic($execution_path,{owner=>'automation',run_id=>'winner2',token=>'tok-winner2',status=>'starting'});
 $launches=0;
 my $s=PGAutomation::decode_json(&main::webui_automation_control('stuck','resume'));
 is($s->{error_code},'resume-state-uncertain','a failed revert is reported as an uncertain state, not a clean rival');
 like($s->{message},qr/Stop/,'and the operator is steered to Stop rather than retrying Resume');
 is($launches,0,'no runner is launched when the claim was lost');
}

# (c) A legitimate paused resume whose own claim is intact still works.
save_run('pausd',status=>'paused');
PGAutomation::write_json_atomic($execution_path,{owner=>'automation',run_id=>'pausd',token=>'tok-pausd',status=>'paused'});
$launches=0;
my $c=PGAutomation::decode_json(&main::webui_automation_control('pausd','resume'));
is($c->{status},'ok','a paused run with its own claim resumes');
is($launches,1,'and its runner is launched');

# --- Load-bearing wiring: deleting a guard must turn this test red, so pin the
#     call sites the way t/idle_pattern_seed.t pins the seeder.
my $src=do { local $/; open(my $fh,'<',"$dir/webui.pm") or die $!; <$fh> };
my ($reconnect)=$src=~/sub webui_automation_reconnect_for_resume \(\@\) \{(.*?)\n\}/s;
like($reconnect,qr/webui_automation_resume_claim_decision/,
 'reconnect_for_resume routes its owner-check through the decision helper');
like($reconnect,qr/\beq\s*["\']rival["\']/,'and only turns a rival away');
my ($decision)=$src=~/sub webui_automation_resume_claim_decision \(\@\) \{(.*?)\n\}/s;
like($decision,qr/ref\(\$execution\) ne "HASH"/,
 'the decision frees only the absent claim, not a foreign one');
like($decision,qr/return "rival"/,'and names the rival case explicitly');
# The end-to-end claim must be ownership-checked, not an unconditional write.
my ($body)=$src=~/sub webui_automation_control_body \(\@\) \{(.*)/s;
my ($resume_block)=$body=~/if\(\$action eq "resume"\) \{(.*?)\n {1,2}\}\n {1,2}if\(\$action eq "stop"\)/s;
like($resume_block,qr/webui_automation_resume_claim_decision.*rival/s,
 'the resume claim refuses to overwrite a different run rather than writing unconditionally');

done_testing();
