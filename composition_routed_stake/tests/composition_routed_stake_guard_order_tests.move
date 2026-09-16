// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module composition_routed_stake::composition_routed_stake_guard_order_tests;

use composition_routed_stake::composition_routed_stake as action;
use musicos::composition::{Self, Composition, CompositionAdminCap};
use musicos::recording::{Self, Recording, RecordingAdminCap};
use royalty_pool::pool::{Self, RoyaltyPool};
use routed_stake::routed_stake;
use sui::balance;

const EStakeNotForComposition: u64 = 1;

public struct RECORDING_SHARE() has drop;
public struct FOREIGN_RECORDING_SHARE() has drop;
public struct COMPOSITION_SHARE() has drop;
public struct CURRENCY() has drop;

fun fixture(
    ctx: &mut TxContext,
): (
    Composition<COMPOSITION_SHARE>,
    CompositionAdminCap<COMPOSITION_SHARE>,
    Recording<RECORDING_SHARE, COMPOSITION_SHARE>,
    RecordingAdminCap<RECORDING_SHARE>,
) {
    let (composition, cap) =
        composition::new_for_testing<COMPOSITION_SHARE>("Composition", 2_000, ctx);
    let (recording, recording_cap) =
        recording::new_for_testing<RECORDING_SHARE, COMPOSITION_SHARE>(object::id(&composition), ctx);
    (composition, cap, recording, recording_cap)
}

#[test, expected_failure(abort_code = 4, location = royalty_pool::pool)]
fun action_unregister_second_recording_pool_reaches_pool_id_guard() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, cap, mut recording, recording_cap) = fixture(ctx);
    let (mut other_recording, other_recording_cap) =
        recording::new_for_testing<RECORDING_SHARE, COMPOSITION_SHARE>(object::id(&composition), ctx);
    let mut pool = pool::new_for_testing<RECORDING_SHARE, CURRENCY>(recording.uid_mut(&recording_cap));
    let mut other_pool = pool::new_for_testing<RECORDING_SHARE, CURRENCY>(other_recording.uid_mut(&other_recording_cap));
    balance::create_for_testing<RECORDING_SHARE>(1).send_funds(object::id(&composition).to_address());
    let mut routed = action::create_stake(&mut composition, &cap, &recording, 1, ctx);
    action::register(&mut composition, &cap, &recording, &mut routed, &mut pool);
    // Both supplied parent objects are valid. The dependency rejects the
    // routed registration because it belongs to the first pool, not this one.
    action::unregister(&mut composition, &cap, &other_recording, &mut routed, &mut other_pool);
    abort
}

#[test, expected_failure(abort_code = EStakeNotForComposition, location = action)]
fun register_valid_recording_wrong_wrapper_precedes_wrong_pool() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, cap, recording, _recording_cap) = fixture(ctx);
    let (mut other_recording, other_recording_cap) =
        recording::new_for_testing<RECORDING_SHARE, COMPOSITION_SHARE>(object::id(&composition), ctx);
    let (mut foreign_composition, foreign_cap) =
        composition::new_for_testing<COMPOSITION_SHARE>("Foreign", 2_000, ctx);
    let mut foreign_routed = routed_stake::new<RECORDING_SHARE, COMPOSITION_SHARE>(
        foreign_composition.uid_mut(&foreign_cap),
        balance::create_for_testing<RECORDING_SHARE>(1),
        ctx,
    );
    let mut wrong_pool = pool::new_for_testing<RECORDING_SHARE, CURRENCY>(other_recording.uid_mut(&other_recording_cap));
    // Recording is valid, so the wrapper check must win over the pool check.
    action::register(&mut composition, &cap, &recording, &mut foreign_routed, &mut wrong_pool);
    abort
}

#[test, expected_failure(abort_code = EStakeNotForComposition, location = action)]
fun unregister_valid_recording_wrong_wrapper_precedes_wrong_pool() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, cap, recording, _recording_cap) = fixture(ctx);
    let (mut other_recording, other_recording_cap) =
        recording::new_for_testing<RECORDING_SHARE, COMPOSITION_SHARE>(object::id(&composition), ctx);
    let (mut foreign_composition, foreign_cap) =
        composition::new_for_testing<COMPOSITION_SHARE>("Foreign", 2_000, ctx);
    let mut foreign_routed = routed_stake::new<RECORDING_SHARE, COMPOSITION_SHARE>(
        foreign_composition.uid_mut(&foreign_cap),
        balance::create_for_testing<RECORDING_SHARE>(1),
        ctx,
    );
    let mut wrong_pool = pool::new_for_testing<RECORDING_SHARE, CURRENCY>(other_recording.uid_mut(&other_recording_cap));
    // The valid Recording passes first; the wrong wrapper must stop the call
    // before either pool guard or dependency registration checks.
    action::unregister(&mut composition, &cap, &recording, &mut foreign_routed, &mut wrong_pool);
    abort
}
