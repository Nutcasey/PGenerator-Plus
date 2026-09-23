#!/usr/bin/perl
# A resume that reacquired a RELEASED TV claim cannot trust its saved
# calibration checkpoints: another run may have calibrated the same TV while
# this job was interrupted, so the installed LUT is no longer proof of this
# job's result. The WebUI marks such a resume with item->{resume_recalibrate};
# _prepare_resume must then recalibrate from reset rather than keep the
# committed 1D/profile and skip straight to Apply to All (which would copy the
# other run's installed LUT as this job's result). Same input, the flag flips
# keep into reset -- these are the properties that keep that working.
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
{ local @ARGV=('recal-test','test-token'); local $SIG{__WARN__}=sub {}; do "$Bin/../usr/bin/pgen_automation_runner.pl"; die $@ if $@; }
my @actions;
local *main::_log=sub {};
local *main::_log_action=sub { push(@actions,$_[0]); };

# A session-closed failure with verified 1D + profile artifacts -- the case
# that, held continuously, keeps both upload checkpoints.
sub grey_state {
 my ($number)=@_;
 my $dir=PGAutomation::item_dir('recal-test',$number).'/calibration';
 make_path($dir);
 open(my $g,'>',"$dir/grey-state.json") or die $!;
 print {$g} JSON::PP->new->encode({status=>'complete',ddc_upload_verified=>JSON::PP::true,hdr20_1d_dpg_data=>[(0) x 3072]});
 close($g);
 for my $name (qw(profile.cube profile.bin)) { open(my $fh,'>',"$dir/$name") or die $!; print {$fh} 'x'; close($fh); }
 open(my $t,'>',"$dir/3d-state.json") or die $!;
 print {$t} JSON::PP->new->encode({status=>'complete',upload_verified=>JSON::PP::true,
  export=>{cube_path=>'/var/lib/PGenerator/lg/luts/profile.cube',payload_path=>'/var/lib/PGenerator/lg/luts/profile.bin'}});
 close($t);
}
sub session_closed_item {
 my (%extra)=@_;
 my @order=qw(item-started tv-setup-verified reset-and-reapply-verified panel-light-settled
  greyscale-done greyscale-settings-verified volume-done volume-settings-verified);
 return {name=>'Job',signal_format=>'hdr10',picture_mode=>'hdrCinema',settings=>{},
  failure=>{stage=>'session-closed',message=>'x',at=>2},
  checkpoints=>[map { {name=>$_,status=>'done',at=>1} } @order],%extra};
}
sub names { [map { $_->{name} } @{$_[0]{checkpoints}}] }

# Without the flag this input keeps the verified profile (the hazard).
grey_state(0);
my $kept=session_closed_item();
main::_prepare_resume(0,$kept,1);
is_deeply(names($kept),
 [qw(item-started tv-setup-verified reset-and-reapply-verified panel-light-settled greyscale-done greyscale-settings-verified volume-done volume-settings-verified)],
 'without the reacquire flag, a verified session-closed profile is kept (baseline behavior)');

# With the flag, the same input recalibrates from reset instead.
grey_state(1);
@actions=();
my $reacq=session_closed_item(resume_recalibrate=>JSON::PP::true);
main::_prepare_resume(1,$reacq,1);
is_deeply(names($reacq),[qw(item-started tv-setup-verified)],
 'a reacquired-TV resume recalibrates from reset, dropping the committed calibration checkpoints');
ok(!exists($reacq->{resume_recalibrate}),'and the one-shot reacquire flag is consumed');
like(join("\n",@actions),qr/released to another run|recalibrat/i,'and the log says why the calibration restarts');

done_testing();
