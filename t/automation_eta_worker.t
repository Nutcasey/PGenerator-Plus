use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{local @ARGV=('eta-worker-test','test-token');do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}
my $update_run=\&main::_update_run;
# Every tick must reach the manifest here; in production only one a minute
# does (the rest go to the live status), which is what this test measures.
$main::WORKER_MANIFEST_INTERVAL=0;
my ($now,@statuses,@clocks);
local *main::time=sub {$now};
local *main::_refresh_control=sub {};
local *main::_sleep_controlled=sub {1};
local *main::_log=sub {};
local *main::_log_worker_events=sub {};
local *main::_worker_progress=sub {''};
local *main::_active_item_number=sub {0};
local *main::_update_run=sub {my $r={};$_[0]->($r);push @clocks,PGAutomation::clone($r->{worker_timing});return $r};
local *main::_api=sub {
 return {status=>'ok'} if $_[1] eq '/api/lg/status';
 die 'unexpected API call' unless $_[1] eq '/test/status' && @statuses;
 my $s=shift @statuses;$now=$s->{at};return $s;
};
$now=1000;
@statuses=(map {{status=>'running',current_step=>$_,total_steps=>8,at=>1000+($_-1)*60}} 1..7);
push @statuses,{status=>'running',current_step=>2,total_steps=>8,at=>1500},
 {status=>'running',current_step=>3,total_steps=>8,at=>1680},
 {status=>'complete',current_step=>8,total_steps=>8,at=>1800};
is(main::_wait_worker('/test/status','greyscale AutoCal',{})->{status},'complete','worker loop completes without device I/O');
is_deeply($clocks[0]{recent_point_seconds},[],'first point does not invent a duration');
is_deeply($clocks[6]{recent_point_seconds},[(60)x5],'only the latest five completed point timings retained');
is_deeply($clocks[7]{recent_point_seconds},[],'counter reset clears old-pass timings');
is($clocks[7]{start_step},1,'reset starts a new measured pass');
is_deeply($clocks[8]{recent_point_seconds},[180],'new pass uses its own observed pace');

{
 local *main::_set_dv_map=sub {1};
 local *main::_grey_payload=sub {{}};
 local *main::_start_worker=sub {{status=>'started'}};
 local *main::_copy_worker_files=sub {1};
 my $last;
 local *main::_api=sub {
  return {status=>'ok'} if $_[1] eq '/api/lg/status';
  die 'unexpected route' if $_[1]!~m{^/api/meter/lg-autocal/status};
  $last=shift @statuses if @statuses;$now=$last->{at};return {%$last};
 };
 $now=1000;
 @statuses=(map {{status=>'running',current_step=>$_,total_steps=>8,at=>1000+($_-1)*60}} 1..8);
 push @statuses,{status=>'complete',current_step=>8,total_steps=>8,at=>1500,final_1d_lut_upload_verified=>1};
 my $result=main::_calibration_greyscale_stage(0,{});
 is($result->{timing_curve}{total_steps},8,'completed greyscale worker passes its learned trajectory to the checkpoint');
 is_deeply($result->{timing_curve}{fractions},[0,.12,.24,.36,.48,.60,.72,.84,1],'learned trajectory includes completed point durations and the final commit');
}
{
 my $cache=PGAutomation::run_dir('eta-worker-test').'/timing.json';
 PGAutomation::write_json_atomic($cache,{version=>1,samples=>[]});
 local *PGAutomation::write_json_atomic=sub {undef};
 local *main::_update_item_snapshot=sub {1};
 local *main::_copy_worker_files=sub {1};
 local *main::_update_run=sub {my $r={items=>[{}]};$_[0]->($r);return $r};
 ok(main::_checkpoint_record(0,{active_stage=>'greyscale-done',stage_started_at=>900},'greyscale-done',1,{}),
  'optional timing cache failure does not fail a saved calibration checkpoint');
 ok(!-e $cache,'failed history save invalidates the older index so the manifest supplies newer timings');
}
{
 my $cache=PGAutomation::run_dir('eta-worker-test').'/timing.json';
 PGAutomation::write_json_atomic($cache,{version=>1,samples=>[{stage=>'greyscale-done',seconds=>1} ]});
 my $manifest_saved=0;
 local *main::_update_item_snapshot=sub {1};
 local *main::_copy_worker_files=sub {1};
 local *main::_update_run=sub {
  my $r={items=>[{}]};
  $_[0]->($r);
  $manifest_saved=1;
  return $r;
 };
 my $write=\&PGAutomation::write_json_atomic;
 local *PGAutomation::write_json_atomic=sub {
  die "simulated interruption before timing rewrite\n" if $_[0] eq $cache;
  return $write->(@_);
 };
 eval { main::_checkpoint_record(0,{active_stage=>'greyscale-done',stage_started_at=>900},'greyscale-done',1,{}); 1 };
 like($@,qr/simulated interruption before timing rewrite/,'interrupts at the timing cache write');
 ok($manifest_saved,'manifest checkpoint can commit before the timing index rewrite');
 ok(!-e $cache,'an interrupted timing rewrite cannot leave a stale valid index');
}
for my $failure (qw(manifest-refused manifest-published cache-refused interrupted)) {
 my $dir=PGAutomation::run_dir('eta-worker-test');
 my $item={active_stage=>'greyscale-done',stage_started_at=>900,
  checkpoints=>[{name=>'item-started',status=>'done',duration_seconds=>25,completed_at=>800}]};
 # Above the legacy parse budget: losing the compact cache hides even the
 # previous completed timings, although the old manifest remains intact.
 my $run={id=>'eta-worker-test',status=>'running',items=>[$item],evidence=>'x' x 2100000};
 my $previous={version=>1,samples=>PGAutomationETA::samples($run)};
 PGAutomation::write_json_atomic("$dir/run.json",$run) or die 'unable to seed manifest';
 PGAutomation::write_json_atomic("$dir/timing.json",$previous) or die 'unable to seed timing cache';
 local *main::_update_run=$update_run;
 local *main::_copy_worker_files=sub {1};
 my $write=\&PGAutomation::write_json_atomic;
 {
  local *PGAutomation::write_json_atomic=sub {
   if ($_[0] eq "$dir/run.json") {
    return 0 if $failure eq 'manifest-refused';
    # The real atomic writer can return failure after publishing a new inode.
    if ($failure eq 'manifest-published') {
     local *PGAutomation::sync_directory=sub {0};
     return $write->(@_);
    }
   }
   if ($_[0] eq "$dir/timing.json") {
    return 0 if $failure eq 'cache-refused';
    die "interrupted cache handover\n" if $failure eq 'interrupted';
   }
   return $write->(@_);
  };
  my $result=eval {main::_checkpoint_record(0,$item,'greyscale-done',1,{})};
  if ($failure eq 'interrupted') {like($@,qr/interrupted cache handover/,'interrupts after the manifest commit');}
  else {is(!!$result,$failure eq 'cache-refused',"$failure preserves the calibration checkpoint outcome");}
 }
 my $saved=PGAutomation::read_json_file("$dir/run.json");
 is(scalar @{$saved->{items}[0]{checkpoints}},$failure eq 'manifest-refused'?1:2,'manifest readback identifies whether the checkpoint became visible');
 if ($failure ne 'manifest-refused') {
  ok(!-e "$dir/timing.json",'a post-publication failure must not restore the stale timing cache');
  ok(-e "$dir/timing.json.previous",'previous timings survive a failed or interrupted cache handover');
 } else {
  is_deeply(PGAutomation::read_json_file("$dir/timing.json"),$previous,'failed commit restores the prior compact cache');
 }
 is_deeply(PGAutomationETA::history('next-run'),$previous->{samples},'prior timings remain available even when the manifest exceeds the history budget');
 if ($failure ne 'manifest-refused') {
  delete $saved->{evidence};
  PGAutomation::write_json_atomic("$dir/run.json",$saved) or die 'unable to reduce manifest';
  is_deeply(PGAutomationETA::history('next-run'),PGAutomationETA::samples($saved),
   'a readable manifest supplies newer checkpoints ahead of the previous cache');
 }
 # Retry with healthy storage. Only checkpoints visible in the saved manifest
 # are resumed; a failed attempt must not appear twice in the recovered cache.
 my $retry=$saved->{items}[0];
 $retry->{active_stage}='volume-done';$retry->{stage_started_at}=900;
 ok(main::_checkpoint_record(0,$retry,'volume-done',1,{}),'checkpoint writes recover after the storage failure');
 is_deeply(PGAutomationETA::history('next-run'),PGAutomationETA::samples(PGAutomation::read_json_file("$dir/run.json")),
  'recovered cache reflects all and only the committed checkpoints');
 ok(!-e "$dir/timing.json.previous",'recovery leaves no previous timing cache behind');
}
done_testing();
