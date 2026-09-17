use strict;
use warnings;
no warnings qw(once redefine);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Test::More;
use lib "$Bin/../usr/share/PGenerator";
require "$Bin/../usr/share/PGenerator/lg.pm";
my $dir=tempdir(CLEANUP=>1);
make_path(map {"$dir/$_"} qw(runs/run-1 luts history/dv history/1d));
sub save {
 my ($path,$data)=@_;open my $f,'>',"$dir/$path" or die $!;
 print {$f} main::lg_encode_json($data);close $f;
}
my $measurements={white_luminance=>700,red_x=>.68};
save('runs/run-1/dv-profile-measurements.json',$measurements);
save('runs/run-1/manifest.json',{config=>{picture_mode=>'dolbyVisionFilmMaker',signal_mode=>'dv'}});
save('history/dv/archived.json',{picture_mode=>'dolbyVisionFilmMaker',measurements=>$measurements});
save('history/1d/archived.json',{picture_mode=>'dolbyVisionFilmMaker',signal_mode=>'dv',dpg_data=>[(0)x3072]});
save('luts/archived.json',{picture_mode=>'hdrFilmMaker',signal_mode=>'hdr10'});
open my $bin,'>',"$dir/luts/archived.bin" or die $!;print {$bin} 'fixture';close $bin;
# Rebind only fixed archive roots for the production dispatch function, not
# its control flow. The helper implementation and JSON readers are unmodified.
open my $source,'<',"$Bin/../usr/share/PGenerator/lg.pm" or die $!;
my $text=do {local $/;<$source>};close $source;
my ($dispatch)=$text=~/(sub webui_lg_calibration_history_reupload\s*\(\@\)\s*\{.*?)(?=\nsub webui_lg_api)/s;
die 'History dispatcher not found' if !$dispatch;
eval 'package main; {my $_lg_cal_hist_runs=q{'.$dir.'/runs};my $_lg_cal_hist_luts=q{'.$dir.'/luts};my $_lg_cal_hist_dir=q{'.$dir.'/history};'.$dispatch.'}';die $@ if $@;
my (@calls,$entry,$exit,$upload,$entry_throw,$exit_throw,$upload_throw);
local *main::webui_lg_calibration_mode=sub {
 my $body=main::lg_decode_json($_[0]);push @calls,$body->{enabled}?'enter':'exit';
 die "Entry transport exception\n" if $body->{enabled} && $entry_throw;
 die "Exit transport exception\n" if !$body->{enabled} && $exit_throw;
 return main::lg_encode_json($body->{enabled}?$entry:$exit);
};
my $upload_stub=sub {push @calls,'upload';die "Upload transport exception\n" if $upload_throw;return main::lg_encode_json($upload);};
local *main::webui_lg_3d_lut_upload=$upload_stub;
local *main::webui_lg_dv_profile_upload=$upload_stub;
local *main::webui_lg_1d_dpg_upload=$upload_stub;
sub fixture {
 @calls=();($entry_throw,$exit_throw,$upload_throw)=(0,0,0);
 $entry={status=>'ok',calibration_mode=>1};$exit={status=>'ok',calibration_mode=>0};$upload={status=>'ok',message=>'Upload accepted'};
}
sub restore {my ($id,$options)=@_;my $result=eval {main::lg_decode_json(main::webui_lg_calibration_history_reupload(main::lg_encode_json({id=>$id,%{$options||{}}})))};return $result||{status=>'error',message=>$@||'Missing result'};}
for my $id ('3d:archived','dvfile:archived','dv:run-1','1dfile:archived') {
 fixture();is(restore($id)->{status},'ok',"$id succeeds with acknowledged entry/upload/exit");
 is_deeply(\@calls,[qw(enter upload exit)],"$id uses ordered bookends");
 for my $bad ({status=>'error',message=>'CAL_START rejected'}, {status=>'ok'}, {status=>'ok',calibration_mode=>0}) {
  fixture();$entry=$bad;
  is(restore($id)->{status},'error',"$id rejects absent calibration-entry acknowledgement");
  is_deeply(\@calls,[qw(enter exit)],"$id never uploads after failed entry and attempts cleanup");
 }
 fixture();$entry_throw=1;
 like(restore($id)->{message},qr/Entry transport exception/,"$id preserves entry exception");
 is_deeply(\@calls,[qw(enter exit)],"$id does not upload after entry exception");
 fixture();$upload_throw=1;
 like(restore($id)->{message},qr/Upload transport exception/,"$id preserves upload exception");
 is_deeply(\@calls,[qw(enter upload exit)],"$id upload exception cannot skip cleanup");
 fixture();$exit={status=>'error',message=>'CAL_END rejected'};
 is(restore($id)->{error_code},'calibration-exit-unconfirmed',"$id does not report success after failed exit");
 fixture();$exit_throw=1;
 is(restore($id)->{error_code},'calibration-exit-unconfirmed',"$id exit exception is visible");
 fixture();$upload={status=>'error',message=>'Upload rejected'};
 is(restore($id)->{status},'error',"$id successful exit does not hide upload failure");
}
# Explicit caller-managed bookends remain available for 3D/DV uploads.
for my $options ({enable_calibration=>0,disable_calibration=>0},{disable_calibration=>0},{enable_calibration=>0}) {
 fixture();is(restore('dvfile:archived',$options)->{status},'ok','successful caller-managed session is preserved');
 my @expected=(($options->{enable_calibration}//1)?'enter':(),'upload',($options->{disable_calibration}//1)?'exit':());
 is_deeply(\@calls,\@expected,'only requested successful bookends are executed');
}
done_testing();
