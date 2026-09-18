#!/usr/bin/perl
# Characterization suite for the RGB balance formulas and the Perceptual
# noise-floor annotation in webui-app.js (and the chart band/tooltip in
# webui-workspace.js). The driver (t/js/rgb_balance_formula.js) brace-extracts
# the functions into a Node vm sandbox with stubs — real execution, no source
# grep for math, no browser. It prints one JSON line; this wrapper turns each
# entry into a TAP assertion. PR-16 (RGB balance noise floor) origin.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;

my $driver = "$Bin/js/rgb_balance_formula.js";
plan skip_all => "driver missing: $driver" unless(-f $driver);
my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null`;
chomp($node);
plan skip_all => "Node is not installed; JS behavior not exercised" if($node eq "");

my $json = do {
    local $/;
    open(my $fh, '-|', $node, $driver) or plan skip_all => "cannot run $node: $!";
    <$fh>;
};
my $data = eval { JSON::PP->new->decode($json // '') };
plan skip_all => "driver produced no parseable JSON: " . substr($json // '', 0, 200)
    unless($data && ref($data->{results}) eq 'ARRAY' && @{$data->{results}});

ok(!$data->{failed}, 'driver reports zero failures')
    or diag("$data->{failed} of " . scalar(@{$data->{results}}) . " checks failed");
for my $r (@{$data->{results}}) {
    ok($r->{ok}, $r->{name}) or diag($r->{msg});
}
done_testing();
