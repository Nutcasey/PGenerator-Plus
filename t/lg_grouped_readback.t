#!/usr/bin/perl
# Picture-settings readbacks read every requested key in one grouped call
# and fall back to single-key reads only for keys the grouped reply omitted
# or when the grouped call fails. Reading contract-flagged keys one at a
# time up front cost a TV round trip per key (26-60 s per readback on the
# G3, 18 Sep 2026).
use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;

my $helper="$Bin/../usr/sbin/pgenerator-lg";
my $loaded=do $helper;
ok(defined($loaded),'LG helper loads') or BAIL_OUT($@);

my $store=tempdir(CLEANUP=>1);
local $ENV{PGENERATOR_LG_CAPABILITY_STORE}=$store;

my $g3=main::lg_generation_info(
 { modelName=>'OLED55G36LA' },
 { model_name=>'HE_DTV_W23O_AFABATAA', product_name=>'webOSTV 23', software_version=>'23.25.55',device_id=>'aa:bb:cc:dd:ee:ff' },
 { deviceOSReleaseVersion=>'9.2.2',deviceUUID=>'grouped-g3' },
);
my $resolved=PGLGCapabilities::resolve_lg_capabilities($g3);
my @wire_keys=sort map { $_->{wire_key}||() } values %{$resolved->{data}{settings}{controls}||{}};
my $matrix=main::lg_setting_contracts($g3,keys=>\@wire_keys,signal_mode=>'hdr10',picture_mode=>'hdrCinema',tv_input=>'hdmi1',category=>'picture');
my @individual=sort grep { $_ ne 'pictureMode' && (($matrix->{contracts}{$_}{read}{access}||'') eq 'individual') } keys %{$matrix->{contracts}};
ok(scalar(@individual) >= 2,'the G3 contract flags keys for individual reads') or BAIL_OUT('no individually flagged keys to test');
my @keys=('brightness',@individual[0,1]);

local *main::lg_authenticated_session=sub {{
 status=>'ok',session=>{},client_key=>'test-key',
 system_info=>{modelName=>'OLED55G36LA'},
 software_info=>{model_name=>'HE_DTV_W23O_AFABATAA',product_name=>'webOSTV 23',software_version=>'23.25.55',device_id=>'aa:bb:cc:dd:ee:ff'},
 hello_info=>{deviceOSReleaseVersion=>'9.2.2',deviceUUID=>'grouped-g3'},
}};
local *main::websocket_close=sub {};

my @requests;
my $reply_all=sub {
 my ($session,$label,$path,$payload)=@_;
 push(@requests,{label=>$label,path=>$path,payload=>$payload});
 return {type=>'response',payload=>{settings=>{map { $_=>"value-$_" } @{$payload->{keys}||[]}}}}
  if($path eq 'settings/getSystemSettings');
 return {type=>'response',payload=>{}};
};

{
 @requests=();
 local *main::lg_request=$reply_all;
 my $read=main::lg_picture_get_workflow('127.0.0.1','test-key',1,[@keys],'hdrCinema','hdmi1',0,'hdr10',0,'picture');
 is($read->{status},'ok','grouped read succeeds');
 my @grouped=grep { $_->{label} eq 'get_picture_settings' } @requests;
 is(scalar(@grouped),1,'exactly one grouped picture read');
 my %asked=map { $_=>1 } @{$grouped[0]{payload}{keys}||[]};
 ok($asked{$_},"$_ is asked for in the grouped call") for @keys;
 my @singles=grep { $_->{label} =~ /^get_picture_setting_/ } @requests;
 is(scalar(@singles),0,'no single-key reads when the grouped reply carries every key') or diag(join(',',map { $_->{label} } @singles));
 is($read->{picture_settings}{$_},"value-$_","$_ value comes from the grouped reply") for @keys;
}

{
 @requests=();
 my $omitted=$individual[0];
 local *main::lg_request=sub {
  my ($session,$label,$path,$payload)=@_;
  push(@requests,{label=>$label,path=>$path,payload=>$payload});
  if($label eq 'get_picture_settings') {
   return {type=>'response',payload=>{settings=>{map { $_=>"value-$_" } grep { $_ ne $omitted } @{$payload->{keys}||[]}}}};
  }
  return {type=>'response',payload=>{settings=>{map { $_=>"single-$_" } @{$payload->{keys}||[]}}}}
   if($path eq 'settings/getSystemSettings');
  return {type=>'response',payload=>{}};
 };
 my $read=main::lg_picture_get_workflow('127.0.0.1','test-key',1,[@keys],'hdrCinema','hdmi1',0,'hdr10',0,'picture');
 is($read->{status},'ok','read with one omitted key succeeds');
 my @singles=grep { $_->{label} =~ /^get_picture_setting_/ } @requests;
 is_deeply([map { $_->{label} } @singles],["get_picture_setting_$omitted"],'only the omitted key is read on its own');
 is($read->{picture_settings}{$omitted},"single-$omitted",'the omitted key takes the single-read value');
 is($read->{picture_settings}{brightness},'value-brightness','keys the grouped reply carried are not re-read');
}

{
 @requests=();
 local *main::lg_request=sub {
  my ($session,$label,$path,$payload)=@_;
  push(@requests,{label=>$label,path=>$path,payload=>$payload});
  return {type=>'error',error=>'grouped read refused'} if($label eq 'get_picture_settings');
  return {type=>'response',payload=>{settings=>{map { $_=>"single-$_" } @{$payload->{keys}||[]}}}}
   if($path eq 'settings/getSystemSettings');
  return {type=>'response',payload=>{}};
 };
 my $read=main::lg_picture_get_workflow('127.0.0.1','test-key',1,[@keys],'hdrCinema','hdmi1',0,'hdr10',0,'picture');
 is($read->{status},'ok','a refused grouped read still completes through single reads');
 my @singles=sort map { $_->{label} } grep { $_->{label} =~ /^get_picture_setting_/ } @requests;
 is_deeply(\@singles,[sort map { "get_picture_setting_$_" } @keys],'every key is read on its own after a refused grouped call');
 is($read->{picture_settings}{$_},"single-$_","$_ value comes from its single read") for @keys;
}

done_testing();
