#!/usr/bin/perl

use strict;
use warnings;

BEGIN {
    my $dir = __FILE__;
    $dir =~ s{/[^/]+$}{};
    $dir =~ s{/bin$}{/share/PGenerator};
    $dir = '/usr/share/PGenerator' if $dir eq '';
    unshift @INC, $dir;
}

use Fcntl qw(:flock);
use File::Path qw(make_path);
use HTTP::Tiny;
use IO::Select;
use JSON::PP ();
use POSIX qw(strftime);
use Time::HiRes qw(time);
use PGAutomation ();
use PGMath ();

my ($RUN_ID, $TOKEN) = @ARGV;
die "usage: pgen_automation_runner.pl RUN_ID TOKEN\n"
    if !defined($RUN_ID) || !defined($TOKEN)
    || !PGAutomation::safe_component($RUN_ID)
    || $TOKEN !~ /^[A-Za-z0-9_.:-]{8,200}$/;

my $RUN_DIR = PGAutomation::run_dir($RUN_ID);
my $RUN_FILE = $RUN_DIR . '/run.json';
my $CONTROL_FILE = $RUN_DIR . '/control.json';
my $EXECUTION_FILE = PGAutomation::base_dir() . '/execution.json';
my $RUNNER_LOCK_FILE = PGAutomation::base_dir() . '/runner.lock';
my $HTTP = HTTP::Tiny->new(
    agent   => 'PGenerator-automation/1',
    timeout => 45,
);
my $API_RETRY_INTERVAL = 5;
my $API_RETRY_WINDOW = 300;

my $STOP_REQUESTED = 0;
my $PAUSE_REQUESTED = 0;
my $STOP_HANDLED = 0;
my $STOPPING = 0;
my $ACTIVE_ITEM;
my $ACTIVE_STAGE = '';
my $ACTIVE_WORKER = '';
my ($ACTIVE_SERIES_KEY, $ACTIVE_SERIES_PHASE);
my $LAST_CONTROL_POLL = 0;
my $LAST_HEARTBEAT = 0;
my $RUNNER_LOCK;

$SIG{TERM} = sub { $STOP_REQUESTED = 1; };
$SIG{INT}  = sub { $STOP_REQUESTED = 1; };

sub _log {
    my ($message) = @_;
    $message = '' if !defined($message);
    my $stamp = strftime('%Y-%m-%dT%H:%M:%S', localtime());
    print STDERR "[$stamp] $message\n";
}

sub _run {
    return PGAutomation::read_json_file($RUN_FILE) || {};
}

sub _active_item_number {
    return undef if ref($ACTIVE_ITEM) ne 'HASH';
    return undef if !defined($ACTIVE_ITEM->{item_number}) || $ACTIVE_ITEM->{item_number} !~ /^\d+$/;
    return int($ACTIVE_ITEM->{item_number});
}

sub _worker_summary {
    my ($status) = @_;
    return {} if ref($status) ne 'HASH';
    my %summary;
    foreach my $key (qw(status current_name current_step total_steps current_delta_e message)) {
        $summary{$key} = $status->{$key} if exists($status->{$key});
    }
    return \%summary;
}

sub _write_run {
    my ($run) = @_;
    return PGAutomation::write_json_atomic($RUN_FILE, $run, 0664);
}

sub _write_artifact {
    my ($path, $value) = @_;
    return 0 if !defined($path) || !defined($value);
    if (!PGAutomation::write_json_atomic($path, $value, 0664)) {
        $::LAST_ERROR = "Unable to write automation artifact $path";
        _log($::LAST_ERROR);
        return 0;
    }
    return 1;
}

sub _update_run {
    my ($callback) = @_;
    my ($ok, $value, $error) = PGAutomation::with_lock($RUN_FILE, sub {
        my ($run) = @_;
        $run = {} if ref($run) ne 'HASH';
        $callback->($run);
        return $run;
    });
    _log("run state update failed: $error") if !$ok && $error;
    return $ok ? $value : undef;
}

sub _control {
    my $control = PGAutomation::read_json_file($CONTROL_FILE);
    return ref($control) eq 'HASH' ? $control : { request => 'none' };
}

sub _refresh_control {
    my $now = time();
    return if $now - $LAST_CONTROL_POLL < 0.5 && !$STOP_REQUESTED;
    $LAST_CONTROL_POLL = $now;
    my $request = _control()->{request} || 'none';
    $STOP_REQUESTED = 1 if $request eq 'stop';
    $PAUSE_REQUESTED = 1 if $request eq 'pause';
}

sub _write_execution {
    my $run = _run();
    my $value = {
        owner     => 'automation',
        run_id    => $RUN_ID,
        token     => $TOKEN,
        pid       => $$,
        updated_at => time(),
        status    => $run->{status} || 'running',
    };
    my ($ok) = PGAutomation::with_lock($EXECUTION_FILE, sub { return $value; });
    return $ok;
}

sub _release_execution {
    my ($ok) = PGAutomation::with_lock($EXECUTION_FILE, sub {
        my ($current) = @_;
        return undef if ref($current) ne 'HASH'
            || ($current->{run_id} || '') ne $RUN_ID
            || ($current->{token} || '') ne $TOKEN;
        return { __pg_automation_delete => 1 };
    });
    _log('execution lock release failed') if !$ok;
}

sub _heartbeat {
    my ($force) = @_;
    my $now = time();
    return if !$force && $now - $LAST_HEARTBEAT < 2;
    $LAST_HEARTBEAT = $now;
    my $saved = _update_run(sub {
        my ($run) = @_;
        $run->{heartbeat} = $now;
        $run->{heartbeat_at} = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($now));
        $run->{runner_pid} = $$;
        my $active_item = _active_item_number();
        $run->{active_item} = $active_item if defined($active_item);
        delete($run->{active_grey_state});
        $run->{active_stage} = $ACTIVE_STAGE if $ACTIVE_STAGE ne '';
    });
    die 'Unable to persist automation heartbeat' if !ref($saved);
    die 'Unable to write automation execution heartbeat' if !_write_execution();
}

sub _sleep_controlled {
    my ($seconds) = @_;
    $seconds = 0 if !defined($seconds) || $seconds < 0;
    my $deadline = time() + $seconds;
    while (time() < $deadline) {
        _refresh_control();
        return 0 if $STOP_REQUESTED;
        _heartbeat(0);
        select(undef, undef, undef, 0.5);
    }
    return 1;
}

sub _shell_quote {
    my ($value) = @_;
    $value = '' if !defined($value);
    $value =~ s/'/'"'"'"/g;
    return "'$value'";
}

sub _api_once {
    my ($method, $path, $payload, $allow_stop) = @_;
    my $url = 'http://127.0.0.1' . $path;
    my %options = (
        headers => {
            Accept => 'application/json',
        },
    );
    if ($method eq 'POST') {
        my $body = ref($payload) eq 'HASH' ? PGAutomation::clone($payload) : {};
        $body->{automation_token} = $TOKEN;
        $options{headers}{'Content-Type'} = 'application/json';
        $options{content} = PGAutomation::encode_json($body);
    }
    # Poll controls and maintain the heartbeat even while a reset or readiness
    # request holds the TV lane for several minutes.
    pipe(my $reader, my $writer) or die "Unable to create HTTP response pipe: $!";
    my $child = fork();
    die "Unable to launch HTTP request: $!" if !defined($child);
    if (!$child) {
        close($reader);
        $SIG{TERM} = 'DEFAULT'; $SIG{INT} = 'DEFAULT';
        my $timeout = ref($payload) eq 'HASH' && $payload->{helper_timeout}
            ? $payload->{helper_timeout} + 20 : 60;
        $timeout = 300 if $path eq '/api/automation/readiness';
        my $client = HTTP::Tiny->new(agent => 'PGenerator-automation/1', timeout => $timeout);
        my $response = eval { $client->request($method, $url, \%options) };
        print {$writer} PGAutomation::encode_json($response || {});
        close($writer);
        POSIX::_exit(0);
    }
    close($writer);
    my $select = IO::Select->new($reader);
    my $raw = '';
    while (1) {
        _refresh_control();
        _heartbeat(0);
        if ($STOP_REQUESTED && !$STOPPING && !$allow_stop) {
            kill('TERM', $child); close($reader); waitpid($child, 0);
            return {status => 'error', error_code => 'stopped', message => 'Automation stop requested'};
        }
        next if !$select->can_read(0.5);
        my $read = sysread($reader, my $chunk, 65536);
        last if !defined($read) || !$read;
        $raw .= $chunk;
    }
    close($reader); waitpid($child, 0);
    my $response = PGAutomation::decode_json($raw);
    if (!$response || !$response->{success}) {
        my $status = $response ? ($response->{status} || 0) : 0;
        my $reason = $response ? ($response->{reason} || 'HTTP request failed') : ($@ || 'HTTP request failed');
        return {
            status => 'error',
            error_code => 'daemon-unreachable',
            http_status => $status,
            message => $reason,
            _transport_error => 1,
        };
    }
    my $decoded = PGAutomation::decode_json($response->{content} || '');
    return $decoded if ref($decoded) eq 'HASH';
    return {
        status => 'error',
        error_code => 'invalid-daemon-response',
        message => 'The daemon returned invalid JSON',
        raw_response => substr($response->{content} || '', 0, 500),
    };
}

sub _ensure_lg_connection {
    my ($force) = @_;
    my $status = _api_once('GET', '/api/lg/status', undef);
    return 1 if !$force && ref($status) eq 'HASH'
        && $status->{connected}
        && !$status->{disconnected};
    my $ip = ref($status) eq 'HASH'
        ? ($status->{stored_ip} || $status->{manual_ip} || $status->{ip} || '') : '';
    if ($ip !~ /^[A-Za-z0-9_.:-]{1,120}$/) {
        $::LAST_ERROR = 'The paired LG TV has no reconnectable address';
        return 0;
    }
    for my $attempt (1..3) {
        my $connect = _api_once('POST', '/api/lg/connect', { ip => $ip });
        if (ref($connect) eq 'HASH' && $connect->{connected} && !$connect->{disconnected}) {
            _log($force ? 'refreshed the paired LG TV connection for automation'
                : 'reconnected the paired LG TV for automation');
            return 1;
        }
        my $check = _api_once('GET', '/api/lg/status', undef);
        if (ref($check) eq 'HASH' && $check->{connected} && !$check->{disconnected}) {
            _log($force ? 'refreshed the paired LG TV connection for automation'
                : 'reconnected the paired LG TV for automation');
            return 1;
        }
        _sleep_controlled(1) or return 0;
    }
    $::LAST_ERROR = 'The paired LG TV could not be reconnected';
    return 0;
}

sub _lg_action_path {
    my ($path) = @_;
    return 0 if !defined($path) || $path !~ m{\A/api/lg/};
    return 0 if $path =~ m{\A/api/lg/(?:status|connect|disconnect)\z};
    return 1;
}

sub _lg_connection_failure {
    my ($response) = @_;
    return 0 if ref($response) ne 'HASH' || ($response->{status} || '') ne 'error';
    my $code = lc($response->{error_code} || '');
    return 1 if $code =~ /(?:lg|tv)[_-](?:unreachable|disconnected|connection)/;
    my $message = lc(join(' ', map { defined($_) ? "$_" : '' }
        @{$response}{qw(message error raw_error)}));
    return 1 if $message =~ /unable to connect to lg webos tv/;
    return 1 if $message =~ /connect the lg tv before/;
    return 1 if $message =~ /lg tv did not (?:answer|finish)/;
    return 1 if $message =~ /lg webos tv.*(?:websocket|connection)/;
    return 0;
}

sub _api {
    my ($method, $path, $payload, $allow_stop, $retry_window) = @_;
    $allow_stop = 0 if !defined($allow_stop);
    $retry_window = $API_RETRY_WINDOW if !defined($retry_window);
    $retry_window = 0 if $retry_window < 0;
    my $last;
    my $started = time();
    my $attempt = 0;
    my $lg_action = _lg_action_path($path) && !$allow_stop;
    my $lg_preflighted = 0;
    my $lg_reconnects = 0;
    while (1) {
        $attempt++;
        _refresh_control() unless $allow_stop;
        if ($STOP_REQUESTED && !$allow_stop) {
            return { status => 'error', error_code => 'stopped', message => 'Automation stop requested' };
        }
        _heartbeat(0);
        if ($lg_action && !$lg_preflighted) {
            $lg_preflighted = 1;
            _ensure_lg_connection();
        }
        $last = _api_once($method, $path, $payload, $allow_stop);
        if (!$last->{_transport_error}) {
            if ($lg_action && _lg_connection_failure($last) && $lg_reconnects < 3) {
                $lg_reconnects++;
                _log("LG request $method $path reported a connection failure; refreshing the pairing (attempt $lg_reconnects)");
                if (_ensure_lg_connection(1)) {
                    next;
                }
            }
            $::LAST_ERROR_CODE = (($last->{status} || '') eq 'error' && $last->{error_code})
                ? $last->{error_code} : '';
            return $last;
        }
        my $remaining = $retry_window - (time() - $started);
        last if $remaining <= 0;
        my $delay = $remaining < $API_RETRY_INTERVAL ? $remaining : $API_RETRY_INTERVAL;
        _log("daemon request $method $path failed; retrying in ${API_RETRY_INTERVAL} seconds (attempt $attempt, ${retry_window}s window)");
        last if !_sleep_controlled($delay);
    }
    $::LAST_ERROR_CODE = 'daemon-unreachable';
    return $last || { status => 'error', error_code => 'daemon-unreachable' };
}

sub _response_ok {
    my ($response) = @_;
    return ref($response) eq 'HASH' && (($response->{status} || '') eq 'ok'
        || ($response->{status} || '') eq 'started'
        || ($response->{status} || '') eq 'measuring'
        || ($response->{status} || '') eq 'running');
}

sub _item_snapshot {
    my ($item) = @_;
    return $item if ref($item) eq 'HASH';
    return {};
}

sub _signal {
    my ($item) = @_;
    my $signal = lc($item->{signal_format} || $item->{signal_mode} || $item->{format} || 'sdr');
    $signal = 'hdr10' if $signal eq 'hdr';
    return $signal =~ /^(?:sdr|hdr10|hlg|dv)$/ ? $signal : 'sdr';
}

sub _picture_mode {
    my ($item) = @_;
    return $item->{picture_mode} || $item->{pictureMode} || '';
}

sub _stages {
    my ($item) = @_;
    my $stages = ref($item->{stages}) eq 'HASH' ? $item->{stages} : {};
    my $pre = exists($stages->{pre_readings}) ? $stages->{pre_readings}
        : exists($item->{pre_readings}) ? $item->{pre_readings} : 1;
    my $cal = exists($stages->{calibration}) ? $stages->{calibration}
        : exists($item->{calibration}) ? $item->{calibration} : 1;
    my $post = exists($stages->{post_readings}) ? $stages->{post_readings}
        : exists($item->{post_readings}) ? $item->{post_readings} : 1;
    return {
        pre => $pre ? 1 : 0,
        calibration => $cal ? 1 : 0,
        post => $post ? 1 : 0,
        apply_all => exists($stages->{apply_all}) ? ($stages->{apply_all} ? 1 : 0)
            : exists($item->{apply_all}) ? ($item->{apply_all} ? 1 : 0) : 1,
    };
}

sub _series_selection {
    my ($item, $which) = @_;
    my $field = $which eq 'post' ? 'post_series' : 'pre_series';
    my $selection = $item->{$field};
    $selection = $item->{series} if ref($selection) ne 'ARRAY';
    $selection = ['greyscale-21', 'colors-30', 'saturations-24']
        if ref($selection) ne 'ARRAY' || !@$selection;
    my %valid = map { $_ => 1 } qw(greyscale-21 colors-30 saturations-24);
    my @keys;
    foreach my $key (@$selection) {
        next if !defined($key) || !$valid{$key};
        push @keys, $key if !grep { $_ eq $key } @keys;
    }
    return @keys;
}

sub _series_info {
    my ($key) = @_;
    return ('greyscale', 21) if $key eq 'greyscale-21';
    return ('colors', 30) if $key eq 'colors-30';
    return ('saturations', 24) if $key eq 'saturations-24';
    return ('greyscale', 21);
}

sub _default_range {
    my ($item) = @_;
    return "$item->{signal_range}" if defined($item->{signal_range}) && $item->{signal_range} =~ /^[12]$/;
    return "$item->{pattern_signal_range}" if defined($item->{pattern_signal_range}) && $item->{pattern_signal_range} =~ /^[12]$/;
    return '2';
}

sub _measurement_options {
    my ($item) = @_;
    return map { $_ => $item->{$_} } grep {
        /^patch_insert/ || /^(?:measurement_meter_port|measurement_meter_usb_id|observer|low_light)$/
    } keys %$item;
}

sub _series_payload {
    my ($item, $key, $run_id) = @_;
    my ($type, $points) = _series_info($key);
    my $signal = _signal($item);
    my $cal = ref($item->{calibration}) eq 'HASH' ? $item->{calibration} : {};
    my $target_gamma = $item->{target_gamma} || $cal->{target_gamma}
        || ($signal eq 'sdr' ? 'bt1886' : $signal eq 'hlg' ? 'hlg' : 'st2084');
    $target_gamma = 'st2084' if $signal eq 'dv';
    my $payload = {
        type => $type,
        points => $points,
        display_type => $item->{display_type} || 'lcd',
        ccss_override => $item->{ccss_override} || '',
        delay_ms => int($item->{delay_ms} // 1000),
        patch_size => int($item->{patch_size} || 10),
        signal_mode => $signal,
        signal_range => _default_range($item),
        pattern_signal_range => _default_range($item),
        transport_signal_range => $item->{transport_signal_range} || _default_range($item),
        max_luma => 0 + ($item->{max_luma} || 1000),
        target_gamma => $target_gamma,
        target_gamut => $signal eq 'dv' ? 'p3d65' : ($item->{target_gamut} || 'auto'),
        dv_map_mode => $signal eq 'dv' ? '1' : '',
        requested_signal_mode => $signal,
        refresh_rate => $item->{refresh_rate} || '',
        measurement_meter_port => $item->{measurement_meter_port} || '',
        measurement_meter_usb_id => $item->{measurement_meter_usb_id} || '',
        observer => '1931_2',
        pattern_provider => $item->{pattern_provider} || 'local',
        target_white_use_measured => JSON::PP::true,
        custom_d65_enabled => JSON::PP::true,
        target_white_x => ($item->{target_white} || $cal->{target_white} || {})->{x} // 0.3127,
        target_white_y => ($item->{target_white} || $cal->{target_white} || {})->{y} // 0.3290,
        series_report_key => $key,
        full_autocal_run_id => $run_id,
        require_device_ready => JSON::PP::false,
    };
    foreach my $key (keys %$item) {
        $payload->{$key} = $item->{$key} if $key =~ /^patch_insert/ || $key eq 'low_light';
    }
    return $payload;
}

sub _grey_code {
    my ($signal, $ire, $range, $max_bpc) = @_;
    $max_bpc = 10 if !defined($max_bpc) || $max_bpc !~ /^(?:8|10|12)$/;
    my $max = $max_bpc == 12 ? 4095 : $max_bpc == 10 ? 1023 : 255;
    if ($signal eq 'dv') {
        return int(256 + ($ire / 100.0) * 3504 + 0.5);
    }
    if ($range eq '1') {
        my $min = $max_bpc == 10 ? 64 : $max_bpc == 12 ? 256 : 16;
        my $span = $max_bpc == 10 ? 876 : $max_bpc == 12 ? 3504 : 219;
        return int($min + ($ire / 100.0) * $span + 0.5);
    }
    return int(($ire / 100.0) * $max + 0.5);
}

sub _grey_steps {
    my ($item) = @_;
    my $signal = _signal($item);
    my $range = _default_range($item);
    my $cal = ref($item->{calibration}) eq 'HASH' ? $item->{calibration} : {};
    my $max_bpc = $item->{max_bpc} || $cal->{max_bpc} || 10;
    my @ires;
    if ($signal eq 'hdr10' || $signal eq 'dv') {
        @ires = (100, 0, 90, 80, 70, 60, 50, 45, 40, 35, 30, 25, 20, 15, 10, 7, 5, 4, 2.7, 2, 1.4);
    } elsif ($range eq '1') {
        @ires = (100, 0, 2.3, 3, 4, 5, 7, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 99, 105, 109);
    } else {
        @ires = (100, 0, 2.3, 3, 4, 5, 7, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95);
    }
    my @steps;
    foreach my $ire (@ires) {
        my $code = _grey_code($signal, $ire, $range, $max_bpc);
        my $step = {
            name => sprintf('%.4g%%', $ire),
            ire => 0 + $ire,
            stimulus => 0 + $ire,
            nominal_ire => 0 + $ire,
            r => $code,
            g => $code,
            b => $code,
            r_code => $code,
            g_code => $code,
            b_code => $code,
            input_max => $signal eq 'dv' ? 4095 : ($max_bpc >= 10 ? 1023 : 255),
            signal_r_pct => 0 + $ire,
            signal_g_pct => 0 + $ire,
            signal_b_pct => 0 + $ire,
            target_ire => 0 + $ire,
            autocal_white_reference => abs($ire - 100) < 0.001 ? JSON::PP::true : undef,
        };
        $step->{autocal_reference_only} = JSON::PP::true if abs($ire) < 0.001;
        push @steps, $step;
    }
    return \@steps;
}

sub _grey_payload {
    my ($item) = @_;
    my $signal = _signal($item);
    my $cal = ref($item->{calibration}) eq 'HASH' ? $item->{calibration} : {};
    my $steps = _grey_steps($item);
    my $target_gamma = $cal->{target_gamma} || $item->{target_gamma} || 'bt1886';
    $target_gamma = '2.2' if $signal eq 'hdr10' || $signal eq 'dv';
    my $body = {
        _measurement_options($item),
        type => 'greyscale',
        points => 26,
        display_type => $item->{display_type} || 'lcd',
        ccss_override => $item->{ccss_override} || '',
        delay_ms => int($item->{delay_ms} // 1000),
        patch_size => int($item->{patch_size} || 10),
        signal_mode => $signal,
        signal_range => _default_range($item),
        pattern_signal_range => _default_range($item),
        transport_signal_range => $item->{transport_signal_range} || _default_range($item),
        target_delta_e => 0 + ($cal->{target_delta_e} || $item->{target_delta_e} || 1),
        delta_e_formula => $cal->{delta_e_formula} || $item->{delta_e_formula} || 'deitp',
        target_gamma => $target_gamma,
        target_white => $cal->{target_white} || $item->{target_white} || { x => 0.3127, y => 0.3290 },
        target_luminance => ($signal eq 'sdr' ? 0 + ($item->{target_luminance} || $cal->{target_luminance} || 100) : undef),
        setup_luminance_reference => ($signal eq 'sdr' ? 0 + ($cal->{setup_luminance_reference} || $item->{target_luminance} || 100) : undef),
        headroom_target_luminance => ($signal eq 'sdr' ? 0 + ($cal->{headroom_target_luminance} || 0) : undef),
        picture_mode => _picture_mode($item),
        force_ddc_white_balance => JSON::PP::true,
        lg_autocal_sdr_1d_dpg_upload_enabled => JSON::PP::true,
        lg_autocal_26 => JSON::PP::true,
        lg_greyscale_21 => JSON::PP::false,
        lg_autocal_26_full_ddc_spine => $cal->{full_ddc_spine} ? JSON::PP::true : JSON::PP::false,
        lg_extended_sdr_16_255 => $cal->{extended_sdr} ? JSON::PP::true : JSON::PP::false,
        dark_detail => $cal->{dark_detail} ? 1 : 0,
        restore_factory_levels => JSON::PP::false,
        reset_ddc_baseline => JSON::PP::false,
        full_workflow => JSON::PP::true,
        full_autocal_run_id => $RUN_ID,
        full_autocal_phase => 'first-greyscale',
        max_iterations => int($cal->{max_iterations} || 36),
        headroom_max_iterations => int($cal->{headroom_max_iterations} || 60),
        max_polish_iterations => int($cal->{max_polish_iterations} // 16),
        precision_polish_iterations => int($cal->{precision_polish_iterations} // 18),
        low_light => ref($item->{low_light}) eq 'HASH' ? $item->{low_light} : {},
        refresh_rate => $item->{refresh_rate} || '',
        require_device_ready => JSON::PP::false,
        steps => $steps,
    };
    delete $body->{$_} for grep { !defined($body->{$_}) } keys %$body;
    return $body;
}

sub _lattice_patches {
    my ($item) = @_;
    my $cal = ref($item->{calibration}) eq 'HASH' ? $item->{calibration} : {};
    return $cal->{lattice_patches} if ref($cal->{lattice_patches}) eq 'ARRAY' && @{$cal->{lattice_patches}};
    my @levels = (0, 25, 50, 75, 100);
    my @patches;
    foreach my $r (@levels) {
        foreach my $g (@levels) {
            foreach my $b (@levels) {
                push @patches, { r => $r, g => $g, b => $b };
            }
        }
    }
    return \@patches;
}

sub _three_d_payload {
    my ($item, $run, $item_number) = @_;
    my $signal = _signal($item);
    my $cal = ref($item->{calibration}) eq 'HASH' ? $item->{calibration} : {};
    my $method = lc($cal->{method} || $item->{method} || ($signal eq 'hdr10' ? 'matrix' : 'hybrid'));
    $method = 'matrix' if $signal eq 'hdr10' && $method ne 'imported';
    $method = 'hybrid' if $method !~ /^(?:matrix|ramp|lattice|skeleton|hybrid|imported)$/;
    my $grey = {};
    if (defined($item_number)) {
        my $saved = PGAutomation::read_json_file(
            PGAutomation::item_dir($RUN_ID, $item_number) . '/calibration/grey-state.json'
        );
        $grey = $saved if ref($saved) eq 'HASH';
    }
    # Runs written before the compact heartbeat format may still have the
    # full state at the top level. Keep that as a resume fallback, but never
    # write it back into a new run record.
    $grey = $run->{active_grey_state}
        if ref($grey) ne 'HASH' || !%$grey;
    $grey = {} if ref($grey) ne 'HASH';
    my $body = {
        _measurement_options($item),
        method => $method,
        type => 'lg-3d-lut',
        display_type => $item->{display_type} || 'lcd',
        ccss_override => $item->{ccss_override} || '',
        delay_ms => int($item->{delay_ms} // 1000),
        patch_size => int($item->{patch_size} || 10),
        signal_mode => $signal,
        requested_signal_mode => $signal,
        signal_range => _default_range($item),
        pattern_signal_range => _default_range($item),
        transport_signal_range => $item->{transport_signal_range} || _default_range($item),
        target_gamma => $signal eq 'hdr10' ? 'st2084' : ($cal->{target_gamma} || $item->{target_gamma} || 'bt1886'),
        target_gamut => $signal eq 'hdr10' ? ($item->{target_gamut} || 'p3d65') : ($cal->{target_gamut} || $item->{target_gamut} || 'bt709'),
        picture_mode => _picture_mode($item),
        upload => JSON::PP::true,
        full_workflow => JSON::PP::true,
        full_autocal_run_id => $RUN_ID,
        full_autocal_phase => '3d-lut',
        lattice_patches => ($method =~ /^(?:lattice|skeleton|hybrid)$/ ? _lattice_patches($item) : undef),
        solve_matrix_only => $cal->{lattice_residuals} ? JSON::PP::false : JSON::PP::true,
        solve_cube_size => int($cal->{solve_cube_size} || 17),
        max_bpc => $item->{max_bpc} || $cal->{max_bpc} || 10,
        refresh_rate => $item->{refresh_rate} || '',
        require_device_ready => JSON::PP::false,
        post_check => JSON::PP::false,
        preflight_lg_generation => $item->{lg_generation},
        lg_autocal_hdr20_postcal_shadow_enable => $cal->{shadow_fix} ? 1 : 0,
        low_light => ref($item->{low_light}) eq 'HASH' ? $item->{low_light} : {},
    };
    if ($signal eq 'hdr10') {
        $body->{upload_command} = 'BT2020_3D_LUT_DATA';
        $body->{get_command} = 'GET_3D_LUT_DATA';
        $body->{full_workflow_peak_luminance} = $grey->{hdr20_1d_tonemap_peak_luminance}
            || $grey->{hdr_tone_map_peak_luminance} || $grey->{hdr20_1d_dpg_white_ref}
            || $grey->{calibrated_white_luminance} if ref($grey) eq 'HASH';
        $body->{full_workflow_dpg_data} = $grey->{hdr20_1d_dpg_data}
            if ref($grey->{hdr20_1d_dpg_data}) eq 'ARRAY' && @{$grey->{hdr20_1d_dpg_data}} == 3072;
    }
    $body->{full_workflow_dpg_data} = $grey->{sdr_1d_dpg_data}
        if $signal eq 'sdr' && ref($grey->{sdr_1d_dpg_data}) eq 'ARRAY' && @{$grey->{sdr_1d_dpg_data}} == 3072;
    delete $body->{$_} for grep { !defined($body->{$_}) } keys %$body;
    return $body;
}

sub _dv_payload {
    my ($item) = @_;
    my $cal = ref($item->{calibration}) eq 'HASH' ? $item->{calibration} : {};
    my $range = _default_range($item);
    return {
        _measurement_options($item),
        input_max => 4095,
        display_type => $item->{display_type} || 'lcd',
        ccss_override => $item->{ccss_override} || '',
        delay_ms => int($item->{delay_ms} // 1000),
        pattern_signal_range => $range,
        signal_range => $range,
        transport_signal_range => $range,
        picture_mode => _picture_mode($item),
        patch_size => int($item->{patch_size} || 10),
        refresh_rate => $item->{refresh_rate} || '',
        upload => JSON::PP::false,
        keep_calibration_mode => JSON::PP::true,
        calibration_mode_active => JSON::PP::true,
        full_autocal_run_id => $RUN_ID,
        require_device_ready => JSON::PP::false,
        max_luma => 1000,
    };
}

sub _status_terminal {
    my ($status) = @_;
    return defined($status) && $status =~ /^(?:complete|error|failed|cancelled|stopped|idle)$/;
}

sub _start_worker {
    my ($path, $status_path, $payload) = @_;
    my $result;
    for my $attempt (1..6) {
        $result = _api('POST', $path, $payload, 0, 0);
        return $result if ($result->{status} || '') eq 'started';
        return $result if $STOP_REQUESTED;
        my $probe = _api('GET', $status_path, undef, 0, 0);
        if (($probe->{status} || '') eq 'running' && $payload->{full_autocal_run_id}
            && ($probe->{full_autocal_run_id} || '') eq $payload->{full_autocal_run_id}) {
            return {status => 'started', adopted => JSON::PP::true};
        }
        last if !$result->{retryable} && !$result->{_transport_error}
            && ($result->{error_code} || '') !~ /finishing/;
        my $delay = ($result->{retry_after_ms} || 1000) / 1000;
        $delay = 3 if $delay > 3; $delay = 0.25 if $delay < 0.25;
        _sleep_controlled($delay) or last;
    }
    return $result;
}

sub _wait_worker {
    my ($status_path, $kind, $item) = @_;
    my $started = time();
    my $last_keepalive = 0;
    while (time() - $started < 21600) {
        _refresh_control();
        if ($STOP_REQUESTED) {
            _log("$kind interrupted by stop request before worker status became terminal");
            return undef;
        }
        my $status = _api('GET', $status_path, undef);
        return $status if $status->{error_code} && $status->{error_code} eq 'daemon-unreachable';
        my $now = time();
        if ($now - $last_keepalive >= 60) {
            $last_keepalive = $now;
            my $tv = _api('GET', '/api/lg/status', undef);
            if (ref($tv) eq 'HASH' && $tv->{disconnected}) {
                _ensure_lg_connection();
                $tv = _api('GET', '/api/lg/status', undef, 0, 0);
            }
            if (ref($tv) ne 'HASH' || ($tv->{status} || '') eq 'error' || $tv->{disconnected}
                || lc($tv->{tv_power} || $tv->{power} || '') =~ /^(?:off|standby|powering-off)$/) {
                $status = {
                    status => 'error',
                    error_code => 'tv-unreachable',
                    message => 'The LG TV stopped answering or entered standby',
                };
                return $status;
            }
        }
        my $state = $status->{status} || '';
        _update_run(sub {
            my ($run) = @_;
            $run->{worker_status} = _worker_summary($status);
            $run->{active_stage} = $ACTIVE_STAGE;
            my $active_item = _active_item_number();
            $run->{active_item} = $active_item if defined($active_item);
        });
        if ($state eq 'idle' && _worker_process_alive($ACTIVE_WORKER)) {
            _sleep_controlled(2) or return undef;
            next;
        }
        return $status if _status_terminal($state);
        return { status => 'error', error_code => 'worker-timeout', message => "$kind exceeded six hours" }
            if time() - $started >= 21600;
        _sleep_controlled(2) or return undef;
    }
    return { status => 'error', error_code => 'worker-timeout', message => "$kind exceeded six hours" };
}

sub _worker_process_alive {
    my ($kind) = @_;
    my %pattern = (
        series => '[m]eter_series\\.sh',
        grey   => '[m]eter_lg_autocal\\.pl',
        '3d'   => '[m]eter_lg_3d_autocal\\.pl',
        dv     => '[m]eter_lg_dv_profile\\.pl',
    );
    my $needle = $pattern{$kind} || '';
    return 0 if $needle eq '';
    my $alive = `pgrep -f '$needle' 2>/dev/null`;
    return $alive =~ /\d/ ? 1 : 0;
}

sub _copy_worker_files {
    my ($item_number, $kind, $state) = @_;
    my $dir = PGAutomation::item_dir($RUN_ID, $item_number) . '/calibration';
    return 0 if $dir eq '';
    if (!-d $dir && !eval { make_path($dir, { mode => 0775 }); 1 }) {
        _log("unable to create calibration artifact directory $dir");
        return 0;
    }
    # The daemon deliberately leaves user files alone, so a previous guided
    # run may still have state in /tmp. Capture only a worker state supplied by
    # the current wait, or a partial state while that worker is still active;
    # later checkpoints preserve the copy already made for this item.
    my $capture_current = ref($state) eq 'HASH' || $ACTIVE_WORKER eq $kind;
    return 1 if !$capture_current;
    my $copy_if_present = sub {
        my ($source, $destination) = @_;
        return 1 if !-f $source;
        if (!PGAutomation::copy_artifact($source, $destination)) {
            _log("unable to copy automation artifact $source to $destination");
            return 0;
        }
        return 1;
    };
    my $ok = 1;
    if ($kind eq 'grey') {
        $ok &&= $copy_if_present->('/tmp/meter_lg_autocal.json', "$dir/grey-state.json");
        $ok &&= $copy_if_present->('/tmp/meter_lg_autocal.log', "$dir/grey-log.txt");
        $ok &&= _write_artifact("$dir/grey-state.json", $state) if ref($state) eq 'HASH' && !-f "$dir/grey-state.json";
    } elsif ($kind eq '3d') {
        $ok &&= $copy_if_present->('/tmp/meter_lg_3d_autocal.json', "$dir/3d-state.json");
        $ok &&= $copy_if_present->('/tmp/meter_lg_3d_autocal.log', "$dir/3d-log.txt");
        $ok &&= _write_artifact("$dir/3d-state.json", $state) if ref($state) eq 'HASH' && !-f "$dir/3d-state.json";
        if (ref($state) eq 'HASH' && ref($state->{export}) eq 'HASH') {
            foreach my $key (qw(cube_path payload_path)) {
                my $source = $state->{export}{$key} || '';
                next if $source eq '' || $source !~ m{/var/lib/PGenerator/lg/luts/[A-Za-z0-9_.-]+$};
                my ($name) = $source =~ m{/([^/]+)$};
                $ok &&= $copy_if_present->($source, "$dir/$name") if $name;
            }
        }
    } elsif ($kind eq 'dv') {
        $ok &&= $copy_if_present->('/tmp/meter_lg_dv_profile.json', "$dir/dv-profile-state.json");
        $ok &&= $copy_if_present->('/tmp/meter_lg_dv_profile.log', "$dir/dv-profile-log.txt");
        $ok &&= _write_artifact("$dir/dv-profile-state.json", $state) if ref($state) eq 'HASH' && !-f "$dir/dv-profile-state.json";
        my $measurements = ref($state) eq 'HASH'
            ? ($state->{measurements} || $state->{dv_profile_measurements}) : undef;
        $ok &&= _write_artifact("$dir/dv-profile-measurements.json", $measurements)
            if ref($measurements) eq 'HASH';
    }
    return $ok;
}

sub _snapshot_series {
    my ($item_number, $which, $key, $status) = @_;
    my $directory = PGAutomation::item_dir($RUN_ID, $item_number) . '/' . $which;
    if (!-d $directory && !eval { make_path($directory, { mode => 0775 }); 1 }) {
        $::LAST_ERROR = "Unable to create series artifact directory $directory";
        return undef;
    }
    my %snapshot;
    foreach my $field (qw(type points steps readings white_reading black_reading signal_mode target_gamma max_luma dv_map_mode status report_key)) {
        $snapshot{$field} = $status->{$field} if exists($status->{$field});
    }
    $snapshot{type} = (_series_info($key))[0] if !exists($snapshot{type});
    $snapshot{points} = (_series_info($key))[1] if !exists($snapshot{points});
    $snapshot{steps} = [] if ref($snapshot{steps}) ne 'ARRAY';
    $snapshot{readings} = [] if ref($snapshot{readings}) ne 'ARRAY';
    my $context = _series_payload(_item_snapshot($ACTIVE_ITEM), $key, $RUN_ID);
    foreach my $field (qw(signal_mode target_gamma max_luma dv_map_mode)) {
        $snapshot{$field} = $context->{$field} if !defined($snapshot{$field});
    }
    $snapshot{status} = $status->{status} || 'error' if !defined($snapshot{status});
    $snapshot{report_key} = $key;
    return undef if !_write_artifact("$directory/$key.json", \%snapshot);
    return \%snapshot;
}

sub _run_series {
    my ($item_number, $item, $which) = @_;
    my @keys = _series_selection($item, $which);
    my $item_dir = PGAutomation::item_dir($RUN_ID, $item_number);
    make_path("$item_dir/$which", { mode => 0775 }) if !-d "$item_dir/$which";
    foreach my $key (@keys) {
        _refresh_control();
        return 0 if $STOP_REQUESTED;
        _log("launching meter worker series $key for $which readings");
        $ACTIVE_WORKER = 'series';
        ($ACTIVE_SERIES_KEY, $ACTIVE_SERIES_PHASE) = ($key, $which);
        _update_run(sub { $_[0]{active_series} = {key=>$key, phase=>$which}; });
        my $started = _api('POST', '/api/meter/series', _series_payload($item, $key, $RUN_ID));
        if (!$started || ($started->{status} || '') ne 'started') {
            $ACTIVE_WORKER = '';
            $::LAST_ERROR = $started->{message} || 'Unable to start meter series';
            return 0;
        }
        _log("meter worker series $key started for $which readings");
        my $status = _wait_worker('/api/meter/series/status', "series $key", $item);
        if ($STOP_REQUESTED) {
            _log("meter worker series $key retained for stop cleanup");
            return 0;
        }
        return 0 if !ref($status);
        my $snapshot = _snapshot_series($item_number, $which, $key, $status);
        if (!ref($snapshot)) {
            $ACTIVE_WORKER = '';
            return 0;
        }
        if (($status->{status} || '') ne 'complete') {
            $::LAST_ERROR = $status->{message} || "Series $key did not complete";
            return 0;
        }
        $ACTIVE_WORKER = '';
        _update_run(sub {
            my ($run) = @_;
            $run->{last_series} = { item => $item_number, phase => $which, key => $key };
        });
    }
    undef $ACTIVE_SERIES_KEY; undef $ACTIVE_SERIES_PHASE;
    return 1;
}

sub _observed_settings {
    my ($response) = @_;
    return {} if ref($response) ne 'HASH';
    foreach my $key (qw(picture_settings settings)) {
        return $response->{$key} if ref($response->{$key}) eq 'HASH';
    }
    return {};
}

sub _mode_agrees {
    my ($expected, $observed) = @_;
    return 0 if !defined($observed) || $observed eq '';
    my $e = lc("$expected");
    my $o = lc("$observed");
    $e =~ s/[\s_-]+//g;
    $o =~ s/[\s_-]+//g;
    return 1 if $e eq $o;
    return 1 if $e =~ /filmmaker|cinemadark/ && $o eq 'dolbyhdrcinema';
    return 1 if $e =~ /cinemahome/ && $o =~ /dolbyhdrcinemahome|dolbyvisioncinemahome/;
    return 1 if $e eq 'standard' && $o eq 'normal';
    return 0;
}

sub _signal_mode_compatible {
    my ($signal, $observed) = @_;
    return 0 if !defined($observed) || $observed eq '';
    my $mode = lc("$observed");
    $mode =~ s/[\s_-]+//g;
    return $mode !~ /^(?:hdr|dolby)/ if ($signal || '') eq 'sdr';
    return $mode =~ /^hdr/ if ($signal || '') eq 'hdr10' || ($signal || '') eq 'hlg';
    return $mode =~ /^dolby(?:vision|hdr)/ if ($signal || '') eq 'dv';
    return 0;
}

sub _value_agrees {
    my ($expected, $observed, $key) = @_;
    return _mode_agrees($expected, $observed) if ($key || '') eq 'pictureMode';
    return 0 if !defined($observed);
    if (!ref($expected) && !ref($observed) && "$expected" =~ /^-?\d+(?:\.\d+)?$/
        && "$observed" =~ /^-?\d+(?:\.\d+)?$/) {
        return abs(($expected + 0) - ($observed + 0)) <= 0.1;
    }
    return lc("$expected") eq lc("$observed") if !ref($expected) && !ref($observed);
    return PGAutomation::encode_json($expected) eq PGAutomation::encode_json($observed);
}

sub _append_setting_check {
    my ($item_number, $point, $record) = @_;
    my $path = PGAutomation::item_dir($RUN_ID, $item_number) . '/settings-checks.ndjson';
    $record->{checkpoint} = $point;
    $record->{timestamp} = time();
    return PGAutomation::append_line_locked($path, PGAutomation::encode_json($record) . "\n");
}

sub _item_settings {
    my ($item) = @_;
    my $settings = ref($item->{settings}) eq 'HASH' ? PGAutomation::clone($item->{settings}) : {};
    my $hazards = ref($item->{hazards}) eq 'ARRAY' ? $item->{hazards} : [];
    my $capabilities = ref($item->{hazard_capabilities}) eq 'HASH' ? $item->{hazard_capabilities} : {};
    foreach my $default_key (qw(energySaving aiPicture)) {
        my $capability = ref($capabilities->{$default_key}) eq 'HASH' ? $capabilities->{$default_key} : {};
        $settings->{$default_key} = 'off'
            if !exists($settings->{$default_key}) && $capability->{controllable} && $capability->{supported};
    }
    foreach my $hazard (@$hazards) {
        next if ref($hazard) ne 'HASH' || !$hazard->{controllable};
        next if !defined($hazard->{key}) || $hazard->{key} eq '';
        my $category = $hazard->{category} || 'picture';
        $item->{hazard_restore}{$hazard->{key}} = {
            value => $hazard->{value},
            category => $category,
        } if exists($hazard->{value}) && !exists($item->{hazard_restore}{$hazard->{key}});
        next if ($hazard->{key} eq 'energySaving' || $hazard->{key} eq 'aiPicture')
            && exists($settings->{$hazard->{key}});
        $settings->{$hazard->{key}} = $hazard->{disabled_value}
            if exists($hazard->{disabled_value});
    }
    return $settings;
}

sub _setting_category {
    my ($item, $key) = @_;
    return 'picture' if !defined($key) || $key eq 'pictureMode';
    my $capabilities = ref($item->{hazard_capabilities}) eq 'HASH' ? $item->{hazard_capabilities} : {};
    return $capabilities->{$key}{category}
        if ref($capabilities->{$key}) eq 'HASH' && $capabilities->{$key}{category};
    foreach my $hazard (@{$item->{hazards} || []}) {
        next if ref($hazard) ne 'HASH' || ($hazard->{key} || '') ne $key;
        return $hazard->{category} || 'picture';
    }
    return 'picture';
}

sub _apply_one_setting {
    my ($item, $key, $value, $category) = @_;
    $category = 'picture' if !defined($category) || $category eq '';
    my $result = _api('POST', '/api/lg/picture-settings/set', {
        settings => { $key => $value },
        readback_keys => [$key, 'pictureMode'],
        picture_mode => _picture_mode($item),
        signal_mode => _signal($item),
        category => $category,
        keep_calibration_mode => JSON::PP::false,
        calibration_mode_active => JSON::PP::false,
    });
    return $result;
}

sub _read_and_verify_settings {
    my ($item_number, $item, $point) = @_;
    my $settings = _item_settings($item);
    my %expected = %$settings;
    $expected{pictureMode} = _picture_mode($item) if _picture_mode($item) ne '';
    my @keys = sort keys %expected;
    my %by_category;
    foreach my $key (@keys) {
        push @{$by_category{_setting_category($item, $key)}}, $key;
    }
    my %observed;
    my %meta;
    my @responses;
    foreach my $category (sort keys %by_category) {
        my $response = _api('POST', '/api/lg/picture-settings', {
            keys => $by_category{$category},
            picture_mode => _picture_mode($item),
            signal_mode => _signal($item),
            include_current_input => JSON::PP::false,
            category => $category,
        });
        push @responses, { category => $category, response => $response };
        my $category_observed = _observed_settings($response);
        foreach my $key (keys %$category_observed) {
            $observed{$key} = $category_observed->{$key};
        }
        my $unverifiable = ref($response) eq 'HASH' && ($response->{virtual_picture_settings}
            || $response->{manual_confirmation_required}
            || $response->{picture_mode_read_forbidden});
        my $unsupported = ref($response) eq 'HASH' && ref($response->{unsupported_picture_keys}) eq 'HASH'
            ? $response->{unsupported_picture_keys} : {};
        foreach my $key (@{$by_category{$category}}) {
            $meta{$key} = {
                unverifiable => $unverifiable ? 1 : 0,
                unsupported => exists($unsupported->{$key}) ? 1 : 0,
                error => (ref($response) ne 'HASH' || ($response->{status} || '') eq 'error') ? 1 : 0,
            };
        }
    }
    my $response = @responses == 1 ? $responses[0]{response} : {
        status => (grep { ref($_->{response}) ne 'HASH' || ($_->{response}{status} || '') eq 'error' } @responses) ? 'error' : 'ok',
        responses => \@responses,
    };
    my $all = 1;
    my $any_unverifiable = 0;
    my $hard_failure = 0;
    my $storage_failure = 0;
    my %values;
    foreach my $key (@keys) {
        my $has = exists($observed{$key});
        my $ok = $has ? _value_agrees($expected{$key}, $observed{$key}, $key) : 0;
        my $meta = $meta{$key} || {};
        my $can_be_unverifiable = $meta->{unsupported}
            || ($meta->{unverifiable} && !$meta->{error});
        $ok = 0 if $can_be_unverifiable;
        $values{$key} = {
            expected => $expected{$key},
            observed => $has ? $observed{$key} : undef,
            matched => $ok ? JSON::PP::true : JSON::PP::false,
            unverifiable => $can_be_unverifiable ? JSON::PP::true : JSON::PP::false,
        };
        $all = 0 if !$ok;
        $any_unverifiable = 1 if $can_be_unverifiable;
        $hard_failure = 1 if !$ok && !$can_be_unverifiable;
        my $check_saved = _append_setting_check($item_number, $point, {
            key => $key,
            expected => $expected{$key},
            observed => $has ? $observed{$key} : undef,
            verified => $ok ? JSON::PP::true : JSON::PP::false,
            result => $ok ? 'verified' : ($can_be_unverifiable ? 'unverifiable' : 'mismatch'),
            category => _setting_category($item, $key),
        });
        $storage_failure = 1 if !$check_saved;
    }
    if ($storage_failure) {
        $::LAST_ERROR = 'Unable to persist LG settings verification evidence';
        $hard_failure = 1;
    }
    return {
        verified => $storage_failure ? 0 : ($all ? 1 : ($any_unverifiable && !$hard_failure ? 'unverifiable' : 0)),
        values => \%values,
        response => $response,
    };
}

sub _apply_and_verify {
    my ($item_number, $item, $point) = @_;
    my $settings = _item_settings($item);
    my @keys = sort keys %$settings;
    my $last;
    for my $cycle (1..3) {
        if (_picture_mode($item) ne '') {
            my $mode_result = _apply_one_setting($item, 'pictureMode', _picture_mode($item), 'picture');
            if (!$mode_result || (($mode_result->{status} || '') ne 'ok' && ($mode_result->{status} || '') ne 'started')) {
                $::LAST_ERROR = $mode_result->{message} || 'Unable to select LG picture mode';
                return 0;
            }
            _sleep_controlled(0 + ($item->{settle_seconds} // 8)) or return 0;
        }
        foreach my $key (@keys) {
            my $category = _setting_category($item, $key);
            my $result = _apply_one_setting($item, $key, $settings->{$key}, $category);
            if (!$result || (($result->{status} || '') ne 'ok' && ($result->{status} || '') ne 'started')) {
                $::LAST_ERROR = $result->{message} || "Unable to set LG picture key $key";
                return 0;
            }
        }
        $last = _read_and_verify_settings($item_number, $item, $point);
        return $last->{verified} if $last->{verified} eq 'unverifiable' || $last->{verified};
    }
    $::LAST_ERROR = "LG settings did not verify at $point after three cycles";
    return 0;
}

sub _apply_signal {
    my ($item) = @_;
    my $signal = _signal($item);
    my $config = {
        signal_mode => $signal,
        requested_signal_mode => $signal,
    };
    $config->{dv_map_mode} = $item->{dv_map_mode} || '1' if $signal eq 'dv';
    foreach my $key (qw(color_format rgb_quant_range max_bpc eotf primaries colorimetry)) {
        $config->{$key} = $item->{$key} if exists($item->{$key}) && defined($item->{$key});
    }
    my $result = _api('POST', '/api/config', $config);
    if (!$result || ($result->{status} || '') ne 'ok') {
        $::LAST_ERROR = $result->{message} || 'Unable to apply signal format';
        return 0;
    }
    my $deadline = time() + 35;
    my $pattern_sent = 0;
    while (time() < $deadline) {
        my $ping = _api('GET', '/api/ping', undef);
        my $config = _api('GET', '/api/config', undef);
        my $reported = lc($config->{signal_mode} || '');
        if (($ping->{ok} || $ping->{status} || '') && ($reported eq $signal || $signal eq 'hdr10' && $reported eq 'hdr')) {
            if (!$pattern_sent) {
                my $pattern = _api('POST', '/api/pattern', {
                    name => 'gray50',
                    signal_mode => $signal,
                    max_luma => $item->{max_luma} || 1000,
                });
                $pattern_sent = 1 if ($pattern->{status} || '') eq 'ok';
            }
            if ($pattern_sent && _picture_mode($item) ne '') {
                my $tv = _api('POST', '/api/lg/picture-settings', {
                    keys => ['pictureMode'],
                    picture_mode => _picture_mode($item),
                    signal_mode => $signal,
                    include_current_input => JSON::PP::true,
                    category => 'picture',
                }, 0, 0);
                my $observed = _observed_settings($tv);
                return 1 if ref($observed) eq 'HASH'
                    && _signal_mode_compatible($signal, $observed->{pictureMode});
            } elsif ($pattern_sent) {
                return 1;
            }
        }
        _sleep_controlled(2) or return 0;
    }
    $::LAST_ERROR = 'Renderer did not settle on the queued signal format';
    return 0;
}

sub _set_dv_map {
    my ($item, $mode) = @_;
    return 1 if _signal($item) ne 'dv';
    my $current = _api('GET', '/api/config', undef);
    return 1 if "$current->{dv_map_mode}" eq "$mode";
    my $result = _api('POST', '/api/config', { dv_map_mode => "$mode", signal_mode => 'dv' });
    return 0 if !$result || ($result->{status} || '') ne 'ok';
    my $deadline = time() + 30;
    while (time() < $deadline) {
        my $ping = _api('GET', '/api/ping', undef);
        my $config = _api('GET', '/api/config', undef);
        if (($ping->{ok} || $ping->{status} || '') && "$config->{dv_map_mode}" eq "$mode") {
            my $pattern = _api('POST', '/api/pattern', {
                name => 'gray50',
                signal_mode => 'dv',
                max_luma => $item->{max_luma} || 1000,
            });
            return 1 if ($pattern->{status} || '') eq 'ok';
        }
        _sleep_controlled(1) or return 0;
    }
    return 0;
}

sub _begin_run {
    my ($item) = @_;
    my $result = _api('POST', '/api/lg/autocal/run/begin', {
        workflow => 'automation',
        controller_id => 'automation-runner',
        client_run_token => $TOKEN,
        config => {
            signal_mode => _signal($item),
            picture_mode => _picture_mode($item),
            target_gamma => $item->{target_gamma} || '',
            target_gamut => $item->{target_gamut} || '',
            luminance_target => $item->{target_luminance} || undef,
        },
    });
    return $result;
}

sub _reset_for_calibration {
    my ($item_number, $item) = @_;
    my $signal = _signal($item);
    my $mode = _picture_mode($item);
    my $begin = _begin_run($item);
    if (!$begin || (($begin->{status} || '') ne 'ok' && ($begin->{status} || '') ne 'started')) {
        $::LAST_ERROR = $begin->{message} || 'Unable to begin the LG automation run';
        return 0;
    }
    _update_run(sub { $_[0]{lg_run_id} = $begin->{run_id} if $begin->{run_id}; });
    my @responses;
    if ($signal eq 'sdr') {
        my $picture = _api('POST', '/api/lg/picture-settings/reset', {
            picture_mode => $mode,
            signal_mode => 'sdr',
            require_white_balance_reset => JSON::PP::true,
            helper_timeout => 170,
        });
        push @responses, { picture_reset => $picture };
        if (!$picture || ($picture->{status} || '') ne 'ok') {
            $::LAST_ERROR = $picture->{message} || 'Unable to reset the LG picture mode';
            return 0;
        }
        my $slots = [ (0) x 22 ];
        my $ddc = _api('POST', '/api/lg/picture-settings/set', {
            settings => {
                whiteBalanceMethod => '22',
                whiteBalanceIre => '109',
                ddc_layout => 'sdr26',
                whiteBalanceRed => $slots,
                whiteBalanceGreen => $slots,
                whiteBalanceBlue => $slots,
                adjustingLuminance => $slots,
            },
            picture_mode => $mode,
            signal_mode => 'sdr',
            reset_ddc_baseline => JSON::PP::true,
            force_ddc_white_balance => JSON::PP::true,
            lg_autocal_sdr_1d_dpg_upload_enabled => JSON::PP::true,
            readback_keys => [qw(whiteBalanceMethod whiteBalanceIre adjustingLuminance)],
        });
        push @responses, { ddc_reset => $ddc };
        if (!$ddc || ($ddc->{status} || '') ne 'ok') {
            $::LAST_ERROR = $ddc->{message} || 'Unable to reset the SDR DDC baseline';
            return 0;
        }
        my $reference = _api('POST', '/api/lg/sdr-calman-reset', {
            picture_mode => $mode,
            action => 'sdr_calman_reset',
            ddc_layout => 'sdr26',
            helper_timeout => 170,
        });
        push @responses, { sdr_calman_reset => $reference };
        if (!$reference || ($reference->{status} || '') ne 'ok') {
            $::LAST_ERROR = $reference->{message} || 'Unable to complete the SDR calibration reset';
            return 0;
        }
    } else {
        my $endpoint = $signal eq 'dv' ? '/api/lg/dv-calman-reset' : '/api/lg/hdr-calman-reset';
        my $reset = _api('POST', $endpoint, {
            picture_mode => $mode,
            signal_mode => $signal,
            action => $signal eq 'dv' ? 'dv_calman_reset' : 'hdr_calman_reset',
            ddc_layout => 'hdr20',
            helper_timeout => 170,
        });
        push @responses, { hdr_calman_reset => $reset };
        if (!$reset || ($reset->{status} || '') ne 'ok') {
            $::LAST_ERROR = $reset->{message} || 'Unable to complete the HDR calibration reset';
            return 0;
        }
    }
    if ($signal ne 'dv') {
        my $lut = _api('POST', '/api/lg/3d-lut/reset', {
            picture_mode => $mode,
            signal_mode => $signal,
            upload_command => $signal eq 'hdr10' ? 'BT2020_3D_LUT_DATA' : '',
            get_command => $signal eq 'hdr10' ? 'GET_3D_LUT_DATA' : '',
            keep_calibration_mode => JSON::PP::false,
            calibration_mode_active => JSON::PP::false,
            helper_timeout => 220,
        });
        push @responses, { lut_reset => $lut };
        if (!$lut || ($lut->{status} || '') ne 'ok') {
            $::LAST_ERROR = $lut->{message} || 'Unable to reset the LG 3D LUT baseline';
            return 0;
        }
    }
    return 0 if !_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/calibration/reset.json', {
        completed_at => time(),
        responses => \@responses,
        calibration_session_unconfirmed => scalar(grep {
            my $response = $_;
            grep { ref($_) eq 'HASH' && $_->{calibration_session_unconfirmed} } values %$response
        } @responses) ? JSON::PP::true : JSON::PP::false,
    });
    return 1;
}

sub _read_white {
    my ($item) = @_;
    my $range = _default_range($item);
    my $max_bpc = $item->{max_bpc} || 10;
    my $code = _grey_code('sdr', 100, $range, $max_bpc);
    my $pattern = _api('POST', '/api/pattern', {
        name => 'patch',
        r => $code, g => $code, b => $code,
        input_max => $max_bpc == 12 ? 4095 : $max_bpc >= 10 ? 1023 : 255,
        size => int($item->{patch_size} || 10),
        signal_mode => 'sdr',
        signal_range => $range,
    });
    return undef if !$pattern || ($pattern->{status} || '') ne 'ok';
    my $read = _api('POST', '/api/meter/read', {
        _measurement_options($item),
        display_type => $item->{display_type} || 'lcd',
        ccss_override => $item->{ccss_override} || '',
        refresh_rate => $item->{refresh_rate} || '',
        name => 'panel-light-white',
        patch_name => 'panel-light-white',
        r => $code, g => $code, b => $code,
        input_max => $max_bpc == 12 ? 4095 : $max_bpc >= 10 ? 1023 : 255,
        size => int($item->{patch_size} || 10),
        patch_size => int($item->{patch_size} || 10),
        signal_mode => 'sdr',
        signal_range => $range,
        transport_signal_range => $range,
        delay_ms => int($item->{delay_ms} // 1000),
    });
    return undef if !$read || (($read->{status} || '') ne 'measuring' && ($read->{status} || '') ne 'starting' && ($read->{status} || '') ne 'ok');
    my $deadline = time() + 240;
    while (time() < $deadline) {
        my $result = _api('GET', '/api/meter/read/result', undef);
        my $state = lc($result->{status} || '');
        return $result if $state eq 'complete' || $state eq 'ok' || exists($result->{luminance}) || exists($result->{Y});
        return undef if $state eq 'error' || $state eq 'cancelled';
        _sleep_controlled(1) or return undef;
    }
    return undef;
}

sub _luminance {
    my ($reading) = @_;
    return undef if ref($reading) ne 'HASH';
    foreach my $key (qw(luminance Y luminance_nits Y_nits white_luminance)) {
        return 0 + $reading->{$key} if defined($reading->{$key}) && "$reading->{$key}" =~ /^-?\d+(?:\.\d+)?$/;
    }
    foreach my $key (qw(reading result data)) {
        my $nested = $reading->{$key};
        my $value = _luminance($nested);
        return $value if defined($value);
    }
    return undef;
}

sub _panel_light_key {
    my ($item) = @_;
    return $item->{panel_light_key} if $item->{panel_light_key};
    my $panel = ref($item->{panel_light}) eq 'HASH' ? $item->{panel_light} : {};
    return $panel->{key} if $panel->{key};
    my $settings = ref($item->{settings}) eq 'HASH' ? $item->{settings} : {};
    foreach my $key (qw(oledPixelBrightness oledLight backlight)) {
        return $key if exists($settings->{$key});
    }
    return '';
}

sub _panel_light_stage {
    my ($item_number, $item) = @_;
    my $panel = ref($item->{panel_light}) eq 'HASH' ? $item->{panel_light} : {};
    my $policy = lc($panel->{policy} || $item->{panel_light_policy} || 'fixed');
    my $key = _panel_light_key($item);
    if ($policy ne 'target') {
        my $verified = _apply_and_verify($item_number, $item, 'c5');
        return 0 if !$verified && $verified ne 'unverifiable';
        return 0 if !_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/panel-light.json', {
            policy => 'fixed',
            key => $key,
            value => $key && ref($item->{settings}) eq 'HASH' ? $item->{settings}{$key} : undef,
            verified => $verified,
            completed_at => time(),
        });
        return 1;
    }
    if (!$key) {
        $::LAST_ERROR = 'Target panel-light policy requires a supported LG panel-light setting';
        return 0;
    }
    my $target = 0 + ($panel->{target_luminance} || $item->{target_luminance} || 100);
    $item->{settings} = {} if ref($item->{settings}) ne 'HASH';
    my $observed = _observed_settings(_api('POST', '/api/lg/picture-settings', {
        keys => [$key], picture_mode => _picture_mode($item), signal_mode => _signal($item),
    }));
    my $current = int($item->{settings}{$key} // $panel->{initial_value} // $observed->{$key} // 50);
    $current = 0 if $current < 0; $current = 100 if $current > 100;
    my $initial = _apply_one_setting($item, $key, $current, 'picture');
    if (!_response_ok($initial)) { $::LAST_ERROR = $initial->{message} || 'Unable to set initial panel light'; return 0; }
    $item->{settings}{$key} = $current;
    _sleep_controlled(2) or return 0;
    my @iterations;
    my $converged = 0;
    my $last_read;
    my $stage_failed = 0;
    for my $iteration (1..8) {
        my $reading = _read_white($item);
        my $luma = _luminance($reading);
        my $entry = { iteration => $iteration, value => $current, reading => $reading, luminance => $luma };
        if (!defined($luma) || $luma <= 0) {
            $entry->{result} = 'measurement-failed';
            $::LAST_ERROR = 'Panel-light control did not receive a valid white luminance measurement';
            $stage_failed = 1;
            push @iterations, $entry;
            last;
        }
        $last_read = $luma;
        my $tolerance = $target * 0.03;
        $tolerance = 2 if $tolerance < 2;
        if (abs($luma - $target) <= $tolerance) {
            $entry->{result} = 'converged';
            $converged = 1;
            push @iterations, $entry;
            last;
        }
        if ($iteration == 8) { push @iterations, $entry; last; }
        my $next = int(($current || 1) * $target / $luma + 0.5);
        $next = 0 if $next < 0;
        $next = 100 if $next > 100;
        if ($next == $current) {
            $entry->{result} = ($current == 0 || $current == 100) ? 'clamped' : 'resolution-limit';
            push @iterations, $entry;
            last;
        }
        $entry->{next_value} = $next;
        push @iterations, $entry;
        my $result = _apply_one_setting($item, $key, $next, 'picture');
        if (!$result || ($result->{status} || '') ne 'ok') {
            $entry->{result} = 'set-failed';
            $::LAST_ERROR = $result->{message} || "Unable to adjust panel light $key";
            $stage_failed = 1;
            last;
        }
        $current = $next;
        $item->{settings}{$key} = $current;
        my $verified = _read_and_verify_settings($item_number, $item, 'c5-panel-iteration');
        if (!$verified->{verified} && $verified->{verified} ne 'unverifiable') {
            $entry->{result} = 'set-unverified';
            $::LAST_ERROR = 'Panel-light adjustment did not verify against the LG TV';
            $stage_failed = 1;
            last;
        }
        _sleep_controlled(2) or last;
    }
    my $unreachable = !$converged && ($current == 0 || $current == 100);
    if (!$converged && !$unreachable && !$stage_failed) {
        $stage_failed = 1;
        $::LAST_ERROR = 'Panel light did not reach the luminance tolerance within eight measurements';
    }
    my $warning = $converged ? undef : ($unreachable ? 'panel-light-target-unreachable' : 'panel-light-unverifiable');
    my $final_check = { verified => 'unverifiable' };
    if (!$stage_failed) {
        $final_check = _read_and_verify_settings($item_number, $item, 'c5');
        if (!$final_check->{verified} && $final_check->{verified} ne 'unverifiable') {
            $stage_failed = 1;
            $::LAST_ERROR = 'Panel-light stage settings did not verify against the LG TV';
        }
    }
    my $result = {
        policy => 'target',
        key => $key,
        target_luminance => $target,
        iterations => \@iterations,
        settled_value => $current,
        last_luminance => $last_read,
        converged => $converged ? JSON::PP::true : JSON::PP::false,
        settings_verified => $final_check->{verified},
        warning => $warning,
        completed_at => time(),
    };
    delete $result->{warning} if !defined($result->{warning});
    return 0 if !_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/panel-light.json', $result);
    return 0 if $stage_failed;
    push @{$item->{warnings}}, $warning if $warning;
    _update_item_snapshot($item_number, $item);
    return 1;
}

sub _update_item_snapshot {
    my ($item_number, $item) = @_;
    my $path = PGAutomation::item_dir($RUN_ID, $item_number) . '/item.json';
    my ($ok) = PGAutomation::with_lock($path, sub { return $item; });
    _log("item $item_number snapshot update failed") if !$ok;
    return $ok;
}

sub _calibration_greyscale_stage {
    my ($item_number, $item) = @_;
    return 0 if !_set_dv_map($item, '2');
    _log('launching LG greyscale AutoCal worker');
    $ACTIVE_WORKER = 'grey';
    my $grey_start = _start_worker('/api/meter/lg-autocal', '/api/meter/lg-autocal/status', _grey_payload($item));
    if (!$grey_start || ($grey_start->{status} || '') ne 'started') {
        $ACTIVE_WORKER = '';
        $::LAST_ERROR = $grey_start->{message} || 'Unable to start LG greyscale AutoCal';
        return 0;
    }
    _log('LG greyscale AutoCal worker started');
    my $grey = _wait_worker('/api/meter/lg-autocal/status', 'greyscale AutoCal', $item);
    my $copied = _copy_worker_files($item_number, 'grey', $grey);
    if ($STOP_REQUESTED) {
        _log('LG greyscale AutoCal worker retained for stop cleanup');
        return 0 if !$copied || $STOP_REQUESTED;
    }
    return 0 if !$copied;
    if (!ref($grey) || ($grey->{status} || '') ne 'complete') {
        $::LAST_ERROR = $grey->{message} || $grey->{error} || 'Greyscale worker did not complete';
        return 0;
    }
    $ACTIVE_WORKER = '';
    my $verified = $grey->{ddc_upload_verified} || $grey->{final_1d_lut_upload_verified};
    return {verified => $verified ? JSON::PP::true : 'unverifiable',
        final_1d_lut_upload_verified => $grey->{final_1d_lut_upload_verified},
        ddc_upload_verified => $grey->{ddc_upload_verified}};
}

sub _calibration_volume_stage {
    my ($item_number, $item) = @_;
    my $signal = _signal($item);
    if ($signal eq 'dv') {
        return 0 if !_set_dv_map($item, '2');
        _log('launching Dolby Vision profile worker');
        $ACTIVE_WORKER = 'dv';
        my $start = _start_worker('/api/lg/dv-profile/start', '/api/lg/dv-profile/status', _dv_payload($item));
        if (!$start || ($start->{status} || '') ne 'started') {
            $ACTIVE_WORKER = '';
            $::LAST_ERROR = $start->{message} || 'Unable to start Dolby Vision profile measurement';
            return 0;
        }
        _log('Dolby Vision profile worker started');
        my $dv = _wait_worker('/api/lg/dv-profile/status', 'Dolby Vision profile', $item);
        my $copied = _copy_worker_files($item_number, 'dv', $dv);
        if ($STOP_REQUESTED) {
            _log('Dolby Vision profile worker retained for stop cleanup');
            return 0 if !$copied || $STOP_REQUESTED;
        }
        return 0 if !$copied;
        return 0 if !ref($dv) || ($dv->{status} || '') ne 'complete';
        $ACTIVE_WORKER = '';
        my $measurements = $dv->{measurements} || $dv->{dv_profile_measurements} || $dv->{result};
        if (ref($measurements) ne 'HASH') {
            $::LAST_ERROR = 'Dolby Vision profile did not return measurements';
            return 0;
        }
        my $upload = _api('POST', '/api/lg/dv-profile/upload', {
            picture_mode => _picture_mode($item),
            signal_mode => 'dv',
            measurements => $measurements,
            keep_calibration_mode => JSON::PP::true,
            calibration_mode_active => JSON::PP::true,
        });
        if (!$upload || ($upload->{status} || '') ne 'ok') {
            $::LAST_ERROR = $upload->{message} || 'Dolby Vision profile upload failed';
            return 0;
        }
        return 0 if !_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/calibration/dv-profile-upload.json', $upload);
        return 1;
    }
    _log('launching LG 3D LUT AutoCal worker');
    $ACTIVE_WORKER = '3d';
    my $start = _start_worker('/api/meter/lg-3d-autocal/start', '/api/meter/lg-3d-autocal/status', _three_d_payload($item, _run(), $item_number));
    if (!$start || ($start->{status} || '') ne 'started') {
        $ACTIVE_WORKER = '';
        $::LAST_ERROR = $start->{message} || 'Unable to start LG 3D LUT AutoCal';
        return 0;
    }
    _log('LG 3D LUT AutoCal worker started');
    my $three_d = _wait_worker('/api/meter/lg-3d-autocal/status', '3D LUT AutoCal', $item);
    if (ref($three_d) eq 'HASH' && ($three_d->{status} || '') eq 'error' && $three_d->{upload_retry_available}) {
        my $retry = _api('POST', '/api/meter/lg-3d-autocal/retry-upload', { run_id => $RUN_ID });
        if ($retry && ($retry->{status} || '') eq 'started') {
            $three_d = _wait_worker('/api/meter/lg-3d-autocal/status', '3D LUT upload retry', $item);
        }
    }
    my $copied = _copy_worker_files($item_number, '3d', $three_d);
    if ($STOP_REQUESTED) {
        _log('LG 3D LUT AutoCal worker retained for stop cleanup');
        return 0 if !$copied || $STOP_REQUESTED;
    }
    return 0 if !$copied;
    if (!ref($three_d) || ($three_d->{status} || '') ne 'complete') {
        $::LAST_ERROR = $three_d->{message} || '3D LUT AutoCal did not complete';
        return 0;
    }
    $ACTIVE_WORKER = '';
    return {verified => ($three_d->{terminal_commit_verified} || $three_d->{upload_verified})
        ? JSON::PP::true : 'unverifiable', terminal_commit_verified => $three_d->{terminal_commit_verified}};
}

sub _close_calibration {
    my ($item) = @_;
    my ($closed, $off, $status);
    for my $attempt (1..3) {
        $off = _api('POST', '/api/lg/calibration-mode', {
            enabled => JSON::PP::false,
            picture_mode => _picture_mode($item),
            signal_mode => _signal($item),
        });
        $status = _api('GET', '/api/lg/status', undef);
        $closed = ref($status) eq 'HASH' && ($status->{status} || '') eq 'ok'
            && !$status->{disconnected} && exists($status->{calibration_mode}) && !$status->{calibration_mode};
        last if $closed;
        _sleep_controlled(1) or last;
    }
    my $end = _api('POST', '/api/lg/autocal/run/end', {
        status => 'complete',
        note => 'Automation calibration stage complete',
        run_id => $RUN_ID,
        client_run_token => $TOKEN,
    });
    my $end_ok = ref($end) eq 'HASH' && ($end->{status} || '') eq 'ok';
    return ($closed && $end_ok, $off, $status, $end);
}

sub _ensure_calibration_mode_off {
    my ($item) = @_;
    for my $attempt (1..3) {
        my $off = _api('POST', '/api/lg/calibration-mode', {
            enabled => JSON::PP::false,
            picture_mode => _picture_mode($item),
            signal_mode => _signal($item),
        });
        my $status = _api('GET', '/api/lg/status', undef);
        return 1 if ref($status) eq 'HASH' && ($status->{status} || '') eq 'ok'
            && !$status->{disconnected} && exists($status->{calibration_mode}) && !$status->{calibration_mode};
        _sleep_controlled(1) or return 0;
    }
    $::LAST_ERROR = 'LG calibration mode could not be confirmed off';
    return 0;
}

sub _quality_value {
    my ($snapshot) = @_;
    my @values;
    foreach my $reading (@{$snapshot->{readings} || []}) {
        next if ref($reading) ne 'HASH';
        my $value;
        foreach my $key (qw(deltaE delta_e dE de de_itp deltaEITP)) {
            if (defined($reading->{$key}) && "$reading->{$key}" =~ /^\d+(?:\.\d+)?$/) {
                $value = 0 + $reading->{$key};
                last;
            }
        }
        push @values, $value if defined($value);
    }
    return (undef, undef, 0) if !@values;
    my $sum = 0;
    $sum += $_ for @values;
    my ($max) = sort { $b <=> $a } @values;
    return ($sum / @values, $max, scalar(@values));
}

sub _quality_stage {
    my ($item_number, $item) = @_;
    my $quality = ref($item->{quality}) eq 'HASH' ? $item->{quality} : {};
    my $result = {
        enabled => $quality->{enabled} ? JSON::PP::true : JSON::PP::false,
        formula => $quality->{dE_formula} || $item->{delta_e_formula} || 'deitp',
        series => {},
        warnings => [],
        completed_at => time(),
    };
    if ($quality->{enabled}) {
        my $limits = ref($quality->{limits}) eq 'HASH' ? $quality->{limits} : {};
        foreach my $key (_series_selection($item, 'post')) {
            my $snapshot = PGAutomation::read_json_file(PGAutomation::item_dir($RUN_ID, $item_number) . "/post/$key.json") || {};
            my ($average, $max, $count, $missing) = PGAutomation::quality_summary(
                $snapshot, $result->{formula}, $item->{target_white});
            my $limit = ref($limits->{$key}) eq 'HASH' ? $limits->{$key} : {};
            my $miss = (defined($average) && defined($limit->{avg}) && $average > $limit->{avg})
                || (defined($max) && defined($limit->{max}) && $max > $limit->{max});
            $result->{series}{$key} = {
                average => $average,
                maximum => $max,
                readings => $count,
                limits => $limit,
                missing_readings => $missing,
                passed => !$count || $missing ? undef : ($miss ? JSON::PP::false : JSON::PP::true),
            };
            push @{$result->{warnings}}, {
                code => 'quality-limit',
                series => $key,
                average => $average,
                maximum => $max,
            } if $miss;
            push @{$result->{warnings}}, {code => 'quality-unverifiable', series => $key,
                message => 'Missing measurements or target metadata; quality was not verified'}
                if !$count || $missing;
        }
    }
    return undef if !_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/quality.json', $result);
    return $result;
}

sub _apply_all {
    my ($item_number, $item) = @_;
    my $fault = PGAutomation::read_json_file(PGAutomation::base_dir() . '/fault.json');
    if (ref($fault) eq 'HASH' && ($fault->{stage} || '') eq 'apply-all' && ($fault->{mode} || '') eq 'error') {
        unlink(PGAutomation::base_dir() . '/fault.json');
        $item->{fault_injected} = JSON::PP::true;
        if (!_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/apply-all.json', {
            status => 'error',
            error_code => 'fault-injected',
            fault_injected => JSON::PP::true,
            completed_at => time(),
        })) {
            return 0;
        }
        $::LAST_ERROR = 'Test fault injected at apply-all';
        return 0;
    }
    my $check = _read_and_verify_settings($item_number, $item, 'c9')->{verified};
    return 0 if !$check && $check ne 'unverifiable';
    my $response = _api('POST', '/api/lg/picture-settings/apply-all-inputs', {
        picture_mode => _picture_mode($item),
        signal_mode => _signal($item),
    });
    my $outcome = 'failed';
    if (ref($response) eq 'HASH' && ($response->{status} || '') eq 'ok') {
        $outcome = $response->{confirmed} ? 'confirmed'
            : ($response->{acknowledged} ? 'unverified' : 'unverified');
    }
    my $record = {
        %{$response || {}},
        outcome => $outcome,
        completed_at => time(),
    };
    return 0 if !_write_artifact(PGAutomation::item_dir($RUN_ID, $item_number) . '/apply-all.json', $record);
    my $error_code = ref($response) eq 'HASH' ? ($response->{error_code} || '') : '';
    if ($outcome eq 'failed' || $error_code =~ /^(?:lg-calibration-session-held|apply-all-inputs-unsupported)$/) {
        $::LAST_ERROR = (ref($response) eq 'HASH' ? $response->{message} : undef) || 'LG apply-to-all-inputs failed';
        return 0;
    }
    $item->{warnings} ||= [];
    push @{$item->{warnings}}, 'apply-all-unverified' if $outcome eq 'unverified';
    return {verified => $outcome eq 'confirmed' ? JSON::PP::true : 'unverifiable', outcome => $outcome};
}

sub _checkpoint_record {
    my ($item_number, $item, $name, $verified, $evidence, $status) = @_;
    $status = 'done' if !defined($status);
    my $record = {
        name => $name,
        status => $status,
        verified => $verified,
        evidence => $evidence || {},
        completed_at => time(),
    };
    _log("checkpoint $name write started for item $item_number status=$status verified=" . (defined($verified) ? $verified : ''));
    $item->{checkpoints} ||= [];
    push @{$item->{checkpoints}}, $record;
    $item->{checkpoint} = $name;
    $item->{checkpoint_status} = $status;
    $item->{active_stage} = '';
    my $item_saved = _update_item_snapshot($item_number, $item);
    my $run_saved = _update_run(sub {
        my ($run) = @_;
        $run->{active_stage} = '';
        $run->{checkpoint} = $name;
        $run->{last_checkpoint} = $record;
        $run->{items}[$item_number] = $item if ref($run->{items}) eq 'ARRAY';
    });
    my $artifacts_saved = _copy_worker_files($item_number, 'grey', undef)
        && _copy_worker_files($item_number, '3d', undef)
        && _copy_worker_files($item_number, 'dv', undef);
    if (!$item_saved || !$run_saved || !$artifacts_saved) {
        $::LAST_ERROR = 'Unable to persist automation checkpoint evidence';
        _log($::LAST_ERROR);
        return undef;
    }
    _log("checkpoint $name written for item $item_number status=$status verified=" . (defined($verified) ? $verified : ''));
    return $record;
}

sub _checkpoint_exists {
    my ($item, $name) = @_;
    return 0 if ref($item->{checkpoints}) ne 'ARRAY';
    foreach my $record (@{$item->{checkpoints}}) {
        return 1 if ref($record) eq 'HASH' && ($record->{name} || '') eq $name
            && ($record->{status} || '') eq 'done';
    }
    return 0;
}

sub _last_checkpoint {
    my ($item) = @_;
    return undef if ref($item->{checkpoints}) ne 'ARRAY' || !@{$item->{checkpoints}};
    my @records = grep { ($_->{status} || '') ne 'skipped' } @{$item->{checkpoints}};
    return $records[-1];
}

sub _skip_stage {
    my ($item_number, $item, $name) = @_;
    return if grep { ($_->{name} || '') eq $name && ($_->{status} || '') eq 'skipped' } @{$item->{checkpoints} || []};
    die($::LAST_ERROR || "Unable to persist skipped checkpoint $name")
        if !ref(_checkpoint_record($item_number, $item, $name, 'unverifiable', { skipped => JSON::PP::true }, 'skipped'));
}

sub _stage {
    my ($item_number, $item, $name, $callback) = @_;
    return 1 if _checkpoint_exists($item, $name);
    _refresh_control();
    return 0 if $STOP_REQUESTED;
    $::LAST_ERROR = '';
    $::LAST_ERROR_CODE = '';
    $ACTIVE_STAGE = $name;
    $item->{active_stage} = $name;
    $item->{stage_started_at} = time();
    _log("stage $name started for item $item_number");
    _update_item_snapshot($item_number, $item);
    _update_run(sub {
        my ($run) = @_;
        $run->{active_item} = $item_number;
        $run->{active_stage} = $name;
        $run->{items}[$item_number] = $item if ref($run->{items}) eq 'ARRAY';
    });
    my $ok = eval { $callback->(); };
    $ok = 0 if !$ok || $@;
    _refresh_control();
    if ($STOP_REQUESTED) {
        _log("stage $name interrupted by stop request for item $item_number");
        return 0;
    }
    if (!$ok) {
        my $message = $::LAST_ERROR || ($@ || "Stage $name failed");
        my $resumable = 1;
        $item->{status} = $resumable ? 'interrupted' : 'failed';
        $item->{failure} = { stage => $name, message => "$message", at => time() };
        $item->{failure}{error_code} = $::LAST_ERROR_CODE if $::LAST_ERROR_CODE;
        _update_item_snapshot($item_number, $item);
        _update_run(sub {
            my ($run) = @_;
            $run->{status} = $resumable ? 'interrupted' : 'failed';
            $run->{failure} = $item->{failure};
            $run->{items}[$item_number] = $item if ref($run->{items}) eq 'ARRAY';
        });
        _log("$name failed: $message");
        return 0;
    }
    my $verified = ref($ok) eq 'HASH' ? ($ok->{verified} // 1) : 1;
    if (defined($verified) && $verified eq 'unverifiable') {
        $item->{warnings} ||= [];
        push @{$item->{warnings}}, "$name-unverified"
            if !grep { !ref($_) && $_ eq "$name-unverified" } @{$item->{warnings}};
    }
    my $evidence = ref($ok) eq 'HASH' ? $ok : { result => $ok };
    my $checkpoint = _checkpoint_record($item_number, $item, $name, $verified, $evidence);
    if (!ref($checkpoint)) {
        my $message = $::LAST_ERROR || "Unable to persist checkpoint $name";
        $item->{status} = 'failed';
        $item->{failure} = { stage => $name, message => $message, at => time() };
        _update_item_snapshot($item_number, $item);
        _update_run(sub {
            my ($run) = @_;
            $run->{status} = 'failed';
            $run->{failure} = $item->{failure};
            $run->{items}[$item_number] = $item if ref($run->{items}) eq 'ARRAY';
        });
        _log("$name checkpoint failed: $message");
        return 0;
    }
    $ACTIVE_STAGE = '';
    $ACTIVE_WORKER = '';
    _log("stage $name completed for item $item_number");
    _refresh_control();
    return 1;
}

sub _pause_after_checkpoint {
    _refresh_control();
    return 0 if !$PAUSE_REQUESTED || $STOP_REQUESTED;
    die 'Unable to persist paused automation state' if !ref(_update_run(sub {
        my ($run) = @_;
        $run->{status} = 'paused';
        $run->{paused_at} = time();
        $run->{runner_pid} = 0;
        $run->{active_stage} = '';
    }));
    unlink($RUN_DIR . '/runner.pid');
    die 'Unable to persist paused execution state' if !_write_execution();
    _log('pause reached a checkpoint; runner exiting');
    return 1;
}

sub _park_interrupted {
    my ($stage) = @_;
    _update_run(sub {
        my ($run) = @_;
        $run->{status} = 'interrupted';
        $run->{runner_pid} = 0;
        $run->{active_stage} = $stage if defined($stage) && $stage ne '';
        $run->{updated_at} = time();
    });
    PGAutomation::with_lock($EXECUTION_FILE, sub {
        my ($current) = @_;
        return undef if ref($current) ne 'HASH'
            || ($current->{run_id} || '') ne $RUN_ID
            || ($current->{token} || '') ne $TOKEN;
        $current->{status} = 'interrupted';
        $current->{pid} = 0;
        $current->{updated_at} = time();
        return $current;
    });
    unlink($RUN_DIR . '/runner.pid');
    $ACTIVE_STAGE = '';
    $ACTIVE_WORKER = '';
    _log('runner parked an interrupted run for resume');
}

sub _stop_active {
    return if $STOP_HANDLED++;
    $STOPPING = 1;
    my %stop_path = (
        series => '/api/meter/series/stop',
        grey => '/api/meter/lg-autocal/stop',
        '3d' => '/api/meter/lg-3d-autocal/stop',
        dv => '/api/lg/dv-profile/stop',
    );
    my %kill_path = (
        series => '/api/meter/series/kill',
        grey => '/api/meter/lg-autocal/kill',
        '3d' => '/api/meter/lg-3d-autocal/kill',
        dv => '/api/lg/dv-profile/kill',
    );
    if ($ACTIVE_WORKER && $stop_path{$ACTIVE_WORKER}) {
        _log("stopping active $ACTIVE_WORKER worker");
        _api('POST', $stop_path{$ACTIVE_WORKER}, { automation_graceful => JSON::PP::true }, 1, 0);
        my $status_path = $ACTIVE_WORKER eq 'series' ? '/api/meter/series/status'
            : $ACTIVE_WORKER eq 'grey' ? '/api/meter/lg-autocal/status'
            : $ACTIVE_WORKER eq '3d' ? '/api/meter/lg-3d-autocal/status'
            : '/api/lg/dv-profile/status';
        my $deadline = time() + 60;
        my $worker_exited = 0;
        my $last_stop_state = '';
        while (time() < $deadline) {
            my $status = _api('GET', $status_path, undef, 1, 0);
            my $alive = _worker_process_alive($ACTIVE_WORKER);
            my $stop_state = (ref($status) eq 'HASH' ? ($status->{status} || '') : 'unavailable')
                . ":alive=$alive";
            if ($stop_state ne $last_stop_state) {
                _log("stop poll $ACTIVE_WORKER status=$stop_state");
                $last_stop_state = $stop_state;
            }
            if (!$alive && ref($status) eq 'HASH' && _status_terminal($status->{status} || '')) {
                $worker_exited = 1;
                last;
            }
            select(undef, undef, undef, 2);
        }
        if (!$worker_exited) {
            _log("active $ACTIVE_WORKER worker did not exit within 60 seconds; escalating to kill endpoint");
            _api('POST', $kill_path{$ACTIVE_WORKER}, { automation_force => JSON::PP::true }, 1, 0);
            my $kill_deadline = time() + 10;
            while (time() < $kill_deadline && _worker_process_alive($ACTIVE_WORKER)) {
                select(undef, undef, undef, 1);
            }
            _log("stop cleanup $ACTIVE_WORKER process_alive=" . (_worker_process_alive($ACTIVE_WORKER) ? 1 : 0));
        }
    }
    if ($ACTIVE_WORKER eq 'series' && $ACTIVE_ITEM && $ACTIVE_SERIES_KEY && $ACTIVE_SERIES_PHASE) {
        my $partial = PGAutomation::read_json_file('/tmp/meter_series.json');
        _snapshot_series($ACTIVE_ITEM->{item_number} || 0, $ACTIVE_SERIES_PHASE, $ACTIVE_SERIES_KEY, $partial)
            if ref($partial) eq 'HASH';
    }
    my $meter_session = _api('POST', '/api/meter/session/stop', {}, 1, 0);
    _log('stop cleanup meter session=' . (($meter_session && ref($meter_session) eq 'HASH' && ($meter_session->{status} || '') eq 'ok') ? 'ok' : 'failed'));
    if ($ACTIVE_ITEM && ref($ACTIVE_ITEM) eq 'HASH') {
        my $item = $ACTIVE_ITEM;
        my $number = $item->{item_number} || 0;
        my $preserve_failure = ref($item->{failure}) eq 'HASH' && !$STOP_REQUESTED;
        my $interrupted_stage = $ACTIVE_STAGE || $item->{active_stage} || 'unknown';
        my $off = _api('POST', '/api/lg/calibration-mode', {
            enabled => JSON::PP::false,
            picture_mode => _picture_mode($item),
            signal_mode => _signal($item),
        }, 1, 0);
        my $end = _api('POST', '/api/lg/autocal/run/end', {
            status => 'aborted',
            note => 'Automation stopped',
            run_id => $RUN_ID,
            client_run_token => $TOKEN,
        }, 1, 0);
        my $status = _api('GET', '/api/lg/status', undef, 1, 0);
        my $closed = _response_ok($off) && _response_ok($end) && _response_ok($status)
            && !$status->{disconnected} && exists($status->{calibration_mode}) && !$status->{calibration_mode};
        _write_artifact(PGAutomation::item_dir($RUN_ID, $number) . '/calibration/stop-cleanup.json', {
            verified => $closed ? JSON::PP::true : JSON::PP::false,
            calibration_mode => $off, run_end => $end, tv_status => $status,
        });
        push @{$item->{warnings}}, 'stop-cleanup-unverified' if !$closed;
        my $visible = _api('POST', '/api/pattern', {
            name => 'gray50',
            signal_mode => _signal($item),
        }, 1, 0);
        _log('stop cleanup visible pattern=' . (ref($visible) eq 'HASH' ? ($visible->{status} || 'unknown') : 'unavailable'));
        $item->{status} = 'stopped' if !$preserve_failure;
        $item->{failure} = { stage => $interrupted_stage, status => 'interrupted', at => time() }
            if !$preserve_failure;
        if (!$preserve_failure && $interrupted_stage ne 'unknown') {
            _checkpoint_record($number, $item, $interrupted_stage, JSON::PP::false, { interrupted => JSON::PP::true }, 'interrupted');
        }
        _update_item_snapshot($number, $item);
    }
    $STOPPING = 0;
}

sub _finish {
    my ($status, $failure) = @_;
    my $meter_session = _api('POST', '/api/meter/session/stop', {}, 1, 0);
    _log('finish cleanup meter session=' . (($meter_session && ref($meter_session) eq 'HASH' && ($meter_session->{status} || '') eq 'ok') ? 'ok' : 'failed'));
    _update_run(sub {
        my ($run) = @_;
        $run->{status} = $status;
        $run->{completed_at} = time() if $status =~ /^(?:complete|failed|stopped)$/;
        $run->{runner_pid} = 0;
        $run->{active_stage} = '';
        $run->{failure} = $failure if ref($failure) eq 'HASH';
    });
    unlink($RUN_DIR . '/runner.pid');
    _release_execution();
}

sub _restore_hazards {
    my ($item) = @_;
    my $restore = ref($item->{hazard_restore}) eq 'HASH' ? $item->{hazard_restore} : {};
    foreach my $key (keys %$restore) {
        my $record = $restore->{$key};
        next if $key eq 'energySaving' || $key eq 'aiPicture';
        my ($value,$category);
        if (ref($record) eq 'HASH') {
            $value = $record->{value};
            $category = $record->{category} || 'picture';
        } else {
            $value = $record;
            $category = _setting_category($item, $key);
        }
        next if !defined($value);
        my $result = _api('POST', '/api/lg/picture-settings/set', {
            settings => { $key => $value }, category => $category,
            picture_mode => _picture_mode($item), signal_mode => _signal($item),
        }, 1, 0);
        _log("Hazard restoration failed for $key: " . ($result->{message} || 'no response'))
            if !_response_ok($result);
    }
}

sub _restore_run_hazards {
    my ($run, $items) = @_;
    my %restore;
    if (ref($run) eq 'HASH' && ref($run->{hazard_restore}) eq 'HASH') {
        %restore = %{$run->{hazard_restore}};
    }
    if (!%restore) {
        foreach my $item (@{$items || []}) {
            next if ref($item) ne 'HASH';
            foreach my $key (keys %{$item->{hazard_restore} || {}}) {
                $restore{$key} = $item->{hazard_restore}{$key}
                    if !exists($restore{$key});
            }
        }
    }
    return if !%restore;
    my $context = ref($ACTIVE_ITEM) eq 'HASH' ? $ACTIVE_ITEM
        : (ref($items) eq 'ARRAY' && ref($items->[0]) eq 'HASH' ? $items->[0] : {});
    _restore_hazards({ %$context, hazard_restore => \%restore });
}

sub _drop_resume_checkpoints {
    my ($item, $names) = @_;
    $item->{checkpoints} = [grep {
        ref($_) eq 'HASH' && !$names->{$_->{name} || ''}
    } @{$item->{checkpoints} || []}];
}

sub _resume_series_artifacts_ok {
    my ($item_number, $item, $which) = @_;
    foreach my $key (_series_selection($item, $which)) {
        my $path = PGAutomation::item_dir($RUN_ID, $item_number) . "/$which/$key.json";
        my $snapshot = PGAutomation::read_json_file($path);
        return 0 if ref($snapshot) ne 'HASH' || ($snapshot->{status} || '') ne 'complete';
    }
    return 1;
}

sub _resume_calibration_artifacts_ok {
    my ($item_number, $item, $kind) = @_;
    my $dir = PGAutomation::item_dir($RUN_ID, $item_number) . '/calibration';
    if ($kind eq 'grey') {
        my $state = PGAutomation::read_json_file($dir . '/grey-state.json');
        return ref($state) eq 'HASH' && ($state->{status} || '') eq 'complete'
            && ($state->{ddc_upload_verified} || $state->{final_1d_lut_upload_verified});
    }
    if (_signal($item) eq 'dv') {
        my $state = PGAutomation::read_json_file($dir . '/dv-profile-state.json');
        my $upload = PGAutomation::read_json_file($dir . '/dv-profile-upload.json');
        return ref($state) eq 'HASH' && ($state->{status} || '') eq 'complete'
            && ref($upload) eq 'HASH' && ($upload->{status} || '') eq 'ok';
    }
    my $state = PGAutomation::read_json_file($dir . '/3d-state.json');
    return 0 if ref($state) ne 'HASH' || ($state->{status} || '') ne 'complete';
    my $export = ref($state->{export}) eq 'HASH' ? $state->{export} : {};
    my @files;
    foreach my $source (map { $export->{$_} || '' } qw(cube_path payload_path)) {
        next if $source !~ m{/([A-Za-z0-9_.-]+)$};
        push @files, $dir . '/' . $1;
    }
    my $files_exist = @files >= 2 && !grep { !-f $_ } @files;
    return ($state->{terminal_commit_verified} || $state->{upload_verified}) && $files_exist;
}

sub _prepare_resume {
    my ($item_number, $item) = @_;
    die($::LAST_ERROR || 'Unable to restore the queued signal format') if !_apply_signal($item);
    my $last = _last_checkpoint($item);
    return if !ref($last);
    my $failure_stage = ref($item->{failure}) eq 'HASH' ? ($item->{failure}{stage} || '') : '';
    if ($item->{drift_recovery_pending} || $failure_stage =~ /^(?:reset-and-reapply-verified|panel-light-settled|greyscale-done|volume-done|session-closed)$/) {
        _drop_resume_checkpoints($item, { map { $_ => 1 } qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete) });
        return;
    }
    my $name = $last->{name} || '';
    if (($last->{status} || '') ne 'done') {
        if ($name eq 'apply-all-done') {
            _drop_resume_checkpoints($item, { 'apply-all-done' => 1 });
        } else {
            _drop_resume_checkpoints($item, { map { $_ => 1 } qw(
                reset-and-reapply-verified panel-light-settled greyscale-done
                volume-done session-closed apply-all-done post-readings-done item-complete
            ) });
        }
        return;
    }
    if ($name eq 'pre-readings-done' && !_resume_series_artifacts_ok($item_number, $item, 'pre')) {
        _drop_resume_checkpoints($item, { map { $_ => 1 } qw(pre-readings-done reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete) });
        return;
    }
    if ($name eq 'greyscale-done' && !_resume_calibration_artifacts_ok($item_number, $item, 'grey')) {
        _drop_resume_checkpoints($item, { map { $_ => 1 } qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete) });
        return;
    }
    if ($name eq 'volume-done' && !_resume_calibration_artifacts_ok($item_number, $item, 'volume')) {
        _drop_resume_checkpoints($item, { map { $_ => 1 } qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete) });
        return;
    }
    if ($name eq 'panel-light-settled' && !-f(PGAutomation::item_dir($RUN_ID, $item_number) . '/panel-light.json')) {
        _drop_resume_checkpoints($item, { map { $_ => 1 } qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete) });
        return;
    }
    if ($name eq 'apply-all-done' && !-f(PGAutomation::item_dir($RUN_ID, $item_number) . '/apply-all.json')) {
        _drop_resume_checkpoints($item, { map { $_ => 1 } qw(apply-all-done post-readings-done item-complete) });
        return;
    }
    my %verification_point = (
        'tv-setup-verified' => 'resume-c1',
        'reset-and-reapply-verified' => 'resume-c4',
        'panel-light-settled' => 'resume-c5',
        'session-closed' => 'resume-c8',
        'apply-all-done' => 'resume-c9',
        'post-readings-done' => 'resume-c10',
    );
    if (exists($verification_point{$name})) {
        my $check = _read_and_verify_settings($item_number, $item, $verification_point{$name});
        if (!$check->{verified} && $check->{verified} ne 'unverifiable') {
            my %drop_from = (
                'tv-setup-verified' => [qw(tv-setup-verified warmup-done pre-readings-done reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete)],
                'reset-and-reapply-verified' => [qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete)],
                'panel-light-settled' => [qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete)],
                'session-closed' => [qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete)],
                'apply-all-done' => [qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete)],
                'post-readings-done' => [qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done post-readings-done item-complete)],
            );
            _drop_resume_checkpoints($item, { map { $_ => 1 } @{$drop_from{$name} || []} });
        }
    }
}

sub _run_item {
    my ($item_number, $item) = @_;
    $ACTIVE_ITEM = $item;
    $item->{item_number} = $item_number;
    _ensure_lg_connection();
    $item->{status} = 'running';
    my $has_prior_checkpoint = ref($item->{checkpoints}) eq 'ARRAY' && @{$item->{checkpoints}};
    if ($has_prior_checkpoint) {
        my $readiness = _api('POST', '/api/automation/readiness', { items => [$item], automation_token => $TOKEN });
        if (!$readiness->{ready}) {
            $::LAST_ERROR = $readiness->{message} || 'Per-item readiness failed during resume';
            $item->{status} = 'failed';
            $item->{failure} = { stage => 'readiness', message => $::LAST_ERROR, at => time() };
            $item->{failure}{error_code} = $::LAST_ERROR_CODE if $::LAST_ERROR_CODE;
            _update_item_snapshot($item_number, $item);
            _update_run(sub {
                my ($run) = @_;
                $run->{status} = 'failed';
                $run->{failure} = $item->{failure};
                $run->{items}[$item_number] = $item if ref($run->{items}) eq 'ARRAY';
            });
            return 0;
        }
        if (ref($readiness->{items}) eq 'ARRAY' && ref($readiness->{items}[0]) eq 'HASH') {
            my $checkpoints = $item->{checkpoints};
            my $status = $item->{status};
            %$item = (%$item, %{$readiness->{items}[0]});
            $item->{checkpoints} = $checkpoints if ref($checkpoints) eq 'ARRAY';
            $item->{status} = $status if defined($status) && $status ne '';
        }
        _prepare_resume($item_number, $item);
    }
    delete $item->{failure};
    _update_item_snapshot($item_number, $item);
    _update_run(sub {
        my ($run) = @_;
        $run->{items}[$item_number] = $item if ref($run->{items}) eq 'ARRAY';
        $run->{active_item} = $item_number;
    });
    my $stages = _stages($item);
    return 0 if !_stage($item_number, $item, 'item-started', sub {
        my $readiness = _api('POST', '/api/automation/readiness', { items => [$item] });
        die($readiness->{message} || 'Per-item readiness failed')
            if !$readiness->{ready};
        if (ref($readiness->{items}) eq 'ARRAY' && ref($readiness->{items}[0]) eq 'HASH') {
            my $checkpoints = $item->{checkpoints};
            my $status = $item->{status};
            %$item = (%$item, %{$readiness->{items}[0]});
            $item->{checkpoints} = $checkpoints if ref($checkpoints) eq 'ARRAY';
            $item->{status} = $status if defined($status) && $status ne '';
            _update_item_snapshot($item_number, $item);
            _update_run(sub { $_[0]{items}[$item_number] = $item if ref($_[0]{items}) eq 'ARRAY'; });
        }
        return { readiness => $readiness };
    });
    return 0 if _pause_after_checkpoint();
    return 0 if !_stage($item_number, $item, 'tv-setup-verified', sub {
        die($::LAST_ERROR || 'Signal format failed') if !_apply_signal($item);
        my $verified = _apply_and_verify($item_number, $item, 'c1');
        die($::LAST_ERROR || 'TV settings failed') if !$verified && $verified ne 'unverifiable';
        _sleep_controlled(0 + ($item->{settle_seconds} // 8)) or die('Automation stopped');
        return { verified => $verified, signal_mode => _signal($item), picture_mode => _picture_mode($item) };
    });
    return 0 if _pause_after_checkpoint();
    return 0 if !_stage($item_number, $item, 'warmup-done', sub {
        my $minutes = 0 + ($item->{warmup_minutes} || 0);
        return 1 if $minutes <= 0;
        my $pattern = _api('POST', '/api/pattern', { name => 'gray50', signal_mode => _signal($item) });
        die($pattern->{message} || 'Unable to show warm-up pattern') if ($pattern->{status} || '') ne 'ok';
        _sleep_controlled($minutes * 60) or die('Automation stopped');
        return 1;
    });
    return 0 if _pause_after_checkpoint();
    if ($stages->{pre}) {
        return 0 if !_stage($item_number, $item, 'pre-readings-done', sub {
            die($::LAST_ERROR || 'Calibration mode did not close before pre-readings')
                if !_ensure_calibration_mode_off($item);
            die('Unable to switch DV to Absolute map') if !_set_dv_map($item, '1');
            die($::LAST_ERROR || 'Pre-readings failed') if !_run_series($item_number, $item, 'pre');
            return 1;
        });
    } else {
        _skip_stage($item_number, $item, 'pre-readings-done');
    }
    return 0 if _pause_after_checkpoint();
    if ($stages->{calibration}) {
        my $drift_recovery_attempts = $item->{drift_recovery_attempts} || 0;
        while (1) {
            return 0 if !_stage($item_number, $item, 'reset-and-reapply-verified', sub {
                die($::LAST_ERROR || 'Calibration reset failed') if !_reset_for_calibration($item_number, $item);
                my $verified = _apply_and_verify($item_number, $item, 'c4');
                die($::LAST_ERROR || 'Settings did not survive reset') if !$verified && $verified ne 'unverifiable';
                return { verified => $verified };
            });
            return 0 if _pause_after_checkpoint();
            return 0 if !_stage($item_number, $item, 'panel-light-settled', sub {
                my $panel = ref($item->{panel_light}) eq 'HASH' ? $item->{panel_light} : {};
                die('Panel light is only targetable on SDR') if lc($panel->{policy} || $item->{panel_light_policy} || 'fixed') eq 'target' && _signal($item) ne 'sdr';
                die($::LAST_ERROR || 'Calibration mode did not close before panel-light control')
                    if !_ensure_calibration_mode_off($item);
                die($::LAST_ERROR || 'Panel-light stage failed') if !_panel_light_stage($item_number, $item);
                my $evidence = PGAutomation::read_json_file(PGAutomation::item_dir($RUN_ID, $item_number) . '/panel-light.json') || {};
                return {verified => $evidence->{settings_verified} // $evidence->{verified} // 'unverifiable',
                    panel_light => $evidence};
            });
            return 0 if _pause_after_checkpoint();
            return 0 if !_stage($item_number, $item, 'greyscale-done', sub {
                my $result = _calibration_greyscale_stage($item_number, $item);
                if (!$result) {
                    return 0 if $STOP_REQUESTED;
                    die($::LAST_ERROR || 'Greyscale calibration failed');
                }
                return $result;
            });
            return 0 if _pause_after_checkpoint();
            return 0 if !_stage($item_number, $item, 'volume-done', sub {
                my $result = _calibration_volume_stage($item_number, $item);
                if (!$result) {
                    return 0 if $STOP_REQUESTED;
                    die($::LAST_ERROR || 'Volume calibration failed');
                }
                return $result;
            });
            return 0 if _pause_after_checkpoint();
            my $settings_drifted = 0;
            return 0 if !_stage($item_number, $item, 'session-closed', sub {
                my ($closed, $off, $status, $end) = _close_calibration($item);
                my $end_message = ref($end) eq 'HASH' ? $end->{message} : undef;
                die(($end_message || $::LAST_ERROR || 'LG calibration session could not be closed'))
                    if !$closed;
                my $verified = _read_and_verify_settings($item_number, $item, 'c8');
                if (!$verified->{verified} && $verified->{verified} ne 'unverifiable') {
                    $settings_drifted = 1;
                    $item->{drift_recovery_pending} = 1;
                    my $reapplied = _apply_and_verify($item_number, $item, 'c8-recovery');
                    die($::LAST_ERROR || 'Settings could not be restored after calibration drift')
                        if !$reapplied && $reapplied ne 'unverifiable';
                    $item->{warnings} ||= [];
                    push @{$item->{warnings}}, 'settings-drift'
                        if !grep { $_ eq 'settings-drift' } @{$item->{warnings}};
                    return {
                        verified => $reapplied,
                        calibration_status => $status,
                        settings_drift => JSON::PP::true,
                        recovery => 'reapplied',
                    };
                }
                return { verified => $verified->{verified}, calibration_status => $status };
            });
            last if !$settings_drifted;
            if ($drift_recovery_attempts++ >= 1) {
                $::LAST_ERROR = 'LG settings drifted after the allowed c4-c8 recovery cycle';
                $item->{status} = 'failed';
                $item->{failure} = { stage => 'session-closed', message => $::LAST_ERROR, at => time() };
                _update_item_snapshot($item_number, $item);
                _update_run(sub {
                    my ($run) = @_;
                    $run->{status} = 'failed';
                    $run->{failure} = $item->{failure};
                    $run->{items}[$item_number] = $item if ref($run->{items}) eq 'ARRAY';
                });
                return 0;
            }
            my %repeat = map { $_ => 1 } qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed);
            $item->{drift_recovery_attempts} = $drift_recovery_attempts;
            delete $item->{drift_recovery_pending};
            $item->{checkpoints} = [grep {
                ref($_) eq 'HASH' && !$repeat{$_->{name} || ''}
            } @{$item->{checkpoints} || []}];
            $item->{checkpoint} = 'pre-readings-done';
            $item->{checkpoint_status} = 'done';
            _update_item_snapshot($item_number, $item);
            _update_run(sub { $_[0]{items}[$item_number] = $item if ref($_[0]{items}) eq 'ARRAY'; });
            return 0 if _pause_after_checkpoint();
        }
        return 0 if _pause_after_checkpoint();
        if ($stages->{apply_all}) {
            return 0 if !_stage($item_number, $item, 'apply-all-done', sub {
                my $result = _apply_all($item_number, $item);
                die($::LAST_ERROR || 'Apply-to-all failed') if !$result;
                return $result;
            });
        } else {
            _skip_stage($item_number, $item, 'apply-all-done');
        }
    } else {
        foreach my $stage (qw(reset-and-reapply-verified panel-light-settled greyscale-done volume-done session-closed apply-all-done)) {
            _skip_stage($item_number, $item, $stage);
        }
    }
        return 0 if _pause_after_checkpoint();
        if ($stages->{post}) {
        return 0 if !_stage($item_number, $item, 'post-readings-done', sub {
            die($::LAST_ERROR || 'Calibration mode did not close before post-readings')
                if !_ensure_calibration_mode_off($item);
            die('Unable to switch DV to Absolute map') if !_set_dv_map($item, '1');
            my $verified = _read_and_verify_settings($item_number, $item, 'c10')->{verified};
            die($::LAST_ERROR || 'Settings did not verify before post-readings') if !$verified && $verified ne 'unverifiable';
            die($::LAST_ERROR || 'Post-readings failed') if !_run_series($item_number, $item, 'post');
            my $quality = _quality_stage($item_number, $item);
            die($::LAST_ERROR || 'Unable to persist quality results') if ref($quality) ne 'HASH';
            push @{$item->{warnings}}, @{$quality->{warnings} || []} if @{$quality->{warnings} || []};
            return { verified => $verified, quality => $quality };
        });
    } else {
        _skip_stage($item_number, $item, 'post-readings-done');
    }
    return 0 if _pause_after_checkpoint();
    my $warnings = ref($item->{warnings}) eq 'ARRAY' && @{$item->{warnings}};
    $item->{status} = $warnings ? 'complete-with-warnings' : 'complete';
    my $complete_checkpoint = _checkpoint_record($item_number, $item, 'item-complete', $warnings ? 'unverifiable' : JSON::PP::true, {
        warnings => $item->{warnings} || [],
    });
    if (!ref($complete_checkpoint)) {
        my $message = $::LAST_ERROR || 'Unable to persist item completion';
        $item->{status} = 'failed';
        $item->{failure} = { stage => 'item-complete', message => $message, at => time() };
        _update_item_snapshot($item_number, $item);
        _update_run(sub {
            my ($run) = @_;
            $run->{status} = 'failed';
            $run->{failure} = $item->{failure};
            $run->{items}[$item_number] = $item if ref($run->{items}) eq 'ARRAY';
        });
        return 0;
    }
    return 0 if !_update_item_snapshot($item_number, $item);
    $ACTIVE_ITEM = undef;
    return 1;
}

sub _main {
    die "automation store unavailable\n" if !PGAutomation::ensure_store() || !-d $RUN_DIR;
    my $run = _run();
    die "run manifest unavailable\n" if ref($run) ne 'HASH' || ($run->{token} || '') ne $TOKEN;
    return if ($run->{status} || '') eq 'paused';
    return if ($run->{status} || '') =~ /^(?:complete|failed|stopped)$/;
    if (!open($RUNNER_LOCK, '>>', $RUNNER_LOCK_FILE) || !flock($RUNNER_LOCK, LOCK_EX | LOCK_NB)) {
        _log('another automation runner owns the runner lock');
        return;
    }
    die 'Unable to persist automation runner PID'
        if !PGAutomation::write_atomic($RUN_DIR . '/runner.pid', "$$\n", 0664);
    die 'Unable to persist automation runner startup' if !ref(_update_run(sub {
        my ($state) = @_;
        $state->{status} = 'running';
        $state->{runner_pid} = $$;
        $state->{started_at} ||= time();
        $state->{heartbeat} = time();
    }));
    die 'Unable to claim automation execution' if !_write_execution();
    _heartbeat(1);
    if (_control()->{request} eq 'stop') {
        $STOP_REQUESTED = 1;
        my $number = $run->{active_item};
        $number = $number->{item_number} if ref($number) eq 'HASH';
        if (defined($number) && ref($run->{items}[$number]) eq 'HASH') {
            $ACTIVE_ITEM = $run->{items}[$number];
            $ACTIVE_ITEM->{item_number} = $number;
            $ACTIVE_STAGE = $run->{active_stage} || $ACTIVE_ITEM->{active_stage} || '';
            my %workers = ('greyscale-done'=>'grey','volume-done'=>_signal($ACTIVE_ITEM) eq 'dv'?'dv':'3d',
                'pre-readings-done'=>'series','post-readings-done'=>'series');
            $ACTIVE_WORKER = $workers{$ACTIVE_STAGE} || '';
            if (ref($run->{active_series}) eq 'HASH') {
                ($ACTIVE_SERIES_KEY, $ACTIVE_SERIES_PHASE) = @{$run->{active_series}}{qw(key phase)};
            }
        }
        _stop_active();
        _restore_run_hazards($run, $run->{items});
        _finish('stopped');
        return;
    }
    _ensure_lg_connection();
    my $readiness = _api('POST', '/api/automation/readiness', {
        items => [grep { ($_->{status} || '') !~ /^complete/ } @{$run->{items} || []}],
    });
    if (!$readiness->{ready}) {
        _finish('failed', { stage => 'readiness', message => $readiness->{message} || 'Automation readiness failed' });
        return;
    }
    _update_run(sub { $_[0]{readiness} = $readiness; });
    my $items = ref($run->{items}) eq 'ARRAY' ? $run->{items}
        : ref($run->{queue_snapshot}{items}) eq 'ARRAY' ? $run->{queue_snapshot}{items} : [];
    for (my $i = 0; ; $i++) {
        my $claimed = _update_run(sub {
            my ($state) = @_;
            if ($i >= @{$state->{items}}) { $state->{status} = 'completing'; return; }
            return if ($state->{items}[$i]{status} || '') =~ /^complete/;
            $state->{active_item} = $i;
            $state->{items}[$i]{status} = 'running';
        });
        die 'Unable to claim next queue item' if !ref($claimed);
        $items = $claimed->{items};
        last if $i >= @$items;
        _refresh_control();
        last if $STOP_REQUESTED;
        my $item = ref($items->[$i]) eq 'HASH' ? $items->[$i] : {};
        next if ($item->{status} || '') =~ /^complete(?:-with-warnings)?$/;
        my $ok = _run_item($i, $item);
        if (!$ok || $STOP_REQUESTED) {
            last;
        }
        _update_run(sub { $_[0]{items}[$i] = $item; });
    }
    if ($STOP_REQUESTED) {
        _stop_active();
        _restore_run_hazards(_run(), $items);
        _finish('stopped', { stage => $ACTIVE_STAGE || 'unknown', message => 'Automation stopped' });
        return;
    }
    my $latest = _run();
    if (($latest->{status} || '') eq 'paused') {
        return;
    }
    if (($latest->{status} || '') eq 'interrupted') {
        my $failure_stage = ref($latest->{failure}) eq 'HASH' ? ($latest->{failure}{stage} || '') : '';
        _stop_active() if $failure_stage ne 'apply-all-done' && ($ACTIVE_WORKER || ref($ACTIVE_ITEM) eq 'HASH');
        _restore_run_hazards($latest, $items);
        _park_interrupted($latest->{active_stage} || $failure_stage || 'interrupted');
        return;
    }
    if (($latest->{status} || '') eq 'failed') {
        _stop_active() if $ACTIVE_WORKER || ref($ACTIVE_ITEM) eq 'HASH';
        _restore_run_hazards($latest, $items);
        _finish('failed', $latest->{failure});
        return;
    }
    _restore_run_hazards($latest, $items);
    _update_run(sub {
        my ($state) = @_;
        $state->{active_item} = undef;
        $state->{active_stage} = '';
    });
    _finish('complete');
}

eval { _main(); 1 } or do {
    my $error = $@ || 'automation runner failed';
    _log($error);
    my $run = eval { _run() } || {};
    _stop_active() if $ACTIVE_WORKER || ref($ACTIVE_ITEM) eq 'HASH';
    _restore_run_hazards($run, ref($run->{items}) eq 'ARRAY' ? $run->{items} : []);
    my $failure = { stage => $ACTIVE_STAGE || 'startup', message => "$error" };
    $failure->{error_code} = $::LAST_ERROR_CODE if $::LAST_ERROR_CODE;
    _finish('failed', $failure)
        if ref($run) eq 'HASH' && ($run->{status} || '') =~ /^(?:running|interrupted|paused)$/;
    exit 1;
};

exit 0;
