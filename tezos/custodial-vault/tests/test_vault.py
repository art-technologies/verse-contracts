"""Scenario tests for the custodial NFT vault (proposal §17, on-chain parts).

Run with: python tests/test_vault.py

Withdrawal targets are the *official* SmartPy FA2 library contracts
(fa2_lib.main.Nft / .Fungible) plus purpose-built mocks (rejecting FA2,
admin proxy, view caller) from tests/mocks.py.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import smartpy as sp
from smartpy.templates import fa1_2 as fa1_2_template
from smartpy.templates import fa2_lib as fa2

from contracts.vault import vault_module
from tests.mocks import mocks

t = fa2.t

# Reference timeline (period_seconds=600 in the default limits)
T0 = sp.timestamp(1_000_000)
T0_PLUS_10 = sp.timestamp(1_000_010)
T0_PLUS_599 = sp.timestamp(1_000_599)
T0_PLUS_600 = sp.timestamp(1_000_600)  # exact expiry boundary
T0_PLUS_601 = sp.timestamp(1_000_601)

DEFAULT_LIMITS = sp.record(max_tokens=5, period_seconds=600, max_items_per_batch=3)

MODULES = [t, fa2.main, vault_module, mocks]


def make_accounts():
    return (
        sp.test_account("admin"),
        sp.test_account("manager"),
        sp.test_account("locker"),
        sp.test_account("user"),
        sp.test_account("recipient"),
    )


def originate_vault(sc, admin, manager, locker, limits=DEFAULT_LIMITS):
    vault = vault_module.Vault(
        admin=admin.address,
        managers=sp.set([manager.address]),
        emergency_lockers=sp.set([locker.address]),
        limits=limits,
        metadata=sp.big_map(),
    )
    sc += vault
    return vault


def originate_nft(sc, owners):
    """Official FA2 NFT with tokens 0..n-1 owned per `owners` list."""
    nft = fa2.main.Nft(
        metadata=sp.big_map(),
        ledger={i: owner for i, owner in enumerate(owners)},
        token_metadata=[
            fa2.make_metadata(symbol="NFT", name=f"Token {i}", decimals=0)
            for i in range(len(owners))
        ],
    )
    sc += nft
    return nft


def originate_fungible(sc, ledger):
    """Official FA2 fungible (editions). ledger: {(owner, token_id): amount}."""
    max_token = max(token_id for (_, token_id) in ledger) + 1
    fungible = fa2.main.Fungible(
        metadata=sp.big_map(),
        ledger=ledger,
        token_metadata=[
            fa2.make_metadata(symbol="ED", name=f"Edition {i}", decimals=0)
            for i in range(max_token)
        ],
    )
    sc += fungible
    return fungible


def withdraw_item(fa2_addr, token_id, amount, recipient):
    return sp.record(
        fa2=fa2_addr, token_id=token_id, amount=amount, recipient=recipient
    )


def originate_fa1_2(sc, admin, ledger):
    """Official SmartPy FA1.2 (TZIP-7) template. ledger: {owner: balance}."""
    token = fa1_2_template.m.Fa1_2TestFull(
        administrator=admin.address,
        metadata=sp.big_map(),
        ledger={
            owner: sp.record(balance=balance, approvals={})
            for owner, balance in ledger.items()
        },
        token_metadata={
            "decimals": sp.scenario_utils.bytes_of_string("0"),
            "name": sp.scenario_utils.bytes_of_string("Mock FA1.2"),
            "symbol": sp.scenario_utils.bytes_of_string("MCK"),
        },
    )
    sc += token
    return token


@sp.add_test()
def test_deposit_and_withdraw():
    """Deposit by plain FA2 transfer, single + batched withdrawals, grouping,
    editions with amount > 1."""
    sc = sp.test_scenario("DepositAndWithdraw", MODULES)
    admin, manager, locker, user, recipient = make_accounts()
    vault = originate_vault(sc, admin, manager, locker)

    sc.h2("Deposit: user sends NFT to the vault with a plain FA2 transfer")
    nft = originate_nft(sc, [user.address, user.address])
    nft.transfer(
        [
            sp.record(
                from_=user.address,
                txs=[
                    sp.record(to_=vault.address, token_id=0, amount=1),
                    sp.record(to_=vault.address, token_id=1, amount=1),
                ],
            )
        ],
        _sender=user,
    )
    sc.verify(nft.data.ledger[0] == vault.address)
    sc.verify(nft.data.ledger[1] == vault.address)

    sc.h2("Manager withdraws a single NFT to the recipient")
    vault.withdraw(
        [withdraw_item(nft.address, 0, 1, recipient.address)],
        _sender=manager,
        _now=T0,
    )
    sc.verify(nft.data.ledger[0] == recipient.address)
    sc.verify(nft.data.ledger[1] == vault.address)
    sc.verify(sp.len(vault.data.withdrawal_history) == 1)

    sc.h2("Batch across two FA2 contracts, including editions (amount > 1)")
    fungible = originate_fungible(sc, {(vault.address, 0): 3})
    vault.withdraw(
        [
            withdraw_item(nft.address, 1, 1, recipient.address),
            withdraw_item(fungible.address, 0, 2, recipient.address),
            withdraw_item(fungible.address, 0, 1, user.address),
        ],
        _sender=manager,
        _now=T0_PLUS_10,
    )
    sc.verify(nft.data.ledger[1] == recipient.address)
    sc.verify(fungible.data.ledger[(recipient.address, 0)] == 2)
    sc.verify(fungible.data.ledger[(user.address, 0)] == 1)
    sc.verify(sp.len(vault.data.withdrawal_history) == 2)


@sp.add_test()
def test_withdraw_access_control_and_validation():
    """Only the manager can withdraw; malformed batches are rejected."""
    sc = sp.test_scenario("WithdrawAccessValidation", MODULES)
    admin, manager, locker, user, recipient = make_accounts()
    vault = originate_vault(sc, admin, manager, locker)
    batch = [withdraw_item(user.address, 0, 1, recipient.address)]

    sc.h2("Non-manager senders are rejected (user, admin, emergency locker)")
    for sender in (user, admin, locker):
        vault.withdraw(
            batch, _sender=sender, _valid=False, _exception="VAULT_NOT_MANAGER"
        )

    sc.h2("Attached tez is rejected")
    vault.withdraw(
        batch,
        _sender=manager,
        _amount=sp.mutez(1),
        _valid=False,
        _exception="VAULT_TEZ_REJECTED",
    )

    sc.h2("Empty batch is rejected")
    vault.withdraw([], _sender=manager, _valid=False, _exception="VAULT_EMPTY_BATCH")

    sc.h2("Zero-amount item is rejected")
    vault.withdraw(
        [withdraw_item(user.address, 0, 0, recipient.address)],
        _sender=manager,
        _valid=False,
        _exception="VAULT_ZERO_AMOUNT",
    )

    sc.h2("Batch longer than max_items_per_batch (3) is rejected")
    vault.withdraw(
        [withdraw_item(user.address, i, 1, recipient.address) for i in range(4)],
        _sender=manager,
        _valid=False,
        _exception="VAULT_BATCH_TOO_LARGE",
    )


@sp.add_test()
def test_rate_limit_autolock_and_window():
    """The limiter counts distinct (fa2, token_id) pairs, never amounts.
    Exact limit passes; over-limit succeeds-but-locks; the window is shared
    across all managers; unlock never resets the active window; expired
    history returns the budget; duplicates within a batch count once."""
    sc = sp.test_scenario("RateLimit", MODULES)
    admin, manager, locker, second_manager, recipient = make_accounts()
    vault = vault_module.Vault(
        admin=admin.address,
        managers=sp.set([manager.address, second_manager.address]),
        emergency_lockers=sp.set([locker.address]),
        limits=DEFAULT_LIMITS,  # max_tokens=5, period=600, batch<=3
        metadata=sp.big_map(),
    )
    sc += vault
    fungible = originate_fungible(
        sc, {(vault.address, token_id): 2_000 for token_id in range(7)}
    )

    sc.h2("Amounts don't count: 3 distinct tokens with huge amounts = 3 units")
    vault.withdraw(
        [
            withdraw_item(fungible.address, 0, 1_000, recipient.address),
            withdraw_item(fungible.address, 1, 500, recipient.address),
            withdraw_item(fungible.address, 2, 100, recipient.address),
        ],
        _sender=manager,
        _now=T0,
    )
    sc.verify(fungible.data.ledger[(recipient.address, 0)] == 1_000)
    sc.verify(sp.len(vault.data.withdrawal_history) == 1)

    sc.h2("Second manager adds 2 more distinct tokens: shared window at 5/5")
    vault.withdraw(
        [
            withdraw_item(fungible.address, 3, 1, recipient.address),
            withdraw_item(fungible.address, 4, 1, recipient.address),
        ],
        _sender=second_manager,
        _now=T0_PLUS_10,
    )
    sc.verify(~vault.data.locked)
    sc.verify(sp.len(vault.data.withdrawal_history) == 2)

    sc.h2("One more distinct token: succeeds but auto-locks, no transfer")
    vault.withdraw(
        [withdraw_item(fungible.address, 5, 1, recipient.address)],
        _sender=second_manager,  # NOT _valid=False: must not fail
        _now=T0_PLUS_10,
    )
    sc.verify(vault.data.locked)
    sc.verify(~fungible.data.ledger.contains((recipient.address, 5)))
    sc.verify(sp.len(vault.data.withdrawal_history) == 2)  # no new record

    sc.h2("While locked, withdrawals fail")
    vault.withdraw(
        [withdraw_item(fungible.address, 5, 1, recipient.address)],
        _sender=manager,
        _now=T0_PLUS_10,
        _valid=False,
        _exception="VAULT_LOCKED",
    )

    sc.h2("Admin unlock keeps the active window: next withdrawal re-locks")
    vault.unlock(_sender=admin, _now=T0_PLUS_10)
    sc.verify(~vault.data.locked)
    sc.verify(sp.len(vault.data.withdrawal_history) == 2)  # still active
    vault.withdraw(
        [withdraw_item(fungible.address, 5, 1, recipient.address)],
        _sender=manager,
        _now=T0_PLUS_599,  # still inside the 600s window
    )
    sc.verify(vault.data.locked)
    sc.verify(~fungible.data.ledger.contains((recipient.address, 5)))

    sc.h2("After the first record expires its 3 units return, 2 stay used")
    vault.unlock(_sender=admin, _now=T0_PLUS_601)
    sc.verify(sp.len(vault.data.withdrawal_history) == 1)  # T0 record expired
    vault.withdraw(
        [
            withdraw_item(fungible.address, 0, 1, recipient.address),
            withdraw_item(fungible.address, 1, 1, recipient.address),
            withdraw_item(fungible.address, 2, 1, recipient.address),
        ],
        _sender=manager,
        _now=T0_PLUS_601,  # used 2 + 3 = 5: exactly at the limit
    )
    sc.verify(~vault.data.locked)
    sc.verify(fungible.data.ledger[(recipient.address, 1)] == 501)

    sc.h2("Same token repeated in one batch counts once")
    t_fresh = sp.timestamp(1_002_000)  # everything above has expired
    vault.withdraw(
        [
            withdraw_item(fungible.address, 6, 700, recipient.address),
            withdraw_item(fungible.address, 6, 300, locker.address),
        ],
        _sender=manager,
        _now=t_fresh,  # 2 items, 1 distinct token
    )
    vault.withdraw(
        [
            withdraw_item(fungible.address, 0, 1, recipient.address),
            withdraw_item(fungible.address, 1, 1, recipient.address),
            withdraw_item(fungible.address, 2, 1, recipient.address),
        ],
        _sender=manager,
        _now=t_fresh,  # 1 + 3 = 4 used
    )
    vault.withdraw(
        [withdraw_item(fungible.address, 3, 1, recipient.address)],
        _sender=manager,
        _now=t_fresh,  # 5/5: only fits if the duplicate counted once
    )
    sc.verify(~vault.data.locked)
    sc.verify(fungible.data.ledger[(recipient.address, 6)] == 700)
    sc.verify(fungible.data.ledger[(locker.address, 6)] == 300)

    sc.h2("The 6th distinct token in the window auto-locks")
    vault.withdraw(
        [withdraw_item(fungible.address, 4, 1, recipient.address)],
        _sender=manager,
        _now=t_fresh,
    )
    sc.verify(vault.data.locked)


@sp.add_test()
def test_lock_roles_and_transitions():
    """Emergency lockers can lock and do nothing else; only admin unlocks."""
    sc = sp.test_scenario("LockRoles", MODULES)
    admin, manager, locker, user, _recipient = make_accounts()
    vault = originate_vault(sc, admin, manager, locker)

    sc.h2("Random accounts and the manager cannot lock")
    vault.lock(_sender=user, _valid=False, _exception="VAULT_NOT_ADMIN_OR_LOCKER")
    vault.lock(_sender=manager, _valid=False, _exception="VAULT_NOT_ADMIN_OR_LOCKER")

    sc.h2("Unlock while not locked fails")
    vault.unlock(_sender=admin, _valid=False, _exception="VAULT_NOT_LOCKED")

    sc.h2("Emergency locker locks")
    vault.lock(_sender=locker, _now=T0)
    sc.verify(vault.data.locked)

    sc.h2("Re-lock while locked is allowed and stays locked (admin this time)")
    vault.lock(_sender=admin, _now=T0_PLUS_10)
    sc.verify(vault.data.locked)

    sc.h2("Emergency locker cannot unlock, rotate managers, or change limits")
    vault.unlock(_sender=locker, _valid=False, _exception="VAULT_NOT_ADMIN")
    vault.set_managers(
        sp.set([user.address]),
        _sender=locker,
        _valid=False,
        _exception="VAULT_NOT_ADMIN",
    )
    vault.set_limits(
        DEFAULT_LIMITS, _sender=locker, _valid=False, _exception="VAULT_NOT_ADMIN"
    )

    sc.h2("Tez is rejected on lock and unlock")
    vault.lock(
        _sender=locker,
        _amount=sp.mutez(1),
        _valid=False,
        _exception="VAULT_TEZ_REJECTED",
    )
    vault.unlock(
        _sender=admin,
        _amount=sp.mutez(1),
        _valid=False,
        _exception="VAULT_TEZ_REJECTED",
    )

    sc.h2("Admin unlocks")
    vault.unlock(_sender=admin)
    sc.verify(~vault.data.locked)


@sp.add_test()
def test_admin_two_step_transfer():
    """set_pending_admin -> accept_admin with every negative path."""
    sc = sp.test_scenario("AdminTwoStep", MODULES)
    admin, manager, locker, user, other = make_accounts()
    vault = originate_vault(sc, admin, manager, locker)

    sc.h2("Non-admin cannot nominate")
    vault.set_pending_admin(
        user.address, _sender=user, _valid=False, _exception="VAULT_NOT_ADMIN"
    )

    sc.h2("Accept without a pending admin fails")
    vault.accept_admin(_sender=user, _valid=False, _exception="VAULT_NO_PENDING_ADMIN")

    sc.h2("Admin nominates `other`")
    vault.set_pending_admin(other.address, _sender=admin)
    sc.verify(vault.data.pending_admin == sp.Some(other.address))

    sc.h2("Someone else cannot accept")
    vault.accept_admin(_sender=user, _valid=False, _exception="VAULT_NOT_PENDING_ADMIN")

    sc.h2("Pending admin has no admin rights before accepting")
    vault.set_managers(
        sp.set([user.address]),
        _sender=other,
        _valid=False,
        _exception="VAULT_NOT_ADMIN",
    )

    sc.h2("Pending admin accepts; pending slot is cleared")
    vault.accept_admin(_sender=other)
    sc.verify(vault.data.admin == other.address)
    sc.verify(~vault.data.pending_admin.is_some())

    sc.h2("Old admin lost its rights; new admin has them")
    vault.set_managers(
        sp.set([user.address]),
        _sender=admin,
        _valid=False,
        _exception="VAULT_NOT_ADMIN",
    )
    vault.set_managers(sp.set([user.address]), _sender=other)
    sc.verify(vault.is_manager(user.address))
    sc.verify(~vault.is_manager(manager.address))


@sp.add_test()
def test_manager_and_locker_rotation():
    """Manager set rotation and hard cap, emergency locker rotation and cap."""
    sc = sp.test_scenario("Rotation", MODULES)
    admin, manager, locker, user, other = make_accounts()
    vault = originate_vault(sc, admin, manager, locker)

    sc.h2("Manager cannot perform admin operations")
    vault.set_managers(
        sp.set([other.address]),
        _sender=manager,
        _valid=False,
        _exception="VAULT_NOT_ADMIN",
    )
    vault.set_emergency_lockers(
        sp.set([user.address]),
        _sender=manager,
        _valid=False,
        _exception="VAULT_NOT_ADMIN",
    )

    sc.h2("Admin grows the set: both managers pass the sender check")
    vault.set_managers(sp.set([manager.address, other.address]), _sender=admin)
    # empty batch error proves the sender got past the manager check
    vault.withdraw([], _sender=manager, _valid=False, _exception="VAULT_EMPTY_BATCH")
    vault.withdraw([], _sender=other, _valid=False, _exception="VAULT_EMPTY_BATCH")

    sc.h2("Admin rotates to `other` only; old manager is rejected")
    vault.set_managers(sp.set([other.address]), _sender=admin)
    vault.withdraw([], _sender=manager, _valid=False, _exception="VAULT_NOT_MANAGER")
    vault.withdraw([], _sender=other, _valid=False, _exception="VAULT_EMPTY_BATCH")

    sc.h2("Manager set cannot be empty")
    vault.set_managers(
        sp.set([]), _sender=admin, _valid=False, _exception="VAULT_NO_MANAGERS"
    )

    sc.h2("Manager set cannot exceed the hard cap of 10")
    too_many_managers = sp.set(
        [sp.test_account(f"manager_{i}").address for i in range(11)]
    )
    vault.set_managers(
        too_many_managers,
        _sender=admin,
        _valid=False,
        _exception="VAULT_TOO_MANY_MANAGERS",
    )

    sc.h2("A set of exactly 10 managers is accepted")
    ten_managers = sp.set([sp.test_account(f"manager_{i}").address for i in range(10)])
    vault.set_managers(ten_managers, _sender=admin)
    vault.withdraw(
        [],
        _sender=sp.test_account("manager_7"),
        _valid=False,
        _exception="VAULT_EMPTY_BATCH",
    )
    vault.set_managers(sp.set([other.address]), _sender=admin)

    sc.h2("Locker set cannot be empty")
    vault.set_emergency_lockers(
        sp.set([]), _sender=admin, _valid=False, _exception="VAULT_NO_LOCKERS"
    )

    sc.h2("Locker set cannot exceed the hard cap of 10")
    too_many = sp.set([sp.test_account(f"locker_{i}").address for i in range(11)])
    vault.set_emergency_lockers(
        too_many, _sender=admin, _valid=False, _exception="VAULT_TOO_MANY_LOCKERS"
    )

    sc.h2("Rotation: user replaces locker; old locker loses the lock right")
    vault.set_emergency_lockers(sp.set([user.address]), _sender=admin)
    vault.lock(_sender=locker, _valid=False, _exception="VAULT_NOT_ADMIN_OR_LOCKER")
    vault.lock(_sender=user)
    sc.verify(vault.data.locked)


@sp.add_test()
def test_set_limits_validation_and_effect():
    """Limits validated against immutable hard caps; new limits enforced."""
    sc = sp.test_scenario("SetLimits", MODULES)
    admin, manager, locker, _user, recipient = make_accounts()
    vault = originate_vault(sc, admin, manager, locker)
    fungible = originate_fungible(
        sc, {(vault.address, token_id): 10 for token_id in range(3)}
    )

    def limits(max_tokens=5, period_seconds=600, max_items_per_batch=3):
        return sp.record(
            max_tokens=max_tokens,
            period_seconds=period_seconds,
            max_items_per_batch=max_items_per_batch,
        )

    sc.h2("Limits outside the hard caps are rejected")
    for bad in (
        limits(max_tokens=0),
        limits(max_tokens=2_001),  # > HARD_MAX_TOKENS_PER_PERIOD
        limits(period_seconds=0),  # < MIN_PERIOD_SECONDS (1)
        limits(period_seconds=2_592_001),  # > HARD_MAX_PERIOD_SECONDS
        limits(max_items_per_batch=0),
        limits(max_items_per_batch=51),  # > HARD_MAX_ITEMS_PER_BATCH
    ):
        vault.set_limits(
            bad, _sender=admin, _valid=False, _exception="VAULT_BAD_LIMITS"
        )

    sc.h2("Limits exactly at the hard caps are accepted")
    vault.set_limits(
        limits(max_tokens=2_000, period_seconds=2_592_000, max_items_per_batch=50),
        _sender=admin,
    )
    sc.verify(vault.data.limits.max_tokens == 2_000)

    sc.h2("period_seconds=1 (escape hatch that ~disables the limiter) is valid")
    vault.set_limits(limits(period_seconds=1), _sender=admin)
    sc.verify(vault.data.limits.period_seconds == 1)

    sc.h2("Valid limits change is applied and enforced")
    vault.set_limits(limits(max_tokens=2), _sender=admin)
    sc.verify(vault.data.limits.max_tokens == 2)

    sc.h2("Withdrawing 3 distinct tokens now exceeds the new max of 2: auto-lock")
    vault.withdraw(
        [
            withdraw_item(fungible.address, 0, 1, recipient.address),
            withdraw_item(fungible.address, 1, 1, recipient.address),
            withdraw_item(fungible.address, 2, 1, recipient.address),
        ],
        _sender=manager,
        _now=T0,
    )
    sc.verify(vault.data.locked)
    sc.verify(~fungible.data.ledger.contains((recipient.address, 0)))


@sp.add_test()
def test_constructor_validation():
    """__init__ rejects out-of-cap initial storage at trace time, so no
    SmartPy-built origination can bypass the hard caps."""
    sc = sp.test_scenario("ConstructorValidation", MODULES)
    admin, manager, locker, _user, _recipient = make_accounts()

    def limits(max_tokens=5, period_seconds=600, max_items_per_batch=3):
        return sp.record(
            max_tokens=max_tokens,
            period_seconds=period_seconds,
            max_items_per_batch=max_items_per_batch,
        )

    def expect_rejected(what, **overrides):
        params = dict(
            admin=admin.address,
            managers=sp.set([manager.address]),
            emergency_lockers=sp.set([locker.address]),
            limits=DEFAULT_LIMITS,
            metadata=sp.big_map(),
        )
        params.update(overrides)
        try:
            # Instantiation alone runs the traced __init__ asserts; no
            # scenario add needed (or wanted) for the negative cases.
            vault_module.Vault(**params)
        except Exception:
            return
        raise RuntimeError(f"constructor accepted invalid {what}")

    many = sp.set([sp.test_account(f"acc_{i}").address for i in range(11)])
    expect_rejected("empty managers", managers=sp.set([]))
    expect_rejected("11 managers", managers=many)
    expect_rejected("empty lockers", emergency_lockers=sp.set([]))
    expect_rejected("11 lockers", emergency_lockers=many)
    expect_rejected("max_tokens=0", limits=limits(max_tokens=0))
    expect_rejected("max_tokens=2001", limits=limits(max_tokens=2_001))
    expect_rejected("period=0", limits=limits(period_seconds=0))
    expect_rejected("period=30d+1", limits=limits(period_seconds=2_592_001))
    expect_rejected("batch=0", limits=limits(max_items_per_batch=0))
    expect_rejected("batch=51", limits=limits(max_items_per_batch=51))

    sc.h2("Valid parameters at the cap boundaries are accepted")
    vault = vault_module.Vault(
        admin=admin.address,
        managers=sp.set([manager.address]),
        emergency_lockers=sp.set([locker.address]),
        limits=limits(
            max_tokens=2_000, period_seconds=2_592_000, max_items_per_batch=50
        ),
        metadata=sp.big_map(),
    )
    sc += vault
    sc.verify(vault.data.limits.max_tokens == 2_000)


@sp.add_test()
def test_sender_not_source():
    """The vault authorizes by SENDER (multisig-compatible), never SOURCE."""
    sc = sp.test_scenario("SenderNotSource", MODULES)
    _admin, manager, locker, user, other = make_accounts()
    proxy = mocks.AdminProxy()
    sc += proxy
    # the proxy contract *is* the admin, like a TzSafe would be
    vault = vault_module.Vault(
        admin=proxy.address,
        managers=sp.set([manager.address]),
        emergency_lockers=sp.set([locker.address]),
        limits=DEFAULT_LIMITS,
        metadata=sp.big_map(),
    )
    sc += vault

    sc.h2("Lock it first so there is something to unlock")
    vault.lock(_sender=locker)

    sc.h2("EOA -> proxy -> vault: SENDER is the proxy (admin), call passes")
    proxy.do_unlock(vault.address, _sender=user)  # user is SOURCE, not SENDER
    sc.verify(~vault.data.locked)

    sc.h2("The same EOA calling the vault directly is rejected")
    vault.lock(_sender=user, _valid=False, _exception="VAULT_NOT_ADMIN_OR_LOCKER")
    vault.unlock(_sender=user, _valid=False, _exception="VAULT_NOT_ADMIN")

    sc.h2("Admin operations work end to end through the proxy")
    proxy.do_set_managers(
        vault=vault.address, new_managers=sp.set([other.address]), _sender=user
    )
    sc.verify(vault.is_manager(other.address))
    sc.verify(~vault.is_manager(manager.address))
    proxy.do_set_limits(
        vault=vault.address,
        new_limits=sp.record(max_tokens=4, period_seconds=600, max_items_per_batch=2),
        _sender=user,
    )
    sc.verify(vault.data.limits.max_tokens == 4)

    sc.h2("Two-step admin rotation away from the proxy multisig")
    proxy.do_set_pending_admin(
        vault=vault.address, new_admin=user.address, _sender=user
    )
    vault.accept_admin(_sender=user)
    sc.verify(vault.data.admin == user.address)


@sp.add_test()
def test_failed_fa2_transfer_rolls_back():
    """A failing FA2 transfer reverts the whole withdrawal, incl. history."""
    sc = sp.test_scenario("Rollback", MODULES)
    admin, manager, locker, _user, recipient = make_accounts()
    vault = originate_vault(sc, admin, manager, locker)
    nft = originate_nft(sc, [vault.address, vault.address])
    rejecting = mocks.RejectingFA2()
    sc += rejecting

    sc.h2("Seed one successful withdrawal")
    vault.withdraw(
        [withdraw_item(nft.address, 0, 1, recipient.address)],
        _sender=manager,
        _now=T0,
    )
    sc.verify(sp.len(vault.data.withdrawal_history) == 1)

    sc.h2("A batch touching the rejecting FA2 fails as a whole")
    vault.withdraw(
        [
            withdraw_item(nft.address, 1, 1, recipient.address),
            withdraw_item(rejecting.address, 7, 1, recipient.address),
        ],
        _sender=manager,
        _now=T0_PLUS_10,
        _valid=False,
        _exception="FA2_TX_DENIED",
    )

    sc.h2("Everything rolled back")
    sc.verify(sp.len(vault.data.withdrawal_history) == 1)
    sc.verify(nft.data.ledger[1] == vault.address)  # token 1 still in vault

    sc.h2("A target with no FA2-compatible %transfer fails cleanly")
    # the vault itself exposes no `transfer` entrypoint
    vault.withdraw(
        [withdraw_item(vault.address, 0, 1, recipient.address)],
        _sender=manager,
        _now=T0_PLUS_10,
        _valid=False,
        _exception="VAULT_NO_FA2_TRANSFER",
    )
    sc.verify(sp.len(vault.data.withdrawal_history) == 1)  # rolled back too


@sp.add_test()
def test_onchain_views():
    """Views read through a real on-chain caller contract."""
    sc = sp.test_scenario("Views", MODULES)
    admin, manager, locker, user, recipient = make_accounts()
    vault = originate_vault(sc, admin, manager, locker)
    fungible = originate_fungible(sc, {(vault.address, 0): 5, (vault.address, 1): 5})
    viewer = mocks.ViewCaller()
    sc += viewer

    sc.h2("Fresh vault: full budget, unlocked")
    viewer.read_vault(vault.address, _now=T0)
    sc.verify(viewer.data.remaining == 5)
    sc.verify(viewer.data.recent == 0)
    sc.verify(~viewer.data.locked)

    sc.h2("After withdrawing 2 distinct tokens: 3 remaining inside the window")
    vault.withdraw(
        [
            withdraw_item(fungible.address, 0, 2, recipient.address),
            withdraw_item(fungible.address, 1, 1, recipient.address),
        ],
        _sender=manager,
        _now=T0,
    )
    viewer.read_vault(vault.address, _now=T0_PLUS_10)
    sc.verify(viewer.data.remaining == 3)
    sc.verify(viewer.data.recent == 2)

    sc.h2("Exact boundary: a record is already expired at timestamp + period")
    viewer.read_vault(vault.address, _now=T0_PLUS_599)
    sc.verify(viewer.data.recent == 2)  # one second before the boundary
    viewer.read_vault(vault.address, _now=T0_PLUS_600)
    sc.verify(viewer.data.recent == 0)  # expires > now is false exactly here
    sc.verify(viewer.data.remaining == 5)

    sc.h2("After the window expires the full budget is visible again")
    viewer.read_vault(vault.address, _now=T0_PLUS_601)
    sc.verify(viewer.data.remaining == 5)
    sc.verify(viewer.data.recent == 0)

    sc.h2("Locked flag is visible; direct scenario view checks")
    vault.lock(_sender=locker, _now=T0_PLUS_601)
    viewer.read_vault(vault.address, _now=T0_PLUS_601)
    sc.verify(viewer.data.locked)
    sc.verify(vault.is_emergency_locker(locker.address))
    sc.verify(~vault.is_emergency_locker(user.address))
    sc.verify(vault.get_admin() == admin.address)
    sc.verify(vault.is_manager(manager.address))
    sc.verify(~vault.is_manager(user.address))
    sc.verify(vault.get_limits() == DEFAULT_LIMITS)


@sp.add_test()
def test_rescue_fa1_2():
    """Admin-only FA1.2 recovery against the official TZIP-7 template."""
    sc = sp.test_scenario("RescueFa1_2", MODULES + [fa1_2_template.m])
    admin, manager, locker, user, recipient = make_accounts()
    vault = originate_vault(sc, admin, manager, locker)
    token = originate_fa1_2(sc, admin, {user.address: 100})
    nft = originate_nft(sc, [vault.address])

    sc.h2("Accidental FA1.2 deposit: plain transfer, vault not called")
    token.transfer(from_=user.address, to_=vault.address, value=40, _sender=user)
    sc.verify(token.data.ledger[vault.address].balance == 40)

    def rescue(value, token_addr=None):
        return sp.record(
            token=token.address if token_addr is None else token_addr,
            recipient=recipient.address,
            value=value,
        )

    sc.h2("Only the admin can rescue; input validation")
    for sender in (manager, locker, user):
        vault.rescue_fa1_2(
            rescue(40), _sender=sender, _valid=False, _exception="VAULT_NOT_ADMIN"
        )
    vault.rescue_fa1_2(
        rescue(40),
        _sender=admin,
        _amount=sp.mutez(1),
        _valid=False,
        _exception="VAULT_TEZ_REJECTED",
    )
    vault.rescue_fa1_2(
        rescue(0), _sender=admin, _valid=False, _exception="VAULT_ZERO_AMOUNT"
    )

    sc.h2("Rescue cannot target an FA2 contract (TZIP-12 type mismatch)")
    vault.rescue_fa1_2(
        rescue(1, token_addr=nft.address),
        _sender=admin,
        _valid=False,
        _exception="VAULT_NO_FA12_TRANSFER",
    )

    sc.h2("Rescuing more than the vault's balance fails in the token")
    vault.rescue_fa1_2(rescue(41), _sender=admin, _valid=False)
    sc.verify(token.data.ledger[vault.address].balance == 40)

    sc.h2("Rescue works while locked (lock protects the NFT path only)")
    vault.lock(_sender=locker)
    vault.rescue_fa1_2(rescue(15), _sender=admin)
    sc.verify(token.data.ledger[vault.address].balance == 25)
    sc.verify(token.data.ledger[recipient.address].balance == 15)
    sc.verify(vault.data.locked)

    sc.h2("Remaining balance rescued after unlock; NFT untouched")
    vault.unlock(_sender=admin)
    vault.rescue_fa1_2(rescue(25), _sender=admin)
    sc.verify(token.data.ledger[vault.address].balance == 0)
    sc.verify(token.data.ledger[recipient.address].balance == 40)
    sc.verify(nft.data.ledger[0] == vault.address)


@sp.add_test()
def test_execute():
    """Admin-only arbitrary lambda (rescue hatch): role matrix, tez
    rejection, works while locked, ignores the rate limiter, executes as
    the vault (SENDER = vault in the inner FA2 call), failing lambda
    reverts the whole operation."""
    sc = sp.test_scenario("Execute", MODULES)
    admin, manager, locker, user, recipient = make_accounts()
    vault = originate_vault(sc, admin, manager, locker)
    nft = originate_nft(sc, [vault.address, vault.address])

    rescue = mocks.rescue_fa2.apply(
        sp.record(
            fa2=nft.address,
            vault=vault.address,
            token_id=0,
            recipient=recipient.address,
        )
    )

    sc.h2("Only the admin can execute (manager, locker, user rejected)")
    for sender in (manager, locker, user):
        vault.execute(
            rescue, _sender=sender, _valid=False, _exception="VAULT_NOT_ADMIN"
        )

    sc.h2("Attached tez is rejected")
    vault.execute(
        rescue,
        _sender=admin,
        _amount=sp.mutez(1),
        _valid=False,
        _exception="VAULT_TEZ_REJECTED",
    )

    sc.h2("Nothing moved so far")
    sc.verify(nft.data.ledger[0] == vault.address)

    sc.h2("Works while locked: the lambda transfers the NFT out as the vault")
    vault.lock(_sender=locker)
    vault.execute(rescue, _sender=admin, _now=T0)
    sc.verify(nft.data.ledger[0] == recipient.address)

    sc.h2("Execute neither unlocks nor consumes the rate-limit window")
    sc.verify(vault.data.locked)
    sc.verify(sp.len(vault.data.withdrawal_history) == 0)

    sc.h2("A failing lambda reverts the whole operation")
    bad = mocks.rescue_fa2.apply(
        sp.record(
            fa2=vault.address,  # the vault has no %transfer entrypoint
            vault=vault.address,
            token_id=1,
            recipient=recipient.address,
        )
    )
    vault.execute(bad, _sender=admin, _valid=False, _exception="LAMBDA_NO_FA2_TRANSFER")
    sc.verify(nft.data.ledger[1] == vault.address)


@sp.add_test()
def test_all_entrypoints_reject_tez():
    """check_no_tez_ runs before anything else in every entrypoint, so even
    otherwise-valid calls fail with VAULT_TEZ_REJECTED when tez is attached."""
    sc = sp.test_scenario("TezRejection", MODULES)
    admin, manager, locker, user, recipient = make_accounts()
    vault = originate_vault(sc, admin, manager, locker)
    tez = sp.mutez(1)
    kw = {"_amount": tez, "_valid": False, "_exception": "VAULT_TEZ_REJECTED"}

    vault.withdraw([], _sender=manager, **kw)
    vault.lock(_sender=locker, **kw)
    vault.unlock(_sender=admin, **kw)
    vault.set_pending_admin(user.address, _sender=admin, **kw)
    vault.accept_admin(_sender=user, **kw)
    vault.set_managers(sp.set([user.address]), _sender=admin, **kw)
    vault.set_emergency_lockers(sp.set([user.address]), _sender=admin, **kw)
    vault.set_limits(DEFAULT_LIMITS, _sender=admin, **kw)
    vault.rescue_fa1_2(
        sp.record(token=user.address, recipient=recipient.address, value=1),
        _sender=admin,
        **kw,
    )
    vault.execute(
        mocks.rescue_fa2.apply(
            sp.record(
                fa2=user.address,
                vault=vault.address,
                token_id=0,
                recipient=recipient.address,
            )
        ),
        _sender=admin,
        **kw,
    )


@sp.add_test()
def test_limits_changes_with_active_history():
    """set_limits vs. existing history: lowering max_tokens below current
    usage, raising period_seconds (conservative resurrection of stored
    records), and the period=1 escape hatch."""
    sc = sp.test_scenario("LimitsVsHistory", MODULES)
    admin, manager, locker, _user, recipient = make_accounts()
    vault = originate_vault(sc, admin, manager, locker)  # 5 / 600s / batch 3
    fungible = originate_fungible(
        sc, {(vault.address, token_id): 100 for token_id in range(6)}
    )
    viewer = mocks.ViewCaller()
    sc += viewer

    def limits(max_tokens=5, period_seconds=600, max_items_per_batch=3):
        return sp.record(
            max_tokens=max_tokens,
            period_seconds=period_seconds,
            max_items_per_batch=max_items_per_batch,
        )

    sc.h2("Withdraw 3 distinct tokens, then lower max_tokens to 2")
    vault.withdraw(
        [
            withdraw_item(fungible.address, 0, 1, recipient.address),
            withdraw_item(fungible.address, 1, 1, recipient.address),
            withdraw_item(fungible.address, 2, 1, recipient.address),
        ],
        _sender=manager,
        _now=T0,
    )
    vault.set_limits(limits(max_tokens=2), _sender=admin, _now=T0_PLUS_10)
    viewer.read_vault(vault.address, _now=T0_PLUS_10)
    sc.verify(viewer.data.recent == 3)  # active history above the new max
    sc.verify(viewer.data.remaining == 0)

    sc.h2("Any further withdrawal auto-locks")
    vault.withdraw(
        [withdraw_item(fungible.address, 3, 1, recipient.address)],
        _sender=manager,
        _now=T0_PLUS_10,
    )
    sc.verify(vault.data.locked)
    vault.unlock(_sender=admin, _now=T0_PLUS_10)

    sc.h2("Raising period_seconds resurrects stored records (conservative)")
    # The T0 record would be expired under the old 600s period at T0+601,
    # but nothing pruned it; the longer period re-activates it. This only
    # ever *shrinks* the available budget, never grows it — fail-safe.
    vault.set_limits(limits(period_seconds=2_000), _sender=admin, _now=T0_PLUS_601)
    viewer.read_vault(vault.address, _now=T0_PLUS_601)
    sc.verify(viewer.data.recent == 3)
    sc.verify(viewer.data.remaining == 2)

    sc.h2("period_seconds=1 escape hatch expires all history immediately")
    vault.set_limits(limits(period_seconds=1), _sender=admin, _now=T0_PLUS_601)
    sc.verify(sp.len(vault.data.withdrawal_history) == 0)
    viewer.read_vault(vault.address, _now=T0_PLUS_601)
    sc.verify(viewer.data.remaining == 5)
    vault.withdraw(
        [
            withdraw_item(fungible.address, 3, 1, recipient.address),
            withdraw_item(fungible.address, 4, 1, recipient.address),
            withdraw_item(fungible.address, 5, 1, recipient.address),
        ],
        _sender=manager,
        _now=T0_PLUS_601,
    )
    sc.verify(~vault.data.locked)
    sc.verify(fungible.data.ledger[(recipient.address, 5)] == 1)


@sp.add_test()
def test_fa2_grouping_preserves_order():
    """Interleaved batch items are grouped into exactly one transfer call per
    FA2 contract, preserving per-collection item order."""
    sc = sp.test_scenario("Grouping", MODULES)
    admin, manager, locker, user, recipient = make_accounts()
    vault = vault_module.Vault(
        admin=admin.address,
        managers=sp.set([manager.address]),
        emergency_lockers=sp.set([locker.address]),
        limits=sp.record(max_tokens=10, period_seconds=600, max_items_per_batch=10),
        metadata=sp.big_map(),
    )
    sc += vault
    rec_a = mocks.RecordingFA2()
    rec_b = mocks.RecordingFA2()
    sc += rec_a
    sc += rec_b

    vault.withdraw(
        [
            withdraw_item(rec_a.address, 0, 1, recipient.address),
            withdraw_item(rec_b.address, 5, 2, recipient.address),
            withdraw_item(rec_a.address, 1, 1, user.address),
            withdraw_item(rec_b.address, 7, 1, recipient.address),
            withdraw_item(rec_a.address, 2, 3, recipient.address),
        ],
        _sender=manager,
        _now=T0,
    )

    sc.h2("Exactly one transfer call per collection")
    sc.verify(rec_a.data.calls == 1)
    sc.verify(rec_b.data.calls == 1)

    sc.h2("Per-collection order and payloads match the batch")
    sc.verify(rec_a.data.seq == 3)
    sc.verify(rec_a.data.txs[0].token_id == 0)
    sc.verify(rec_a.data.txs[1].token_id == 1)
    sc.verify(rec_a.data.txs[1].to_ == user.address)
    sc.verify(rec_a.data.txs[2].token_id == 2)
    sc.verify(rec_a.data.txs[2].amount == 3)
    sc.verify(rec_b.data.seq == 2)
    sc.verify(rec_b.data.txs[0].token_id == 5)
    sc.verify(rec_b.data.txs[0].amount == 2)
    sc.verify(rec_b.data.txs[1].token_id == 7)
