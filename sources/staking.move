/*
 * Copyright (c) 2025 Bima Kharisma Wicaksana
 * GitHub: https://github.com/bimakw
 *
 * Licensed under MIT License with Attribution Requirement.
 * See LICENSE file for details.
 */

/// Staking Module - Time-based staking with reward distribution.
/// Demonstrates staking mechanics with lock periods and APY calculation.
module sui_defi_vault::staking {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::event;

    /// Error codes
    const EStillLocked: u64 = 0;
    const EInvalidAmount: u64 = 1;
    const EPoolEmpty: u64 = 2;
    const ENoRewards: u64 = 3;

    /// Reward token one-time-witness
    public struct STAKING has drop {}

    /// Staking pool configuration
    public struct StakingPool<phantom StakeToken> has key {
        id: UID,
        staked_balance: Balance<StakeToken>,
        reward_balance: Balance<STAKING>,
        total_staked: u64,
        reward_per_second: u64,      // Rewards distributed per second (scaled by 1e9)
        last_update_time: u64,
        accumulated_reward_per_share: u64, // Scaled by 1e18
        lock_period_ms: u64,
    }

    /// Individual stake position
    public struct StakePosition<phantom StakeToken> has key, store {
        id: UID,
        pool_id: ID,
        owner: address,
        amount: u64,
        reward_debt: u64,            // Rewards already accounted for
        stake_time: u64,
        unlock_time: u64,
    }

    /// Events
    public struct Staked has copy, drop {
        user: address,
        amount: u64,
        unlock_time: u64,
    }

    public struct Unstaked has copy, drop {
        user: address,
        amount: u64,
        rewards: u64,
    }

    public struct RewardsClaimed has copy, drop {
        user: address,
        rewards: u64,
    }

    /// Initialize staking reward token
    fun init(witness: STAKING, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency(
            witness,
            9,
            b"REWARD",
            b"Staking Reward Token",
            b"Reward token for staking",
            option::none(),
            ctx
        );

        transfer::public_freeze_object(metadata);
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
    }

    /// Create a new staking pool
    public entry fun create_pool<StakeToken>(
        reward_per_second: u64,
        lock_period_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let pool = StakingPool<StakeToken> {
            id: object::new(ctx),
            staked_balance: balance::zero(),
            reward_balance: balance::zero(),
            total_staked: 0,
            reward_per_second,
            last_update_time: clock::timestamp_ms(clock),
            accumulated_reward_per_share: 0,
            lock_period_ms,
        };

        transfer::share_object(pool);
    }

    /// Fund the reward pool
    public entry fun fund_rewards<StakeToken>(
        pool: &mut StakingPool<StakeToken>,
        rewards: Coin<STAKING>
    ) {
        balance::join(&mut pool.reward_balance, coin::into_balance(rewards));
    }

    /// Update reward accumulator
    fun update_rewards<StakeToken>(
        pool: &mut StakingPool<StakeToken>,
        clock: &Clock
    ) {
        let current_time = clock::timestamp_ms(clock);

        if (pool.total_staked == 0) {
            pool.last_update_time = current_time;
            return
        };

        let time_elapsed = current_time - pool.last_update_time;
        let rewards = (time_elapsed * pool.reward_per_second) / 1000; // Convert ms to seconds

        if (rewards > 0) {
            // Scale by 1e18 for precision
            pool.accumulated_reward_per_share = pool.accumulated_reward_per_share +
                (rewards * 1_000_000_000_000_000_000) / pool.total_staked;
        };

        pool.last_update_time = current_time;
    }

    /// Calculate pending rewards for a position
    public fun pending_rewards<StakeToken>(
        pool: &StakingPool<StakeToken>,
        position: &StakePosition<StakeToken>,
        clock: &Clock
    ): u64 {
        let current_time = clock::timestamp_ms(clock);
        let time_elapsed = current_time - pool.last_update_time;

        let mut acc_reward_per_share = pool.accumulated_reward_per_share;

        if (pool.total_staked > 0 && time_elapsed > 0) {
            let rewards = (time_elapsed * pool.reward_per_second) / 1000;
            acc_reward_per_share = acc_reward_per_share +
                (rewards * 1_000_000_000_000_000_000) / pool.total_staked;
        };

        let pending = (position.amount * acc_reward_per_share) / 1_000_000_000_000_000_000;

        if (pending > position.reward_debt) {
            pending - position.reward_debt
        } else {
            0
        }
    }

    /// Stake tokens
    public entry fun stake<StakeToken>(
        pool: &mut StakingPool<StakeToken>,
        stake_coin: Coin<StakeToken>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let amount = coin::value(&stake_coin);
        let staker = tx_context::sender(ctx);

        assert!(amount > 0, EInvalidAmount);

        // Update rewards before state change
        update_rewards(pool, clock);

        let current_time = clock::timestamp_ms(clock);
        let unlock_time = current_time + pool.lock_period_ms;

        // Add to pool
        balance::join(&mut pool.staked_balance, coin::into_balance(stake_coin));
        pool.total_staked = pool.total_staked + amount;

        // Calculate initial reward debt
        let reward_debt = (amount * pool.accumulated_reward_per_share) / 1_000_000_000_000_000_000;

        // Create position
        let position = StakePosition<StakeToken> {
            id: object::new(ctx),
            pool_id: object::id(pool),
            owner: staker,
            amount,
            reward_debt,
            stake_time: current_time,
            unlock_time,
        };

        event::emit(Staked {
            user: staker,
            amount,
            unlock_time,
        });

        transfer::transfer(position, staker);
    }

    /// Claim rewards without unstaking
    public entry fun claim_rewards<StakeToken>(
        pool: &mut StakingPool<StakeToken>,
        position: &mut StakePosition<StakeToken>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let claimer = tx_context::sender(ctx);

        update_rewards(pool, clock);

        let pending = (position.amount * pool.accumulated_reward_per_share) / 1_000_000_000_000_000_000;
        let rewards = pending - position.reward_debt;

        assert!(rewards > 0, ENoRewards);
        assert!(balance::value(&pool.reward_balance) >= rewards, EPoolEmpty);

        position.reward_debt = pending;

        let reward_coin = coin::from_balance(
            balance::split(&mut pool.reward_balance, rewards),
            ctx
        );

        event::emit(RewardsClaimed {
            user: claimer,
            rewards,
        });

        transfer::public_transfer(reward_coin, claimer);
    }

    /// Unstake and claim rewards
    public entry fun unstake<StakeToken>(
        pool: &mut StakingPool<StakeToken>,
        position: StakePosition<StakeToken>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        let unstaker = tx_context::sender(ctx);

        assert!(current_time >= position.unlock_time, EStillLocked);

        update_rewards(pool, clock);

        let pending = (position.amount * pool.accumulated_reward_per_share) / 1_000_000_000_000_000_000;
        let rewards = if (pending > position.reward_debt) {
            pending - position.reward_debt
        } else {
            0
        };

        let amount = position.amount;

        // Update pool state
        pool.total_staked = pool.total_staked - amount;

        // Return staked tokens
        let staked_coin = coin::from_balance(
            balance::split(&mut pool.staked_balance, amount),
            ctx
        );
        transfer::public_transfer(staked_coin, unstaker);

        // Transfer rewards if any
        if (rewards > 0 && balance::value(&pool.reward_balance) >= rewards) {
            let reward_coin = coin::from_balance(
                balance::split(&mut pool.reward_balance, rewards),
                ctx
            );
            transfer::public_transfer(reward_coin, unstaker);
        };

        // Destroy position
        let StakePosition {
            id,
            pool_id: _,
            owner: _,
            amount: _,
            reward_debt: _,
            stake_time: _,
            unlock_time: _,
        } = position;
        object::delete(id);

        event::emit(Unstaked {
            user: unstaker,
            amount,
            rewards,
        });
    }

    /// View functions
    public fun get_staked_amount<StakeToken>(position: &StakePosition<StakeToken>): u64 {
        position.amount
    }

    public fun get_unlock_time<StakeToken>(position: &StakePosition<StakeToken>): u64 {
        position.unlock_time
    }

    public fun is_unlocked<StakeToken>(position: &StakePosition<StakeToken>, clock: &Clock): bool {
        clock::timestamp_ms(clock) >= position.unlock_time
    }

    public fun pool_total_staked<StakeToken>(pool: &StakingPool<StakeToken>): u64 {
        pool.total_staked
    }

    public fun pool_reward_balance<StakeToken>(pool: &StakingPool<StakeToken>): u64 {
        balance::value(&pool.reward_balance)
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(STAKING {}, ctx);
    }
}
