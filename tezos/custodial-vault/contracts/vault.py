"""Tezos Custodial FA2 Vault — v1 (SmartPy).

Withdrawal-control contract for FA2 / TZIP-12 tokens (NFTs, editions and
other FA2 assets alike — the vault does not distinguish token kinds).

Deposits are plain FA2 transfers to this contract's address and never call
this contract. This contract only controls the withdrawal path:
  - manager-only batched withdrawals (set of up to 10 manager addresses)
  - rolling-window rate limit with auto-lock instead of failure
  - emergency lock (lock-only role), admin-only unlock
  - two-step admin transfer
No deposit entrypoint, no allowlist/blocklist. Besides rotating
`managers` and draining via `withdraw`, the admin has two direct
asset-motion paths: `rescue_fa1_2` (recovers accidentally sent FA1.2
tokens; TZIP-7-typed, so it cannot call a standard TZIP-12 `transfer` —
the types do not match) and `execute` (arbitrary admin lambda, the
escape hatch for tokens the typed paths cannot move).
Rationale for `execute`: admin ownership is already effective root — a
compromised admin multisig can remove all managers and emergency
lockers, max the limits and drain the vault via `withdraw`; if the admin
is a batching contract or operation group, those config changes and
withdrawals can land in one operation. Therefore `execute` grants no
authority the admin does not already have. It does change observability:
the direct path emits `executed`, while the rotate-and-withdraw path
emits the relevant config/unlock/withdraw events, but monitoring must
treat both as same-operation admin-compromise asset-motion risks. The
multisig threshold is the actual boundary against admin compromise, with
or without `execute`.

Defense in depth: the on-chain rolling withdrawal limit with auto-lock is
assumed to be the most bulletproof and simplest layer of security — it is
deliberately dumb. Deployments are expected to ALSO run off-chain scanners
holding the emergency-locker role, implementing any richer policy (anomaly
detection, business rules, allowlists) and locking withdrawals remotely.
Those are additional layers on top of the on-chain limiter, never a
replacement for it.
"""

import smartpy as sp
from smartpy.templates import fa2_lib as fa2

# Canonical TZIP-12 types (tx / transfer_params) from the official FA2 library.
t = fa2.t


@sp.module
def vault_module():
    import t

    # ---------- Explicit types ----------

    withdraw_item: type = sp.record(
        fa2=sp.address,
        token_id=sp.nat,
        amount=sp.nat,
        recipient=sp.address,
    ).layout(("fa2", ("token_id", ("amount", "recipient"))))

    # `tokens` counts distinct (fa2, token_id) pairs in that withdrawal,
    # NOT FA2 amounts: 1000 editions of one token = 1.
    withdrawal_record: type = sp.record(
        timestamp=sp.timestamp,
        tokens=sp.nat,
    ).layout(("timestamp", "tokens"))

    limits_type: type = sp.record(
        max_tokens=sp.nat,
        period_seconds=sp.nat,
        max_items_per_batch=sp.nat,
    ).layout(("max_tokens", ("period_seconds", "max_items_per_batch")))

    # TZIP-7 transfer parameter (annotations %from, %to, %value).
    fa1_2_transfer_type: type = sp.record(
        from_=sp.address,
        to_=sp.address,
        value=sp.nat,
    ).layout(("from_ as from", ("to_ as to", "value")))

    # Arbitrary admin lambda; with_operations lambdas emit their operations
    # directly when called.
    execute_lambda_type: type = sp.lambda_(sp.unit, sp.unit, with_operations=True)

    rescue_params: type = sp.record(
        token=sp.address,
        recipient=sp.address,
        value=sp.nat,
    ).layout(("token", ("recipient", "value")))

    storage_type: type = sp.record(
        admin=sp.address,
        pending_admin=sp.option[sp.address],
        managers=sp.set[sp.address],
        emergency_lockers=sp.set[sp.address],
        locked=sp.bool,
        limits=limits_type,
        withdrawal_history=sp.list[withdrawal_record],
        metadata=sp.big_map[sp.string, sp.bytes],
    )

    class Vault(sp.Contract):
        """Custodial FA2 vault: manager-only rate-limited withdrawals.

        Immutable hard caps (compiled in, not admin-changeable):
          HARD_MAX_ITEMS_PER_BATCH    = 50 items
          MIN_PERIOD_SECONDS          = 1 second (a ~1s window practically
              disables the limiter — deliberate admin escape hatch)
          HARD_MAX_PERIOD_SECONDS     = 2_592_000 seconds (30 days)
          HARD_MAX_TOKENS_PER_PERIOD  = 2_000 distinct tokens
          HARD_MAX_EMERGENCY_LOCKERS  = 10 addresses
          HARD_MAX_MANAGERS           = 10 addresses
        Literals live in check_limits_, set_emergency_lockers, set_managers
        and (mirrored, because initial storage bypasses the setters) in
        __init__ and the withdraw config guard.
        """

        def __init__(self, admin, managers, emergency_lockers, limits, metadata):
            # Enforced by SmartPy at trace time: initial storage is written
            # at origination without passing through the setters, so bad
            # values must be rejected before any storage is produced.
            assert sp.len(managers) > 0, "VAULT_NO_MANAGERS"
            assert sp.len(managers) <= 10, "VAULT_TOO_MANY_MANAGERS"
            assert sp.len(emergency_lockers) > 0, "VAULT_NO_LOCKERS"
            assert sp.len(emergency_lockers) <= 10, "VAULT_TOO_MANY_LOCKERS"
            assert limits.max_tokens > 0, "VAULT_BAD_LIMITS"
            assert limits.max_tokens <= 2_000, "VAULT_BAD_LIMITS"
            assert limits.period_seconds >= 1, "VAULT_BAD_LIMITS"
            assert limits.period_seconds <= 2_592_000, "VAULT_BAD_LIMITS"
            assert limits.max_items_per_batch > 0, "VAULT_BAD_LIMITS"
            assert limits.max_items_per_batch <= 50, "VAULT_BAD_LIMITS"
            self.data.admin = sp.cast(admin, sp.address)
            self.data.pending_admin = sp.cast(None, sp.option[sp.address])
            self.data.managers = sp.cast(managers, sp.set[sp.address])
            self.data.emergency_lockers = sp.cast(emergency_lockers, sp.set[sp.address])
            self.data.locked = sp.cast(False, sp.bool)
            self.data.limits = sp.cast(limits, limits_type)
            self.data.withdrawal_history = sp.cast([], sp.list[withdrawal_record])
            self.data.metadata = sp.cast(metadata, sp.big_map[sp.string, sp.bytes])
            sp.cast(self.data, storage_type)

        # ---------- Private helpers ----------

        @sp.private(with_storage="read-only")
        def check_no_tez_(self):
            """Every entrypoint rejects attached tez."""
            assert sp.amount == sp.mutez(0), "VAULT_TEZ_REJECTED"

        @sp.private(with_storage="read-only")
        def check_is_admin_(self):
            """Role check: SENDER must be the admin (e.g. the TzSafe multisig)."""
            assert sp.sender == self.data.admin, "VAULT_NOT_ADMIN"

        @sp.private(with_storage="read-only")
        def check_limits_(self, limits):
            """Validate limits against the immutable hard caps.

            HARD_MAX_TOKENS_PER_PERIOD also bounds withdrawal_history: every
            active record holds tokens >= 1 and records only enter while the
            active total is within the max_tokens in force at the time.
            Lowering max_tokens keeps still-active records, so the list can
            temporarily exceed the *current* max_tokens — the guaranteed
            bound (scanned on every withdraw, unlock and set_limits) is the
            hard cap, not the configured value.
            """
            sp.cast(limits, limits_type)
            assert limits.max_tokens > 0, "VAULT_BAD_LIMITS"
            assert limits.max_tokens <= 2_000, (
                "VAULT_BAD_LIMITS"
            )  # HARD_MAX_TOKENS_PER_PERIOD
            assert limits.period_seconds >= 1, (
                "VAULT_BAD_LIMITS"
            )  # MIN_PERIOD_SECONDS: ~1s window ≈ limiter off (escape hatch)
            assert limits.period_seconds <= 2_592_000, (
                "VAULT_BAD_LIMITS"
            )  # HARD_MAX_PERIOD_SECONDS (30 days)
            assert limits.max_items_per_batch > 0, "VAULT_BAD_LIMITS"
            assert limits.max_items_per_batch <= 50, (
                "VAULT_BAD_LIMITS"
            )  # HARD_MAX_ITEMS_PER_BATCH

        @sp.private(with_storage="read-only")
        def active_history_(self):
            """Rolling window: drop expired records, sum the active ones.

            `used` is the budget consumed in the current window (sum of
            distinct-token counts of the active records). `recent` is the
            surviving records only — every caller must write it back to
            self.data.withdrawal_history, which is how expired records get
            pruned (Michelson lists are rebuilt, not modified in place).
            Note `recent` i s in reverse storage order (sp.cons prepends);
            harmless, as nothing depends on history order.
            """
            recent = sp.cast([], sp.list[withdrawal_record])
            used = sp.nat(0)
            for record in self.data.withdrawal_history:
                expires = sp.add_seconds(
                    record.timestamp, sp.to_int(self.data.limits.period_seconds)
                )
                if expires > sp.now:
                    recent = sp.cons(record, recent)
                    used += record.tokens
            return sp.record(recent=recent, used=used)

        @sp.private(with_operations=True)
        def send_fa2_transfers_(self, batch):
            """FA2 transfer construction, all in one place.

            Groups the batch per FA2 contract (preserving item order) and
            emits exactly one TZIP-12 `transfer` call per collection, with
            the vault as `from_`.
            """
            sp.cast(batch, sp.list[withdraw_item])
            grouped = sp.cast({}, sp.map[sp.address, sp.list[t.tx]])
            for item in batch:
                tx = sp.record(
                    to_=item.recipient, token_id=item.token_id, amount=item.amount
                )
                grouped[item.fa2] = sp.cons(tx, grouped.get(item.fa2, default=[]))
            for group in grouped.items():
                # un-reverse to restore original per-collection order
                txs = sp.cast([], sp.list[t.tx])
                for tx in group.value:
                    txs = sp.cons(tx, txs)
                fa2_transfer = sp.contract(
                    t.transfer_params, group.key, entrypoint="transfer"
                ).unwrap_some(error="VAULT_NO_FA2_TRANSFER")
                sp.transfer(
                    [sp.record(from_=sp.self_address, txs=txs)],
                    sp.mutez(0),
                    fa2_transfer,
                )

        # ---------- Entrypoints ----------

        @sp.entrypoint
        def withdraw(self, batch):
            """Manager-only batched FA2 withdrawal.

            The rate limiter counts *distinct tokens* — unique
            (fa2, token_id) pairs in the batch — not FA2 amounts, so
            withdrawing 1000 editions of one token costs 1 unit of the
            window budget. Duplicates within a batch count once; the same
            token withdrawn again in a later withdrawal inside the window
            counts again (per-withdrawal dedup keeps storage bounded).

            An over-limit request must NOT fail: a failure would revert the
            lock state, so instead the contract auto-locks and transfers
            nothing.
            """
            sp.cast(batch, sp.list[withdraw_item])
            self.check_no_tez_()
            # Fail-closed config guard: __init__ validates SmartPy-built
            # storage, but origination accepts hand-crafted Michelson storage
            # that bypasses it. Out-of-cap storage must not be withdrawable
            # from. Repair caveat: out-of-cap *values* are repairable on-chain
            # (set_limits/set_managers), but a vault originated with huge
            # *structures* (managers/lockers/history) may exceed gas on any
            # call — the setters pack the old sets for event hashes, unlock/
            # set_limits iterate the history, and the whole storage is
            # (de)serialized on every call since none of it is a big_map.
            # Such a vault must be ABANDONED, not repaired: it holds nothing
            # at origination and deposits are attributed off-chain, so never
            # attribute deposits to a vault whose initial storage was not
            # produced by the audited pipeline (scripts/compile.py).
            self.check_limits_(self.data.limits)
            assert sp.len(self.data.managers) <= 10, "VAULT_TOO_MANY_MANAGERS"
            assert sp.sender in self.data.managers, "VAULT_NOT_MANAGER"
            assert not self.data.locked, "VAULT_LOCKED"

            item_count = sp.nat(0)
            seen = sp.cast({}, sp.map[sp.pair[sp.address, sp.nat], sp.unit])
            for item in batch:
                assert item.amount > 0, "VAULT_ZERO_AMOUNT"
                item_count += 1
                seen[(item.fa2, item.token_id)] = ()
            assert item_count > 0, "VAULT_EMPTY_BATCH"
            assert item_count <= self.data.limits.max_items_per_batch, (
                "VAULT_BATCH_TOO_LARGE"
            )
            requested = sp.len(seen)

            window = self.active_history_()
            if window.used + requested > self.data.limits.max_tokens:
                # Auto-lock path: succeed with no transfers so the lock persists.
                # Deliberate consequence: any manager can trigger this lock at
                # will by submitting an over-limit batch. That is intentional
                # and accepted — fail-safe beats availability here, and a
                # manager who wants to grief could already burn the window's
                # budget with real withdrawals. Admin unlock is the remedy.
                self.data.locked = True
                self.data.withdrawal_history = window.recent
                sp.emit(
                    sp.record(
                        used_in_window=window.used,
                        requested=requested,
                        max_tokens=self.data.limits.max_tokens,
                        period_seconds=self.data.limits.period_seconds,
                    ),
                    tag="auto_locked",
                )
            else:
                self.data.withdrawal_history = sp.cons(
                    sp.record(timestamp=sp.now, tokens=requested), window.recent
                )
                self.send_fa2_transfers_(batch)
                sp.emit(
                    sp.record(
                        manager=sp.sender,
                        item_count=item_count,
                        distinct_tokens=requested,
                    ),
                    tag="withdraw",
                )

        @sp.entrypoint
        def lock(self):
            """Pause withdrawals. Callable by admin or any emergency locker.

            Idempotent: locking while already locked succeeds, so emergency
            responders never see a failure.
            """
            self.check_no_tez_()
            is_admin = sp.sender == self.data.admin
            is_emergency_locker = sp.sender in self.data.emergency_lockers
            assert is_admin or is_emergency_locker, "VAULT_NOT_ADMIN_OR_LOCKER"
            self.data.locked = True
            sp.emit(sp.record(by=sp.sender), tag="locked")

        @sp.entrypoint
        def unlock(self):
            """Resume withdrawals. Admin only.

            Prunes only expired rate-limit records; still-active records are
            kept so unlocking cannot bypass the limit.
            """
            self.check_no_tez_()
            self.check_is_admin_()
            assert self.data.locked, "VAULT_NOT_LOCKED"
            self.data.locked = False
            window = self.active_history_()
            self.data.withdrawal_history = window.recent
            sp.emit(sp.record(by=sp.sender), tag="unlocked")

        @sp.entrypoint
        def set_pending_admin(self, new_admin):
            """Step 1 of two-step admin transfer. Admin only."""
            sp.cast(new_admin, sp.address)
            self.check_no_tez_()
            self.check_is_admin_()
            sp.emit(
                sp.record(
                    old_pending_admin=self.data.pending_admin,
                    new_pending_admin=new_admin,
                ),
                tag="pending_admin_set",
            )
            self.data.pending_admin = sp.Some(new_admin)

        @sp.entrypoint
        def accept_admin(self):
            """Step 2 of two-step admin transfer. Pending admin only."""
            self.check_no_tez_()
            pending = self.data.pending_admin.unwrap_some(
                error="VAULT_NO_PENDING_ADMIN"
            )
            assert sp.sender == pending, "VAULT_NOT_PENDING_ADMIN"
            sp.emit(
                sp.record(old_admin=self.data.admin, new_admin=sp.sender),
                tag="admin_accepted",
            )
            self.data.admin = sp.sender
            self.data.pending_admin = None

        @sp.entrypoint
        def set_managers(self, managers):
            """Replace the withdrawal manager set. Admin only."""
            sp.cast(managers, sp.set[sp.address])
            self.check_no_tez_()
            self.check_is_admin_()
            assert sp.len(managers) > 0, "VAULT_NO_MANAGERS"
            assert sp.len(managers) <= 10, (
                "VAULT_TOO_MANY_MANAGERS"
            )  # HARD_MAX_MANAGERS
            sp.emit(
                sp.record(
                    old_hash=sp.blake2b(sp.pack(self.data.managers)),
                    new_hash=sp.blake2b(sp.pack(managers)),
                ),
                tag="managers_changed",
            )
            self.data.managers = managers

        @sp.entrypoint
        def set_emergency_lockers(self, lockers):
            """Replace the lock-only emergency addresses. Admin only."""
            sp.cast(lockers, sp.set[sp.address])
            self.check_no_tez_()
            self.check_is_admin_()
            assert sp.len(lockers) > 0, "VAULT_NO_LOCKERS"
            assert sp.len(lockers) <= 10, (
                "VAULT_TOO_MANY_LOCKERS"
            )  # HARD_MAX_EMERGENCY_LOCKERS
            sp.emit(
                sp.record(
                    old_hash=sp.blake2b(sp.pack(self.data.emergency_lockers)),
                    new_hash=sp.blake2b(sp.pack(lockers)),
                ),
                tag="emergency_lockers_changed",
            )
            self.data.emergency_lockers = lockers

        @sp.entrypoint
        def set_limits(self, new_limits):
            """Change withdrawal rate limits within immutable hard caps. Admin only."""
            sp.cast(new_limits, limits_type)
            self.check_no_tez_()
            self.check_is_admin_()
            self.check_limits_(new_limits)
            sp.emit(
                sp.record(old_limits=self.data.limits, new_limits=new_limits),
                tag="limits_changed",
            )
            self.data.limits = new_limits
            window = self.active_history_()
            self.data.withdrawal_history = window.recent

        @sp.entrypoint
        def rescue_fa1_2(self, params):
            """Recover FA1.2 tokens accidentally sent to the vault. Admin only.

            The parameter is TZIP-7-typed, so this cannot call a *standard*
            TZIP-12 `transfer` entrypoint (the types do not match and
            sp.contract resolution fails). A non-standard contract exposing
            an FA1.2-shaped `%transfer` could still be called — this guard
            is a type-mismatch argument, not a universal proof. Deliberately
            ignores the lock and the rate limiter — both protect the FA2
            withdrawal path, and FA1.2 balances are never
            marketplace-credited.
            """
            sp.cast(params, rescue_params)
            self.check_no_tez_()
            self.check_is_admin_()
            assert params.value > 0, "VAULT_ZERO_AMOUNT"
            fa1_2_transfer = sp.contract(
                fa1_2_transfer_type, params.token, entrypoint="transfer"
            ).unwrap_some(error="VAULT_NO_FA12_TRANSFER")
            sp.transfer(
                sp.record(
                    from_=sp.self_address, to_=params.recipient, value=params.value
                ),
                sp.mutez(0),
                fa1_2_transfer,
            )
            sp.emit(
                sp.record(
                    token=params.token, recipient=params.recipient, value=params.value
                ),
                tag="fa1_2_rescued",
            )

        @sp.entrypoint
        def execute(self, lambda_):
            """Execute an arbitrary lambda as the vault. Admin only.

            Escape hatch for rescuing tokens the typed paths cannot move:
            broken or non-standard token contracts, standards other than
            FA2/FA1.2, misbehaving `transfer` entrypoints.

            Trust-model note: this grants the admin no authority it does
            not already have. A compromised admin multisig can remove all
            managers and emergency lockers, max out the limits and drain
            the vault via `withdraw`; if the admin is a batching contract
            or operation group, those config changes and withdrawals can
            land in one operation. Ownership is effective root either way,
            and the multisig threshold is the real boundary. What `execute`
            changes is observability: the direct path emits `executed`,
            while the rotate-and-withdraw path emits the relevant
            config/unlock/withdraw events, but monitoring must treat both
            as same-operation admin-compromise asset-motion risks.
            Deliberately ignores the lock and the rate limiter — it must
            work exactly when the normal paths don't.
            """
            sp.cast(lambda_, execute_lambda_type)
            self.check_no_tez_()
            self.check_is_admin_()
            sp.emit(
                sp.record(lambda_hash=sp.blake2b(sp.pack(lambda_))),
                tag="executed",
            )
            lambda_()

        # ---------- On-chain views ----------

        @sp.onchain_view()
        def get_admin(self):
            return self.data.admin

        @sp.onchain_view()
        def get_pending_admin(self):
            return self.data.pending_admin

        @sp.onchain_view()
        def is_manager(self, candidate):
            sp.cast(candidate, sp.address)
            return candidate in self.data.managers

        @sp.onchain_view()
        def is_emergency_locker(self, candidate):
            sp.cast(candidate, sp.address)
            return candidate in self.data.emergency_lockers

        @sp.onchain_view()
        def is_locked(self):
            return self.data.locked

        @sp.onchain_view()
        def get_limits(self):
            return self.data.limits

        @sp.onchain_view()
        def get_recent_withdrawn(self):
            """Distinct tokens withdrawn inside the current rolling window."""
            used = sp.nat(0)
            for record in self.data.withdrawal_history:
                expires = sp.add_seconds(
                    record.timestamp, sp.to_int(self.data.limits.period_seconds)
                )
                if expires > sp.now:
                    used += record.tokens
            return used

        @sp.onchain_view()
        def get_remaining_limit(self):
            """Distinct tokens still withdrawable inside the current window."""
            used = sp.nat(0)
            for record in self.data.withdrawal_history:
                expires = sp.add_seconds(
                    record.timestamp, sp.to_int(self.data.limits.period_seconds)
                )
                if expires > sp.now:
                    used += record.tokens
            if used >= self.data.limits.max_tokens:
                return sp.nat(0)
            else:
                return abs(self.data.limits.max_tokens - used)
