use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{ local @ARGV=('timeout-test','test-token'); local $SIG{__WARN__}=sub {}; do "$Bin/../usr/bin/pgen_automation_runner.pl"; die $@ if $@; }
local *main::_log=sub {};
local *main::_heartbeat=sub {};
local *main::_refresh_control=sub {};

# A helper that ran out of time reached the TV; it is not a connection refusal.
ok(!main::_lg_connection_failure({status=>'error',message=>'LG TV did not finish the white-balance write within 45s.'}),'a helper timeout is not a refusal');
ok(!main::_lg_connection_failure({status=>'error',message=>'LG TV did not answer the picture-settings request within 60s.'}),'a read timeout is not a refusal');
ok(main::_lg_connection_failure({status=>'error',message=>'Unable to connect to LG WebOS TV at 192.168.50.28'}),'a websocket refusal still is');
ok(main::_lg_connection_failure({status=>'error',error_code=>'lg-disconnected'}),'a disconnect code still is');

# Helper timeouts the runner asks for: only where the daemon action is known.
# 18 Sep 2026: a 19-key readback took 59 s on the G3 against a 60 s budget.
is(main::_lg_helper_timeout_for('/api/lg/picture-settings',{}),120,'a read with no key list keeps the 120 s floor');
is(main::_lg_helper_timeout_for('/api/lg/picture-settings',{keys=>[1..19]}),182,'a 19-key read budgets the 8 s floor per key');
is(main::_lg_helper_timeout_for('/api/lg/picture-settings/set',{settings=>{brightness=>50}}),45,'a lone control keeps the daemon default');
is(main::_lg_helper_timeout_for('/api/lg/picture-settings/set',{settings=>{map {$_=>1} 1..18}}),174,'eighteen controls get time for eighteen in-session writes');
is(main::_lg_helper_timeout_for('/api/lg/picture-settings/set',{settings=>{map {$_=>1} 1..40}}),300,'capped at 300 s');
# 18-19 Sep 2026: the batched 18-control write ran at 10 s per control and the
# constant 174 s budget fell back to one write at a time on every SDR job. The
# budget follows the slowest of the last three measured batched writes with
# 50% headroom, clamped to the budget a write was given.
my $set='/api/lg/picture-settings/set';
sub set_payload { return {settings=>{map {$_=>1} 1..$_[0]}} }
main::_reset_lg_control_seconds();
ok(!defined(main::_note_lg_control_seconds(1,30)),'a single-control write teaches nothing');
ok(!defined(main::_note_lg_control_seconds(18,0)),'a zero elapsed teaches nothing');
main::_note_lg_control_seconds(18,180);
is(main::_lg_helper_timeout_for($set,set_payload(18)),300,'ten seconds per control measured lifts eighteen controls to the cap');
is(main::_lg_helper_timeout_for($set,set_payload(4)),90,'the measured figure scales with the control count');
is(main::_lg_helper_timeout_for('/api/lg/picture-settings',{keys=>[1..19]}),300,'reads follow the measured figure, capped');
main::_note_lg_control_seconds(18,72);
is(main::_lg_helper_timeout_for($set,set_payload(18)),300,'one faster write does not discard the slower figure');
main::_note_lg_control_seconds(18,72);
main::_note_lg_control_seconds(18,72);
is(main::_lg_helper_timeout_for($set,set_payload(18)),174,'three faster writes let the figure fall, never below the 8 s floor');
main::_reset_lg_control_seconds();
main::_note_lg_control_seconds(2,900,60);
is(main::_lg_helper_timeout_for($set,set_payload(4)),210,'a write that ran out of time teaches at most its own budget');
is(main::_reset_lg_control_seconds(15,'x',-1,undef),1,'seeding keeps only positive numeric samples');
is(main::_lg_control_seconds(),15,'and the seeded figure is used');

# The batched write itself measures, carries its budget, and stamps the
# samples into the manifest for a resumed run.
{
 main::_reset_lg_control_seconds();
 my $now=1000; my $step=30;
 local *main::time=sub { $now };
 my @calls; my $reply={status=>'ok'};
 local *main::_api=sub { my ($method,$path,$payload)=@_; push(@calls,$payload); $now+=$step; return $reply; };
 local *main::_update_live=sub {};
 local *main::_log_action=sub {};
 my @saved;
 local *main::_update_run=sub { my ($cb)=@_; my $run={}; $cb->($run); push(@saved,$run); return $run; };
 my $item={signal_format=>'sdr',picture_mode=>'cinema',tv_input=>'hdmi1'};
 my $settings={brightness=>50,contrast=>85,color=>50};
 my $done=main::_apply_settings_batched(0,$item,'c4',[sort keys %$settings],$settings,0);
 is(scalar(keys %$done),3,'three controls written together');
 is($calls[0]{helper_timeout},54,'the batched write carries its budget (30 s plus 8 s per control)');
 is(main::_lg_control_seconds(),15,'a confirmed 30 s write of three controls teaches 15 s per control');
 is_deeply($saved[-1]{lg_control_samples},[15],'the sample is stamped into the manifest');
 $reply={status=>'error',message=>'Unable to connect to LG WebOS TV at 192.168.50.28'};
 main::_apply_settings_batched(0,$item,'c4',[sort keys %$settings],$settings,0);
 is(main::_lg_control_seconds(),15,'a refused connection teaches nothing');
 is($calls[-1]{helper_timeout},75,'the next budget follows the measured figure');
 $reply={status=>'error',message=>'LG TV did not finish writing 3 picture controls within 75s.'};
 $step=400;
 main::_apply_settings_batched(0,$item,'c4',[sort keys %$settings],$settings,0);
 is(main::_lg_control_seconds(),37.5,'a helper that ran out of time teaches at most the budget it was given');
 main::_reset_lg_control_seconds();
}
ok(!defined(main::_lg_helper_timeout_for('/api/lg/picture-settings/set',{settings=>{whiteBalanceRed=>[0,0],whiteBalanceMethod=>'22'}})),'white-balance arrays keep the daemon DDC default');
ok(!defined(main::_lg_helper_timeout_for('/api/lg/3d-lut/reset',{})),'unknown actions keep the daemon default');

# Which LG actions may be re-posted after a transport error.
is(main::_lg_retry_window('/api/lg/picture-settings',{keys=>['pictureMode']}),300,'reads retry');
is(main::_lg_retry_window('/api/lg/picture-settings/set',{settings=>{brightness=>50,contrast=>85}}),300,'absolute-value control writes retry');
is(main::_lg_retry_window('/api/lg/picture-settings/set',{settings=>{whiteBalanceMethod=>'22',whiteBalanceRed=>[0,0]},reset_ddc_baseline=>1}),0,'the DDC baseline reset through /set never re-posts');
is(main::_lg_retry_window('/api/lg/picture-settings/set',{settings=>{whiteBalanceRed=>[1,2]}}),0,'white-balance arrays never re-post');
is(main::_lg_retry_window('/api/lg/picture-settings/set',{settings=>{brightness=>50},force_ddc_white_balance=>1}),0,'forced DDC writes never re-post');
for my $path (qw(/api/lg/picture-settings/reset /api/lg/3d-lut/reset /api/lg/1d-dpg/upload /api/lg/hdr-calman-reset /api/lg/dv-calman-reset /api/lg/sdr-calman-reset /api/lg/panel-protection /api/lg/dv-profile/upload /api/lg/autocal/run/begin /api/lg/picture-settings/apply-all-inputs /api/lg/something-new)) {
 is(main::_lg_retry_window($path,{}),0,"$path gets a single attempt");
}
is(main::_lg_retry_window('/api/lg/calibration-mode',{enabled=>JSON::PP::false}),30,'CAL_END keeps a bounded retry for Stop cleanup');
is(main::_lg_retry_window('/api/lg/calibration-mode',{enabled=>JSON::PP::true}),0,'CAL_START is a single attempt');

# _api injects the helper timeout only when the caller gave none, and
# retries transport errors only for the classes above.
my (@calls,@sleeps);
my $reply;
local *main::_api_once=sub { my ($method,$path,$payload)=@_; push @calls,{path=>$path,payload=>$payload}; return $reply->(@_); };
local *main::_sleep_controlled=sub { push @sleeps,$_[0]; return 0 };
$reply=sub {{status=>'ok',connected=>1}};
@calls=();
main::_api('POST','/api/lg/picture-settings/set',{settings=>{a=>1,b=>2,c=>3}});
my ($write)=grep {$_->{path} eq '/api/lg/picture-settings/set'} @calls;
is($write->{payload}{helper_timeout},54,'three controls ask the daemon for 54 s');
@calls=();
main::_api('POST','/api/lg/picture-settings/set',{settings=>{a=>1},helper_timeout=>170});
($write)=grep {$_->{path} eq '/api/lg/picture-settings/set'} @calls;
is($write->{payload}{helper_timeout},170,'an explicit helper timeout is kept');
@calls=();
main::_api('POST','/api/automation/readiness',{scope=>'batch'});
ok(!exists($calls[-1]{payload}{helper_timeout}),'non-LG requests are untouched');

$reply=sub { my ($method,$path)=@_; return {status=>'ok',connected=>1} if $path eq '/api/lg/status'; return {status=>'error',error_code=>'daemon-unreachable',message=>'timeout',_transport_error=>1} };
@calls=();@sleeps=();
main::_api('POST','/api/lg/hdr-calman-reset',{picture_mode=>'hdrFilmMaker'});
is(scalar(grep {$_->{path} eq '/api/lg/hdr-calman-reset'} @calls),1,'a reset that timed out is not re-posted');
is(scalar(@sleeps),0,'and does not wait for a retry');
@calls=();@sleeps=();
main::_api('POST','/api/lg/picture-settings',{keys=>['pictureMode']});
is(scalar(grep {$_->{path} eq '/api/lg/picture-settings'} @calls),1,'a read waits before its retry');
is(scalar(@sleeps),1,'the read scheduled a retry');

# A helper timeout no longer triggers a pairing refresh.
$reply=sub { my ($method,$path)=@_; return {status=>'ok',connected=>1} if $path eq '/api/lg/status'; return {status=>'error',message=>'LG TV did not finish writing 18 picture controls within 174s.'} };
@calls=();
main::_api('POST','/api/lg/picture-settings/set',{settings=>{map {$_=>1} 1..18}});
is(scalar(grep {$_->{path} eq '/api/lg/connect'} @calls),0,'no pairing refresh for a timeout');
is(scalar(grep {$_->{path} eq '/api/lg/picture-settings/set'} @calls),1,'and no repeated write');

# The status probe before each LG action is cached briefly and dropped on
# any connection failure or forced refresh.
my $status_calls=0;
$reply=sub { my ($method,$path)=@_; if($path eq '/api/lg/status'){$status_calls++;return {status=>'ok',connected=>1,stored_ip=>'1.2.3.4'}} return {status=>'ok',connected=>1} if $path eq '/api/lg/connect'; return {status=>'ok'} };
@calls=();$status_calls=0;
main::_ensure_lg_connection(1);
is($status_calls,1,'a forced probe always asks');
main::_ensure_lg_connection();main::_ensure_lg_connection();main::_ensure_lg_connection();
is($status_calls,1,'a healthy status answer is reused');
main::_ensure_lg_connection(1);
is($status_calls,2,'a forced refresh re-probes');
$status_calls=0;
my $connected=0;
$reply=sub { my ($method,$path)=@_; if($path eq '/api/lg/status'){$status_calls++;return {status=>'ok',connected=>$connected,stored_ip=>'1.2.3.4'}} return {status=>'ok',connected=>0} if $path eq '/api/lg/connect'; return {status=>'error',message=>'Unable to connect to LG WebOS TV at 1.2.3.4'} };
main::_ensure_lg_connection();
is($status_calls,0,'the cache is still warm from the forced refresh');
main::_api('POST','/api/lg/picture-settings',{keys=>['pictureMode']});
my $after_failure=$status_calls;
ok($after_failure>0,'the refusal forced a fresh probe');
$connected=1;
main::_ensure_lg_connection();
is($status_calls,$after_failure+1,'a connection failure drops the cached status, so the next action probes again');
done_testing();
