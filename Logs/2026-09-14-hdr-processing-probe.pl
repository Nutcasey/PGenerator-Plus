use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP;
use lib '/usr/share/PGenerator';
use PGAutomationProcessing ();
my $guard=grep {$_ eq '--guard'} @ARGV;
my $path='/var/lib/PGenerator/automation/runs/20260913-225541-73ee6d/run.json';
open my $fh,'<',$path or die $!;my $r=decode_json(do{local $/;<$fh>});close $fh;
die 'Batch must be interrupted' unless $r->{status} eq 'interrupted';
die 'Wrong mode' unless $r->{items}[4]{picture_mode} eq 'hdrCinema';
my $http=HTTP::Tiny->new(timeout=>60);
sub call {
 my ($path,$body)=@_;
 my $resp=$http->post('http://127.0.0.1'.$path,{headers=>{'content-type'=>'application/json'},content=>encode_json({%$body,automation_token=>$r->{token}})});
 die "HTTP $resp->{status}" unless $resp->{success};
 my $d=decode_json($resp->{content});
 die($d->{message}||'API failed') unless $d->{status} eq 'ok';
 return $d;
}
sub read_settings {
 my ($label)=@_;
 my $d=call('/api/lg/picture-settings',{keys=>[qw(pictureMode smoothGradation brightness contrast)],picture_mode=>'hdrCinema',signal_mode=>'hdr10',category=>'picture'});
 print encode_json({label=>$label,settings=>$d->{picture_settings},unsupported=>$d->{unsupported_picture_keys}}),"\n";
 return $d->{picture_settings};
}
call('/api/lg/connect',{});
my $before=read_settings('before-cal-start');
die 'Baseline is not Off' unless $before->{smoothGradation} eq 'off';
my $error;
eval {
 call('/api/lg/calibration-mode',{enabled=>JSON::PP::true,picture_mode=>'hdrCinema',signal_mode=>'hdr10'});
 read_settings('after-cal-start');
 1;
} or $error=$@;
my $end=call('/api/lg/calibration-mode',{enabled=>JSON::PP::false,picture_mode=>'hdrCinema',signal_mode=>'hdr10'});
print encode_json({label=>'cal-end',calibration_mode=>$end->{calibration_mode}}),"\n";
my $after=read_settings('after-cal-end');
if($guard) {
 my $state={};
 PGAutomationProcessing::enforce({picture_mode=>'hdrCinema',signal_mode=>'hdr10',automation_processing_settings=>{map {$_=>$r->{items}[4]{settings}{$_}} grep {/^(?:smoothGradation|noiseReduction|mpegNoiseReduction|superResolution|sharpness|realCinema)$/} keys %{$r->{items}[4]{settings}}}},$state,1,sub {
  my ($method,$path,$body)=@_;
  return call($path,$body) if $method eq 'POST';
  my $resp=$http->get('http://127.0.0.1'.$path);
  die "HTTP $resp->{status}" unless $resp->{success};
  return decode_json($resp->{content});
 },sub {print $_[0],"\n"});
 print encode_json({guard_checks=>scalar @{$state->{automation_processing_checks}||[]},warnings=>$state->{automation_processing_warnings},verified_epoch=>$state->{automation_processing_epoch}}),"\n";
 read_settings('guard-restored-requested-off');
} elsif($after->{smoothGradation} ne 'off') {
 call('/api/lg/picture-settings/set',{settings=>{smoothGradation=>'off'},readback_keys=>[qw(pictureMode smoothGradation)],picture_mode=>'hdrCinema',signal_mode=>'hdr10',category=>'picture',keep_calibration_mode=>JSON::PP::false,calibration_mode_active=>JSON::PP::false});
 read_settings('restored-requested-off');
}
die $error if $error;
