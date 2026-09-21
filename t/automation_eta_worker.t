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
done_testing();
