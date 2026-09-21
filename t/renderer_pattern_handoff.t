use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;

# Execute the real parser/draw methods with an in-memory drawing surface.
# Notifications can then be injected at precise points within a frame.
sub read_file {
    open my $fh, '<', $_[0] or die "$!";
    local $/;
    return <$fh>;
}
my $source = read_file("$Bin/../src/pattern_generator/src/ofApp.cpp");
my @methods;
for my $name (qw(update draw set_values)) {
    my ($method) = $source =~ /(^void ofApp::\Q$name\E\s*\([^)]*\)\s*\{.*?^\})/ms;
    BAIL_OUT("Cannot locate renderer method $name") unless defined $method;
    push @methods, $method;
}
my $harness = read_file("$Bin/fixtures/renderer_pattern_handoff.cpp");
$harness =~ s{// REAL_RENDERER_METHODS}{join("\n", @methods)}e;
my $tmp = tempdir(CLEANUP => 1);
mkdir "$tmp/running" or die "$!";
open my $cpp, '>', "$tmp/handoff.cpp" or die "$!";
print {$cpp} $harness;
close $cpp;
my $compiler = $ENV{CXX} || 'c++';
is(system($compiler, '-std=c++11', '-O0', "$tmp/handoff.cpp", '-o', "$tmp/handoff"),
    0, 'compile real renderer methods') or BAIL_OUT('Renderer harness did not compile');
is(system("$tmp/handoff", $tmp), 0, 'pattern changes preserve complete frames and reload promptly');
done_testing();
