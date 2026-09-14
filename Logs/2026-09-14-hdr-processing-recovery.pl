# Bounded repair of the saved pre-fix recovery plan. All original artifacts
# are archived before this script is run. No calibration result is fabricated.
use strict;
use warnings;
require '/usr/share/PGenerator/webui.pm';
my $id='20260913-225541-73ee6d';
my $dir=PGAutomation::run_dir($id);
my ($ok,$result,$error)=main::webui_automation_lock(sub {
 my $r=PGAutomation::read_json_file("$dir/run.json") or die 'Missing run';
 my @run_owner=stat("$dir/run.json");
 my @item_owner=stat("$dir/items/4/item.json");
 die 'Missing ownership' unless @run_owner && @item_owner;
 die 'Run changed' unless $r->{status} eq 'interrupted' && $r->{active_item}==4;
 die 'Runner alive' if PGAutomation::pid_is_live($r->{runner_pid},'pgen_automation_runner.pl');
 die 'Missing verified cleanup' unless $r->{stop_cleanup}{verified};
 my $i=$r->{items}[4];
 die 'Unexpected job' unless $i->{picture_mode} eq 'hdrCinema' && $i->{signal_format} eq 'hdr10';
 die 'Unexpected recovery' unless $i->{settings_recovery}{point} eq 'c7' && $i->{settings_recovery}{resume_from} eq 'greyscale-done';
 die 'Unexpected failure' unless $i->{failure}{message}=~/smoothGradation: requested off, TV reported low/;
 my ($c)=grep {$_->{name} eq 'greyscale-settings-verified' && $_->{status} eq 'done'} @{$i->{checkpoints}};
 die 'Missing post-1D evidence' unless $c && $c->{evidence}{values}{pictureMode}{matched};
 my $values=$c->{evidence}{values};
 for my $key (keys %{$i->{settings}},'pictureMode') {
  my $v=$values->{$key} or die "Missing $key";
  die "Unverified $key" if $v->{read_failed} || $v->{unverifiable};
  next if $v->{matched};
  die "Unexpected mismatch $key" unless $key eq 'colorGamut' && $v->{expected} eq 'auto' && $v->{observed} eq 'wide' && $v->{readback_warning};
 }
 die 'Smooth Gradation was not verified Off' unless $values->{smoothGradation}{matched} && $values->{smoothGradation}{observed} eq 'off';
 my $grey=PGAutomation::read_json_file("$dir/items/4/calibration/grey-state.json");
 die 'No reusable 1D' unless $grey->{status} eq 'complete' && ($grey->{ddc_upload_verified} || $grey->{final_1d_lut_upload_verified}) && ref($grey->{hdr20_1d_dpg_data}) eq 'ARRAY' && @{$grey->{hdr20_1d_dpg_data}}==3072;
 my $message='HDR Cinema CAL_END was reproduced resetting Smooth Gradation to Low. Retaining the verified saved 1D curve; Resume restores its unity/profile baseline and repeats profiling with processing checks before subsequent measurements.';
 $i->{settings_recovery}{resume_from}='volume-done';
 $i->{settings_recovery}{message}=$message;
 $i->{settings_recovery}{reviewed_at}=PGAutomation::now();
 $i->{failure}{message}=$message;
 $r->{failure}=$i->{failure};
 $r->{worker_status}={message=>$message};
 push @{$r->{startup_events}},{time=>PGAutomation::now(),level=>'info',item_number=>4,message=>$message};
 PGAutomation::write_json_atomic("$dir/items/4/item.json",$i) or die 'Item save failed';
 chown($item_owner[4],$item_owner[5],"$dir/items/4/item.json")==1 or die 'Item ownership restore failed';
 chmod($item_owner[2]&0777,"$dir/items/4/item.json")==1 or die 'Item permissions restore failed';
 my ($saved,undef,$why)=PGAutomation::with_lock("$dir/run.json",sub {$r});
 die "Manifest save failed: $why" unless $saved;
 chown($run_owner[4],$run_owner[5],"$dir/run.json")==1 or die 'Manifest ownership restore failed';
 return {status=>'ok',resume_from=>$i->{settings_recovery}{resume_from},message=>$message};
});
die "Recovery review failed: $error" unless $ok && ref($result) eq 'HASH';
print PGAutomation::encode_json($result),"\n";
