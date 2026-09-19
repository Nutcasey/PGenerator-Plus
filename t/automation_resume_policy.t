#!/usr/bin/perl
# Resume after a failure in the profile stage keeps a verified 1D result.
# The 18 Sep 2026 batch repeated a 95-minute greyscale after a restore write
# timed out in the 3D LUT stage; the settings-recovery resume already knew
# how to keep the 1D result and restore the unity 3D baseline instead.
use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();

local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
{ local @ARGV=('resume-test','test-token'); local $SIG{__WARN__}=sub {}; do "$Bin/../usr/bin/pgen_automation_runner.pl"; die $@ if $@; }
my @actions;
local *main::_log=sub {};
local *main::_log_action=sub { push(@actions,$_[0]); };
local *main::_heartbeat=sub {};
local *main::_refresh_control=sub {};
local *main::_apply_signal=sub { 1 };

my @order=qw(item-started tv-setup-verified reset-and-reapply-verified panel-light-settled greyscale-done greyscale-settings-verified);
sub item {
 my (%extra)=@_;
 my $signal=delete($extra{signal_format}) || 'hdr10';
 return {name=>'Job',signal_format=>$signal,picture_mode=>'hdrCinema',settings=>{},
  checkpoints=>[map { {name=>$_,status=>'done',at=>1} } @order],%extra};
}
sub names { [map { $_->{name} } @{$_[0]{checkpoints}}] }
sub grey_state {
 my ($number,$state)=@_;
 my $dir=PGAutomation::item_dir('resume-test',$number).'/calibration';
 make_path($dir);
 if(!defined($state)) { unlink("$dir/grey-state.json"); return; }
 open(my $fh,'>',"$dir/grey-state.json") or die $!;
 print {$fh} JSON::PP->new->encode($state);
 close($fh);
}

# A verified 1D result survives a profile-stage failure.
{
 grey_state(0,{status=>'complete',ddc_upload_verified=>JSON::PP::true,hdr20_1d_dpg_data=>[(0) x 3072]});
 my $item=item(failure=>{stage=>'volume-done',message=>'Processing settings check: failed to restore smoothGradation',at=>2});
 @actions=();
 main::_prepare_resume(0,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified reset-and-reapply-verified panel-light-settled greyscale-done)],
  'volume-done failure keeps the reset, panel light and greyscale checkpoints');
 is($item->{profile_baseline_needs_restore},1,'the unity 3D baseline is restored before profiling');
 like(join("\n",@actions),qr/failure in Color calibration: retaining the verified 1D result/,'the resume names the stage and says the 1D result is kept');
}

# A session that failed to close after a verified profile keeps the profile.
{
 my $number=6;
 grey_state($number,{status=>'complete',ddc_upload_verified=>JSON::PP::true,hdr20_1d_dpg_data=>[(0) x 3072]});
 my $dir=PGAutomation::item_dir('resume-test',$number).'/calibration';
 for my $name (qw(profile.cube profile.bin)) { open(my $fh,'>',"$dir/$name") or die $!; print {$fh} 'x'; close($fh); }
 open(my $fh,'>',"$dir/3d-state.json") or die $!;
 print {$fh} JSON::PP->new->encode({status=>'complete',upload_verified=>JSON::PP::true,
  export=>{cube_path=>'/var/lib/PGenerator/lg/luts/profile.cube',payload_path=>'/var/lib/PGenerator/lg/luts/profile.bin'}});
 close($fh);
 my $item=item(failure=>{stage=>'session-closed',message=>'x',at=>2});
 push(@{$item->{checkpoints}},{name=>'volume-done',status=>'done',at=>3},{name=>'volume-settings-verified',status=>'done',at=>3});
 @actions=();
 main::_prepare_resume($number,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified reset-and-reapply-verified panel-light-settled greyscale-done greyscale-settings-verified volume-done volume-settings-verified)],
  'session-closed failure with a verified profile keeps the profile checkpoints');
 ok(!$item->{profile_baseline_needs_restore},'no baseline restore when the profile is kept');
 like(join("\n",@actions),qr/failure in Calibration-mode exit: retaining the verified 1D and profile results/,'the resume says both results are kept');
}

# Without the saved 1D curve the baseline cannot be restored, so the old full
# reset applies rather than a resume that would fail at job readiness.
{
 grey_state(7,{status=>'complete',ddc_upload_verified=>JSON::PP::true});
 my $item=item(failure=>{stage=>'volume-done',message=>'x',at=>2});
 @actions=();
 main::_prepare_resume(7,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified)],'a verified 1D result without its curve resets from the calibration start');
 ok(!$item->{profile_baseline_needs_restore},'and arms no baseline restore');
 like(join("\n",@actions),qr/saved 1D curve is missing/,'the resume says why');
}

# A session-close failure on a Dolby Vision job keeps the 1D result too, and
# has no 3D baseline to restore.
{
 grey_state(1,{status=>'complete',final_1d_lut_upload_verified=>JSON::PP::true});
 my $item=item(signal_format=>'dv',failure=>{stage=>'session-closed',message=>'x',at=>2});
 push(@{$item->{checkpoints}},{name=>'volume-done',status=>'done',at=>3},{name=>'volume-settings-verified',status=>'done',at=>3});
 main::_prepare_resume(1,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified reset-and-reapply-verified panel-light-settled greyscale-done)],
  'session-closed failure drops the profile checkpoints and keeps the greyscale');
 ok(!$item->{profile_baseline_needs_restore},'a Dolby Vision job sets no 3D baseline restore');
}

# Without the committed 1D file the old full reset still applies.
{
 grey_state(2,undef);
 my $item=item(failure=>{stage=>'volume-done',message=>'x',at=>2});
 main::_prepare_resume(2,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified)],'missing 1D artifacts reset from the calibration start');
 ok(!$item->{profile_baseline_needs_restore},'no baseline restore without a 1D result');
}

# An unverified 1D upload is not a result to keep.
{
 grey_state(3,{status=>'complete'});
 my $item=item(failure=>{stage=>'volume-done',message=>'x',at=>2});
 main::_prepare_resume(3,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified)],'an unverified 1D upload resets from the calibration start');
}

# Failures before the greyscale finished still reset everything.
{
 grey_state(4,{status=>'complete',ddc_upload_verified=>JSON::PP::true});
 my $item=item(failure=>{stage=>'greyscale-done',message=>'x',at=>2});
 $item->{checkpoints}=[grep { $_->{name} !~ /^greyscale/ } @{$item->{checkpoints}}];
 main::_prepare_resume(4,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified)],'a greyscale failure resets from the calibration start');
}

# A pending drift recovery keeps the full reset regardless of the stage.
{
 grey_state(5,{status=>'complete',ddc_upload_verified=>JSON::PP::true});
 my $item=item(failure=>{stage=>'volume-done',message=>'x',at=>2},drift_recovery_pending=>1);
 main::_prepare_resume(5,$item,1);
 is_deeply(names($item),[qw(item-started tv-setup-verified)],'drift recovery resets from the calibration start');
}

done_testing();
