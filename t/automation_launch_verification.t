use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Fcntl qw(:flock);
use Test::More;
use Time::HiRes ();
use lib "$Bin/../usr/share/PGenerator";
use PGAutomation ();
use PGAutomationLaunch ();
require "$Bin/../usr/share/PGenerator/webui.pm";

local $ENV{PGEN_AUTOMATION_DIR}=tempdir(CLEANUP=>1);
local $ENV{PERL5LIB}="$Bin/../usr/share/PGenerator";
PGAutomation::ensure_store();
my $fixture_dir=tempdir(CLEANUP=>1);
my $fixture="$fixture_dir/pgen_automation_runner.pl";
open my $fh,'>',$fixture or die $!;
print $fh <<'WORKER';
use strict;
use warnings;
use Fcntl qw(:flock);
use Time::HiRes ();
use PGAutomation ();
use PGAutomationLaunch ();
my ($id,$token,$attempt)=@ARGV;
my $dir=PGAutomation::run_dir($id);
my $mode=$ENV{PGEN_LAUNCH_TEST_MODE}||'';
exit 3 if $mode eq 'exit';
Time::HiRes::sleep(0.7) if $mode eq 'delay';
my $run=PGAutomation::read_json_file("$dir/run.json");
exit 4 unless ref($run) eq 'HASH' && ($run->{token}||'') eq $token;
open my $lock,'>>',PGAutomation::base_dir().'/runner.lock' or die $!;
exit 5 unless flock($lock,LOCK_EX|LOCK_NB);
exit 6 unless PGAutomationLaunch::worker_handshake($id,$token,$attempt);
PGAutomation::write_atomic("$dir/device-command.marker","accepted\n") or die $!;
WORKER
close $fh;
local $PGAutomationLaunch::RUNNER_PATH=$fixture;
local $PGAutomationLaunch::PERL_PATH=$^X;
local $PGAutomationLaunch::START_TIMEOUT=2;
my $counter=0;
sub setup {
 my $id='launch-test-'.++$counter;
 make_path(PGAutomation::run_dir($id));
 PGAutomation::write_json_atomic(PGAutomation::run_dir($id).'/run.json',
  {id=>$id,token=>'test-token',status=>'starting',runner_pid=>0,items=>[]});
 PGAutomation::write_json_atomic(PGAutomation::run_dir($id).'/control.json',{request=>'none'});
 PGAutomation::write_json_atomic(PGAutomation::base_dir().'/execution.json',
  {run_id=>$id,token=>'test-token',owner=>'automation',status=>'starting',pid=>0});
 return $id;
}
sub marker { return PGAutomation::run_dir($_[0]).'/device-command.marker'; }
sub settle {
 my ($condition)=@_;my $until=Time::HiRes::time()+2;
 Time::HiRes::sleep(0.02) while Time::HiRes::time()<$until && !$condition->();
 return $condition->();
}
{
 my $id=setup();
 PGAutomation::write_atomic(PGAutomation::run_dir($id).'/runner.pid',"$$\n");
 ok(main::webui_automation_launch_runner($id,'test-token'),'production entry point launches a real subprocess with the new handshake');
 ok(settle(sub {-f marker($id)}),'child may perform device work only after acceptance');
 my $launch=PGAutomation::read_json_file(PGAutomation::run_dir($id).'/launch.json');
 is($launch->{state},'accepted','unique attempt committed');
 my $run=PGAutomation::read_json_file(PGAutomation::run_dir($id).'/run.json');
 my $execution=PGAutomation::read_json_file(PGAutomation::base_dir().'/execution.json');
 is($run->{launch_attempt},$launch->{attempt},'manifest acknowledges this attempt');
 is($execution->{launch_attempt},$launch->{attempt},'execution acknowledges the same attempt');
 is($run->{runner_pid},$launch->{pid},'manifest PID belongs to accepted child');
 is($execution->{pid},$launch->{pid},'ownership PID agrees');
 isnt($launch->{pid},$$,'stale PID was not accepted');
 ok($run->{heartbeat}>0,'initial heartbeat is persisted before acceptance');
}
for my $mode (qw(exit delay)) {
 my $id=setup();local $ENV{PGEN_LAUNCH_TEST_MODE}=$mode;
 local $PGAutomationLaunch::START_TIMEOUT=0.2;
 ok(!PGAutomationLaunch::launch_runner($id,'test-token'),"real $mode startup fails rather than pretending it launched");
 Time::HiRes::sleep(0.8) if $mode eq 'delay';
 ok(!-e marker($id),"$mode child cannot perform work later");
 is(PGAutomation::read_json_file(PGAutomation::run_dir($id).'/launch.json')->{state},'cancelled',"$mode attempt durably fenced");
}
for my $failure (qw(pid manifest accepted)) {
 my $id=setup();my $dir=PGAutomation::run_dir($id);
 my $original=\&PGAutomation::write_atomic;
 local *PGAutomation::write_atomic=sub {
  my ($path,$data)=@_;
  return 0 if $failure eq 'pid' && $path eq "$dir/runner.pid";
  return 0 if $failure eq 'manifest' && $path eq "$dir/run.json";
  return 0 if $failure eq 'accepted' && $path eq "$dir/launch.json" && $data=~/"state":"accepted"/;
  return $original->(@_);
 };
 ok(!PGAutomationLaunch::launch_runner($id,'test-token'),"$failure persistence failure prevents launch acceptance");
 ok(!-e marker($id),"no child work after $failure persistence failure");
}
{
 my $id=setup();my $before=PGAutomation::read_raw(PGAutomation::base_dir().'/execution.json');
 ok(!PGAutomationLaunch::launch_runner($id,'wrong-token'),'wrong token is rejected before spawn');
 is(PGAutomation::read_raw(PGAutomation::base_dir().'/execution.json'),$before,'foreign ownership not modified');
 ok(!-e marker($id),'no work after invalid credentials');
}
{
 my $id=setup();open my $lock,'>>',PGAutomation::base_dir().'/runner.lock' or die $!;
 flock($lock,LOCK_EX) or die $!;
 ok(!PGAutomationLaunch::launch_runner($id,'test-token'),'singleton contention is a real launch failure');
 ok(!-e marker($id),'contending child cannot issue device work');
 close $lock;
}
{
 my $id=setup();my $file=PGAutomation::run_dir($id).'/launch.json';
 PGAutomation::write_json_atomic($file,{run_id=>$id,attempt=>'stale-attempt',state=>'cancelled',expires_at=>Time::HiRes::time()+10});
 local $ENV{PGEN_LAUNCH_TEST_MODE}='';
 system($^X,$fixture,$id,'test-token','stale-attempt');
 isnt($? >> 8,0,'late child observes the durable cancellation even without being killed');
 ok(!-e marker($id),'late cancelled attempt can never perform work');
 PGAutomation::write_json_atomic($file,{run_id=>$id,attempt=>'new-attempt',state=>'pending',expires_at=>Time::HiRes::time()+10});
 system($^X,$fixture,$id,'test-token','stale-attempt');
 isnt($? >> 8,0,'old child cannot join a newer attempt');
 is(PGAutomation::read_json_file($file)->{state},'pending','old child does not overwrite the new attempt');
}
{
 my $id=setup();my $file=PGAutomation::run_dir($id).'/launch.json';
 PGAutomation::write_json_atomic($file,{run_id=>$id,attempt=>'wrong-pid',state=>'ready',pid=>$$,expires_at=>Time::HiRes::time()+10});
 ok(!PGAutomationLaunch::_accept_ready($id,'test-token','wrong-pid'),'unrelated live process cannot impersonate a ready worker');
 is(PGAutomation::read_json_file($file)->{state},'ready','invalid PID cannot advance the handshake');
}
{
 my $id=setup();my $log=PGAutomation::run_dir($id).'/actual-runner.log';
 # Real application worker, deliberately no valid launch attempt. Its startup
 # error handler must not send Stop/CAL_END requests as the old handler did.
 my $child=fork();die $! unless defined $child;
 if(!$child){open STDOUT,'>',$log;open STDERR,'>&',\*STDOUT;exec $^X,"$Bin/../usr/bin/pgen_automation_runner.pl",$id,'test-token','cancelled-attempt';exit 127;}
 waitpid($child,0);
 isnt($? >> 8,0,'actual application worker refuses a missing/cancelled attempt');
 unlike(PGAutomation::read_raw($log),qr/Stop requested|cancelling all|calibration exit/,'unaccepted worker never runs device cleanup');
 is(PGAutomation::read_json_file(PGAutomation::base_dir().'/execution.json')->{status},'starting','unaccepted worker does not rewrite execution state');
}
# Publication must not ignore flush/sync errors: the launch journal and
# ownership manifest use this writer. Preserve the previous valid file.
for my $method (qw(flush sync)) {
 my $file=PGAutomation::base_dir()."/durability-$method.json";
 PGAutomation::write_atomic($file,'old');
 no strict 'refs';
 local *{"IO::Handle::$method"}=sub {0};
 ok(!PGAutomation::write_atomic($file,'new'),"$method failure prevents publishing a false success");
 is(PGAutomation::read_raw($file),'old',"$method failure preserves the previous manifest");
}
done_testing();
