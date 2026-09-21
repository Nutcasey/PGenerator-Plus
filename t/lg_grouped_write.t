use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP;
use Test::More;

ok(defined(do "$Bin/../usr/sbin/pgenerator-lg"),'LG helper loads') or die $@;
my (%tv,@requests,@events,$connections,$closed,$scenario,$written);
local *main::lg_authenticated_session=sub {
 ++$connections;
 return {status=>'ok',session=>{id=>$connections},client_key=>'fixture',
  system_info=>{modelName=>'OLED55G36LA'},
  software_info=>{model_name=>'HE_DTV_W23O_AFABATAA',product_name=>'webOSTV 23',software_version=>'23.25.55'},
  hello_info=>{deviceOSReleaseVersion=>'9.2.2',deviceUUID=>'grouped-write-fixture'}};
};
local *main::websocket_close=sub {++$closed};
local *main::diag_log_append=sub {push @events,{label=>$_[0],data=>$_[1]}};
local *main::lg_request=sub {
 my ($session,$label,$path,$payload)=@_;
 die 'request on a closed session' if $closed;
 push @requests,{session=>$session->{id},label=>$label,path=>$path,payload=>$payload};
 if($path eq 'settings/setSystemSettings') {
  my $values=$payload->{settings};
  my $bulk=keys(%$values)>1;
  die "simulated socket exception\n" if $scenario eq 'exception';
  return {type=>'error',error=>'TV refused grouped request'} if $scenario eq 'refused' && $bulk;
  return {type=>'error',error=>'TV refuses contrast'} if $scenario eq 'single-refused' && exists($values->{contrast}) && !$bulk;
  for my $key (keys %$values) {
   next if $scenario =~ /^(partial|single-refused)$/ && $bulk && $key eq 'contrast';
   $tv{$key}=$values->{$key};
  }
  $written=1;
  return {type=>'response',payload=>{returnValue=>JSON::PP::true}};
 }
 if($path eq 'settings/getSystemSettings') {
  my @keys=@{$payload->{keys}||[]};
  @keys=grep {$_ ne 'contrast'} @keys if ($scenario eq 'missing' && $written)
   || ($scenario eq 'omitted' && @keys>1);
  return {type=>'response',payload=>{settings=>{map {$_=>$tv{$_}} grep {exists $tv{$_}} @keys}}};
 }
 die "unexpected route $path";
};

# Exercise the full helper workflow against a changing transport model. Each
# scenario has a fresh capability store so earlier refusal evidence cannot
# change a later scenario's preflight policy.
for my $case (qw(ordinary special refused partial single-refused missing omitted invalid blocked exception)) {
 local $ENV{PGENERATOR_LG_CAPABILITY_STORE}=tempdir(CLEANUP=>1);
 $scenario=$case;
 %tv=(brightness=>49,contrast=>84,color=>49,backlight=>50,hdrDynamicToneMapping=>'on');
 @requests=();@events=();$connections=0;$closed=0;$written=0;
 my $values={brightness=>50,contrast=>85,color=>50};
 if($case eq 'special') { $values->{hdrDynamicToneMapping}='off';$values->{backlight}=50; }
 $values->{contrast}=101 if $case eq 'invalid';
 $values->{truMotionMode}='off' if $case eq 'blocked';
 my $result=eval {main::lg_picture_set_workflow('fixture','fixture',1,$values,[],
  'hdmi1',0,'hdrCinema',0,0,0,0,'hdr10','picture')};
 my $error=$@;
 my @writes=grep {$_->{path} eq 'settings/setSystemSettings'} @requests;
 my @write_keys=map {[sort keys %{$_->{payload}{settings}}]} @writes;
 my @reads=grep {$_->{path} eq 'settings/getSystemSettings'} @requests;
 is($connections,1,"$case authenticates once");
 is($closed,1,"$case closes exactly once");
 ok(!grep({$_->{session}!=1} @requests),"$case uses the original session for every operation");
 if($case eq 'exception') {
  like($error,qr/simulated socket exception/,'exception propagates after closing the session');
  next;
 }
 is($error,'',"$case completes without an exception");
 if($case =~ /^(invalid|blocked)$/) {
  is($result->{status},'error',"$case batch is refused");
  is(scalar(@writes),0,"$case batch cannot partially write other controls");
  next;
 }
 if($case eq 'single-refused' || $case eq 'missing') {
  is($result->{status},'error',"$case cannot report success");
  is($result->{failed_setting_key},'contrast',"$case identifies failed control");
  is($result->{setting_verification}{brightness}{status},'verified',"$case retains earlier brightness verification");
  is($result->{setting_verification}{color}{status},'verified',"$case retains earlier colour verification");
  isnt($result->{setting_verification}{contrast}{status}||'','verified',"$case does not inherit stale contrast verification");
  is_deeply(\@write_keys,[[qw(brightness color contrast)],['contrast']],"$case retries only the unverified control");
  next;
 }
 is($result->{status},'ok',"$case succeeds");
 is($result->{verification_state},'verified',"$case is verified");
 for my $key (keys %$values) {
  is($result->{setting_verification}{$key}{status},'verified',"$case verifies $key individually");
  is($result->{picture_settings}{$key},$values->{$key},"$case returns observed $key");
 }
 if($case eq 'ordinary') {
  is_deeply(\@write_keys,[[qw(brightness color contrast)]],'three compatible controls share one write');
  is(scalar(@reads),1,'one grouped read verifies all three controls');
  my @saved=grep {$_->{label} eq 'settings:observations' && $_->{data}{saved}} @events;
  is(scalar(@saved),1,'write and verification evidence share one transaction');
  is($saved[0]{data}{records},6,'all three acknowledgements and comparisons are persisted');
  is_deeply($writes[0]{payload}{dimension},{input=>'hdmi1',pictureMode=>'hdrCinema',_3dStatus=>'2d'},'bulk write keeps the exact input and mode scope');
  is_deeply($reads[0]{payload}{dimension},$writes[0]{payload}{dimension},'verification uses the accepted write scope');
 } elsif($case eq 'special') {
  is_deeply(\@write_keys,[[qw(brightness color contrast)],['backlight'],['hdrDynamicToneMapping']],
   'panel light and individual-access tone mapping retain separate writes');
 } elsif($case eq 'refused') {
  is_deeply(\@write_keys,[[qw(brightness color contrast)],['brightness'],['color'],['contrast']],
   'refused group falls back individually on the same session');
 } elsif($case eq 'partial') {
  is_deeply(\@write_keys,[[qw(brightness color contrast)],['contrast']],
   'partially accepted group retries only the mismatch');
  my ($event)=grep {$_->{label} eq 'picture_set:grouped-fallback'} @events;
  is($event->{data}{verified},2,'fallback logs how many controls already verified');
  is_deeply($event->{data}{retry_keys},['contrast'],'fallback names only the retried key');
 } elsif($case eq 'omitted') {
  is_deeply(\@write_keys,[[qw(brightness color contrast)]],'omitted grouped readback does not cause a rewrite');
  is_deeply([map {$_->{payload}{keys}} @reads],[[qw(brightness color contrast)],['contrast']],
   'only the omitted key gets an individual read');
 }
 my ($session_event)=grep {$_->{label} eq 'picture_set:session-complete'} @events;
 ok(defined($session_event->{data}{duration_ms}),'session duration has explicit millisecond units');
}

done_testing();
