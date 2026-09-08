// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Raw-cap, custody-agnostic royalty-pool actions for musicos Recordings.
///
/// Every mutating action requires the Recording's own admin capability. The
/// canonical pool remains derived from the Recording and is returned unshared.
module recording_royalty_pool::recording_royalty_pool;

use hikida::hikida;
use musicos::recording::{Recording, RecordingAdminCap};
use royalty_pool::pool::{Self, RoyaltyPool};
use sui::coin::Coin;
use sui::transfer::Receiving;

/// Create and return the canonical unshared pool derived from `recording`.
public fun new_pool<RecordingShare, CompositionShare, Currency>(
    recording: &mut Recording<RecordingShare, CompositionShare>,
    admin_cap: &RecordingAdminCap<RecordingShare>,
): RoyaltyPool<RecordingShare, Currency> {
    pool::new(recording.uid_mut(admin_cap))
}

/// Receive selected coins sent to the Recording and deposit their balance
/// into the canonical pool derived from that same Recording.
public fun receive_and_deposit<RecordingShare, CompositionShare, Currency>(
    recording: &mut Recording<RecordingShare, CompositionShare>,
    admin_cap: &RecordingAdminCap<RecordingShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    coins: vector<Receiving<Coin<Currency>>>,
) {
    pool.assert_derived_from(object::id(recording));
    let received = hikida::receive_balance(recording.uid_mut(admin_cap), coins);
    pool.deposit(received)
}

/// Redeem `value` from the Recording's funds accumulator and deposit it into
/// the canonical pool derived from that same Recording.
public fun redeem_and_deposit<RecordingShare, CompositionShare, Currency>(
    recording: &mut Recording<RecordingShare, CompositionShare>,
    admin_cap: &RecordingAdminCap<RecordingShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    value: u64,
) {
    pool.assert_derived_from(object::id(recording));
    let redeemed = hikida::redeem_balance<Currency>(recording.uid_mut(admin_cap), value);
    pool.deposit(redeemed)
}

/// Canonical pool address for this Recording, share type, and Currency.
public fun pool_address<RecordingShare, CompositionShare, Currency>(
    recording: &Recording<RecordingShare, CompositionShare>,
): address {
    pool::derived_address<RecordingShare, Currency>(object::id(recording))
}
