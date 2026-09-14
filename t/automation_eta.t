use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../usr/share/PGenerator";
use Test::More;
use File::Temp qw(tempdir);
use PGAutomation ();
use PGAutomationETA ();
require "$Bin/../usr/share/PGenerator/webui.pm";
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
sub job {
 return {signal_format=>'sdr',picture_mode=>'filmMaker',status=>'running',settings=>{gamma=>'high2'},
  device_identity=>{model_name=>'Test TV'},calibration=>{target_delta_e=>.5},
  stages=>{pre_readings=>0,calibration=>1,post_readings=>0,apply_all=>0}};
}
sub run {
 return {id=>'eta-test',status=>'running',active_item=>0,active_stage=>'greyscale-done',stage_started_at=>1000,
  items=>[job()],worker_status=>{status=>'running',current_step=>6,total_steps=>26},
  worker_timing=>{kind=>'grey',stage=>'greyscale-done',started_at=>1000,start_step=>0}};
}
my $r=run();
my $before=PGAutomation::clone($r);
PGAutomationETA::update($r,1100,[]);
is($r->{time_estimate}{scope},'unknown','no guessed ETA before sufficient elapsed time');
my $after=PGAutomation::clone($r);delete $after->{time_estimate};
is_deeply($after,$before,'estimate metadata does not alter calibration configuration');
PGAutomationETA::update($r,1300,[]);
is($r->{time_estimate}{scope},'stage','live point pace gives a labelled stage estimate');
is($r->{time_estimate}{remaining_seconds},1260,'five completed points in 300 seconds leaves 21 points');
$r->{worker_status}{current_step}=7;
PGAutomationETA::update($r,1350,[]);
is($r->{time_estimate}{calculated_at},1300,'ordinary polls do not recompute within two minutes');
PGAutomationETA::update($r,1420,[]);
is($r->{time_estimate}{remaining_seconds},1400,'pace is recomputed after two minutes');

$r=run();$r->{worker_timing}{start_step}=3;
PGAutomationETA::update($r,1300,[]);
is($r->{time_estimate}{scope},'unknown','counter restart waits for three new completed points');
$r->{worker_status}{current_step}=8;
PGAutomationETA::update($r,1420,[]);
is($r->{time_estimate}{remaining_seconds},1995,'counter restart uses only progress since the reset');

$r=run();
my $history=[map {{profile=>PGAutomationETA::profile($r->{items}[0]),stage=>$_,seconds=>60}} @{PGAutomationETA::plan($r->{items}[0])}];
$r->{items}[0]{checkpoints}=[map {{name=>$_,status=>'done',duration_seconds=>60}} qw(item-started tv-setup-verified reset-and-reapply-verified panel-light-settled)];
my $next=job();$next->{status}='queued';delete $next->{device_identity};push @{$r->{items}},$next;
PGAutomationETA::update($r,1300,$history);
is($r->{time_estimate}{scope},'batch','comparable history plus live pace gives a full batch estimate');
is($r->{time_estimate}{remaining_seconds},2040,'batch includes current remainder, later stages and next job, but not completed checkpoints');
my $no_post=$r->{time_estimate}{remaining_seconds};
$r->{items}[1]{stages}{post_readings}=1;
push @$history,{profile=>PGAutomationETA::profile($r->{items}[0]),stage=>'post-readings-done',seconds=>600};
PGAutomationETA::update($r,1310,$history);
cmp_ok($r->{time_estimate}{remaining_seconds},'>',$no_post+590,'pending sweep opt-in changes the estimate immediately');
is($r->{time_estimate}{calculated_at},1310,'queue edits invalidate the cache');
$r->{items}[1]{signal_format}='hdr10';
PGAutomationETA::update($r,1320,$history);
is($r->{time_estimate}{scope},'stage','unknown HDR timing is not filled with SDR history');
$r->{items}[1]{signal_format}='sdr';$r->{items}[1]{calibration}{target_delta_e}=.2;
PGAutomationETA::update($r,1330,$history);
is($r->{time_estimate}{scope},'stage','a different target needs comparable history');

$r=run();$r->{active_stage}='post-readings-done';
$r->{items}[0]{post_series}=[qw(greyscale-21 colors-30 saturations-24)];
$r->{worker_timing}={kind=>'series',stage=>'post-readings-done',started_at=>1000,series_key=>'colors-30'};
$r->{worker_status}={status=>'running',current_step=>7,total_steps=>30};
PGAutomationETA::update($r,1300,[]);
is($r->{time_estimate}{remaining_seconds},2450,'post-stage estimate includes ColorChecker plus 24 saturations and their white reference, not finished greyscale');
$r->{worker_status}{status}='complete';
PGAutomationETA::update($r,1310,[]);
is($r->{time_estimate}{scope},'unknown','completed sub-pass never shows a false zero-time batch estimate');
$r->{active_stage}='volume-done';
PGAutomationETA::update($r,1320,[]);
is($r->{time_estimate}{scope},'unknown','previous stage pace does not leak into volume solve/upload');
for my $status (qw(paused stopped complete failed interrupted stopping)) {
 $r=run();PGAutomationETA::update($r,1300,[]);$r->{status}=$status;
 PGAutomationETA::update($r,1310,[]);
 ok(!exists($r->{time_estimate}),"$status clears live ETA");
}
$r=run();PGAutomationETA::update($r,1300,[]);$r->{resumed_at}=1310;
PGAutomationETA::update($r,1320,[]);
is($r->{time_estimate}{calculated_at},1320,'resume invalidates earlier estimate');
is($r->{time_estimate}{scope},'unknown','pre-resume worker clock cannot count paused time as measurement pace');

my $saved={id=>'saved-eta',items=>[job()]};
$saved->{items}[0]{checkpoints}=[{name=>'greyscale-done',status=>'done',duration_seconds=>500},
 {name=>'volume-done',status=>'skipped',duration_seconds=>100},
 {name=>'post-readings-done',status=>'done',duration_seconds=>900,timing_interrupted=>1},
 {name=>'tv-setup-verified',status=>'done'}];
is(scalar @{PGAutomationETA::samples($saved)},1,'only timed completed stages enter history');
PGAutomation::write_json_atomic(PGAutomation::run_dir($saved->{id}).'/run.json',$saved);
is(scalar @{PGAutomationETA::history('current')},1,'historical timings survive process restart');
is(scalar @{PGAutomationETA::history($saved->{id})},0,'current run is not counted twice');
$r=run();PGAutomationETA::update($r,1300,[]);$r->{time_estimate}{private}='secret';
my $public=main::webui_automation_public_run($r);
is($public->{time_estimate}{remaining_seconds},1260,'ETA reaches lightweight status API');
ok(!exists($public->{time_estimate}{identity})&&!exists($public->{time_estimate}{private}),'internal fingerprints and extra fields stay private');
$r->{resumed_at}=1400;
ok(!exists(main::webui_automation_public_run($r)->{time_estimate}),'API suppresses pre-resume estimates');
done_testing();
