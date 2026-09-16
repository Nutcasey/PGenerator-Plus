package PGAutomationLaunch;

use strict;
use warnings;
use Time::HiRes ();
use PGAutomation ();

sub runner_announced {
    my ($run_id, $timeout) = @_;
    $timeout = 3 if !defined($timeout) || ref($timeout) || $timeout !~ /^\d+(?:\.\d+)?$/;
    return 0 if !defined($run_id) || PGAutomation::safe_component($run_id) eq '';

    my $file = PGAutomation::run_dir($run_id) . '/runner.pid';
    my $deadline = Time::HiRes::time() + $timeout;
    while (1) {
        my $pid = PGAutomation::read_raw($file);
        if (defined($pid)) {
            $pid =~ s/^\s+|\s+$//g;
            return 1 if $pid =~ /^\d+$/
                && PGAutomation::pid_is_live($pid, 'pgen_automation_runner.pl');
        }
        last if Time::HiRes::time() >= $deadline;
        Time::HiRes::sleep(0.1);
    }
    return 0;
}

sub _spawn_runner {
    my ($command) = @_;
    return system($command) == 0 ? 1 : 0;
}

sub launch_runner {
    my ($run_id, $token) = @_;
    $run_id = PGAutomation::safe_component($run_id);
    return 0 if $run_id eq '';
    return 0 if !defined($token) || $token !~ /^[A-Za-z0-9_.:-]{8,200}$/;

    my $dir = PGAutomation::run_dir($run_id);
    my $pid_file = $dir . '/runner.pid';

    # A previous interrupted/paused runner can leave runner.pid behind. The
    # startup handshake must observe a PID written by this launch, not stale
    # state (or a recycled PID that happens to name another runner process).
    if (-e $pid_file && !unlink($pid_file)) {
        return 0;
    }

    my $quote = \&main::webui_automation_shell_quote;
    my $cmd = 'setsid /usr/bin/perl /usr/bin/pgen_automation_runner.pl '
        . $quote->($run_id) . ' ' . $quote->($token)
        . ' </dev/null >>' . $quote->($dir . '/runner.log') . ' 2>&1 &';

    # `system()` only establishes that the shell accepted the background
    # command. The runner can still die immediately while validating its
    # manifest, token, or singleton lock. Report launch success only once the
    # validated runner has written runner.pid and that PID is actually live.
    return 0 if !_spawn_runner($cmd);
    return runner_announced($run_id, 3);
}

sub install {
    no warnings 'redefine';
    *main::webui_automation_runner_announced = \&runner_announced;
    *main::webui_automation_launch_runner = \&launch_runner;
    return 1;
}

1;
