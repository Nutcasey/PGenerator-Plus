# Read-only artifact audit. Does not contact or change the TV. Run on the Pi.
use strict;
use warnings;
use JSON::PP;
use File::Basename qw(basename);
use lib '/usr/share/PGenerator';
use PGAutomationProcessing ();
my $id=shift||'20260913-225541-73ee6d';
die 'Invalid run id' unless $id=~/^[A-Za-z0-9_-]+$/;
my $dir="/var/lib/PGenerator/automation/runs/$id";
sub read_json {
 my ($p)=@_;open my $f,'<',$p or die "Cannot read $p: $!";
 return decode_json(do {local $/;<$f>});
}
my $r=read_json("$dir/run.json");
my @problems;my @results;
push @problems,'Batch has not completed' unless ($r->{status}||'') eq 'complete';
push @problems,'Batch has a failure' if $r->{failure};
push @problems,'Expected six jobs' unless @{$r->{items}||[]}==6;
my %expected=map {$_=>1} qw(cinema filmMaker hdrCinema hdrFilmMaker dolbyVisionFilmMaker dolbyVisionCinemaBright);
my %seen;
for my $n (0..$#{$r->{items}}) {
 my $i=$r->{items}[$n];my @errors;
 my $mode=$i->{picture_mode}||'';
 push @errors,'Unexpected/duplicate picture mode' unless $expected{$mode} && !$seen{$mode}++;
 push @errors,'Job not complete' unless ($i->{status}||'')=~/^complete(?:-with-warnings)?$/;
 push @errors,'Job retains failure' if $i->{failure};
 push @errors,'Target is not 0.5' unless ($i->{calibration}{target_delta_e}||0)==0.5;
 push @errors,'Unexpected selected stages' unless $i->{stages}{calibration} && !$i->{stages}{pre_readings} && !$i->{stages}{post_readings};
 my %cp=map {$_->{name}=>$_} @{$i->{checkpoints}||[]};
 for my $name (qw(pre-readings-done post-readings-done)) {
  push @errors,"Optional stage was not skipped: $name" unless ($cp{$name}{status}||'') eq 'skipped';
 }
 for my $name (qw(tv-setup-verified reset-and-reapply-verified panel-light-settled greyscale-done greyscale-settings-verified volume-done volume-settings-verified session-closed item-complete)) {
  push @errors,"Missing completed $name" unless ($cp{$name}{status}||'') eq 'done';
 }
 my $cal="$dir/items/$n/calibration";
 my $g=eval {read_json("$cal/grey-state.json")};
 push @errors,'Missing completed, verified 1D artifact' unless $g && $g->{status} eq 'complete' && ($g->{ddc_upload_verified}||$g->{final_1d_lut_upload_verified}) && @{$g->{readings}||[]};
 my ($profile,$profile_count);
 if(($i->{signal_format}||'') eq 'dv') {
  $profile=eval {read_json("$cal/dv-profile-state.json")};
  my $upload=eval {read_json("$cal/dv-profile-upload.json")};
  my $m=$profile->{measurements}||{};
  push @errors,'Missing completed DV profile/upload' unless $profile && ($profile->{status}||'') eq 'complete' && ($upload->{status}||'') eq 'ok';
  push @errors,'Missing DV measurements' unless ($m->{white_luminance}||0)>0 && defined($m->{black_luminance}) && !grep {!defined($m->{$_})} qw(red_x red_y green_x green_y blue_x blue_y);
  $profile_count=scalar keys %$m;
 } else {
  $profile=eval {read_json("$cal/3d-state.json")};
  push @errors,'Missing completed, verified 3D artifact' unless $profile && ($profile->{status}||'') eq 'complete' && $profile->{upload_verified} && $profile->{terminal_commit_verified};
  for my $key (qw(cube_path payload_path)) {
   my $source=$profile->{export}{$key}||'';
   push @errors,"Missing $key export" unless $source && -s "$cal/".basename($source);
  }
  $profile_count=scalar @{$profile->{readings}||[]};
  push @errors,'Profile has no readings' unless $profile_count;
 }
 my %final;
 if(open my $fh,'<',"$dir/items/$n/settings-checks.ndjson") {
  while(my $line=<$fh>) {
   my $c=decode_json($line);
   next unless ($c->{checkpoint}||'')=~/^c8(?:-confirm|-repair|-stable)?$/ && ($c->{operation}||'') ne 'write';
   $final{$c->{key}}=$c;
  }
  close $fh;
 }
 for my $key (keys %{$i->{settings}||{}},'pictureMode') {
  my $c=$final{$key};
  my $want=$key eq 'pictureMode'?$mode:$i->{settings}{$key};
  # Actual selectors used by pgenerator-lg, not an Auto/Wide-style guess.
  my %wire=(dolbyVisionFilmMaker=>'dolbyHdrCinema',dolbyVisionCinemaBright=>'dolbyHdrCinemaBright');
  my $wire_want=$key eq 'pictureMode'?($wire{$want}||$want):$want;
  my $matched=$c && $c->{verified} && PGAutomationProcessing::agrees($wire_want,$c->{observed},$key);
  my $managed=$c && $key eq 'colorGamut' && ($c->{result}||'') eq 'lut-managed' && $want eq 'auto' && $c->{observed} eq 'wide';
  push @errors,"Final setting unverified: $key" unless $c && PGAutomationProcessing::agrees($want,$c->{expected},$key) && ($matched||$managed);
 }
 push @results,{job=>$n+1,name=>$i->{name},status=>$i->{status},grey_readings=>scalar @{$g->{readings}||[]},profile_values=>$profile_count,final_controls=>scalar keys %final,warnings=>$i->{warnings}||[],errors=>\@errors};
 push @problems,map {'Job '.($n+1).': '.$_} @errors;
}
print JSON::PP->new->canonical->pretty->encode({run=>$id,status=>$r->{status},complete=>@problems?JSON::PP::false:JSON::PP::true,problems=>\@problems,jobs=>\@results});
exit(@problems?1:0);
