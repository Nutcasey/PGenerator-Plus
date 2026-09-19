# The automation runner polls a worker's status every two seconds and reads
# only a few top-level keys, while the full greyscale state passes 100 KB.
# ?view=summary serves that projection from the worker's .summary sidecar, or
# from the full state when the sidecar is missing or stale, applies the same
# status fix-ups as the plain view, and never writes a summary back.
use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
require "$Bin/../usr/share/PGenerator/webui.pm";
require "$Bin/../usr/share/PGenerator/lg.pm";

my $dir=tempdir(CLEANUP=>1);
my $encoder=JSON::PP->new->canonical(1);
sub write_text { my ($path,$text)=@_; open my $fh,'>',$path or die "$path: $!"; print {$fh} $text; close $fh; }
sub read_text { my ($path)=@_; open my $fh,'<',$path or return ''; local $/; my $t=<$fh>; close $fh; return $t; }
sub decode { my ($text)=@_; my $v=eval { JSON::PP->new->utf8(1)->decode($text) }; return ref($v) eq 'HASH' ? $v : {}; }
my @summary_keys=qw(status current_name current_step total_steps current_delta_e message error_code debug phase
 automation_worker_id worker_pid worker_start_ticks activity_sequence activity_events started_at completed_at
 elapsed_ms autocal calibration_mode full_workflow full_autocal_run_id full_autocal_phase);
sub summary_of { my ($state)=@_; my %s; $s{$_}=$state->{$_} for grep { exists $state->{$_} } @summary_keys; return \%s; }

my @events=map {{seq=>$_,time=>100+$_,message=>"event $_"}} 1..5;
sub full_state {
 my (%over)=@_;
 return {
  status=>'running',current_name=>'Auto Cal 7%',current_step=>34,total_steps=>37,current_delta_e=>0.42,
  message=>'Reading 7% sample 1/1',phase=>'greyscale',automation_worker_id=>'run-1-abc',worker_pid=>4242,
  worker_start_ticks=>'12345',activity_sequence=>5,activity_events=>[@events],started_at=>1000,
  autocal=>JSON::PP::true,calibration_mode=>JSON::PP::true,full_workflow=>JSON::PP::true,
  full_autocal_run_id=>'run-1',full_autocal_phase=>'greyscale',
  hdr20_1d_dpg_anchor_history=>[map {{step=>$_,codes=>[($_)x64]}} 1..400],
  readings=>[map {{x=>$_,y=>$_,z=>$_}} 1..200],
  steps=>[map {{name=>"step $_"}} 1..37],
  %over,
 };
}

is(main::webui_worker_status_summary_after(undef),undef,'no query is the plain view');
is(main::webui_worker_status_summary_after('summary=1'),undef,'the series summary flag does not select the worker projection');
is(main::webui_worker_status_summary_after('view=summary'),0,'view=summary without a cursor keeps every event');
is(main::webui_worker_status_summary_after('view=summary&after=12'),12,'the cursor is read from the query');
is(main::webui_worker_status_summary_after('after=7&view=summary'),7,'parameter order does not matter');
is(main::webui_worker_status_summary_after('view=summary&after=x'),0,'a malformed cursor keeps every event');

my $running=1;
local *main::webui_meter_lg_autocal_running=sub {$running};
local *main::webui_meter_lg_3d_autocal_running=sub {$running};
local *main::webui_meter_lg_dv_profile_running=sub {$running};

# ---- greyscale worker
my $grey="$dir/meter_lg_autocal.json";
my $state=full_state();
write_text($grey,$encoder->encode($state));
my $full_text=read_text($grey);
ok(length($full_text)>60000,'fixture state is large, like a late greyscale stage');
write_text("$grey.summary",$encoder->encode(summary_of($state)));

is(main::webui_meter_lg_autocal_status('view=summary',"$dir/absent.json"),'{"status":"idle"}','no state file is idle in either view');
is(main::webui_meter_lg_autocal_status(undef,$grey),$full_text,'plain view serves the full state byte for byte');
is(main::webui_meter_lg_autocal_status('',$grey),$full_text,'an empty query is the plain view');
is(main::webui_meter_lg_autocal_status('summary=1',$grey),$full_text,'only view=summary selects the projection');

my $text=main::webui_meter_lg_autocal_status('view=summary&after=0',$grey);
ok(length($text)<4000,'summary view is small') or diag(length($text));
my $summary=decode($text);
is($summary->{status},'running','summary carries the status');
is($summary->{current_step},34,'summary carries the patch counter');
is($summary->{automation_worker_id},'run-1-abc','summary carries the attempt identity');
is($summary->{worker_pid},4242,'summary carries the worker pid');
is($summary->{worker_start_ticks},'12345','summary carries the worker start ticks');
ok(!exists $summary->{hdr20_1d_dpg_anchor_history},'anchor history is not in the summary');
ok(!exists $summary->{readings},'readings are not in the summary');
is(scalar @{$summary->{activity_events}},5,'after=0 keeps every event');
ok($summary->{autocal} && $summary->{calibration_mode},'busy flags pass through while the worker runs');

$summary=decode(main::webui_meter_lg_autocal_status('view=summary&after=3',$grey));
is_deeply([map {$_->{seq}} @{$summary->{activity_events}}],[4,5],'after=N drops events already seen');
$summary=decode(main::webui_meter_lg_autocal_status('after=2&view=summary',$grey));
is_deeply([map {$_->{seq}} @{$summary->{activity_events}}],[3,4,5],'the cursor is honoured whatever the parameter order');
$summary=decode(main::webui_meter_lg_autocal_status('view=summary&after=9',$grey));
is_deeply($summary->{activity_events},[],'nothing new is an empty list, not a missing key');
is(read_text($grey),$full_text,'serving the summary does not touch the state file');

# A sidecar older than the state file is ignored: the same keys come from a
# decode of the full state, still filtered by the cursor.
write_text("$grey.summary",$encoder->encode({%{summary_of($state)},message=>'stale sidecar'}));
utime(time()-30,time()-30,"$grey.summary") or die "utime: $!";
$summary=decode(main::webui_meter_lg_autocal_status('view=summary&after=3',$grey));
is($summary->{message},'Reading 7% sample 1/1','a sidecar older than the state file is ignored');
ok(!exists $summary->{hdr20_1d_dpg_anchor_history},'the fallback projects the same keys');
is_deeply([map {$_->{seq}} @{$summary->{activity_events}}],[4,5],'the fallback applies the cursor too');
is(read_text($grey),$full_text,'the fallback does not touch the state file');
unlink("$grey.summary");
$summary=decode(main::webui_meter_lg_autocal_status('view=summary',$grey));
is($summary->{current_name},'Auto Cal 7%','a missing sidecar falls back to the full state');
ok(!exists $summary->{steps},'and still leaves the bulk keys out');

# Undecodable state with no sidecar is served whole rather than hidden.
write_text($grey,'{"status":"running","current_name":"torn"');
is(main::webui_meter_lg_autocal_status('view=summary',$grey),'{"status":"running","current_name":"torn"','text that does not decode is served as it is');
write_text($grey,$encoder->encode($state));
$full_text=read_text($grey);

# The dead-worker flip is applied to the summary text but never saved from
# the summary view; the plain read that follows saves it.
write_text("$grey.summary",$encoder->encode(summary_of($state)));
$running=0;
write_text("$grey.misses",int(time()*1000)-20000);
# The handler's stop file is a fixed path, so on a machine where one is left
# over the flip reads cancelled instead of error; both views must agree.
$summary=decode(main::webui_meter_lg_autocal_status('view=summary&after=0',$grey));
like($summary->{status},qr/^(?:error|cancelled)$/,'summary view still flips a dead running worker to a terminal status');
like($summary->{current_name},qr/^Auto Cal (?:process died|cancelled)$/,'the flip rewrites the current name as the plain view does');
is(read_text($grey),$full_text,'summary mode never writes the flipped text back');
ok(-f "$grey.misses",'summary mode keeps the first-miss marker for the full read');
my $plain=main::webui_meter_lg_autocal_status(undef,$grey);
is(decode($plain)->{status},$summary->{status},'the full read that follows applies the same flip');
is(decode($plain)->{current_name},$summary->{current_name},'with the same wording');
is(read_text($grey),$plain,'the plain view saves the flipped state');
ok(!-f "$grey.misses",'the plain view clears the first-miss marker');
my $later=decode(main::webui_meter_lg_autocal_status('view=summary&after=0',$grey));
is($later->{status},$summary->{status},'a later summary poll reads the saved outcome through the stale-sidecar fallback');

# Within the grace window both views report running and persist the first miss.
write_text($grey,$encoder->encode($state));
write_text("$grey.summary",$encoder->encode(summary_of($state)));
unlink("$grey.misses");
$summary=decode(main::webui_meter_lg_autocal_status('view=summary',$grey));
is($summary->{status},'running','a first pgrep miss does not flip the summary');
ok(-f "$grey.misses",'the first miss is recorded from the summary view');
unlink("$grey.misses");

# Stale busy flags on a finished worker are cleared in the summary text only.
my $done=full_state(status=>'complete',phase=>'restoring');
write_text($grey,$encoder->encode($done));
write_text("$grey.summary",$encoder->encode(summary_of($done)));
my $done_text=read_text($grey);
$summary=decode(main::webui_meter_lg_autocal_status('view=summary&after=0',$grey));
ok(!$summary->{autocal} && !$summary->{calibration_mode},'stale busy flags are cleared in the summary view');
is($summary->{phase},'cancelled','the restoring phase rewrite applies too');
is(read_text($grey),$done_text,'clearing flags in summary mode does not rewrite the state file');
main::webui_meter_lg_autocal_status(undef,$grey);
isnt(read_text($grey),$done_text,'the plain view still saves the cleared flags');
like(read_text($grey),qr/"autocal":false/,'with autocal false');

# ---- 3D LUT worker
$running=1;
my $three="$dir/meter_lg_3d_autocal.json";
my $three_state={status=>'running',current_name=>'3D LUT 12/33',current_step=>12,total_steps=>33,message=>'Measuring',
 automation_worker_id=>'run-1-3d',worker_pid=>4343,upload_verified=>JSON::PP::false,
 hdr20_postcal_shadow_dpg_data=>[map {$_/3072} 0..3071],data=>('x' x 5000)};
write_text($three,$encoder->encode($three_state));
my $three_text=read_text($three);
write_text("$three.summary",$encoder->encode({status=>'running',current_name=>'3D LUT 12/33',current_step=>12,total_steps=>33,
 message=>'Measuring',automation_worker_id=>'run-1-3d',worker_pid=>4343,upload_verified=>JSON::PP::false}));
like(main::webui_meter_lg_3d_autocal_status(undef,$three),qr/omitted from status/,'plain 3D view still elides the large payloads');
$text=main::webui_meter_lg_3d_autocal_status('view=summary',$three);
ok(length($text)<1000,'3D summary view is small');
$summary=decode($text);
is($summary->{current_step},12,'3D summary view serves the sidecar');
ok(!exists $summary->{hdr20_postcal_shadow_dpg_data},'3D summary omits the shadow data');
$running=0;
write_text("$three.misses",int(time()*1000)-20000);
$summary=decode(main::webui_meter_lg_3d_autocal_status('view=summary',$three));
is($summary->{status},'error','3D summary view flips a dead worker to error');
is($summary->{current_name},'3D LUT AutoCal process died','with the plain view wording');
is(read_text($three),$three_text,'3D summary mode never writes back');
ok(-f "$three.misses",'3D summary mode keeps the first-miss marker');
$plain=main::webui_meter_lg_3d_autocal_status(undef,$three);
is(decode($plain)->{status},'error','3D plain view applies the same flip');
isnt(read_text($three),$three_text,'3D plain view saves it');
ok(!-f "$three.misses",'3D plain view clears the first-miss marker');

# ---- Dolby Vision profile worker
$running=1;
my $dv="$dir/meter_lg_dv_profile.json";
my $dv_state={status=>'running',current_name=>'White',current_step=>2,total_steps=>5,message=>'Reading white',
 automation_worker_id=>'run-1-dv',worker_pid=>4444,full_autocal_run_id=>'run-1',
 steps=>[map {{name=>"s$_",xyz=>[1,2,3]}} 1..5],readings=>[1..500]};
write_text($dv,$encoder->encode($dv_state));
my $dv_text=read_text($dv);
write_text("$dv.summary",$encoder->encode({status=>'running',current_name=>'White',current_step=>2,total_steps=>5,
 message=>'Reading white',automation_worker_id=>'run-1-dv',worker_pid=>4444,full_autocal_run_id=>'run-1'}));
is(main::webui_meter_lg_dv_profile_status(undef,$dv),$dv_text,'plain DV view serves the full state');
$summary=decode(main::webui_meter_lg_dv_profile_status('view=summary&after=0',$dv));
is($summary->{current_name},'White','DV summary view serves the sidecar');
is($summary->{full_autocal_run_id},'run-1','DV summary keeps the run id the adoption probe checks');
ok(!exists $summary->{steps},'DV summary omits the step detail');
$running=0;
$summary=decode(main::webui_meter_lg_dv_profile_status('view=summary',$dv));
is($summary->{status},'error','DV summary view flips a dead worker');
like($summary->{message},qr/ended unexpectedly/,'with the plain view message');
is(read_text($dv),$dv_text,'DV state file untouched');
like(main::webui_meter_lg_dv_profile_status('view=summary',"$dir/absent-dv.json"),qr/"status":"idle"/,'no DV state file is idle in the summary view');
done_testing();
