#!/usr/bin/perl
# Regression tests for the OTA update source repo setting.
#
# The operator can point the updater at a different GitHub repo (fork or
# release channel) from System Settings -> Software Update. The value
# persists as ota_repo=owner/name in PGenerator.conf and
# /usr/sbin/pgenerator-update resolves it at check/apply time with
# precedence GITHUB_REPO env > conf key > factory default. Anything that
# is not a safe owner/repo pair must fall back to the default so a typo
# cannot break updates or inject a URL into the curl target.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More tests => 17;

my $script = "$Bin/../usr/sbin/pgenerator-update";
ok(-f $script, 'pgenerator-update is present');

# Source only the header (config resolution lives before the cmd
# dispatch), so `check`/`apply` never run.
my $full = do { local(@ARGV,$/); open(my $fh,'<',$script) or die "$script: $!"; <$fh> };
my ($head) = split(/cmd="\$\{1:-help\}"/, $full, 2);
ok(defined $head && $head =~ /normalize_repo/, 'header contains the repo resolution block');

my $tmp = tempdir(CLEANUP => 1);
sub resolved_api {
 my (%o) = @_;
 my $conf = "$tmp/conf";
 if(exists $o{conf}) { open(my $fh,'>',$conf) or die $!; print $fh $o{conf}; close($fh); }
 else { unlink($conf) if -e $conf; }
 my $headfile = "$tmp/head.sh";
 open(my $hf,'>',$headfile) or die $!; print $hf $head; close($hf);
 local $ENV{PGENERATOR_CONF_FILE} = $conf;
 local $ENV{GITHUB_REPO} = $o{env} if exists $o{env};
 delete $ENV{GITHUB_REPO} unless exists $o{env};
 my $out = `bash -c '. "$headfile"; printf "%s" "\$GITHUB_API"' 2>/dev/null`;
 chomp $out;
 return $out;
}

my $default_api = 'https://api.github.com/repos/oldgithubman/PGenerator-Plus/releases/latest';

is(resolved_api(conf => ''), $default_api, 'empty conf falls back to the official default');
is(resolved_api(), $default_api, 'missing conf file falls back to the official default');
is(resolved_api(conf => "ota_repo=someone-else/PGenerator-Plus\n"),
   'https://api.github.com/repos/someone-else/PGenerator-Plus/releases/latest',
   'owner/name from conf is used');
is(resolved_api(conf => "ota_repo=https://github.com/foo/bar\n"),
   'https://api.github.com/repos/foo/bar/releases/latest',
   'full https URL is normalized to owner/repo');
is(resolved_api(conf => "ota_repo=https://github.com/foo/bar/releases/latest\n"),
   'https://api.github.com/repos/foo/bar/releases/latest',
   'releases/latest URL suffix is stripped');
is(resolved_api(conf => "ota_repo=git\@github.com:foo/bar.git\n"),
   'https://api.github.com/repos/foo/bar/releases/latest',
   'ssh remote form is normalized');
is(resolved_api(conf => "mode_idx=20\nota_repo=envowner/envrepo\n"),
   'https://api.github.com/repos/envowner/envrepo/releases/latest',
   'other conf keys do not interfere');
is(resolved_api(conf => "ota_repo=conf/one\n", env => 'envowner/envrepo'),
   'https://api.github.com/repos/envowner/envrepo/releases/latest',
   'explicit GITHUB_REPO env overrides the conf key');
is(resolved_api(conf => "ota_repo=bad value with spaces\n"), $default_api,
   'value with spaces falls back to default');
is(resolved_api(conf => "ota_repo=justowner\n"), $default_api,
   'owner without repo falls back to default');
is(resolved_api(conf => "ota_repo=../etc/passwd\n"), $default_api,
   'path traversal is rejected');
is(resolved_api(conf => 'ota_repo="..$(curl evil)"' . "\n"), $default_api,
   'shell metacharacters are rejected');
is(resolved_api(conf => "ota_repo=a/b/c\n"), $default_api,
   'three-segment path falls back to default');

# The check JSON must report which repo served the release so the WebUI
# can show it next to the "Latest" version.
ok($full =~ /"repo":%s/, 'check output carries the repo field');
ok($full =~ /json_escape "\$GITHUB_REPO"/, 'check output escapes the resolved repo');
