use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
do "$Bin/../usr/sbin/pgenerator-lg";die $@ if $@;
my $unsupported='500 Application error: Some keys are not allowed for the request. ( applyToAllInput )';
ok(lg_apply_all_inputs_readback_unavailable($unsupported),'recognises exact LG confirmation capability rejection');
for my $error (undef,'','timeout','connection lost','Permission denied','Some keys are not allowed for the request. ( brightness )','Some keys are not allowed for the request. ( applyToAllInputs )') {
 ok(!lg_apply_all_inputs_readback_unavailable($error),'unrelated failures and plural-key mistakes are not excused');
}
for my $route(qw(ssap luna)) {
 my ($confirmed,$acknowledged,$message)=lg_apply_all_inputs_outcome('filmMaker',$route,'',$unsupported,0);
 ok(!$confirmed,'does not fabricate completion confirmation');
 is($acknowledged,$route eq 'ssap'?1:0,'bridge dispatch is not falsely acknowledged as action completion');
 like($message,qr/Apply to All Inputs sent.*confirmation unavailable on this TV/,'operator sees informational limitation');
}
my ($confirmed,undef,$message)=lg_apply_all_inputs_outcome('filmMaker','luna','done','',1);
ok($confirmed,'fresh picture-to-done transition still confirms completion');
($confirmed,undef,$message)=lg_apply_all_inputs_outcome('filmMaker','luna','done','',0);
ok(!$confirmed,'resting done is not proof of a fresh action');
unlike($message,qr/confirmation unavailable on this TV/,'ordinary unconfirmed action is not misclassified as unsupported readback');
done_testing();
