// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Raw-cap Release revenue actions.
///
/// Revenue is split from the immutable Release tracklist and sent to the
/// corresponding Recording addresses. Callers select only funds already held
/// by the Release; they cannot select recipients or alter split amounts.
module release_revenue_distributor::release_revenue_distributor;

use hikida::hikida;
use musicos::release::{Release, ReleaseAdminCap};
use sui::accumulator::AccumulatorRoot;
use sui::balance::{Self, Balance};
use sui::coin::Coin;
use sui::event::emit;
use sui::transfer::Receiving;

/// Emitted after selected coins are received into the Release accumulator.
public struct ReleaseCoinsReceivedEvent<phantom Currency> has copy, drop {
    release_id: address,
    admin_cap_id: address,
    coin_ids: vector<address>,
    amount: u64,
}

/// Emitted after funds are redeemed from the Release accumulator.
public struct ReleaseFundsRedeemedEvent<phantom Currency> has copy, drop {
    release_id: address,
    admin_cap_id: address,
    amount: u64,
}

/// Emitted for every Release track, including a zero-value rounded split.
public struct ReleaseTrackRevenueDistributedEvent<phantom Currency> has copy, drop {
    release_id: address,
    track_index: u64,
    composition_id: address,
    recording_id: address,
    split_bps: u16,
    total_input: u64,
    amount: u64,
}

/// Emitted once after an entire Release distribution completes.
public struct ReleaseRevenueDistributedEvent<phantom Currency> has copy, drop {
    release_id: address,
    track_count: u64,
    total_input: u64,
    total_distributed: u64,
    remainder: u64,
}

/// Redeem `value` from the Release accumulator and distribute it according to
/// the immutable tracklist.
public fun redeem_and_distribute<Currency>(
    release: &mut Release,
    admin_cap: &ReleaseAdminCap,
    value: u64,
) {
    let release_id = object::id(release).to_address();
    let admin_cap_id = object::id(admin_cap).to_address();
    let revenue = hikida::redeem_balance<Currency>(release.uid_mut(admin_cap), value);
    emit(ReleaseFundsRedeemedEvent<Currency> {
        release_id,
        admin_cap_id,
        amount: revenue.value(),
    });
    distribute(release, revenue)
}

/// Redeem all Release funds settled at the start of the current consensus
/// commit and distribute them according to the immutable tracklist.
///
/// The framework snapshot is capped at `u64::MAX`; excess funds, newly sent
/// funds, and per-track flooring remainder settle for a later call. This fixed
/// crank prevents permissionless adapters from selecting dust-sized fragments.
/// A zero settled snapshot is an idempotent no-op.
public fun redeem_all_and_distribute<Currency>(
    release: &mut Release,
    admin_cap: &ReleaseAdminCap,
    root: &AccumulatorRoot,
) {
    let value = balance::settled_funds_value<Currency>(root, object::id(release).to_address());
    redeem_settled_value_and_distribute<Currency>(release, admin_cap, value)
}

/// Redeem a previously read settled snapshot when it is positive.
fun redeem_settled_value_and_distribute<Currency>(
    release: &mut Release,
    admin_cap: &ReleaseAdminCap,
    value: u64,
) {
    release.authorize(admin_cap);
    if (value == 0) return;
    redeem_and_distribute<Currency>(release, admin_cap, value)
}

/// Receive selected coins sent to the Release and distribute their combined
/// value according to the immutable tracklist.
public fun receive_and_distribute<Currency>(
    release: &mut Release,
    admin_cap: &ReleaseAdminCap,
    coins: vector<Receiving<Coin<Currency>>>,
) {
    let release_id = object::id(release).to_address();
    let admin_cap_id = object::id(admin_cap).to_address();
    let coin_ids = coins.map_ref!(|coin| sui::transfer::receiving_object_id(coin).to_address());
    let revenue = hikida::receive_balance(release.uid_mut(admin_cap), coins);
    emit(ReleaseCoinsReceivedEvent<Currency> {
        release_id,
        admin_cap_id,
        coin_ids,
        amount: revenue.value(),
    });
    distribute(release, revenue)
}

/// Split a balance using only immutable Release data. Per-track flooring
/// remainder returns to the Release address for a later distribution.
fun distribute<Currency>(release: &Release, mut revenue: Balance<Currency>) {
    let release_id = object::id(release).to_address();
    let total_input = revenue.value();
    let mut total_distributed = 0;
    let mut track_index = 0;

    release.tracks().do_ref!(|track| {
        let amount = track.split_bps().apply(total_input);
        total_distributed = total_distributed + amount;
        if (amount > 0) {
            revenue.split(amount).send_funds(track.recording_id().to_address());
        };
        emit(ReleaseTrackRevenueDistributedEvent<Currency> {
            release_id,
            track_index,
            composition_id: track.composition_id().to_address(),
            recording_id: track.recording_id().to_address(),
            split_bps: track.split_bps().value(),
            total_input,
            amount,
        });
        track_index = track_index + 1;
    });

    let remainder = revenue.value();
    if (remainder > 0) {
        revenue.send_funds(release_id);
    } else {
        revenue.destroy_zero();
    };

    emit(ReleaseRevenueDistributedEvent<Currency> {
        release_id,
        track_count: track_index,
        total_input,
        total_distributed,
        remainder,
    })
}

#[test_only]
public fun coins_received_event_fields<Currency>(
    event: &ReleaseCoinsReceivedEvent<Currency>,
): (address, address, vector<address>, u64) {
    (event.release_id, event.admin_cap_id, event.coin_ids, event.amount)
}

#[test_only]
public fun funds_redeemed_event_fields<Currency>(
    event: &ReleaseFundsRedeemedEvent<Currency>,
): (address, address, u64) {
    (event.release_id, event.admin_cap_id, event.amount)
}

#[test_only]
public fun track_event_fields<Currency>(
    event: &ReleaseTrackRevenueDistributedEvent<Currency>,
): (address, u64, address, address, u16, u64, u64) {
    (
        event.release_id,
        event.track_index,
        event.composition_id,
        event.recording_id,
        event.split_bps,
        event.total_input,
        event.amount,
    )
}

#[test_only]
public fun distribution_event_fields<Currency>(
    event: &ReleaseRevenueDistributedEvent<Currency>,
): (address, u64, u64, u64, u64) {
    (
        event.release_id,
        event.track_count,
        event.total_input,
        event.total_distributed,
        event.remainder,
    )
}

#[test_only]
public fun redeem_settled_value_and_distribute_for_testing<Currency>(
    release: &mut Release,
    admin_cap: &ReleaseAdminCap,
    value: u64,
) {
    redeem_settled_value_and_distribute<Currency>(release, admin_cap, value)
}
