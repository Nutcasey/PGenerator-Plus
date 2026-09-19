# Each calibration worker's real write_state leaves a .summary sidecar beside
# the state file holding only the automation poller's keys, no older than the
# state file, and a sidecar that cannot be written never breaks the state write.
use FindBin qw($Bin);
use strict;
use warnings;
no warnings qw(once redefine);
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;
my $WT="$Bin/..";
my $dir=tempdir(CLEANUP=>1);
my $id='run-7-20260919-010203-abcdef';
my $perl=$^X;
sub run_perl {my ($code)=@_;my $f="$dir/p$$".int(rand(1e9)).".pl";open my $h,'>',$f or die;print {$h} $code;close $h;my $out=`"$perl" "$f" 2>&1`;return ($?>>8,$out);}
sub load_json {my ($p)=@_;open my $f,'<',$p or return undef;local $/;my $t=<$f>;close $f;return eval { JSON::PP::decode_json($t) };}
my $events='[map {{seq=>$_,time=>$_,message=>"e$_"}} 1..70]';
for my $w (
 ['grey','meter_lg_autocal.pl','$main::LG_AUTOCAL_CONFIG={automation_worker_id=>"'.$id.'"};'
   .'main::write_state({status=>"running",message=>"x",current_step=>3,total_steps=>37,phase=>"greyscale",activity_sequence=>70,'
   .'activity_events=>'.$events.',hdr20_1d_dpg_anchor_history=>[1..5000],readings=>[1..500]});'],
 ['3d','meter_lg_3d_autocal.pl','$main::LG_3D_REQUEST_CONTEXT={automation_worker_id=>"'.$id.'"};'
   .'main::write_state({status=>"running",message=>"x",current_step=>3,total_steps=>33,upload_verified=>JSON::PP::false,hdr20_postcal_shadow_dpg_data=>[1..3072]});'],
) {
 my $state="$dir/$w->[0].json";
 my ($rc,$out)=run_perl(qq{\@ARGV=("$dir/none-config.json","$state","$dir/stop");
   local \$SIG{__WARN__}=sub{};
   do "$WT/usr/bin/$w->[1]"; die \$@ if \$@;
   $w->[2]
   print "OK\\n";});
 like($out,qr/OK/,"$w->[0]: worker loaded and wrote state") or diag $out;
 my $s=load_json($state)||{};
 my $sum=load_json("$state.summary");
 is(ref $sum,'HASH',"$w->[0]: summary sidecar written beside the state file") or next;
 is($sum->{automation_worker_id},$id,"$w->[0]: sidecar carries the attempt identity");
 is($sum->{worker_pid},$s->{worker_pid},"$w->[0]: sidecar carries the same pid as the state");
 is($sum->{current_step},3,"$w->[0]: sidecar carries the patch counter");
 ok(!exists $sum->{hdr20_1d_dpg_anchor_history} && !exists $sum->{readings} && !exists $sum->{hdr20_postcal_shadow_dpg_data},"$w->[0]: bulk keys stay out of the sidecar");
 ok(-s "$state.summary" < -s $state,"$w->[0]: sidecar is smaller than the state");
 my @st=stat($state);my @ss=stat("$state.summary");
 ok($ss[9]>=$st[9],"$w->[0]: sidecar is not older than the state file");
 is($ss[2] & 07777,$st[2] & 07777,"$w->[0]: sidecar has the state file's permissions");
}
{
 my $state="$dir/grey.json";
 my $sum=load_json("$state.summary")||{};
 is(scalar @{$sum->{activity_events}||[]},60,'grey: sidecar keeps the last 60 events');
 is($sum->{activity_events}[0]{seq},11,'grey: the oldest kept event is the eleventh');
 is($sum->{activity_events}[-1]{seq},70,'grey: the newest event is kept');
 ok($sum->{autocal},'grey: the autocal flag write_state sets is in the sidecar');
 is($sum->{phase},'greyscale','grey: the phase is in the sidecar');
}
# A sidecar path that cannot be written (a directory sits there) leaves the
# state write intact.
{
 my $state="$dir/blocked.json";
 mkdir "$state.summary" or die "mkdir: $!";
 my ($rc,$out)=run_perl(qq{\@ARGV=("$dir/none-config.json","$state","$dir/stop");
   local \$SIG{__WARN__}=sub{};
   do "$WT/usr/bin/meter_lg_autocal.pl"; die \$@ if \$@;
   \$main::LG_AUTOCAL_CONFIG={automation_worker_id=>"$id"};
   main::write_state({status=>"running",message=>"blocked"});
   print "OK\\n";});
 like($out,qr/OK/,'grey: write_state survives an unwritable sidecar') or diag $out;
 is((load_json($state)||{})->{message},'blocked','grey: the state file is still written');
}
{
 my $state="$dir/blocked-3d.json";
 mkdir "$state.summary" or die "mkdir: $!";
 my ($rc,$out)=run_perl(qq{\@ARGV=("$dir/none-config.json","$state","$dir/stop");
   local \$SIG{__WARN__}=sub{};
   do "$WT/usr/bin/meter_lg_3d_autocal.pl"; die \$@ if \$@;
   \$main::LG_3D_REQUEST_CONTEXT={automation_worker_id=>"$id"};
   print main::write_state({status=>"running",message=>"blocked"}) ? "OK\\n" : "FAILED\\n";});
 like($out,qr/OK/,'3d: write_state still reports success with an unwritable sidecar') or diag $out;
 is((load_json($state)||{})->{message},'blocked','3d: the state file is still written');
}
# The Dolby Vision worker has no caller() guard: run its real write_state on its own.
{
 open my $f,'<',"$WT/usr/bin/meter_lg_dv_profile.pl" or die;my $src=do{local $/;<$f>};close $f;
 my ($sub)=$src=~/^(sub write_state \{.*?^\})/ms or die 'write_state not found';
 my $state="$dir/dv.json";
 my ($rc,$out)=run_perl(qq{use lib "$WT/usr/share/PGenerator"; use PGAutomation (); use JSON::PP ();
   our \$config={automation_worker_id=>"$id",full_autocal_run_id=>"fa-9"}; our \$state_file="$state"; our \$json=JSON::PP->new;
   $sub
   write_state(status=>"running",message=>"x",current_step=>2,total_steps=>5,steps=>[{name=>"white"}]) or die "write failed";print "OK\\n";});
 like($out,qr/OK/,'dv: real write_state ran') or diag $out;
 my $sum=load_json("$state.summary");
 is(ref $sum,'HASH','dv: summary sidecar written');
 is($sum->{full_autocal_run_id},'fa-9','dv: sidecar carries the run id');
 is($sum->{automation_worker_id},$id,'dv: sidecar carries the attempt identity');
 is($sum->{current_step},2,'dv: sidecar carries the patch counter');
 ok(!exists $sum->{steps},'dv: step detail stays out of the sidecar');
 my @st=stat($state);my @ss=stat("$state.summary");
 ok($ss[9]>=$st[9],'dv: sidecar is not older than the state file');
 mkdir "$dir/dv-blocked.json.summary" or die;
 ($rc,$out)=run_perl(qq{use lib "$WT/usr/share/PGenerator"; use PGAutomation (); use JSON::PP ();
   our \$config={automation_worker_id=>"$id"}; our \$state_file="$dir/dv-blocked.json"; our \$json=JSON::PP->new;
   $sub
   write_state(status=>"running",message=>"blocked") or die "write failed";print "OK\\n";});
 like($out,qr/OK/,'dv: write_state survives an unwritable sidecar') or diag $out;
 is((load_json("$dir/dv-blocked.json")||{})->{message},'blocked','dv: the state file is still written');
}
done_testing();
