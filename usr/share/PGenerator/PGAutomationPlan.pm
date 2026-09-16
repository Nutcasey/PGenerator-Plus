package PGAutomationPlan;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use PGAutomation ();

# Exclude evidence and derived device observations, not request fields. New
# execution options therefore invalidate the plan by default rather than
# accidentally falling outside a hand-maintained allowlist.
# JSON round trips through the daemon, the browser and older JSON::PP builds
# do not preserve whether a value was a number or a numeric string. Execution
# intent must not change with that, so numeric scalars hash by their value.
sub _normalize_scalars {
    my ($value) = @_;
    if (ref($value) eq 'HASH') { $value->{$_} = _normalize_scalars($value->{$_}) for keys %$value; return $value; }
    if (ref($value) eq 'ARRAY') { $value->[$_] = _normalize_scalars($value->[$_]) for 0..$#$value; return $value; }
    return $value if ref($value) || !defined($value);
    return $value =~ /\A-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\z/ ? ''.(0+$value) : $value;
}

sub intent_hash {
    my ($source) = @_;
    my $item = _normalize_scalars(PGAutomation::clone($source) || {});
    delete @$item{qw(item_number status checkpoints checkpoint checkpoint_status active_stage stage_started_at
        failure warnings readiness settings_recovery profile_baseline_needs_restore recheck fault_injected
        hazard_restore hazards hazard_capabilities drift_recovery_attempts drift_recovery_pending
        setting_contracts generation_profile capability_profile calibration_settings_recipe device_identity
        best_available_settings best_available_write_ack supported_picture_keys tv_input preflight_contract
        worker_status started_at completed_at series calibration_results panel-light apply-all quality_result)};
    return sha256_hex(PGAutomation::encode_json($item));
}

sub contract {
    my ($item) = @_;
    return {intent_hash=>intent_hash($item),tv_input=>$item->{tv_input}||'',
        profile_hash=>$item->{capability_profile}{hash}||'',device_identity=>PGAutomation::clone($item->{device_identity}||{})};
}

sub matches {
    my ($item, $contract) = @_;
    return 0 if ref($contract) ne 'HASH' || ($contract->{intent_hash}||'') ne intent_hash($item);
    return 0 if ($contract->{tv_input}||'') ne ($item->{tv_input}||'')
        || ($contract->{profile_hash}||'') ne ($item->{capability_profile}{hash}||'');
    return PGAutomation::encode_json($contract->{device_identity}||{}) eq PGAutomation::encode_json($item->{device_identity}||{});
}
1;
