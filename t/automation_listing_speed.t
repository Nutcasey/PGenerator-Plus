# Regression for PR 14 test report P3 and P33: the History list and the LG
# Calibration History list stop re-decoding unchanged files, and starting a
# batch no longer holds the request for the TV checks the runner repeats.
use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Time::HiRes ();
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
require "$Bin/../usr/share/PGenerator/webui.pm";
require "$Bin/../usr/share/PGenerator/lg.pm";

# ---- P3: automation History list
{
 my $store=tempdir(CLEANUP=>1);$ENV{PGEN_AUTOMATION_DIR}=$store;PGAutomation::ensure_store();
 for my $n (1..3) {
  PGAutomation::write_json_atomic(PGAutomation::run_dir("run-$n").'/run.json',{id=>"run-$n",token=>"t$n",status=>'complete',
   queue_name=>"Queue $n",created_at=>$n,items=>[{name=>"Job $n",signal_format=>'sdr',status=>'complete'}]});
 }
 my $reads=0;my $real=\&main::webui_automation_read_run;
 local *main::webui_automation_read_run=sub {$reads++;$real->(@_)};
 my $first=main::webui_automation_list_runs();
 is(scalar(@$first),3,'every run is listed');
 is($reads,3,'the first listing reads each manifest');
 ok(-f PGAutomation::run_dir('run-1').'/listing-cache.json','a summary is kept beside each manifest');
 $reads=0;
 my $second=main::webui_automation_list_runs();
 is($reads,0,'an unchanged store is listed without decoding any manifest');
 is_deeply($second,$first,'and the listing is identical');
 PGAutomation::write_json_atomic(PGAutomation::run_dir('run-2').'/run.json',{id=>'run-2',token=>'t2',status=>'failed',
  queue_name=>'Queue 2',created_at=>2,items=>[{name=>'Job 2',signal_format=>'sdr',status=>'failed'}],failure=>{stage=>'x',message=>'boom'}});
 $reads=0;
 my ($changed)=grep {$_->{id} eq 'run-2'} @{main::webui_automation_list_runs()};
 is($reads,1,'only the changed manifest is decoded again');
 is($changed->{status},'failed','and its new state is listed');
 PGAutomation::write_json_atomic(PGAutomation::run_dir('run-3').'/listing-cache.json',{key=>'stale',summary=>{id=>'run-3',status=>'bogus'}});
 my ($rebuilt)=grep {$_->{id} eq 'run-3'} @{main::webui_automation_list_runs()};
 is($rebuilt->{status},'complete','a summary for a different manifest version is never used');
 # Round 3: the summary write never creates a run directory (a run deleted
 # while it was being listed must not come back holding only its cache).
 my $gone=PGAutomation::run_dir('run-gone');
 ok(!main::webui_automation_write_listing_cache($gone,{key=>'k',summary=>{id=>'run-gone'}}),'no summary is written for a run that no longer exists');
 ok(!-e $gone,'and its directory is not recreated');
 opendir(my $rd,PGAutomation::run_dir('run-1'));my @tmp=grep {/\.tmp\z/} readdir($rd);closedir($rd);
 is(scalar(@tmp),0,'no temporary summary files are left behind');
 {
  local *Time::HiRes::stat=sub {die "no hires stat\n"};
  like(main::webui_automation_listing_key(PGAutomation::run_dir('run-1').'/run.json'),qr/\A\d+:\d+:\d+\z/,'the manifest key falls back to the core stat when the high-resolution one fails');
 }
}

# ---- P3: LG Calibration History list
{
 my $root=tempdir(CLEANUP=>1);
 make_path(map {"$root/$_"} qw(runs luts history/1d history/dv));
 my $save=sub {my ($path,$data)=@_;open my $f,'>',"$root/$path" or die $!;print {$f} main::lg_encode_json($data);close $f;};
 $save->('history/1d/a.json',{picture_mode=>'filmMaker',signal_mode=>'sdr',dpg_data=>[(0)x3072]});
 open my $source,'<',"$Bin/../usr/share/PGenerator/lg.pm" or die $!;
 my $text=do {local $/;<$source>};close $source;
 my ($subs)=$text=~/(sub _lg_cal_hist_fingerprint \{.*?)(?=\nsub webui_lg_calibration_history_download)/s;
 die 'History list source not found' if !$subs;
 eval 'package main; {my $_lg_cal_hist_runs=q{'.$root.'/runs};my $_lg_cal_hist_luts=q{'.$root.'/luts};my $_lg_cal_hist_dir=q{'.$root.'/history};'.$subs.'}';die $@ if $@;
 my $reads=0;my $real=\&main::_lg_cal_hist_read_json_file;
 local *main::_lg_cal_hist_read_json_file=sub {$reads++;$real->(@_)};
 my $first=main::webui_lg_calibration_history_list();
 like($first,qr/"id":"1dfile:a"/,'the archive is listed');
 ok($reads>0,'the first listing decodes the archive');
 $reads=0;
 is(main::webui_lg_calibration_history_list(),$first,'an unchanged archive set returns the same list');
 is($reads,0,'without decoding any archive');
 Time::HiRes::sleep(0.02);
 $save->('history/1d/b.json',{picture_mode=>'expert1',signal_mode=>'sdr',dpg_data=>[(1)x3072]});
 $reads=0;
 my $grown=main::webui_lg_calibration_history_list();
 like($grown,qr/"id":"1dfile:b"/,'a new archive appears');
 is($reads,1,'and only the new archive is decoded (unchanged files come from the per-file memo)');
 # Round 3: a hidden archive name still changes the fingerprint.
 my $before=main::_lg_cal_hist_fingerprint();
 Time::HiRes::sleep(0.02);
 $save->('history/1d/.c.json',{picture_mode=>'expert2',signal_mode=>'sdr',dpg_data=>[(2)x3072]});
 isnt(main::_lg_cal_hist_fingerprint(),$before,'an archive whose name starts with a dot changes the fingerprint');
 $grown=main::webui_lg_calibration_history_list();
 like($grown,qr/"id":"1dfile:\.c"/,'and it is listed straight away');
 # Round 3: a torn cache body under the right fingerprint is never served.
 my $fp=main::_lg_cal_hist_fingerprint();
 open my $torn,'>',"$root/history.list-cache" or die $!;print {$torn} "$fp\n{\"status\":\"ok\",\"items\":[{\"id\":\"x\"}}\n";close $torn;
 is(main::webui_lg_calibration_history_list(),$grown,'a torn cache body is rebuilt, not served');
 # Round 4: the disk cache itself is served (not just the per-file memo).
 my $uncached=0;my $real_uncached=\&main::_lg_cal_hist_list_uncached;
 {
  local *main::_lg_cal_hist_list_uncached=sub {$uncached++;$real_uncached->(@_)};
  main::webui_lg_calibration_history_list();
  $uncached=0;
  main::webui_lg_calibration_history_list();
  is($uncached,0,'an unchanged archive set is answered from the disk cache without rebuilding the list');
  # Accented titles are sent as UTF-8 and still served from the disk cache.
  Time::HiRes::sleep(0.02);
  $save->('luts/cafe.json',{title=>"Caf\x{e9} HDR",picture_mode=>'hdrFilmMaker',signal_mode=>'hdr10'});
  open my $bin,'>',"$root/luts/cafe.bin" or die $!;print {$bin} 'lut';close $bin;
  my $accented=main::webui_lg_calibration_history_list();
  ok(!utf8::is_utf8($accented),'the list body is bytes, ready to send');
  my ($item)=grep {$_->{id} eq '3d:cafe'} @{JSON::PP::decode_json($accented)->{items}};
  is($item->{label},"Caf\x{e9} HDR",'an accented title decodes correctly');
  $uncached=0;
  is(main::webui_lg_calibration_history_list(),$accented,'and the same body comes back');
  is($uncached,0,'from the disk cache');
 }
 # Round 4: the memo keeps only what the list reads, and forgets removed files.
 make_path("$root/runs/run-9");
 $save->('runs/run-9/grey-state.json',{final_1d_lut_uploaded=>JSON::PP::true,hdr20_1d_dpg_data=>[(0.5)x3072],readings=>[map {{ire=>$_,Y=>$_*2}} 1..500],
  picture_mode=>'hdrFilmMaker',signal_mode=>'hdr10',nested=>{deeper=>{deepest=>{gone=>1},kept=>2}}});
 my $lite=main::_lg_cal_hist_read_json_lite("$root/runs/run-9/grey-state.json");
 is(scalar(@{$lite->{hdr20_1d_dpg_data}}),3072,'a 1D curve keeps its length for the list check');
 ok(!grep({defined} @{$lite->{hdr20_1d_dpg_data}}),'but not its values');
 is_deeply($lite->{readings},[],'readings are dropped');
 is($lite->{picture_mode},'hdrFilmMaker','scalars the list shows are kept');
 is($lite->{nested}{deeper}{kept},2,'two levels of nested settings are kept');
 ok(!exists $lite->{nested}{deeper}{deepest},'deeper structures are dropped');
 like(main::webui_lg_calibration_history_list(),qr/"id":"1d:run-9"/,'the run is listed from its trimmed state');
 ok((grep {m{/runs/run-9/grey-state\.json\z}} main::_lg_cal_hist_lite_memo_paths()),'its state is remembered');
 # A non-ASCII picture mode read from a run's stage log is encoded once.
 make_path("$root/runs/run-dv");
 $save->('runs/run-dv/dv-profile-measurements.json',{measurements=>{white_luminance=>700}});
 open my $stages,'>',"$root/runs/run-dv/stages.ndjson" or die $!;
 print {$stages} qq({"stage":"dv_profile_upload","ok":true,"picture_mode":"Caf\xc3\xa9 DV"}\n);close $stages;
 my ($dv)=grep {$_->{id} eq 'dv:run-dv'} @{JSON::PP::decode_json(main::webui_lg_calibration_history_list())->{items}};
 is($dv->{picture_mode},"Caf\x{e9} DV",'a stage-log picture mode with an accent is not double-encoded');
 unlink("$root/runs/run-9/grey-state.json");rmdir("$root/runs/run-9");
 unlike(main::webui_lg_calibration_history_list(),qr/"id":"1d:run-9"/,'a removed run leaves the list');
 ok(!(grep {m{/run-9/}} main::_lg_cal_hist_lite_memo_paths()),'and the memo forgets it');
 $grown=main::webui_lg_calibration_history_list();
 open my $junk,'>',"$root/history.list-cache" or die $!;print {$junk} "0123456789abcdef0123456789abcdef\n{\"status\":\"ok\",\"items\":[]}\n";close $junk;
 is(main::webui_lg_calibration_history_list(),$grown,'a cache for a different fingerprint is ignored');
}

# ---- P33: Run queue does not hold the request for TV conversations
{
 my $store=tempdir(CLEANUP=>1);$ENV{PGEN_AUTOMATION_DIR}=$store;PGAutomation::ensure_store();
 my $tv=0;
 local *main::webui_lg_status_json=sub {$tv++;'{"status":"ok","paired":1,"connected":1}'};
 local *main::webui_lg_calibration_mode=sub {$tv++;'{"status":"ok","calibration_mode":false}'};
 local *main::webui_meter_status=sub {'{"detected":1}'};
 local *main::webui_meter_series_alive=sub {0};local *main::webui_meter_lg_autocal_running=sub {0};
 local *main::webui_meter_lg_3d_autocal_running=sub {0};local *main::webui_meter_lg_dv_profile_running=sub {0};
 local *main::webui_meter_session_alive=sub {0};
 local *main::webui_automation_launch_runner=sub {1};
 my $reply=PGAutomation::decode_json(main::webui_automation_start({queue=>{name=>'Batch',items=>[{name=>'Job',signal_format=>'sdr',picture_mode=>'filmMaker'}]}}));
 is($reply->{status},'started','a valid queue starts');
 is($tv,0,'without any TV conversation in the start request');
 my $events=PGAutomation::read_json_file("$store/preflight.json")->{events}||[];
 ok(!grep({($_->{message}||'')=~/TV connection/} @$events),'and its progress never claims to be checking the TV');
 is($events->[0]{message},'Validating the queue, meter and storage','it names the checks the start request actually makes');
 # Each refusal gets its own store: the started run above holds the claim.
 $store=tempdir(CLEANUP=>1);$ENV{PGEN_AUTOMATION_DIR}=$store;PGAutomation::ensure_store();
 local *main::webui_meter_status=sub {'{"detected":0}'};
 $reply=PGAutomation::decode_json(main::webui_automation_start({queue=>{name=>'Batch',items=>[{name=>'Job',signal_format=>'sdr',picture_mode=>'filmMaker'}]}}));
 is($reply->{status},'blocked','a missing meter still refuses the start immediately');
 unlike($reply->{message}||'',qr/\bTV\b/,'and the refusal does not blame a TV it never checked');
 ok(!grep({($_->{message}||'')=~/\bTV\b/} @{PGAutomation::read_json_file("$store/preflight.json")->{events}||[]}),'nor does its progress log');
 local *main::webui_meter_status=sub {'{"detected":1}'};
 my $invalid=PGAutomation::decode_json(main::webui_automation_start({queue=>{name=>'Batch',items=>[{name=>'Job',signal_format=>'hlg',picture_mode=>'hdrCinema'}]}}));
 is($invalid->{status},'blocked','an invalid queue still refuses the start immediately');
 is($tv,0,'and neither refusal talks to the TV');
}
done_testing();
