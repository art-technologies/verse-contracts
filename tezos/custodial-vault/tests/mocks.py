"""Test-only contracts for the vault scenario tests.

- RecordingFA2: FA2 that records transfer calls and tx order (grouping tests).
- RejectingFA2: FA2 whose transfer always fails (rollback tests).
- SimpleFA1_2:  minimal TZIP-7 token (rescue_fa1_2 integration fixture).
- AdminProxy:   multisig stand-in that forwards calls to the vault, proving
                the vault authorizes by SENDER, not SOURCE.
- ViewCaller:   reads the vault's on-chain views through a real on-chain call.
- rescue_fa2:   effects lambda for the vault's `execute` entrypoint (moves
                one FA2 token out of the vault; apply() the args record).
"""

import smartpy as sp
from smartpy.templates import fa2_lib as fa2

t = fa2.t


@sp.module
def mocks():
    import t

    limits_type: type = sp.record(
        max_tokens=sp.nat,
        period_seconds=sp.nat,
        max_items_per_batch=sp.nat,
    ).layout(("max_tokens", ("period_seconds", "max_items_per_batch")))

    class SimpleFA2(sp.Contract):
        """Minimal FA2 mock: (owner, token_id) -> amount ledger, owner-only
        transfers (no operators), editions supported. Includes a get_balance
        view so integration tests can assert ownership on-chain."""

        def __init__(self, ledger):
            self.data.ledger = sp.cast(
                ledger, sp.big_map[sp.pair[sp.address, sp.nat], sp.nat]
            )

        @sp.entrypoint
        def transfer(self, batch):
            sp.cast(batch, t.transfer_params)
            for transfer in batch:
                assert transfer.from_ == sp.sender, "FA2_NOT_OPERATOR"
                for tx in transfer.txs:
                    from_key = (transfer.from_, tx.token_id)
                    from_balance = self.data.ledger.get(from_key, default=0)
                    assert from_balance >= tx.amount, "FA2_INSUFFICIENT_BALANCE"
                    self.data.ledger[from_key] = abs(from_balance - tx.amount)
                    to_key = (tx.to_, tx.token_id)
                    self.data.ledger[to_key] = (
                        self.data.ledger.get(to_key, default=0) + tx.amount
                    )

        @sp.entrypoint
        def noop(self):
            pass

        @sp.onchain_view()
        def get_balance(self, params):
            sp.cast(params, sp.pair[sp.address, sp.nat])
            return self.data.ledger.get(params, default=0)

    class SimpleFA1_2(sp.Contract):
        """Minimal TZIP-7 (FA1.2) token: owner-only transfers, no approvals.
        Includes a get_balance view so integration tests can assert
        ownership on-chain."""

        def __init__(self, ledger):
            self.data.ledger = sp.cast(ledger, sp.big_map[sp.address, sp.nat])

        @sp.entrypoint
        def transfer(self, param):
            sp.cast(
                param,
                sp.record(from_=sp.address, to_=sp.address, value=sp.nat).layout(
                    ("from_ as from", ("to_ as to", "value"))
                ),
            )
            assert param.from_ == sp.sender, "FA1.2_NotAllowed"
            from_balance = self.data.ledger.get(param.from_, default=0)
            assert from_balance >= param.value, "FA1.2_InsufficientBalance"
            self.data.ledger[param.from_] = abs(from_balance - param.value)
            self.data.ledger[param.to_] = (
                self.data.ledger.get(param.to_, default=0) + param.value
            )

        @sp.onchain_view()
        def get_balance(self, owner):
            sp.cast(owner, sp.address)
            return self.data.ledger.get(owner, default=0)

    class RecordingFA2(sp.Contract):
        """FA2 mock that records every transfer call and the tx order."""

        def __init__(self):
            self.data.calls = sp.nat(0)
            self.data.seq = sp.nat(0)
            self.data.txs = sp.cast({}, sp.map[sp.nat, t.tx])

        @sp.entrypoint
        def transfer(self, batch):
            sp.cast(batch, t.transfer_params)
            self.data.calls += 1
            for transfer in batch:
                for tx in transfer.txs:
                    self.data.txs[self.data.seq] = tx
                    self.data.seq += 1

    class RejectingFA2(sp.Contract):
        """FA2 mock whose transfer always fails."""

        @sp.entrypoint
        def transfer(self, batch):
            sp.cast(batch, t.transfer_params)
            raise "FA2_TX_DENIED"

        @sp.entrypoint
        def noop(self):
            pass

    class AdminProxy(sp.Contract):
        """Forwards admin calls to the vault (TzSafe stand-in)."""

        @sp.entrypoint
        def do_unlock(self, vault):
            sp.cast(vault, sp.address)
            target = sp.contract(sp.unit, vault, entrypoint="unlock").unwrap_some(
                error="PROXY_NO_ENTRYPOINT"
            )
            sp.transfer((), sp.mutez(0), target)

        @sp.entrypoint
        def do_lock(self, vault):
            sp.cast(vault, sp.address)
            target = sp.contract(sp.unit, vault, entrypoint="lock").unwrap_some(
                error="PROXY_NO_ENTRYPOINT"
            )
            sp.transfer((), sp.mutez(0), target)

        @sp.entrypoint
        def do_set_managers(self, vault, new_managers):
            sp.cast(vault, sp.address)
            sp.cast(new_managers, sp.set[sp.address])
            target = sp.contract(
                sp.set[sp.address], vault, entrypoint="set_managers"
            ).unwrap_some(error="PROXY_NO_ENTRYPOINT")
            sp.transfer(new_managers, sp.mutez(0), target)

        @sp.entrypoint
        def do_set_limits(self, vault, new_limits):
            sp.cast(vault, sp.address)
            sp.cast(new_limits, limits_type)
            target = sp.contract(
                limits_type, vault, entrypoint="set_limits"
            ).unwrap_some(error="PROXY_NO_ENTRYPOINT")
            sp.transfer(new_limits, sp.mutez(0), target)

        @sp.entrypoint
        def do_set_pending_admin(self, vault, new_admin):
            sp.cast(vault, sp.address)
            sp.cast(new_admin, sp.address)
            target = sp.contract(
                sp.address, vault, entrypoint="set_pending_admin"
            ).unwrap_some(error="PROXY_NO_ENTRYPOINT")
            sp.transfer(new_admin, sp.mutez(0), target)

        @sp.entrypoint
        def do_accept_admin(self, vault):
            sp.cast(vault, sp.address)
            target = sp.contract(sp.unit, vault, entrypoint="accept_admin").unwrap_some(
                error="PROXY_NO_ENTRYPOINT"
            )
            sp.transfer((), sp.mutez(0), target)

    @sp.effects(with_operations=True)
    def rescue_fa2(
        param: sp.pair[
            sp.record(
                fa2=sp.address,
                vault=sp.address,
                token_id=sp.nat,
                recipient=sp.address,
            ),
            sp.unit,
        ],
    ):
        args = sp.fst(param)
        target = sp.contract(
            t.transfer_params, args.fa2, entrypoint="transfer"
        ).unwrap_some(error="LAMBDA_NO_FA2_TRANSFER")
        sp.transfer(
            [
                sp.record(
                    from_=args.vault,
                    txs=[
                        sp.record(to_=args.recipient, token_id=args.token_id, amount=1)
                    ],
                )
            ],
            sp.mutez(0),
            target,
        )

    class ViewCaller(sp.Contract):
        """Stores the results of the vault's views for assertion in tests."""

        def __init__(self):
            self.data.remaining = sp.nat(999)
            self.data.recent = sp.nat(999)
            self.data.locked = sp.cast(True, sp.bool)

        @sp.entrypoint
        def read_vault(self, vault):
            sp.cast(vault, sp.address)
            self.data.remaining = sp.view(
                "get_remaining_limit", vault, (), sp.nat
            ).unwrap_some(error="NO_VIEW_REMAINING")
            self.data.recent = sp.view(
                "get_recent_withdrawn", vault, (), sp.nat
            ).unwrap_some(error="NO_VIEW_RECENT")
            self.data.locked = sp.view("is_locked", vault, (), sp.bool).unwrap_some(
                error="NO_VIEW_LOCKED"
            )
