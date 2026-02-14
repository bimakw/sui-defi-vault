module sui_defi_vault::vault {
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use sui::event;

    const EInsufficientShares: u64 = 0;
    const EInsufficientDeposit: u64 = 1;
    const EVaultEmpty: u64 = 2;
    const EZeroAmount: u64 = 3;

    public struct Vault has key {
        id: UID,
        balance: Balance<SUI>,
        total_shares: u64,
        min_deposit: u64,
    }

    public struct VaultShare has key, store {
        id: UID,
        vault_id: address,
        shares: u64,
        owner: address,
    }

    public struct Deposited has copy, drop {
        depositor: address,
        amount: u64,
        shares_minted: u64,
        total_shares: u64,
    }

    public struct Withdrawn has copy, drop {
        withdrawer: address,
        shares_burned: u64,
        amount_received: u64,
        total_shares: u64,
    }

    fun init(ctx: &mut TxContext) {
        let vault = Vault {
            id: object::new(ctx),
            balance: balance::zero(),
            total_shares: 0,
            min_deposit: 1_000_000, // 0.001 SUI minimum
        };

        transfer::share_object(vault);
    }

    public fun calculate_shares(vault: &Vault, amount: u64): u64 {
        let total_balance = balance::value(&vault.balance);

        if (vault.total_shares == 0 || total_balance == 0) {
            // First deposit: 1:1 ratio
            amount
        } else {
            // Proportional shares based on current ratio
            (amount * vault.total_shares) / total_balance
        }
    }

    public fun calculate_withdrawal(vault: &Vault, shares: u64): u64 {
        let total_balance = balance::value(&vault.balance);

        if (vault.total_shares == 0) {
            0
        } else {
            (shares * total_balance) / vault.total_shares
        }
    }

    public entry fun deposit(
        vault: &mut Vault,
        payment: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        let amount = coin::value(&payment);
        let depositor = tx_context::sender(ctx);

        assert!(amount >= vault.min_deposit, EInsufficientDeposit);

        let shares = calculate_shares(vault, amount);
        assert!(shares > 0, EZeroAmount);

        balance::join(&mut vault.balance, coin::into_balance(payment));
        vault.total_shares = vault.total_shares + shares;

        let share_token = VaultShare {
            id: object::new(ctx),
            vault_id: object::uid_to_address(&vault.id),
            shares,
            owner: depositor,
        };

        event::emit(Deposited {
            depositor,
            amount,
            shares_minted: shares,
            total_shares: vault.total_shares,
        });

        transfer::public_transfer(share_token, depositor);
    }

    public entry fun withdraw(
        vault: &mut Vault,
        share_token: VaultShare,
        ctx: &mut TxContext
    ) {
        let withdrawer = tx_context::sender(ctx);
        let shares = share_token.shares;

        assert!(shares > 0, EInsufficientShares);
        assert!(vault.total_shares >= shares, EInsufficientShares);

        let withdrawal_amount = calculate_withdrawal(vault, shares);
        assert!(withdrawal_amount > 0, EVaultEmpty);

        vault.total_shares = vault.total_shares - shares;

        let VaultShare { id, vault_id: _, shares: _, owner: _ } = share_token;
        object::delete(id);

        let withdrawn_coin = coin::from_balance(
            balance::split(&mut vault.balance, withdrawal_amount),
            ctx
        );

        event::emit(Withdrawn {
            withdrawer,
            shares_burned: shares,
            amount_received: withdrawal_amount,
            total_shares: vault.total_shares,
        });

        transfer::public_transfer(withdrawn_coin, withdrawer);
    }

    public entry fun withdraw_partial(
        vault: &mut Vault,
        share_token: &mut VaultShare,
        shares_to_withdraw: u64,
        ctx: &mut TxContext
    ) {
        let withdrawer = tx_context::sender(ctx);

        assert!(shares_to_withdraw > 0, EZeroAmount);
        assert!(share_token.shares >= shares_to_withdraw, EInsufficientShares);
        assert!(vault.total_shares >= shares_to_withdraw, EInsufficientShares);

        let withdrawal_amount = calculate_withdrawal(vault, shares_to_withdraw);
        assert!(withdrawal_amount > 0, EVaultEmpty);

        vault.total_shares = vault.total_shares - shares_to_withdraw;
        share_token.shares = share_token.shares - shares_to_withdraw;

        let withdrawn_coin = coin::from_balance(
            balance::split(&mut vault.balance, withdrawal_amount),
            ctx
        );

        event::emit(Withdrawn {
            withdrawer,
            shares_burned: shares_to_withdraw,
            amount_received: withdrawal_amount,
            total_shares: vault.total_shares,
        });

        transfer::public_transfer(withdrawn_coin, withdrawer);
    }

    public entry fun transfer_shares(
        share_token: VaultShare,
        recipient: address
    ) {
        transfer::public_transfer(share_token, recipient);
    }

    public entry fun merge_shares(
        share1: &mut VaultShare,
        share2: VaultShare
    ) {
        assert!(share1.vault_id == share2.vault_id, 0);

        share1.shares = share1.shares + share2.shares;

        let VaultShare { id, vault_id: _, shares: _, owner: _ } = share2;
        object::delete(id);
    }

    public fun vault_balance(vault: &Vault): u64 {
        balance::value(&vault.balance)
    }

    public fun total_shares(vault: &Vault): u64 {
        vault.total_shares
    }

    public fun share_balance(share_token: &VaultShare): u64 {
        share_token.shares
    }

    public fun share_value(vault: &Vault, share_token: &VaultShare): u64 {
        calculate_withdrawal(vault, share_token.shares)
    }

    public fun exchange_rate(vault: &Vault): u64 {
        let total_balance = balance::value(&vault.balance);
        if (vault.total_shares == 0) {
            1_000_000_000 // 1:1 initial rate (scaled by 1e9)
        } else {
            (total_balance * 1_000_000_000) / vault.total_shares
        }
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
}
