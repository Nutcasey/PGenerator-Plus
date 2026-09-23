# A queued job that differs from the reference template it was built from is
# invisible on the queue row: the row shows the name, and the name still says
# "SDR Filmmaker". One such job calibrated with Dark Detail off and a 17-node
# solve. The behavior lives in the browser, so the assertions are in
# t/js/automation_queue_drift.js and this runs them.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null`;
chomp $node;
plan skip_all => 'Node is required for the queue drift badge tests' if !$node;
plan tests => 2;

my $out = `"$node" "$Bin/js/automation_queue_drift.js" 2>&1`;
is($? >> 8, 0, 'queue drift detection and badge rendering behave') or diag($out);
like($out, qr/\bok\b/, 'the drift suite ran to completion');
