#!/usr/bin/perl
use strict;
use warnings;
no warnings 'redefine';
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use JSON::PP ();
use Fcntl qw(:flock);
use Time::HiRes ();
use lib "$Bin/../usr/share/PGenerator";
use PGLGCapabilities qw(lg_record_setting_observation lg_record_setting_observations);

my $store=tempdir(CLEANUP=>1);
my $identity={device_uuid=>'batch-tv',series=>'G3',platform_model=>'W23O',software_version=>'fixture'};
my $context={signal_mode=>'sdr',picture_mode=>'filmMaker',tv_input=>'hdmi4'};
my @observations=(
 {key=>'brightness',operation=>'read',result=>{status=>'supported',route=>'ssap.settings',value_type=>'scalar'}},
 {key=>'brightness',operation=>'write',result=>{status=>'acknowledged',route=>'ssap.settings'}},
 {key=>'brightness',operation=>'verify',result=>{status=>'mismatch',reason=>'Different value'}},
 {key=>'contrast',operation=>'verify',result=>{status=>'unavailable',reason=>'Missing readback'}},
);
my ($saved,$reads);
{
 my $read=\&PGLGCapabilities::_read_observation_document;
 local *PGLGCapabilities::_read_observation_document=sub {$reads++;$read->(@_)};
 $saved=lg_record_setting_observations($identity,$context,\@observations,store_root=>$store);
}
ok($saved->{ok},'mixed bulk evidence is saved');
is($reads,1,'one document transaction for the whole reply');
sub document {
 open my $fh,'<',$saved->{path} or die $!;
 local $/;return JSON::PP::decode_json(<$fh>);
}
my $settings=document()->{contexts}{$saved->{context_hash}}{settings};
is($settings->{brightness}{read}{value_type},'scalar','read evidence retained');
is($settings->{brightness}{verify}{status},'mismatch','a mismatch remains distinct from acknowledgement');
is($settings->{contrast}{verify}{reason},'Missing readback','missing evidence retains its reason');
my $before=document();
my $invalid=lg_record_setting_observations($identity,$context,[@observations,{key=>'gamma',operation=>'invalid',result=>{}}],store_root=>$store);
is($invalid->{error},'invalid-observation','invalid batch rejected');
is_deeply(document(),$before,'no partial update on invalid batch');
for my $ctx ({%$context,context_confirmed=>0},{picture_mode=>'filmMaker',signal_mode=>'sdr'}) {
 is(lg_record_setting_observations($identity,$ctx,\@observations,store_root=>$store)->{error},'context-unconfirmed','unconfirmed context cannot teach later operations');
}
is(lg_record_setting_observations({},$context,\@observations,store_root=>$store)->{error},'device-identity-unavailable','unknown device cannot receive reusable evidence');
my $other=lg_record_setting_observations($identity,{%$context,tv_input=>'hdmi1'},\@observations,store_root=>$store);
isnt($other->{context_hash},$saved->{context_hash},'other input has separate evidence');

# Exercise real simultaneous processes, including a legacy single-key caller.
my @children;
for (1..3) {
 my $pid=fork();die "fork: $!" if !defined $pid;
 if(!$pid) {
  for (1..4) {
   my $result=lg_record_setting_observations($identity,$context,\@observations,store_root=>$store);
   exit 1 if !$result->{ok};
  }
  exit 0;
 }
 push @children,$pid;
}
ok(lg_record_setting_observation($identity,$context,'brightness','read',{status=>'supported'},store_root=>$store)->{ok},'single observation API still works alongside bulk writers');
for (@children) {waitpid($_,0);is($?,0,'concurrent bulk writer finished')}
$settings=document()->{contexts}{$saved->{context_hash}}{settings};
is($settings->{brightness}{read}{count},14,'concurrent and legacy counts are all retained');
is($settings->{brightness}{write}{count},13,'each batch contributes once');
is(document()->{contexts}{$other->{context_hash}}{settings}{brightness}{read}{count},1,'concurrent changes do not cross inputs');

# A failed atomic replacement must leave the previous evidence intact.
$before=document();
{
 open(my $lock,'>>',$saved->{path}.'.lock') or die $!;
 flock($lock,LOCK_EX) or die $!;
 my $start=Time::HiRes::time();
 my $blocked=lg_record_setting_observations($identity,$context,\@observations,store_root=>$store,lock_timeout=>.1);
 is($blocked->{error},'observation-lock-failed','contended observation lock returns a bounded failure');
 cmp_ok(Time::HiRes::time()-$start,'<',1,'lock contention does not strand the helper');
 is_deeply(document(),$before,'timeout leaves earlier evidence unchanged');
 close($lock);
 ok(lg_record_setting_observations($identity,$context,\@observations,store_root=>$store)->{ok},'observation writes recover after the lock is released');
}
$before=document();
mkdir($saved->{path}.'.tmp.'.$$) or die $!;
my $failed=lg_record_setting_observations($identity,$context,\@observations,store_root=>$store);
is($failed->{error},'observation-write-failed','storage failure is explicit');
is_deeply(document(),$before,'failed replacement preserves the previous document');
done_testing();
