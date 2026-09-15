// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module release_revenue_distributor::release_revenue_distributor_tests;

use musicos::release::{Self, Release, ReleaseAdminCap};
use musicos::test_helpers;
use musicos::track;
use release_revenue_distributor::release_revenue_distributor as action;
use std::unit_test::{assert_eq, destroy};
use sui::accumulator::AccumulatorRoot;
use sui::balance;
use sui::coin::{Self, Coin};
use sui::event;
use sui::test_scenario;
use vault::vault;

const EUnauthorized: u64 = 0;
const ENoCoinsToReceive: u64 = 0;

public struct CURRENCY() has drop;

fun fixture(ctx: &mut TxContext): (Release, ReleaseAdminCap, ID, ID) {
    let composition_id = test_helpers::fake_id(ctx);
    let recording_a = test_helpers::fake_id(ctx);
    let recording_b = test_helpers::fake_id(ctx);
    let target_release_id = test_helpers::fake_id(ctx);
    let tracks = vector[
        track::new_for_testing(composition_id, recording_a, target_release_id, 6_000),
        track::new_for_testing(composition_id, recording_b, target_release_id, 4_000),
    ];
    let (release, admin_cap) = release::new_for_testing("Release", tracks, ctx);
    (release, admin_cap, recording_a, recording_b)
}

#[test]
fun received_coins_are_combined_split_and_fully_reported() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut release, admin_cap, recording_a, recording_b) = fixture(scenario.ctx());
    let release_id = object::id(&release);
    let release_address = release_id.to_address();
    let admin_cap_id = object::id(&admin_cap).to_address();
    let composition_id = release.tracks()[0].composition_id().to_address();
    let coin_a = coin::from_balance(balance::create_for_testing<CURRENCY>(6_000), scenario.ctx());
    let coin_b = coin::from_balance(balance::create_for_testing<CURRENCY>(4_001), scenario.ctx());
    let coin_a_id = object::id(&coin_a);
    let coin_b_id = object::id(&coin_b);
    transfer::public_transfer(coin_a, release_id.to_address());
    transfer::public_transfer(coin_b, release_id.to_address());

    scenario.next_tx(@0xB);
    action::receive_and_distribute(
        &mut release,
        &admin_cap,
        vector[
            test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(coin_a_id),
            test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(coin_b_id),
        ],
    );

    let sources = event::events_by_type<action::ReleaseCoinsReceivedEvent<CURRENCY>>();
    assert_eq!(sources.length(), 1);
    let (source_release, source_admin, source_coin_ids, source_amount) =
        action::coins_received_event_fields(&sources[0]);
    assert_eq!(source_release, release_address);
    assert_eq!(source_admin, admin_cap_id);
    assert_eq!(source_coin_ids, vector[coin_a_id.to_address(), coin_b_id.to_address()]);
    assert_eq!(source_amount, 10_001);

    let track_events =
        event::events_by_type<action::ReleaseTrackRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(track_events.length(), 2);
    let (event_release_a, index_a, event_composition_a, event_recording_a, split_a, input_a, amount_a) =
        action::track_event_fields(&track_events[0]);
    let (event_release_b, index_b, event_composition_b, event_recording_b, split_b, input_b, amount_b) =
        action::track_event_fields(&track_events[1]);
    assert_eq!(event_release_a, release_address);
    assert_eq!(event_release_b, release_address);
    assert_eq!(index_a, 0);
    assert_eq!(index_b, 1);
    assert_eq!(event_composition_a, composition_id);
    assert_eq!(event_composition_b, composition_id);
    assert_eq!(event_recording_a, recording_a.to_address());
    assert_eq!(event_recording_b, recording_b.to_address());
    assert_eq!(split_a, 6_000);
    assert_eq!(split_b, 4_000);
    assert_eq!(input_a, 10_001);
    assert_eq!(input_b, 10_001);
    assert_eq!(amount_a, 6_000);
    assert_eq!(amount_b, 4_000);

    let summaries = event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(summaries.length(), 1);
    let (event_release, track_count, input, distributed, remainder) =
        action::distribution_event_fields(&summaries[0]);
    assert_eq!(event_release, release_address);
    assert_eq!(track_count, 2);
    assert_eq!(input, 10_001);
    assert_eq!(distributed, 10_000);
    assert_eq!(remainder, 1);

    destroy(release);
    destroy(admin_cap);
    scenario.end();
}

#[test]
fun zero_value_coin_keeps_only_the_source_receipt() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut release, admin_cap, _recording_a, _recording_b) = fixture(scenario.ctx());
    let release_id = object::id(&release);
    let release_address = release_id.to_address();
    let admin_cap_id = object::id(&admin_cap).to_address();
    let coin = coin::zero<CURRENCY>(scenario.ctx());
    let coin_id = object::id(&coin);
    transfer::public_transfer(coin, release_id.to_address());

    scenario.next_tx(@0xB);
    action::receive_and_distribute(
        &mut release,
        &admin_cap,
        vector[test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(coin_id)],
    );
    let sources = event::events_by_type<action::ReleaseCoinsReceivedEvent<CURRENCY>>();
    assert_eq!(sources.length(), 1);
    let (source_release, source_admin, source_coin_ids, source_amount) =
        action::coins_received_event_fields(&sources[0]);
    assert_eq!(source_release, release_address);
    assert_eq!(source_admin, admin_cap_id);
    assert_eq!(source_coin_ids, vector[coin_id.to_address()]);
    assert_eq!(source_amount, 0);

    let tracks = event::events_by_type<action::ReleaseTrackRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(tracks.length(), 0);
    let summaries = event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(summaries.length(), 0);

    destroy(release);
    destroy(admin_cap);
    scenario.end();
}

#[test]
fun vault_admin_borrow_action_put_back_and_borrow_again() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut release, admin_cap, _recording_a, _recording_b) = fixture(scenario.ctx());
    let mut registry = vault::new_registry_for_testing(scenario.ctx());
    let (mut vault, vault_admin_cap) = vault::new(&mut registry, admin_cap, scenario.ctx());
    let coin = coin::from_balance(balance::create_for_testing<CURRENCY>(10_000), scenario.ctx());
    let coin_id = object::id(&coin);
    transfer::public_transfer(coin, object::id(&release).to_address());

    scenario.next_tx(@0xB);
    let (borrowed_cap, receipt) = vault.borrow_as_admin(&vault_admin_cap);
    action::receive_and_distribute(
        &mut release,
        &borrowed_cap,
        vector[test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(coin_id)],
    );
    vault.put_back(borrowed_cap, receipt);
    let (borrowed_again, second_receipt) = vault.borrow_as_admin(&vault_admin_cap);
    assert_eq!(borrowed_again.release_id(), object::id(&release));
    vault.put_back(borrowed_again, second_receipt);

    let admin_cap = vault.withdraw_cap(&vault_admin_cap);
    destroy(admin_cap);
    destroy(vault_admin_cap);
    destroy(vault);
    destroy(registry);
    destroy(release);
    scenario.end();
}

#[test]
fun settled_value_helper_distributes_full_amount_and_later_remainder() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut release, admin_cap, _recording_a, _recording_b) = fixture(scenario.ctx());
    let release_address = object::id(&release).to_address();
    let admin_cap_id = object::id(&admin_cap).to_address();
    balance::create_for_testing<CURRENCY>(10_001).send_funds(release_address);

    scenario.next_tx(@0xB);
    action::redeem_settled_value_and_distribute_for_testing<CURRENCY>(
        &mut release,
        &admin_cap,
        10_001,
    );
    let redeemed = event::events_by_type<action::ReleaseFundsRedeemedEvent<CURRENCY>>();
    assert_eq!(redeemed.length(), 1);
    let (first_source_release, first_source_admin, first_source_amount) =
        action::funds_redeemed_event_fields(&redeemed[0]);
    assert_eq!(first_source_release, release_address);
    assert_eq!(first_source_admin, admin_cap_id);
    assert_eq!(first_source_amount, 10_001);
    let summaries = event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>();
    let (_, first_track_count, first_input, first_distributed, first_remainder) =
        action::distribution_event_fields(&summaries[0]);
    assert_eq!(first_track_count, 2);
    assert_eq!(first_input, 10_001);
    assert_eq!(first_distributed, 10_000);
    assert_eq!(first_remainder, 1);

    // The first call requeues its one-unit flooring remainder. Batch it with
    // later revenue so the next settled redemption has no rounding dust.
    balance::create_for_testing<CURRENCY>(9_999).send_funds(release_address);
    scenario.next_tx(@0xC);
    action::redeem_settled_value_and_distribute_for_testing<CURRENCY>(
        &mut release,
        &admin_cap,
        10_000,
    );
    let redeemed = event::events_by_type<action::ReleaseFundsRedeemedEvent<CURRENCY>>();
    assert_eq!(redeemed.length(), 1);
    let (second_source_release, second_source_admin, second_source_amount) =
        action::funds_redeemed_event_fields(&redeemed[0]);
    assert_eq!(second_source_release, release_address);
    assert_eq!(second_source_admin, admin_cap_id);
    assert_eq!(second_source_amount, 10_000);
    let summaries = event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(summaries.length(), 1);
    let (_, second_track_count, second_input, second_distributed, second_remainder) =
        action::distribution_event_fields(&summaries[0]);
    assert_eq!(second_track_count, 2);
    assert_eq!(second_input, 10_000);
    assert_eq!(second_distributed, 10_000);
    assert_eq!(second_remainder, 0);

    destroy(release);
    destroy(admin_cap);
    scenario.end();
}

/// The unit VM does not populate a positive consensus `AccumulatorRoot`
/// snapshot after `send_funds`. This pins the honest local boundary; a funded
/// `redeem_all_and_distribute` success remains a network E2E requirement.
#[test]
fun funded_accumulator_snapshot_documents_zero_vm_result() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    let (release, admin_cap, _, _) = fixture(scenario.ctx());
    let release_address = object::id(&release).to_address();

    scenario.next_tx(@0xA);
    balance::create_for_testing<CURRENCY>(10_001).send_funds(release_address);
    scenario.next_tx(@0xB);
    let root = scenario.take_shared<AccumulatorRoot>();
    assert_eq!(balance::settled_funds_value<CURRENCY>(&root, release_address), 0);
    test_scenario::return_shared(root);

    destroy(release);
    destroy(admin_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = EUnauthorized, location = release)]
fun another_releases_cap_is_rejected_before_a_funded_redemption() {
    let ctx = &mut tx_context::dummy();
    let (mut release, _cap, _, _) = fixture(ctx);
    let (_other_release, other_cap, _, _) = fixture(ctx);
    action::redeem_settled_value_and_distribute_for_testing<CURRENCY>(
        &mut release,
        &other_cap,
        1,
    );
    abort
}

#[test, expected_failure(abort_code = EUnauthorized, location = release)]
fun redeem_all_rejects_foreign_cap_on_empty_settled_snapshot() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    scenario.next_tx(@0xA);
    let (mut release, _admin_cap, _, _) = fixture(scenario.ctx());
    let (_other_release, other_admin_cap, _, _) = fixture(scenario.ctx());
    let root = scenario.take_shared<AccumulatorRoot>();
    action::redeem_all_and_distribute<CURRENCY>(&mut release, &other_admin_cap, &root);
    abort
}

#[test, expected_failure(abort_code = ENoCoinsToReceive, location = action)]
fun empty_receive_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut release, admin_cap, _, _) = fixture(ctx);
    action::receive_and_distribute<CURRENCY>(&mut release, &admin_cap, vector[]);
    abort
}

/// The private settled-value path is total at zero: no abort and no event
/// family, matching the on-chain reader's empty snapshot.
#[test]
fun settled_value_helper_is_a_silent_no_op_at_zero() {
    let ctx = &mut tx_context::dummy();
    let (mut release, admin_cap, _, _) = fixture(ctx);
    let events_before = event::num_events();
    action::redeem_settled_value_and_distribute_for_testing<CURRENCY>(
        &mut release,
        &admin_cap,
        0,
    );
    assert_eq!(event::num_events(), events_before);
    destroy(release);
    destroy(admin_cap);
}

#[test]
fun redeem_all_is_an_idempotent_no_op_without_settled_funds() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    scenario.next_tx(@0xA);
    let (mut release, admin_cap, _, _) = fixture(scenario.ctx());
    let root = scenario.take_shared<AccumulatorRoot>();
    action::redeem_all_and_distribute<CURRENCY>(&mut release, &admin_cap, &root);
    action::redeem_all_and_distribute<CURRENCY>(&mut release, &admin_cap, &root);
    assert_eq!(
        event::events_by_type<action::ReleaseCoinsReceivedEvent<CURRENCY>>().length(),
        0,
    );
    assert_eq!(
        event::events_by_type<action::ReleaseFundsRedeemedEvent<CURRENCY>>().length(),
        0,
    );
    assert_eq!(
        event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>().length(),
        0,
    );
    assert_eq!(
        event::events_by_type<action::ReleaseTrackRevenueDistributedEvent<CURRENCY>>().length(),
        0,
    );
    test_scenario::return_shared(root);
    destroy(release);
    destroy(admin_cap);
    scenario.end();
}

/// The unit VM records accumulator withdrawals without checking them against
/// a balance (`withdraw_from_accumulator_address` only tracks per-transaction
/// totals), so an overdraw of an empty accumulator succeeds locally. This
/// pins that boundary explicitly: overdraw rejection is a network property
/// covered by the testnet checklist, not by this suite. The previous
/// `expected_failure` overdraw test passed only through its own trailing
/// `abort`.
#[test]
fun overdraw_is_not_enforced_by_the_unit_vm() {
    let ctx = &mut tx_context::dummy();
    let (mut release, admin_cap, _, _) = fixture(ctx);
    action::redeem_settled_value_and_distribute_for_testing<CURRENCY>(
        &mut release,
        &admin_cap,
        1,
    );
    let redeemed = event::events_by_type<action::ReleaseFundsRedeemedEvent<CURRENCY>>();
    assert_eq!(redeemed.length(), 1);
    destroy(release);
    destroy(admin_cap);
}

/// Unit-VM boundary pin, not a same-commit idempotency claim: after a funded
/// helper call, `redeem_all_and_distribute` in the same transaction reads the
/// unit VM's always-zero snapshot and adds nothing. On the network the
/// snapshot is constant within a commit, so a second redemption of the same
/// Release in one PTB withdraws the snapshot again and the whole transaction
/// fails with `InsufficientFundsForWithdraw`; only a call in a later commit is
/// a no-op. See `same_tx_duplicate_redemptions_withdraw_twice_in_the_unit_vm`.
#[test]
fun second_redeem_all_in_the_same_tx_sees_the_vm_zero_snapshot() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    scenario.next_tx(@0xA);
    let (mut release, admin_cap, _, _) = fixture(scenario.ctx());
    let release_address = object::id(&release).to_address();
    balance::create_for_testing<CURRENCY>(10_000).send_funds(release_address);

    scenario.next_tx(@0xB);
    action::redeem_settled_value_and_distribute_for_testing<CURRENCY>(
        &mut release,
        &admin_cap,
        10_000,
    );
    let events_after_first = event::num_events();
    let root = scenario.take_shared<AccumulatorRoot>();
    action::redeem_all_and_distribute<CURRENCY>(&mut release, &admin_cap, &root);
    assert_eq!(event::num_events(), events_after_first);
    let redeemed = event::events_by_type<action::ReleaseFundsRedeemedEvent<CURRENCY>>();
    assert_eq!(redeemed.length(), 1);
    let (_, _, amount) = action::funds_redeemed_event_fields(&redeemed[0]);
    assert_eq!(amount, 10_000);
    let summaries = event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(summaries.length(), 1);
    test_scenario::return_shared(root);
    destroy(release);
    destroy(admin_cap);
    scenario.end();
}

/// Two helper calls with the same snapshot value in ONE transaction withdraw
/// twice. The Action has no in-transaction dedupe; on the network the second
/// withdrawal exceeds the settled balance and the whole transaction fails with
/// `InsufficientFundsForWithdraw` (not a Move abort), which the unit VM cannot
/// show because it never checks withdrawals against a balance. Crankers must
/// include each Release at most once per PTB.
#[test]
fun same_tx_duplicate_redemptions_withdraw_twice_in_the_unit_vm() {
    let ctx = &mut tx_context::dummy();
    let (mut release, admin_cap, _, _) = fixture(ctx);
    action::redeem_settled_value_and_distribute_for_testing<CURRENCY>(
        &mut release,
        &admin_cap,
        10_000,
    );
    action::redeem_settled_value_and_distribute_for_testing<CURRENCY>(
        &mut release,
        &admin_cap,
        10_000,
    );
    let redeemed = event::events_by_type<action::ReleaseFundsRedeemedEvent<CURRENCY>>();
    assert_eq!(redeemed.length(), 2);
    let (_, _, first_amount) = action::funds_redeemed_event_fields(&redeemed[0]);
    let (_, _, second_amount) = action::funds_redeemed_event_fields(&redeemed[1]);
    assert_eq!(first_amount, 10_000);
    assert_eq!(second_amount, 10_000);
    let summaries = event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(summaries.length(), 2);
    destroy(release);
    destroy(admin_cap);
}

/// The framework caps the settled snapshot at `u64::MAX`; the helper must not
/// abort there (per-track `bps::apply` widens to u128) and must conserve the
/// full input across the tracks and the requeued remainder.
#[test]
fun u64_max_snapshot_distributes_without_abort() {
    let ctx = &mut tx_context::dummy();
    let (mut release, admin_cap, _, _) = fixture(ctx);
    let max = std::u64::max_value!();
    action::redeem_settled_value_and_distribute_for_testing<CURRENCY>(&mut release, &admin_cap, max);
    let redeemed = event::events_by_type<action::ReleaseFundsRedeemedEvent<CURRENCY>>();
    assert_eq!(redeemed.length(), 1);
    let (_, _, amount) = action::funds_redeemed_event_fields(&redeemed[0]);
    assert_eq!(amount, max);
    let summaries = event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(summaries.length(), 1);
    let (_, track_count, input, distributed, remainder) =
        action::distribution_event_fields(&summaries[0]);
    assert_eq!(track_count, 2);
    assert_eq!(input, max);
    assert_eq!(distributed + remainder, max);
    let tracks = event::events_by_type<action::ReleaseTrackRevenueDistributedEvent<CURRENCY>>();
    let (_, _, _, _, _, _, amount_a) = action::track_event_fields(&tracks[0]);
    let (_, _, _, _, _, _, amount_b) = action::track_event_fields(&tracks[1]);
    assert_eq!(amount_a + amount_b, distributed);
    destroy(release);
    destroy(admin_cap);
}

/// Batch safety: three Releases cranked in one transaction. The middle one
/// has an empty settled snapshot and passes through silently while the other
/// two are fully distributed with exact amounts.
#[test]
fun batch_with_an_empty_snapshot_release_still_distributes_the_others() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    scenario.next_tx(@0xA);
    let (mut release_a, cap_a, _, _) = fixture(scenario.ctx());
    let (mut release_b, cap_b, _, _) = fixture(scenario.ctx());
    let (mut release_c, cap_c, _, _) = fixture(scenario.ctx());
    let address_a = object::id(&release_a).to_address();
    let address_c = object::id(&release_c).to_address();
    balance::create_for_testing<CURRENCY>(10_000).send_funds(address_a);
    balance::create_for_testing<CURRENCY>(5_001).send_funds(address_c);

    scenario.next_tx(@0xB);
    let root = scenario.take_shared<AccumulatorRoot>();
    action::redeem_settled_value_and_distribute_for_testing<CURRENCY>(
        &mut release_a,
        &cap_a,
        10_000,
    );
    action::redeem_all_and_distribute<CURRENCY>(&mut release_b, &cap_b, &root);
    action::redeem_settled_value_and_distribute_for_testing<CURRENCY>(
        &mut release_c,
        &cap_c,
        5_001,
    );

    let redeemed = event::events_by_type<action::ReleaseFundsRedeemedEvent<CURRENCY>>();
    assert_eq!(redeemed.length(), 2);
    let (redeemed_release_a, _, redeemed_amount_a) = action::funds_redeemed_event_fields(&redeemed[0]);
    let (redeemed_release_c, _, redeemed_amount_c) = action::funds_redeemed_event_fields(&redeemed[1]);
    assert_eq!(redeemed_release_a, address_a);
    assert_eq!(redeemed_amount_a, 10_000);
    assert_eq!(redeemed_release_c, address_c);
    assert_eq!(redeemed_amount_c, 5_001);
    let tracks = event::events_by_type<action::ReleaseTrackRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(tracks.length(), 4);
    let summaries = event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(summaries.length(), 2);
    let (summary_release_a, _, input_a, distributed_a, remainder_a) =
        action::distribution_event_fields(&summaries[0]);
    let (summary_release_c, _, input_c, distributed_c, remainder_c) =
        action::distribution_event_fields(&summaries[1]);
    assert_eq!(summary_release_a, address_a);
    assert_eq!(input_a, 10_000);
    assert_eq!(distributed_a, 10_000);
    assert_eq!(remainder_a, 0);
    assert_eq!(summary_release_c, address_c);
    assert_eq!(input_c, 5_001);
    assert_eq!(distributed_c, 5_000);
    assert_eq!(remainder_c, 1);

    test_scenario::return_shared(root);
    destroy(release_a);
    destroy(release_b);
    destroy(release_c);
    destroy(cap_a);
    destroy(cap_b);
    destroy(cap_c);
    scenario.end();
}
