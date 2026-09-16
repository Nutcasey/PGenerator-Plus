use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
PGAutomation::ensure_store();
make_path(PGAutomation::run_dir('batch-test').'/items');
{
 local @ARGV=('batch-test','token-for-batch-test');
 local $SIG{__WARN__}=sub {};
 do "$Bin/../usr/bin/pgen_automation_runner.pl";
 die $@ if $@;
}
# TV setup used to write 18 controls one helper call each, 3-14 s per call
# on the G3. The first pass now writes each category in one session and the
# readback verifies them together; anything unverified takes the old path.
local *main::_log=sub {};
my @actions;local *main::_log_action=sub {push @actions,$_[0]};
local *main::_update_run=sub {$_[0]->({});{}};
local *main::_sleep_controlled=sub {1};
local *main::_append_setting_check=sub {1};
local *main::_verify_live_capability_profile=sub {1};
local *main::_select_item_picture_mode=sub {1};
my %tv=(pictureMode=>'filmMaker',brightness=>50,contrast=>85,color=>50);
my (@writes,$batch_reply,$reads);
local *main::_api=sub {
 my ($method,$path,$payload)=@_;
 if($path eq '/api/lg/picture-settings/set'){push @writes,[sort keys %{$payload->{settings}}];return $batch_reply->($payload) if @{[keys %{$payload->{settings}}]}>1;return {status=>'ok',verification_state=>'verified'};}
 $reads++;
 return {status=>'ok',picture_settings=>{%tv}};
};
my $item=sub { {signal_format=>'sdr',picture_mode=>'filmMaker',stages=>{calibration=>0},settle_seconds=>0,settings=>{brightness=>50,contrast=>85,color=>50}} };

$batch_reply=sub {{status=>'ok',verification_state=>'verified'}};@writes=();$reads=0;@actions=();
ok(main::_apply_and_verify(0,$item->(),'settings-applied',1),'three controls apply and verify');
is_deeply(\@writes,[['brightness','color','contrast']],'one write carries every picture control');
ok(grep({/Applied 3 picture controls in one TV session/} @actions),'the batched write is announced');

$batch_reply=sub {{status=>'error',message=>'TV refused the batch'}};@writes=();
ok(main::_apply_and_verify(0,$item->(),'settings-applied',1),'a refused batch still ends verified');
is_deeply(\@writes,[['brightness','color','contrast'],['brightness'],['color'],['contrast']],'a refused batch falls back to one control at a time');
ok(grep({/not confirmed; applying them one at a time/} @actions),'the fallback is announced');

$batch_reply=sub {{status=>'ok',verification_state=>'unverified',message=>'no readback'}};@writes=();
main::_apply_and_verify(0,$item->(),'settings-applied',1);
is(scalar(@writes),4,'an unverified batch also falls back per control');

# A readback mismatch after the batch reaches the existing retry cycle.
$batch_reply=sub {{status=>'ok',verification_state=>'verified'}};@writes=();
my $stale=1;local *main::_api=sub {
 my ($method,$path,$payload)=@_;
 if($path eq '/api/lg/picture-settings/set'){push @writes,[sort keys %{$payload->{settings}}];return {status=>'ok',verification_state=>'verified'};}
 my %seen=%tv;$seen{contrast}=80 if $stale--;return {status=>'ok',picture_settings=>\%seen};
};
ok(main::_apply_and_verify(0,$item->(),'settings-applied',1),'a mismatch after the batch is repaired by the second cycle');
is_deeply($writes[0],['brightness','color','contrast'],'second cycle starts from the batched first cycle');
is(scalar(@writes),4,'the second cycle uses the per-control path');

@writes=();
ok(main::_apply_and_verify(0,{%{$item->()},settings=>{brightness=>50}},'settings-applied',1),'a single control applies');
is_deeply(\@writes,[['brightness']],'a lone control is not batched');
done_testing();
