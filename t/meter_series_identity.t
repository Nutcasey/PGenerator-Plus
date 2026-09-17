use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use IPC::Open3;
use Symbol qw(gensym);
use Test::More;
use JSON::PP ();
open my $fh,'<',"$Bin/../usr/bin/meter_series.sh" or die $!;
my $source=do {local $/;<$fh>};close $fh;
my @functions;
for my $name (qw(series_state_claim_lost load_series_identity_meta write_state_json)) {
 my ($f)=$source=~/^($name\(\) \{.*?^\})/ms;
 die "Missing production function $name" if !$f;
 push @functions,$f;
}
# Execute the actual shell state writer, isolated from USB and device commands.
# Both startup/minimal and explicit-points writes must retain attempt metadata.
for my $with_points (0,1) {
 my $dir=tempdir(CLEANUP=>1);
 local $ENV{IDENTITY_TEST_DIR}=$dir;
 open my $seed,'>',"$dir/state.json" or die $!;
 print {$seed} JSON::PP::encode_json({series_id=>'owned-series',type=>'colors',points=>913,signal_mode=>'hdr10',
  target_gamma=>'st2084',automation_worker_id=>'batch-1-colours',full_autocal_run_id=>'batch-1'});close $seed;
 my $functions=join("\n",@functions);$functions=~s{/tmp/meter_series_debug\.log}{$dir/debug.log}g;
 my $payload={status=>'complete',series_id=>'owned-series',readings=>[{Y=>1.234}],calibration_target_context=>{white_nits=>123}};
 @$payload{qw(type points)}=('colors',913) if $with_points;
 my $script=<<'BASH';
set -e
STATE_FILE="$IDENTITY_TEST_DIR/state.json"
SERIES_ID=owned-series
SERIES_META_JSON=''
SERIES_META_LOADED=''
SERIES_WORKER_META_JSON=''
# Do not touch host ownership/permissions during this isolated regression.
chown() { :; }
BASH
 $script.=$functions."\nwrite_state_json <<'PAYLOAD'\n".JSON::PP::encode_json($payload)."\nPAYLOAD\ncat \"\$STATE_FILE\"\n";
 my $err=gensym;my $pid=open3(my $in,my $out,$err,'bash');print {$in} $script;close $in;
 my $text=do {local $/;<$out>};my $errors=do {local $/;<$err>};waitpid($pid,0);
 is($? >> 8,0,"points=$with_points writer succeeds") or diag $errors;
 my $state=eval {JSON::PP::decode_json($text)}||{};
 is($state->{automation_worker_id},'batch-1-colours',"points=$with_points retains worker attempt");
 is($state->{full_autocal_run_id},'batch-1',"points=$with_points retains run identity");
 ok($state->{worker_pid}>1,"points=$with_points records worker PID");
 like($state->{worker_start_ticks}//'',qr/^\d+$/,"points=$with_points records process birth");
 is($state->{points},913,'series identity is retained');
 is_deeply($state->{readings},$payload->{readings},'physical readings unchanged');
 is_deeply($state->{calibration_target_context},$payload->{calibration_target_context},'provided chart context unchanged');
}
done_testing();
