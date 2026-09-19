# The wait loop polls the worker's summary view carrying the last activity
# sequence it saw, and reads the full state exactly once when the summary
# reports a terminal status, so callers and the archive still get the whole
# result. Routes without a summary view are polled as before.
use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{
 local @ARGV=('wait-worker-summary-test','test-token');
 local $SIG{__WARN__}=sub {};
 do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;
}
my (@lines,@paths);
local *main::_log=sub {push @lines,$_[0]};
local *main::_log_action=sub {push @lines,$_[0]};
local *main::_active_item_number=sub {0};
local *main::_refresh_control=sub {};
local *main::_sleep_controlled=sub {1};
local *main::_update_run=sub {my $r={};$_[0]->($r);return $r};

is(main::_worker_status_poll_path('/api/meter/lg-autocal/status',0),'/api/meter/lg-autocal/status?view=summary&after=0','greyscale polls use the summary view');
is(main::_worker_status_poll_path('/api/meter/lg-3d-autocal/status',5),'/api/meter/lg-3d-autocal/status?view=summary&after=5','3D LUT polls use the summary view');
is(main::_worker_status_poll_path('/api/lg/dv-profile/status',17),'/api/lg/dv-profile/status?view=summary&after=17','the poll asks only for events after the last one seen');
is(main::_worker_status_poll_path('/api/meter/lg-autocal/status','bad'),'/api/meter/lg-autocal/status?view=summary&after=0','a malformed cursor falls back to zero');
is(main::_worker_status_poll_path('/api/meter/series/status',3),'/api/meter/series/status','routes without a summary view are polled unchanged');
is(main::_lg_action_path('/api/lg/dv-profile/status?view=summary&after=0'),main::_lg_action_path('/api/lg/dv-profile/status'),'the query does not change LG action detection');
is(main::_lg_retry_window('/api/lg/dv-profile/status?view=summary&after=0'),main::_lg_retry_window('/api/lg/dv-profile/status'),'nor the retry window');

my $event=sub {my ($seq)=@_;return {seq=>$seq,time=>100+$seq,message=>"event $seq"}};
{
 my @summaries=(
  {status=>'running',current_name=>'Auto Cal 7%',current_step=>1,total_steps=>3,automation_worker_id=>'w1',activity_sequence=>2,activity_events=>[$event->(1),$event->(2)]},
  {status=>'running',current_name=>'Auto Cal 7%',current_step=>2,total_steps=>3,automation_worker_id=>'w1',activity_sequence=>3,activity_events=>[$event->(3)]},
  {status=>'complete',current_name=>'Auto Cal complete',message=>'Auto Cal complete',automation_worker_id=>'w1',activity_sequence=>4,activity_events=>[$event->(4)]},
 );
 my $full={status=>'complete',current_name=>'Auto Cal complete',message=>'Auto Cal complete',automation_worker_id=>'w1',activity_sequence=>4,
  activity_events=>[map {$event->($_)} 1..4],measurements=>[1,2,3],ddc_upload_verified=>JSON::PP::true,hdr20_1d_dpg_anchor_history=>[1..10]};
 my $full_fetches=0;
 local *main::_api=sub {
  my ($method,$path)=@_;
  return {status=>'ok'} if $path eq '/api/lg/status';
  push @paths,$path;
  if($path eq '/api/meter/lg-autocal/status') {$full_fetches++;return PGAutomation::clone($full)}
  die "unexpected poll path $path" if $path !~ m{^/api/meter/lg-autocal/status\?view=summary&after=\d+$};
  return shift(@summaries) || die 'polled after the terminal summary';
 };
 my $result=main::_wait_worker('/api/meter/lg-autocal/status','greyscale AutoCal',{});
 is($result->{status},'complete','the wait returns the terminal status');
 is_deeply($result->{measurements},[1,2,3],'the returned object is the full state, not the summary');
 ok($result->{ddc_upload_verified},'callers still see the verification flags');
 is($full_fetches,1,'the full state is fetched exactly once');
 is_deeply(\@paths,[
  '/api/meter/lg-autocal/status?view=summary&after=0',
  '/api/meter/lg-autocal/status?view=summary&after=2',
  '/api/meter/lg-autocal/status?view=summary&after=3',
  '/api/meter/lg-autocal/status',
 ],'every poll is a summary carrying the last seen sequence; only the end reads the full state');
 is(scalar(grep {/1D LUT \| event \d/} @lines),4,'each event is saved once across summary polls and the full read');
 is(scalar(grep {/activity gap/} @lines),0,'server-side filtering does not look like a gap');
}
{
 @lines=();
 my @summaries=(
  {status=>'running',automation_worker_id=>'w1',activity_sequence=>2,activity_events=>[$event->(1),$event->(2)]},
  {status=>'running',automation_worker_id=>'w1',activity_sequence=>9,activity_events=>[$event->(8),$event->(9)]},
  {status=>'complete',automation_worker_id=>'w1',activity_sequence=>9,activity_events=>[]},
 );
 local *main::_api=sub {
  my ($method,$path)=@_;
  return {status=>'ok'} if $path eq '/api/lg/status';
  return {status=>'complete',automation_worker_id=>'w1',activity_events=>[]} if $path eq '/api/meter/lg-autocal/status';
  return shift(@summaries) || die 'polled after the terminal summary';
 };
 main::_wait_worker('/api/meter/lg-autocal/status','greyscale AutoCal',{});
 is(scalar(grep {/activity gap/} @lines),1,'events that expired before collection are still reported as a gap');
}
{
 my @summaries=({status=>'complete',automation_worker_id=>'w1'});
 local *main::_api=sub {
  my ($method,$path)=@_;
  return {status=>'ok'} if $path eq '/api/lg/status';
  return {status=>'error',error_code=>'daemon-unreachable'} if $path eq '/api/meter/lg-autocal/status';
  return shift(@summaries) || die 'polled after the terminal summary';
 };
 is(main::_wait_worker('/api/meter/lg-autocal/status','greyscale AutoCal',{})->{error_code},'daemon-unreachable','a daemon lost during the full read is reported, not polled forever');
}
{
 my @statuses=({status=>'running',current_step=>1,total_steps=>2},{status=>'complete',current_step=>2,total_steps=>2});
 my @seen;
 local *main::_api=sub {my ($m,$p)=@_;return {status=>'ok'} if $p eq '/api/lg/status';push @seen,$p;return shift(@statuses) || die 'extra poll'};
 is(main::_wait_worker('/api/meter/series/status','series',{})->{status},'complete','series waits complete as before');
 is_deeply(\@seen,['/api/meter/series/status','/api/meter/series/status'],'series polls carry no summary query and fetch nothing extra');
}
{
 my @summaries=({status=>'running',automation_worker_id=>'w1'},{status=>'complete',automation_worker_id=>'w1'});
 my @seen;
 local *main::_api=sub {
  my ($m,$p)=@_;
  return {status=>'ok'} if $p eq '/api/lg/status';
  push @seen,$p;
  return {status=>'complete',automation_worker_id=>'w1',profile=>{}} if $p eq '/api/lg/dv-profile/status';
  return shift(@summaries) || die 'extra poll';
 };
 my $dv=main::_wait_worker('/api/lg/dv-profile/status','Dolby Vision profile',{});
 ok(exists $dv->{profile},'the Dolby Vision wait also ends on the full state');
 is_deeply(\@seen,['/api/lg/dv-profile/status?view=summary&after=0','/api/lg/dv-profile/status?view=summary&after=0','/api/lg/dv-profile/status'],'Dolby Vision polls use the summary view');
}
done_testing();
