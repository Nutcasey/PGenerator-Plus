#!/usr/bin/perl
# Regression: the deploy console's pre-apply perl -c check stages only the
# SELECTED files. A module left out of the selection that has its own
# self-locating BEGIN block -- `unshift @INC, "$directory/../share/PGenerator"`
# in a usr/sbin script, or `use lib File::Basename::dirname(__FILE__)` in a
# usr/share/PGenerator module -- loads from its REAL installed path when not
# staged, and its own self-location then re-prioritizes the installed
# directory ahead of the staged tree for the REST of that perl -c process
# (@INC is process-global). A sibling module's new export in the staged tree
# then goes unseen even though the file on disk is correct.
#
# 2026-09-21 incident: selecting only usr/sbin/pgenerator-lg and
# usr/share/PGenerator/PGLGCapabilities.pm (PR23's new
# lg_record_setting_observations export) failed the syntax check with
# "is not exported by the PGLGCapabilities module", solely because
# usr/share/PGenerator/PGAutomation.pm (unmodified, not part of the
# selection, has `unshift @INC, $directory` at its own top) was pulled in
# from the real install and won the @INC race.
#
# The fix backfills the staged usr/share/PGenerator with the installed
# directory's files, never overwriting what was staged, before running any
# check, so self-locating modules always resolve into the SAME complete
# directory regardless of what was selected.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);

my $server = File::Spec->catfile($FindBin::Bin, '..', 'github-deployer', 'server.py');
plan skip_all => "github-deployer/server.py not present" unless -f $server;

my $src = do {
    open my $fh, '<', $server or die "open $server: $!";
    local $/; <$fh>;
};

# --- Structural check: the fix is present, correctly guarded, and ordered
#     before the perl -c loop, inside the upload_files() bash template. -----
my $fn_start = index($src, 'def upload_files(');
ok($fn_start >= 0, 'upload_files() found in server.py');
my $fn_end = index($src, "\ndef ", $fn_start + 1);
$fn_end = length($src) if $fn_end < 0;
my $body = substr($src, $fn_start, $fn_end - $fn_start);

my $modules_at   = index($body, 'modules="$stage/tree/usr/share/PGenerator"');
my $backfill_at  = index($body, 'cp -an /usr/share/PGenerator/. "$modules/"');
my $guard_at     = index($body, 'if [ -d "$modules" ]');
my $perlc_loop_at = index($body, 'if [ "$check" = "perl" ]');

ok($modules_at >= 0, '$modules is set to the staged usr/share/PGenerator');
ok($backfill_at >= 0, 'cp -an backfill from the installed directory is present');
ok($guard_at >= 0 && $guard_at < $backfill_at, 'backfill is guarded by a -d check, guard precedes the copy');
ok($backfill_at >= 0 && $perlc_loop_at >= 0 && $backfill_at < $perlc_loop_at,
    'backfill runs BEFORE the perl -c check loop, not after');

# `-an`, not `-a` alone: must never clobber a file this upload actually staged.
like($body, qr/cp -an \Q\E\S*\/usr\/share\/PGenerator\/\.\s+"\$modules\/"/,
    'the copy uses -n (no-clobber) so staged/new files always win over the backfill');

# The perl -c invocation itself is unchanged by this fix (still searches
# $modules first, then falls back to the installed tree for anything the
# backfill didn't reach, e.g. non-PGenerator dependencies).
like($body, qr/perl -c -I "\$modules" -I \/usr\/share\/PGenerator/,
    'perl -c still searches the staged/backfilled tree before the installed fallback');

# --- Behavioral check: cp -an really does merge without clobbering. --------
# This proves the underlying mechanism the fix relies on, in a sandbox wholly
# separate from real system paths (the embedded script itself is not directly
# executable in CI -- it assumes /usr/share/PGenerator and /root/pgen-backups
# exist on the target Pi).
SKIP: {
    skip 'cp not available', 3 unless `command -v cp 2>/dev/null` =~ /\S/;
    my $dir = tempdir(CLEANUP => 1);
    mkdir("$dir/installed") or die $!;
    mkdir("$dir/staged") or die $!;
    open(my $fh1, '>', "$dir/installed/Shared.pm") or die $!;
    print $fh1 "package Shared; 1; # installed, unmodified\n";
    close $fh1;
    open(my $fh2, '>', "$dir/installed/Changed.pm") or die $!;
    print $fh2 "package Changed; sub old_only { 1 } 1;\n";
    close $fh2;
    open(my $fh3, '>', "$dir/staged/Changed.pm") or die $!;
    print $fh3 "package Changed; sub old_only { 1 } sub new_export { 1 } 1;\n";
    close $fh3;

    # cp -an exits non-zero whenever it SKIPS an already-present destination
    # file -- which is the common case here, since the tree being backfilled
    # almost always already has at least the files this upload staged. That
    # is success, not failure: the real script backgrounds this exact call
    # with `2>/dev/null || true` for that reason. Check file state, not the
    # exit code.
    system("cp -an $dir/installed/. $dir/staged/ 2>/dev/null");

    ok(-f "$dir/staged/Shared.pm", 'an installed-only sibling is backfilled into the staged tree');
    my $changed = do { open(my $fh, '<', "$dir/staged/Changed.pm") or die $!; local $/; <$fh> };
    like($changed, qr/new_export/, 'a file the upload DID stage is never overwritten by the backfill (new content survives)');
    unlike($changed, qr/^package Changed; sub old_only \{ 1 \} 1;$/m,
        'the staged version, not the installed version, is what remains');
}

done_testing();
