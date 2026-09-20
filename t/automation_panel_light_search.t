use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{local @ARGV=('panel-search','test-token');do "$Bin/../usr/bin/pgen_automation_runner.pl";die $@ if $@;}

sub search {
 my ($start,$measurements,%options)=@_;
 my (@writes,@logs,$artifact,$value,$reads);
 my $item={signal_format=>'sdr',picture_mode=>'expert2',settings=>{backlight=>$start},
  panel_light=>{policy=>'target',key=>'backlight',target_luminance=>100}};
 local *main::_api=sub {{status=>'ok',settings=>{backlight=>$start}}};
 local *main::_apply_one_setting=sub {
  push @writes,$_[2];
  return {status=>'error',message=>'TV refused best restore'} if $options{restore_fails} && @writes>2;
  $value=$_[2];return {status=>'ok'};
 };
 local *main::_read_white=sub {
  $reads++;
  die "Unexpected measurement at setting $value" if ref($measurements) eq 'HASH' && !exists $measurements->{$value};
  return {Y=>ref($measurements) eq 'HASH' ? $measurements->{$value} : $measurements->($value)};
 };
 local *main::_read_and_verify_settings=sub {{verified=>1}};
 local *main::_sleep_controlled=sub {if ($options{cancel_after_write} && @writes>1) {kill 'TERM',$$;return 0;} return 1;};
 local *main::_refresh_control=sub {};
 local *main::_write_artifact=sub {$artifact=$_[1];1};
 local *main::_update_item_snapshot=sub {1};
 local *main::_log_action=sub {push @logs,$_[0]};
 $::LAST_ERROR='';
 my $ok=main::_panel_light_stage(0,$item);
 return {ok=>$ok,writes=>\@writes,logs=>\@logs,artifact=>$artifact,reads=>$reads,error=>$::LAST_ERROR,item=>$item};
}

# Replay the seven recorded readings from the interrupted overnight run.
# Setting 5 is a simulated next reading, not a claimed live TV result.
my $r=search(80,{80=>365.673471,22=>165.855943,13=>133.737586,10=>119.034205,
 8=>114.880912,7=>111.298578,6=>107.009534,5=>102});
ok($r->{ok},'overnight sequence continues past rounded setting 6 and reaches tolerance');
is_deeply($r->{writes},[80,22,13,10,8,7,6,5],'one-step correction tries setting 5 within the budget');
is($r->{artifact}{attempts},8,'actual measurement count is recorded');
is($r->{artifact}{outcome},'converged','measured convergence is recorded');
is($r->{item}{target_luminance},102,'calibration uses the accepted measured luminance');
like(join("\n",@{$r->{logs}}),qr/Attempt 7\/8.*Setting 6.*107\.01.*trying 5/,'decision log explains the rounding correction');

$r=search(10,{10=>120,8=>80,9=>100});
ok($r->{ok},'measured bracket narrows to an unmeasured setting');
is_deeply($r->{writes},[10,8,9],'bracket prevents bouncing between measured settings');

$r=search(6,{6=>107,5=>94});
ok(!$r->{ok},'unreachable tolerance pauses rather than accepting inaccurate luminance');
is($r->{artifact}{outcome},'resolution-limit','adjacent measured settings establish the resolution limit');
is($r->{reads},2,'no oscillation or duplicate measurements');
is_deeply($r->{writes},[6,5],'closest measured setting stays applied when it is already current');
like($r->{error},qr/2\/8 measurements.*Adjacent settings 5.*94\.00.*6.*107\.00.*best setting 5/s,'failure identifies actual attempts, bracket and best measurement');

$r=search(6,{6=>104,5=>90});
ok(!$r->{ok},'adjacent out-of-tolerance readings remain a failure');
is_deeply($r->{writes},[6,5,6],'restores the closest measured setting');
is($r->{artifact}{best_restore},'verified','restoration has setting readback evidence');
is($r->{artifact}{settled_value},6,'artifact records the restored setting');
is($r->{artifact}{best_luminance},104,'best measurement remains distinct from last measurement');
is($r->{artifact}{last_luminance},90,'no fresh measurement is invented after restoring best');

$r=search(6,{6=>104,5=>90},restore_fails=>1);
ok(!$r->{ok},'failed best restore cannot become success');
is($r->{artifact}{best_restore},'failed','restore refusal is explicit');
like($r->{error},qr/best-setting restore failed/,'user sees failed preservation');

$r=search(80,sub {110});
ok(!$r->{ok},'search budget exhaustion pauses');
is($r->{reads},8,'budget is strictly bounded');
is($r->{artifact}{outcome},'attempt-limit','budget exhaustion is not called unreachable');
like($r->{error},qr/8\/8.*reachability unknown/,'budget failure states uncertainty');
is($r->{writes}[-1],80,'best measured setting is preserved on exhaustion');
my %seen;ok(!grep($seen{$_->{value}}++,@{$r->{artifact}{iterations}}),'no setting is measured twice');

for my $case ([0,110],[100,90]) {
 $r=search($case->[0],{$case->[0]=>$case->[1]});
 ok(!$r->{ok},'measured boundary outside tolerance cannot silently continue');
 is($r->{artifact}{outcome},'control-limit','boundary failure is identified');
 is($r->{reads},1,'boundary failure reports one actual measurement');
}
$r=search(6,{6=>94,7=>100});
ok($r->{ok},'rounded stall below target tries one setting higher');
is_deeply($r->{writes},[6,7],'upward correction reaches the next unmeasured setting');

$r=search(6,{6=>0});
ok(!$r->{ok},'invalid meter measurement interrupts search');
is($r->{artifact}{outcome},'measurement-failed','meter failure is distinct from convergence failure');
$r=search(6,{6=>107},cancel_after_write=>1);
ok(!$r->{ok},'Stop during adjustment interrupts the search');
is($r->{artifact}{outcome},'cancelled','cancellation is distinct from an unreachable target');
is_deeply($r->{writes},[6,5],'Stop does not write the previous best back after cancellation');
is($r->{reads},1,'Stop prevents another measurement');
done_testing();
