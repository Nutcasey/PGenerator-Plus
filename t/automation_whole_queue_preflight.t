use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
use PGAutomationPlan ();
require "$Bin/../usr/share/PGenerator/webui.pm";

# Real runner, file store, signal switching, mode selection, plan and restoration
# code. Only the external TV/renderer/readiness responses are simulated.
my ($run_id,$run_file,$store,@calls,%config,%modes,$profile,$input,$bad_job,$virtual,$restore_fail,$cancel,$prepares,$mode_writes,$use_real_transport);
sub fixture {
    $store=tempdir(CLEANUP=>1);$ENV{PGEN_AUTOMATION_DIR}=$store;
    PGAutomation::ensure_store();
    $run_id='whole-queue';$run_file=PGAutomation::run_dir($run_id).'/run.json';
    local @ARGV=($run_id,'test-token');
    {local $SIG{__WARN__}=sub {warn @_ unless $_[0]=~/^Subroutine .* redefined at/;};
     do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}
    @calls=();%config=(signal_mode=>'sdr',eotf=>'0',primaries=>'0',colorimetry=>'2',color_format=>'0',rgb_quant_range=>'2',max_bpc=>'10',dv_map_mode=>'2');
    %modes=(sdr=>'expert1',hdr10=>'hdrCinema',dv=>'dolbyVisionCinemaBright');
    $profile='a'x64;$input='hdmi1';$bad_job=0;$virtual=0;$restore_fail=0;$cancel=0;$prepares=0;$mode_writes=0;$use_real_transport=0;
    my @specs=(['sdr','filmMaker'],['hdr10','hdrFilmMaker'],['dv','dolbyVisionFilmMaker'],['sdr','cinema']);
    my @items=map {main::webui_automation_normalize_item({id=>'job-'.($_+1),name=>'Job '.($_+1),signal_format=>$specs[$_][0],picture_mode=>$specs[$_][1],settings=>{},settle_seconds=>0,stages=>{calibration=>1,apply_all=>0}})} 0..$#specs;
    PGAutomation::write_json_atomic($run_file,{id=>$run_id,token=>'test-token',status=>'running',items=>\@items,queue_revision=>0});
    PGAutomation::write_json_atomic("$store/execution.json",{owner=>'automation',run_id=>$run_id,token=>'test-token',status=>'running',pid=>0});
    PGAutomation::write_json_atomic(PGAutomation::run_dir($run_id).'/control.json',{request=>'none'});
}
sub tv_response {
    return {status=>'ok',current_input=>$input,picture_settings=>{pictureMode=>$modes{$config{signal_mode}}},
        supported_picture_keys=>['pictureMode'],virtual_picture_settings=>$virtual,
        generation_profile=>{capability_profile_hash=>$profile,capability_profile_id=>'fixture',capability_library_valid=>1,capability_platform_profile_applied=>1}};
}
sub fake_api {
    my ($method,$path,$payload)=@_;
    push @calls,[$method,$path,PGAutomation::clone($payload)];
    if($path eq '/api/config') {
        return {%config} if $method eq 'GET';
        return {status=>'error',message=>'Injected output restoration failure'} if $restore_fail && exists($payload->{dv_map_mode}) && $payload->{signal_mode} eq 'sdr';
        @config{keys %$payload}=values %$payload;
        return {status=>'ok'};
    }
    return {ok=>1} if $path eq '/api/ping';
    if($path eq '/api/pattern') {die 'Non-neutral preflight patch' if ($payload->{name}||'') ne 'gray50';return {status=>'ok'};}
    if($path eq '/api/lg/picture-settings') {
        return main::_api_once($method,$path,$payload,0) if $use_real_transport && $payload->{ignore_calibration_picture_mode};
        return tv_response();
    }
    if($path eq '/api/lg/picture-settings/set') {
        die 'Preflight attempted settings/LUT writes' if join(',',sort keys %{$payload->{settings}||{}}) ne 'pictureMode';
        $mode_writes++;$modes{$config{signal_mode}}=$payload->{settings}{pictureMode};return tv_response();
    }
    if($path eq '/api/automation/readiness') {
        return {status=>'ok',ready=>1,checks=>[],items=>$payload->{items}} if $payload->{scope} eq 'batch';
        die 'Only one mode may be queried in its actual signal context' if @{$payload->{items}}!=1;
        $prepares++;
        my $raw=$payload->{items}[0];
        die 'Readiness queried wrong signal context' if $raw->{signal_format} ne $config{signal_mode};
        die 'Readiness queried wrong picture context' if $raw->{picture_mode} ne $modes{$config{signal_mode}};
        if($cancel && $prepares==2) {PGAutomation::write_json_atomic(PGAutomation::run_dir($run_id).'/control.json',{request=>'stop'});select undef,undef,undef,.55;}
        my $item=main::webui_automation_normalize_item($raw);
        $item->{tv_input}=$input;$item->{generation_profile}=tv_response()->{generation_profile};
        $item->{capability_profile}={hash=>$profile,id=>'fixture'};
        $item->{device_identity}={model_name=>'test LG',generation_id=>'lg2023_oled',firmware=>'test'};
        return {status=>'ok',ready=>0,checks=>[{ok=>0,level=>'error',message=>'Unsupported control in job four'}],message=>'Unsupported control in job four'} if $bad_job && $item->{id} eq 'job-4';
        return {status=>'ok',ready=>1,items=>[$item],checks=>[{ok=>1,level=>'ok',message=>'Mode-specific controls checked'}]};
    }
    return {status=>'ok'} if $path eq '/api/meter/session/stop';
    die "Unexpected device operation $method $path";
}
sub run_check {
    local *main::_api=\&fake_api;
    local *main::_sleep_controlled=sub {1};
    local *main::_log=sub {};
    local *main::_ensure_lg_connection=sub {1};
    return main::_preflight_queue();
}
fixture();
my %original=%config;my %original_modes=%modes;
my $r=run_check();
ok($r->{ready},'every job passes against its actual signal and selected picture mode') or diag explain $r;
is($r->{checked_items},4,'not just the first job is live checked');
is_deeply([map {$_->{status}} @{$r->{jobs}}],[('checked')x4],'all four jobs carry individual results');
# requested_signal_mode is input-only; compare all saved generator fields.
is_deeply({map {$_=>$config{$_}} keys %original},\%original,'original generator output is restored');
is_deeply(\%modes,\%original_modes,'each signal family original picture mode is restored');
ok($r->{restored},'restoration is independently verified');
my $saved=PGAutomation::read_json_file($run_file);
is($saved->{preflight_revision},0,'successful plan is tied to the exact queue revision');
ok(!main::webui_automation_cleanup_required($saved),'successful preflight leaves no recovery obligation');
for my $item (@{$saved->{items}}) {ok(PGAutomationPlan::matches($item,$item->{preflight_contract}),'frozen execution matches the verified plan');}
is(scalar(grep {$_->[1]=~/reset|lut|autocal|meter\/read/} @calls),0,'preflight sends no reset, LUT upload or meter measurement');
{
 local *main::_api=\&fake_api;local *main::_sleep_controlled=sub{1};local *main::_log=sub{};
 my $item=PGAutomation::clone($saved->{items}[0]);
 ok(eval {main::_prepare_job_context(0,$item);1},'fresh job checks accept the unchanged frozen plan') or diag $@;
 $input='hdmi2';
 ok(!eval {main::_prepare_job_context(0,$item);1},'changed input blocks the job before settings or calibration');
 like($@,qr/stale|input|compatibility/,'input change has an actionable error');
 $input='hdmi1';$profile='b'x64;
 ok(!eval {main::_prepare_job_context(0,$item);1},'changed compatibility signature blocks the job');
 $profile='a'x64;$item->{settings}{brightness}=53;
 ok(!eval {main::_prepare_job_context(0,$item);1},'changed job options cannot reuse an old plan');
 like($@,qr/stale/,'settings change requests fresh queue preflight');
}
fixture();$bad_job=1;%original=%config;%original_modes=%modes;
$r=run_check();
ok(!$r->{ready},'an incompatible fourth job blocks the entire queue');
is($prepares,4,'the incompatible late job is discovered upfront');
is($r->{jobs}[3]{status},'blocked','specific late job is named');
is_deeply(\%modes,\%original_modes,'blocked preflight still restores every changed picture mode');
ok($r->{restored},'blocked result carries restoration confirmation');
ok(!exists(PGAutomation::read_json_file($run_file)->{preflight_revision}),'blocked queue has no executable plan');
is(scalar(grep {$_->[1]=~/reset|lut|autocal|meter\/read/} @calls),0,'late incompatibility never reaches a destructive command');
fixture();$virtual=1;
$r=run_check();
ok(!$r->{ready},'unreadable/echoed original mode blocks reversible probing');
is($mode_writes,0,'no TV mode is changed without a restorable original mode');
is(scalar(grep {$_->[0] eq 'POST' && $_->[1] eq '/api/config'} @calls),0,'no output is changed before original context can be captured');
fixture();$cancel=1;%original_modes=%modes;
$r=run_check();
ok(!$r->{ready},'cancelled preflight cannot become ready');
is($prepares,2,'Stop prevents checking the remaining jobs');
ok($r->{restored},'Stop still runs reversible restoration');
is_deeply(\%modes,\%original_modes,'cancel restores signal family modes');
fixture();$restore_fail=1;
$r=run_check();
ok(!$r->{ready} && !$r->{restored},'failed restoration blocks an otherwise compatible queue');
ok(PGAutomation::read_json_file($run_file)->{preflight_restore_required},'restoration journal obligation persists');
{
 local *main::_api=\&fake_api;local *main::_sleep_controlled=sub{1};local *main::_log=sub{};
 main::_finish('failed',{stage=>'queue-preflight',message=>'Restoration failed'});
 is(PGAutomation::read_json_file($run_file)->{status},'interrupted','failed restoration stays recoverable');
 ok(-f "$store/execution.json",'failed restoration retains exclusive device ownership');
 $restore_fail=0;
 ok(main::_restore_preflight_context(),'a later retry uses the saved restoration journal');
 ok(!PGAutomation::read_json_file($run_file)->{preflight_restore_required},'successful retry clears restoration obligation');
}
{
 my $original={settings=>{brightness=>50},picture_mode=>'cinema',signal_format=>'sdr',tv_input=>'hdmi1',capability_profile=>{hash=>'a'x64},device_identity=>{firmware=>'1'}};
 my $contract=PGAutomationPlan::contract($original);
 my $changed=PGAutomation::clone($original);$changed->{status}='running';$changed->{checkpoints}=[{name=>'item-started',status=>'done'}];
 ok(PGAutomationPlan::matches($changed,$contract),'runtime progress does not invalidate execution intent');
 $changed->{some_future_execution_option}=1;
 ok(!PGAutomationPlan::matches($changed,$contract),'future execution options invalidate old plans by default');
 $changed=PGAutomation::clone($original);$changed->{device_identity}{firmware}='2';
 ok(!PGAutomationPlan::matches($changed,$contract),'device identity changes invalidate plans');
 my $normalized=main::webui_automation_normalize_item({%$original,preflight_contract=>$contract});
 ok(!exists($normalized->{preflight_contract}),'HTTP input cannot forge a server preflight contract');
}

# Actual _main orchestration. The handshake is stubbed only in this test; the
# separate launcher test exercises its real process/locking/acceptance path.
for my $scenario (qw(blocked check-only run)) {
 fixture();$bad_job=$scenario eq 'blocked';
 PGAutomation::with_lock($run_file,sub {$_[0]{preflight_only}=1 if $scenario eq 'check-only';return $_[0];});
 my $executed=0;
 local *PGAutomationLaunch::worker_handshake=sub {return 1;};
 local *main::_api=\&fake_api;local *main::_sleep_controlled=sub{1};local *main::_log=sub{};
 local *main::_run_item=sub {
  $executed++;
  is($prepares,4,'all jobs were live checked before the first calibration stage');
  my ($number,$item)=@_;$item->{status}='complete';
  main::_update_run(sub {$_[0]{items}[$number]=$item;});return 1;
 };
 ok(eval {main::_main();1},"$scenario actual runner main completes without unexpected device commands") or diag $@;
 is($executed,$scenario eq 'run'?4:0,"$scenario executes calibration only after the entire queue passed and execution was requested");
 is(PGAutomation::read_json_file($run_file)->{status},$scenario eq 'blocked'?'failed':'complete',"$scenario terminal status reflects the actual outcome");
 ok(!-f "$store/execution.json","$scenario safely restored run releases its own claim");
}
fixture();$r=run_check();
{
 local *main::_log=sub{};
 PGAutomation::with_lock($run_file,sub {$_[0]{queue_revision}=1;return $_[0];});
 my ($claimed,$changed)=main::_claim_queue_item(0);
 ok($changed,'an edit between optimistic check and claim cannot bypass preflight');
 isnt($claimed->{items}[0]{status}||'queued','running','unverified revision is not claimed for execution');
 PGAutomation::with_lock($run_file,sub {$_[0]{queue_revision}=0;$_[0]{items}[0]{settings}{brightness}=56;return $_[0];});
 ($claimed,$changed)=main::_claim_queue_item(0);
 ok($changed,'even a changed option without a revision bump is rejected');
 ok(!defined($claimed->{preflight_revision}),'changed intent forces full preflight on the next loop');
 PGAutomation::with_lock($run_file,sub {$_[0]{items}=[{name=>'Already done',status=>'complete'}];return $_[0];});
 @calls=();$r=run_check();
 ok($r->{ready},'a resumed run with no pending jobs can finish without re-calibrating');
 is(scalar @calls,0,'already complete queue needs no mode switching or TV reads');
}
{
 my $calls=0;
 local *main::webui_automation_start=sub {$calls++;ok($_[0]{preflight_only},'Check Readiness creates a check-only owned run');return '{"status":"started","run_id":"check-only"}';};
 my $r=PGAutomation::decode_json(main::webui_automation_api('/api/automation/readiness','POST','{"scope":"queue","items":[]}'));
 is($r->{error_code},'preflight-consent-required','API requires consent before switching modes for a check');
 is($calls,0,'no preflight run launched without consent');
 $r=PGAutomation::decode_json(main::webui_automation_api('/api/automation/readiness','POST','{"scope":"queue","confirm_mode_switches":true,"items":[]}'));
 is($calls,1,'explicit consent reaches owned preflight startup');
 $r=PGAutomation::decode_json(main::webui_automation_api('/api/automation/readiness','POST','{"scope":"job","automation_token":"forged"}'));
 is($r->{error_code},'automation-owner-mismatch','a forged token cannot request internal live job probing');
}
fixture();$use_real_transport=1;
{
 local *HTTP::Tiny::request=sub {
  my ($client,$method,$url,$options)=@_;
  # Runs in the real transport subprocess. Capture the encoded request rather
  # than inspecting a pre-transport mock which would miss context injection.
  PGAutomation::append_line_locked("$store/independent-requests.ndjson",$options->{content}."\n");
  return {success=>1,status=>200,content=>PGAutomation::encode_json(tv_response())};
 };
 $r=run_check();
 ok($r->{ready},'whole preflight also passes through the actual scoped HTTP transport');
 my @requests=map {PGAutomation::decode_json($_)} split /\n/,PGAutomation::read_raw("$store/independent-requests.ndjson");
 ok(@requests>4,'independent snapshots reached the actual transport multiple times');
 is(scalar(grep {exists($_->{picture_mode}) || exists($_->{expected_tv_input})} @requests),0,'snapshot reads never inherit the queued mode or a guessed input');
 is(scalar(grep {!$_->{ignore_calibration_picture_mode}} @requests),0,'every snapshot explicitly ignores cached calibration selection');
}
done_testing();
