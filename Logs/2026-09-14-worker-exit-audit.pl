use strict;
use warnings;
use JSON::PP;
use File::Basename qw(basename);
my %workers=map {$_=>1} qw(pgen_automation_runner.pl meter_lg_autocal.pl meter_lg_3d_autocal.pl meter_lg_dv_profile.pl meter_session.sh meter_series.sh spotread);
my @live;
for my $path (glob('/proc/[0-9]*/cmdline')) {
 open my $f,'<',$path or next;
 local $/;my @args=split /\0/,scalar(<$f>)||'';close $f;
 next unless @args;
 my $executable=basename($args[0]);
 my $script=$executable=~/^(?:perl|bash|sh)$/?basename($args[1]||''):$executable;
 next unless $workers{$script};
 my ($pid)=$path=~m{/proc/(\d+)/};
 push @live,{pid=>0+$pid,worker=>$script};
}
print encode_json({workers_alive=>\@live,verified=>@live?JSON::PP::false:JSON::PP::true}),"\n";
exit(@live?1:0);
