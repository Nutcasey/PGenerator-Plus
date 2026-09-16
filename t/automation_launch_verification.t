use strict;
use warnings;
no warnings qw(redefine once);
use FindBin qw($Bin);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;

require "$Bin/../usr/share/PGenerator/webui.pm";
require "$Bin/../usr/share/PGenerator/PGAutomationLaunch.pm";

local $ENV{PGEN_AUTOMATION_DIR} = tempdir(CLEANUP => 1);
PGAutomation::ensure_store();

{
    my $id = PGAutomation::new_id();
    make_path(PGAutomation::run_dir($id));
    ok(!PGAutomationLaunch::runner_announced($id, 0.05),
        'missing runner.pid is not treated as a successful launch');

    PGAutomation::write_atomic(PGAutomation::run_dir($id) . '/runner.pid', "2147483647\n", 0664);
    ok(!PGAutomationLaunch::runner_announced($id, 0.05),
        'dead runner PID is not treated as a successful launch');

    no warnings 'redefine';
    local *PGAutomation::pid_is_live = sub {
        my ($pid, $needle) = @_;
        return $pid == 4321 && ($needle || '') eq 'pgen_automation_runner.pl' ? 1 : 0;
    };
    PGAutomation::write_atomic(PGAutomation::run_dir($id) . '/runner.pid', "4321\n", 0664);
    ok(PGAutomationLaunch::runner_announced($id, 0.05),
        'a live announced automation runner is accepted');

    PGAutomation::write_atomic(PGAutomation::run_dir($id) . '/runner.pid', "abc4321\n", 0664);
    ok(!PGAutomationLaunch::runner_announced($id, 0.05),
        'malformed runner.pid cannot be massaged into a valid PID');
}

{
    my $id = PGAutomation::new_id();
    make_path(PGAutomation::run_dir($id));
    my $pid_file = PGAutomation::run_dir($id) . '/runner.pid';
    PGAutomation::write_atomic($pid_file, "9999\n", 0664);

    local *main::webui_automation_shell_quote = sub {
        my ($value) = @_;
        $value =~ s/'/'"'"'/g;
        return "'$value'";
    };

    my $spawn_saw_stale = 0;
    local *PGAutomationLaunch::_spawn_runner = sub {
        $spawn_saw_stale = -e $pid_file ? 1 : 0;
        return 1;
    };
    local *PGAutomationLaunch::runner_announced = sub { return 1; };
    ok(PGAutomationLaunch::launch_runner($id, 'private-token'),
        'launch succeeds only after the announcement check succeeds');
    ok(!$spawn_saw_stale, 'stale runner.pid is removed before spawning');
}

{
    my $id = PGAutomation::new_id();
    make_path(PGAutomation::run_dir($id));
    local *main::webui_automation_shell_quote = sub { return "'$_[0]'"; };

    my $announced = 0;
    local *PGAutomationLaunch::_spawn_runner = sub { return 0; };
    local *PGAutomationLaunch::runner_announced = sub { $announced++; return 1; };
    ok(!PGAutomationLaunch::launch_runner($id, 'private-token'),
        'shell spawn failure is reported immediately');
    is($announced, 0, 'announcement is not checked after a spawn failure');
}

{
    my $id = PGAutomation::new_id();
    make_path(PGAutomation::run_dir($id));
    local *main::webui_automation_shell_quote = sub { return "'$_[0]'"; };
    local *PGAutomationLaunch::_spawn_runner = sub { return 1; };
    local *PGAutomationLaunch::runner_announced = sub { return 0; };
    ok(!PGAutomationLaunch::launch_runner($id, 'private-token'),
        'background shell success is rejected when the runner never announces');
}

{
    PGAutomationLaunch::install();
    is(\&main::webui_automation_launch_runner, \&PGAutomationLaunch::launch_runner,
        'production launcher is replaced by the verified launcher');
    is(\&main::webui_automation_runner_announced, \&PGAutomationLaunch::runner_announced,
        'announcement helper is installed for diagnostics and tests');
}

done_testing();
