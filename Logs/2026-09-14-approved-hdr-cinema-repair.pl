# One-off, user-approved repair of the interrupted, uncalibrated fifth item.
# Run on the Pi. The ordinary pending-item editor correctly locks started jobs.
# This deliberately does not weaken that API or edit the four finished jobs.
use strict;
use warnings;
use File::Path qw(make_path);
require '/usr/share/PGenerator/webui.pm';
my $id='20260913-225541-73ee6d';
my $dir=PGAutomation::run_dir($id);
my $archive="$dir/replaced-items/hdr-home-before-approved-change";
my ($locked,$result,$error)=main::webui_automation_lock(sub {
 my $r=PGAutomation::read_json_file("$dir/run.json") or die 'Missing run';
 die 'Run changed' unless $r->{status} eq 'interrupted' && $r->{active_item}==4;
 die 'Runner still alive' if PGAutomation::pid_is_live($r->{runner_pid},'pgen_automation_runner.pl');
 my $old=$r->{items}[4];
 die 'Unexpected target' unless $old->{picture_mode} eq 'hdrCinemaBright' && $old->{signal_format} eq 'hdr10';
 die 'Unexpected failure stage' unless $old->{failure}{stage} eq 'reset-and-reapply-verified';
 die 'Missing cleanup' unless $r->{stop_cleanup}{verified};
 die 'Calibration already progressed' if grep {$_->{name}!~/^(?:item-started|tv-setup-verified|pre-readings-done)$/} @{$old->{checkpoints}||[]};
 die 'Completed jobs changed' if grep {$_->{status}!~/^complete(?:-with-warnings)?$/} @{$r->{items}}[0..3];
 die 'Last job changed' unless ($r->{items}[5]{status}||'queued') eq 'queued';
 die 'Archive already exists' if -e $archive;
 my @owner=stat("$dir/items/4");die 'Missing item ownership' unless @owner;
 my $item=main::webui_automation_normalize_item($old);
 delete @$item{qw(hazards hazard_capabilities apply_all_supported supported_picture_keys device_identity lg_generation)};
 $item->{picture_mode}='hdrCinema';$item->{name}='HDR10 Cinema';
 $item->{template_id}='reference-settings-v4';$item->{status}='queued';$item->{recheck}=1;
 make_path("$dir/replaced-items");
 PGAutomation::write_json_atomic("$dir/replaced-items/run-before-approved-change.json",$r,0600) or die 'Backup failed';
 rename "$dir/items/4",$archive or die "Archive failed: $!";
 make_path("$dir/items/4");
 PGAutomation::write_json_atomic("$dir/items/4/item.json",$item) or die 'New item copy failed; restore from archive before proceeding';
 chown($owner[4],$owner[5],"$dir/items/4","$dir/items/4/item.json")==2 or die 'Unable to preserve runner ownership';
 $r->{items}[4]=$item;
 delete @$r{qw(failure checkpoint last_checkpoint)};
 $r->{active_stage}='readiness';$r->{worker_status}={message=>'Approved change: HDR10 Cinema replaces unsupported HDR10 Cinema Home; ready to resume with fresh checks.'};
 push @{$r->{startup_events}}, {time=>PGAutomation::now(),level=>'info',item_number=>4,message=>$r->{worker_status}{message}};
 my ($saved,undef,$why)=PGAutomation::with_lock("$dir/run.json",sub {$r});
 die "Manifest save failed: $why; restore archived item before proceeding" unless $saved;
 return {status=>'ok',name=>$item->{name},picture_mode=>$item->{picture_mode},archive=>$archive};
});
die "Repair failed: $error" unless $locked && ref($result) eq 'HASH';
print PGAutomation::encode_json($result),"\n";
