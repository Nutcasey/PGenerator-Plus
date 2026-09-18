#!/usr/bin/perl
# Regression: the Deploy Console ref picker ships the ref field EMPTY
# (index.html clears the prefilled "main" so the datalist stays unfiltered),
# so /api/scan and /api/upload can arrive with ref:"". github_source_from()
# must fall back to "main" for empty, missing, and whitespace-only refs —
# dict.get's default only fires on a MISSING key, so the naive form
# payload.get("ref", "main") lets "" through to REF_RE and the first-click
# scan fails with "Enter a valid GitHub branch, tag, or commit."
# Real refs still pass through unchanged; garbage stays rejected.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;

my $server = File::Spec->catfile($FindBin::Bin, '..', 'github-deployer', 'server.py');
plan skip_all => "github-deployer/server.py not present" unless -f $server;

my $py = do {
    open my $fh, '<', $server or die "open $server: $!";
    local $/; <$fh>;
};

# Slice github_source_from out of the module: it is pure string handling
# (no network, no subprocess), so running it needs only REF_RE/REPO_PART_RE
# and AppError, which the slice defines inline. Extract by string anchors —
# the sub's own nested braces defeat brace-counting regexes.
my $start = index($py, 'def github_source_from(');
ok($start >= 0, 'github_source_from found in server.py');
my $end = index($py, "\ndef ssh_base(", $start);
ok($end > $start, 'sub body delimited');
my $body = substr($py, $start, $end - $start);

my $preamble_head = <<'PY';
import re
from http import HTTPStatus
from typing import Any
class AppError(Exception):
    def __init__(self, msg, status=HTTPStatus.BAD_REQUEST):
        super().__init__(msg)
PY

# Build the regex constants from the module's OWN lines rather than
# duplicating the patterns here: a future module-side tightening is then
# exercised by this probe instead of diverging from a stale copy.
my @consts = $py =~ /^(REPO_PART_RE\s*=\s*re\.compile\(.*\))\n^(REF_RE\s*=\s*re\.compile\(.*\))/m;
is(scalar @consts, 2, 'REPO_PART_RE and REF_RE constant lines found in module');

my $probe = $preamble_head . join("\n", @consts) . "\n" . $body . <<'PY';

cases = [
    ("", "main"),
    (None, "main"),
    ("   ", "main"),
    ("fix/rgb-balance-improvements", "fix/rgb-balance-improvements"),
    ("v1.2.3", "v1.2.3"),
    ("0123456789abcdef0123456789abcdef01234567", "0123456789abcdef0123456789abcdef01234567"),
]
for given, want in cases:
    payload = {"repository": "owner/repo"}
    if given is not None:
        payload["ref"] = given
    got = github_source_from(payload)["ref"]
    print(f"OK {given!r} -> {got}" if got == want else f"FAIL {given!r} -> {got} (want {want})")

for bad in ("..bad", "-x", "a/../b", "ref.lock", "ref/"):
    try:
        github_source_from({"repository": "owner/repo", "ref": bad})
        print(f"FAIL {bad!r} accepted")
    except AppError:
        print(f"OK {bad!r} rejected")
PY

use IPC::Open2;
my ($rh, $wh);
my $pid = open2($rh, $wh, 'python3', '-c', $probe);
close $wh;
my @lines = <$rh>;
close $rh;
waitpid($pid, 0);
is($? >> 8, 0, 'probe ran without traceback');

my $seen = 0;
for my $line (@lines) {
    chomp $line;
    next unless $line =~ /^(OK|FAIL) (.*)/;
    $seen++;
    is($1, 'OK', $2);
}
cmp_ok($seen, '>=', 11, 'all probe cases reported');

done_testing();
