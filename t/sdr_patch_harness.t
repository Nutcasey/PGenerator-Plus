use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
my $python=$ENV{PYTHON} || 'python3';
# This controller runs on the host; device Python 3.5 is not its runtime.
# These contracts import the math adapter but never connect to hardware.
if(system($python,'-c','import sys; sys.exit(0 if sys.version_info >= (3,12) else 1)')!=0) {
 plan skip_all=>'hardware harness checks require host Python 3.12+';
}
is(system($python,'-m','unittest','discover','-s',"$Bin/hardware",'-p','test_sdr_patch_test.py'),0,
 'focused hardware harness offline contracts');
done_testing();
