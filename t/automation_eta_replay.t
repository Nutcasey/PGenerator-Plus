use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../usr/share/PGenerator";
use Test::More;
use PGAutomationETA ();

# Recorded trajectories are also the factory priors. Exclude the job being
# replayed, so its own duration and point weights cannot predict its finish.
my $data=PGAutomation::read_json_file("$Bin/../usr/share/PGenerator/automation-timing.json");
my ($count,$covered,$error)=(0,0,0);
for my $record (@{$data->{records}}) {
 my $saved=$record->{stages}{'greyscale-done'};my $curve=$saved->{curve};
 next if !$curve;
 local $PGAutomationETA::BASELINES={records=>[grep {$_->{source} ne $record->{source}} @{$data->{records}}]};
 for my $part (1..9) {
  my $elapsed=$saved->{seconds}*$part/10;my $done=0;
  $done++ while $done<$curve->{total_steps} && $curve->{fractions}[$done+1]*$saved->{seconds}<$elapsed;
  next if $done==0 || $done==$curve->{total_steps};
  my $run={id=>'replay',status=>'running',stage_started_at=>1000,active_item=>0,active_stage=>'greyscale-done',
   items=>[{%{$record->{job}},status=>'running'}],
   worker_status=>{status=>'running',total_steps=>$curve->{total_steps},current_step=>$done+1},
   worker_timing=>{kind=>'grey',stage=>'greyscale-done',started_at=>1000,start_step=>0,
    point_started_at=>1000+$saved->{seconds}*$curve->{fractions}[$done]}};
  PGAutomationETA::update($run,1000+$elapsed,[]);
  my $eta=$run->{time_estimate};my $truth=$saved->{seconds}-$elapsed;
  $count++;$error+=abs(($eta->{stage_remaining_seconds}||0)-$truth)/$truth;
  my $range=$eta->{ranges}{stage}||{};
  $covered++ if defined($range->{low}) && $truth>=$range->{low} && $truth<=$range->{high};
 }
}
is($count,63,'replay all seven measured SDR, HDR and DV trajectories at nine times each');
cmp_ok($error/$count,'<',.25,'unseen-run mean remaining-time error stays below 25%');
cmp_ok($covered/$count,'>=',.8,'observed remaining time lies inside the range for at least 80% of replay checkpoints');

local $PGAutomationETA::BASELINES=$data;
my $record=$data->{records}[1];my $job=PGAutomation::clone($record->{job});
my $run={id=>'adaptive',status=>'running',stage_started_at=>1000,active_item=>0,active_stage=>'greyscale-done',items=>[$job]};
PGAutomationETA::update($run,1000,[]);
is($run->{time_estimate}{batch_unknown_stages},0,'recorded workload has an estimate for every stage before any points complete');
ok($run->{time_estimate}{seeded_history},'cold estimate identifies its recorded starting point');
my $curve=$record->{stages}{'greyscale-done'}{curve};
my $seconds=$record->{stages}{'greyscale-done'}{seconds};
my @remaining;
my @queued;
for my $speed (.5,2) {
 my $r=PGAutomation::clone($run);delete $r->{time_estimate};
 push @{$r->{items}},{%{PGAutomation::clone($job)},picture_mode=>'next-mode',status=>'queued'};
 my $elapsed=$seconds*$curve->{fractions}[18]*$speed;
 $r->{worker_status}={status=>'running',current_step=>19,total_steps=>$curve->{total_steps}};
 $r->{worker_timing}={kind=>'grey',stage=>'greyscale-done',started_at=>1000,start_step=>0,point_started_at=>1000+$elapsed};
 PGAutomationETA::update($r,1000+$elapsed,[]);
 push @remaining,$r->{time_estimate}{stage_remaining_seconds};
 push @queued,$r->{time_estimate}{jobs}[1]{remaining_seconds};
 ok($r->{time_estimate}{adaptive},'measured progress adapts the prior');
}
cmp_ok($remaining[1],'>',$remaining[0]*2,'a slow run increases remaining time while a fast run reduces it');
cmp_ok($queued[1],'>',$queued[0]*2,'live speed also adjusts comparable work in the queued jobs');
$run->{active_stage}='volume-done';
PGAutomationETA::update($run,100000,[]);
ok($run->{time_estimate}{stage_remaining_seconds}>60,'overrun retains a positive residual instead of losing the stage estimate');
my $before=PGAutomation::clone($job);
PGAutomationETA::context($run);
is_deeply($job,$before,'private timing context never mutates the job');
$job->{signal_format}='unsupported';delete $run->{time_estimate};
PGAutomationETA::update($run,100001,[]);
ok($run->{time_estimate}{batch_unknown_stages}>0,'unsupported signal never borrows a calibrated signal family');

my $hdr=PGAutomation::clone($data->{records}[0]{job});
my $volume={id=>'volume',status=>'running',stage_started_at=>1000,active_item=>0,active_stage=>'volume-done',items=>[$hdr],
 worker_status=>{status=>'running',phase=>'postcal_shadow',current_step=>5,total_steps=>5},
 worker_timing=>{kind=>'3d',stage=>'volume-done',started_at=>1000,start_step=>0,tail_started_at=>1150}};
PGAutomationETA::update($volume,1300,[]);
my $tail=$volume->{time_estimate}{stage_remaining_seconds};
cmp_ok($tail,'>',1500,'HDR finishing estimate includes the measured long shadow-correction phase');
ok(!defined($volume->{time_estimate}{pass_remaining_seconds}),'frozen profile counters do not fabricate an active measurement pass');
PGAutomationETA::update($volume,1600,[]);
is($volume->{time_estimate}{stage_remaining_seconds},$tail-300,'finishing estimate counts down from its own phase start');
for my $status (qw(complete failed stopped interrupted)) {
 $volume->{worker_status}{status}=$status;
 PGAutomationETA::update($volume,10000,[]);
 ok(!defined($volume->{time_estimate}{stage_remaining_seconds}),"$status worker cannot grow a tail or fallback estimate");
}
my $cold={id=>'local',status=>'running',stage_started_at=>1000,active_item=>0,active_stage=>'greyscale-done',items=>[PGAutomation::clone($job)]};
my $local=[{profile=>PGAutomationETA::profile($job),stage=>'greyscale-done',seconds=>600,completed_at=>1}];
{
 local $PGAutomationETA::BASELINES=PGAutomation::clone($data);
 $_->{stages}{'greyscale-done'}{completed_at}=2000000000 for @{$PGAutomationETA::BASELINES->{records}};
 PGAutomationETA::update($cold,1100,$local);
 is($cold->{time_estimate}{stage_remaining_seconds},500,'older local measurements take precedence over a newer factory seed');
}
my $shape=PGAutomation::clone($cold);delete $shape->{time_estimate};
$shape->{items}[0]{calibration}{target_delta_e}=.123;
$shape->{worker_status}={status=>'failed',current_step=>4,total_steps=>$curve->{total_steps}};
$shape->{worker_timing}={kind=>'grey',stage=>'greyscale-done',started_at=>1000,point_started_at=>1000,start_step=>0};
PGAutomationETA::update($shape,1300,[]);
ok(!defined($shape->{time_estimate}{stage_remaining_seconds}),'equal-resolution clocks cannot invent a zero-duration stage estimate');
my $zero=PGAutomation::clone($cold);delete $zero->{time_estimate};
PGAutomationETA::update($zero,1300,[{profile=>PGAutomationETA::profile($job),stage=>'greyscale-done',seconds=>0}]);
ok(!defined($zero->{time_estimate}{stage_remaining_seconds}),'zero-duration history cannot grow an overdue fallback');
my $large=$data->{records}[-1]{job};
cmp_ok(PGAutomationETA::baseline($large,'volume-done')->{tail_seconds},'<',120,'large SDR profile retains measured finishing overhead rather than a percentage of its four-hour profile');
done_testing();
