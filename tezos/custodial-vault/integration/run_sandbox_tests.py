"""Integration tests against a real Tezos protocol via octez-client mockup.

The mockup mode runs the actual protocol (application, gas, views, events)
locally with no node — the officially supported way to integration-test
contracts before Ghostnet. The same flows are expected to be re-run on
Ghostnet before mainnet (see integration/README.md).

Usage:
    python integration/run_sandbox_tests.py [--protocol HASH] [--keep]

Requires: octez-client on PATH, SmartPy (uv sync; see pyproject.toml).
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_PROTOCOL = "PsRiotumaAMotcRoDWW1bysEhQy2n1M5fy8JgRp8jjRfHGmfeA7"  # Rio

passed = 0


def ok(name):
    global passed
    passed += 1
    print(f"  ok {passed:2d} - {name}")


def check_eq(actual, expected, what):
    # Not `assert`: bare asserts are stripped under python -O / PYTHONOPTIMIZE.
    if actual != expected:
        raise SystemExit(f"CHECK FAILED: {what}: expected {expected!r}, got {actual!r}")


def check_in(haystack, needle, what):
    if needle not in haystack:
        raise SystemExit(f"CHECK FAILED: {what}: {needle!r} not in output:\n{haystack}")


class Client:
    def __init__(self, base_dir, protocol):
        self.base = ["octez-client", "--base-dir", base_dir, "--mode", "mockup"]
        self.protocol = protocol

    def run(self, *args, expect_failure=None):
        """Run octez-client. If expect_failure is a string, the command must
        fail and stderr/stdout must mention it."""
        result = subprocess.run(self.base + list(args), capture_output=True, text=True)
        output = result.stdout + result.stderr
        if expect_failure is None:
            if result.returncode != 0:
                raise SystemExit(f"command failed: {' '.join(args)}\n{output}")
            return result.stdout
        if result.returncode == 0:
            raise SystemExit(
                f"expected failure containing {expect_failure!r} but "
                f"command succeeded: {' '.join(args)}\n{output}"
            )
        if expect_failure not in output:
            raise SystemExit(
                f"expected failure containing {expect_failure!r}, got:\n{output}"
            )
        return output

    def create(self):
        subprocess.run(
            self.base + ["--protocol", self.protocol, "create", "mockup"],
            capture_output=True,
            text=True,
            check=True,
        )

    def address_of(self, alias):
        out = self.run("show", "address", alias)
        return re.search(r"Hash: (\S+)", out).group(1)

    def originate(self, name, code_file, storage_file, source):
        with open(storage_file) as fh:
            storage = fh.read().strip()
        out = self.run(
            "originate",
            "contract",
            name,
            "transferring",
            "0",
            "from",
            source,
            "running",
            code_file,
            "--init",
            storage,
            "--burn-cap",
            "10",
            "--force",
        )
        return re.search(r"New contract (KT1\S+) originated", out).group(1)

    def call(self, contract, entrypoint, arg, source, expect_failure=None):
        return self.run(
            "transfer",
            "0",
            "from",
            source,
            "to",
            contract,
            "--entrypoint",
            entrypoint,
            "--arg",
            arg,
            "--burn-cap",
            "10",
            expect_failure=expect_failure,
        )

    def view(self, view_name, contract, view_input="Unit"):
        out = self.run(
            "run",
            "view",
            view_name,
            "on",
            "contract",
            contract,
            "with",
            "input",
            view_input,
        )
        return out.strip().splitlines()[-1].strip()


def withdraw_arg(items):
    """Michelson for list<withdraw_item> (fa2, token_id, amount, recipient)."""
    parts = [
        f'Pair "{fa2}" (Pair {token_id} (Pair {amount} "{recipient}"))'
        for fa2, token_id, amount, recipient in items
    ]
    return "{ " + " ; ".join(parts) + " }"


def fa2_transfer_arg(from_addr, txs):
    """Michelson for a TZIP-12 transfer: [(to, token_id, amount)]."""
    inner = " ; ".join(
        f'Pair "{to}" (Pair {token_id} {amount})' for to, token_id, amount in txs
    )
    return f'{{ Pair "{from_addr}" {{ {inner} }} }}'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--protocol", default=DEFAULT_PROTOCOL)
    parser.add_argument(
        "--keep", action="store_true", help="keep the work directory for inspection"
    )
    args = parser.parse_args()

    if shutil.which("octez-client") is None:
        raise SystemExit("octez-client not found on PATH")

    work = tempfile.mkdtemp(prefix="vault_integration_")
    print(f"# work dir: {work}")
    client = Client(os.path.join(work, "mockup"), args.protocol)
    client.create()
    print(f"# mockup created on protocol {args.protocol}")

    admin = client.address_of("bootstrap1")
    manager = client.address_of("bootstrap2")
    locker = client.address_of("bootstrap3")
    new_admin = client.address_of("bootstrap4")
    recipient = client.address_of("bootstrap5")

    print("# compiling contracts (SmartPy)")
    subprocess.run(
        [
            sys.executable,
            os.path.join(ROOT, "scripts", "compile.py"),
            "--admin",
            admin,
            "--manager",
            manager,
            "--locker",
            locker,
            "--max-tokens",
            "5",
            "--period-seconds",
            "600",
            "--max-items-per-batch",
            "3",
            "--out",
            os.path.join(work, "build"),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    subprocess.run(
        [
            sys.executable,
            os.path.join(ROOT, "integration", "compile_fixtures.py"),
            "--owner",
            admin,
            "--out",
            os.path.join(work, "fixtures"),
        ],
        check=True,
        capture_output=True,
        text=True,
    )

    print("# originating contracts")
    vault = client.originate(
        "vault",
        os.path.join(work, "build", "vault.tz"),
        os.path.join(work, "build", "storage.tz"),
        "bootstrap1",
    )
    fa2 = client.originate(
        "simple_fa2",
        os.path.join(work, "fixtures", "simple_fa2.tz"),
        os.path.join(work, "fixtures", "simple_fa2_storage.tz"),
        "bootstrap1",
    )
    rejecting = client.originate(
        "rejecting_fa2",
        os.path.join(work, "fixtures", "rejecting_fa2.tz"),
        os.path.join(work, "fixtures", "rejecting_fa2_storage.tz"),
        "bootstrap1",
    )
    fa1_2 = client.originate(
        "simple_fa1_2",
        os.path.join(work, "fixtures", "simple_fa1_2.tz"),
        os.path.join(work, "fixtures", "simple_fa1_2_storage.tz"),
        "bootstrap1",
    )
    print(f"#   vault={vault} fa2={fa2} rejecting={rejecting} fa1_2={fa1_2}")

    def fa2_balance(owner, token_id):
        return client.view("get_balance", fa2, f'Pair "{owner}" {token_id}')

    # --- deposit is a plain FA2 transfer, no vault call -------------------
    client.call(
        fa2,
        "transfer",
        fa2_transfer_arg(admin, [(vault, 0, 1), (vault, 1, 1), (vault, 2, 6)]),
        "bootstrap1",
    )
    check_eq(fa2_balance(vault, 0), "1", "vault balance of token 0 after deposit")
    check_eq(fa2_balance(vault, 2), "6", "vault balance of token 2 after deposit")
    ok("deposit via direct FA2 transfer credits the vault in the FA2 ledger")

    # --- withdrawal happy path --------------------------------------------
    client.call(vault, "withdraw", withdraw_arg([(fa2, 0, 1, recipient)]), "bootstrap2")
    check_eq(fa2_balance(recipient, 0), "1", "recipient balance of token 0")
    check_eq(fa2_balance(vault, 0), "0", "vault balance of token 0 after withdraw")
    ok("manager withdraws a single NFT")

    client.call(
        vault,
        "withdraw",
        withdraw_arg([(fa2, 1, 1, recipient), (fa2, 2, 2, recipient)]),
        "bootstrap2",
    )
    check_eq(fa2_balance(recipient, 1), "1", "recipient balance of token 1")
    check_eq(fa2_balance(recipient, 2), "2", "recipient balance of token 2")
    ok("manager withdraws a batch incl. editions (amount > 1)")

    # 3 distinct tokens withdrawn so far; token 2's amount=2 counted once
    check_eq(client.view("get_recent_withdrawn", vault), "3", "get_recent_withdrawn")
    check_eq(client.view("get_remaining_limit", vault), "2", "get_remaining_limit")
    ok("views count distinct tokens, not amounts")

    # --- access control ----------------------------------------------------
    client.call(
        vault,
        "withdraw",
        withdraw_arg([(fa2, 2, 1, recipient)]),
        "bootstrap1",
        expect_failure="VAULT_NOT_MANAGER",
    )
    ok("non-manager (admin) cannot withdraw")

    client.call(
        vault, "unlock", "Unit", "bootstrap1", expect_failure="VAULT_NOT_LOCKED"
    )
    ok("unlock while not locked is rejected")

    # --- rollback on failing FA2 ------------------------------------------
    # 3 distinct tokens used, 2 remaining: a single-item batch passes the
    # rate limiter and reaches the rejecting FA2, whose failure reverts the
    # whole operation including the vault's history update.
    client.call(
        vault,
        "withdraw",
        withdraw_arg([(rejecting, 0, 1, recipient)]),
        "bootstrap2",
        expect_failure="FA2_TX_DENIED",
    )
    check_eq(
        client.view("get_recent_withdrawn", vault),
        "3",
        "get_recent_withdrawn unchanged after rollback",
    )
    check_eq(client.view("is_locked", vault), "False", "is_locked after rollback")
    ok("failing FA2 transfer rolls back the whole withdrawal")

    # --- rate limit auto-lock: succeeds, transfers nothing, locks ---------
    out = client.call(
        vault,
        "withdraw",
        withdraw_arg(
            [(fa2, 0, 1, recipient), (fa2, 1, 1, recipient), (fa2, 2, 1, recipient)]
        ),
        "bootstrap2",
    )  # over limit: 3 distinct used + 3 distinct > 5 — must NOT fail
    check_in(out, "auto_locked", "auto_locked event tag in receipt")
    check_eq(client.view("is_locked", vault), "True", "is_locked after auto-lock")
    check_eq(
        fa2_balance(recipient, 2),
        "2",
        "recipient balance of token 2 unchanged: no transfer happened",
    )
    ok("over-limit withdrawal succeeds with no transfers and auto-locks")

    client.call(
        vault,
        "withdraw",
        withdraw_arg([(fa2, 2, 1, recipient)]),
        "bootstrap2",
        expect_failure="VAULT_LOCKED",
    )
    ok("withdrawals fail while locked")

    client.call(vault, "unlock", "Unit", "bootstrap3", expect_failure="VAULT_NOT_ADMIN")
    ok("emergency locker cannot unlock")

    out = client.call(vault, "unlock", "Unit", "bootstrap1")
    check_in(out, "unlocked", "unlocked event tag in receipt")
    check_eq(client.view("is_locked", vault), "False", "is_locked after unlock")
    check_eq(
        client.view("get_recent_withdrawn", vault),
        "3",
        "active rate-limit window kept across unlock",
    )
    ok("admin unlock works and keeps the active rate-limit window")

    # --- emergency lock ----------------------------------------------------
    client.call(
        vault, "lock", "Unit", "bootstrap5", expect_failure="VAULT_NOT_ADMIN_OR_LOCKER"
    )
    ok("random account cannot lock")

    client.call(vault, "lock", "Unit", "bootstrap3")
    check_eq(client.view("is_locked", vault), "True", "is_locked after emergency lock")
    ok("emergency locker can lock")

    client.call(vault, "unlock", "Unit", "bootstrap1")
    ok("admin unlock after emergency lock")

    # --- FA1.2 rescue -------------------------------------------------------
    client.call(fa1_2, "transfer", f'Pair "{admin}" (Pair "{vault}" 40)', "bootstrap1")
    check_eq(
        client.view("get_balance", fa1_2, f'"{vault}"'),
        "40",
        "vault FA1.2 balance after accidental deposit",
    )
    ok("accidental FA1.2 deposit credits the vault in the token ledger")

    client.call(
        vault,
        "rescue_fa1_2",
        f'Pair "{fa1_2}" (Pair "{recipient}" 40)',
        "bootstrap2",
        expect_failure="VAULT_NOT_ADMIN",
    )
    ok("manager cannot rescue FA1.2")

    client.call(
        vault,
        "rescue_fa1_2",
        f'Pair "{fa2}" (Pair "{recipient}" 1)',
        "bootstrap1",
        expect_failure="VAULT_NO_FA12_TRANSFER",
    )
    ok("rescue cannot target an FA2 contract")

    client.call(
        vault, "rescue_fa1_2", f'Pair "{fa1_2}" (Pair "{recipient}" 40)', "bootstrap1"
    )
    check_eq(
        client.view("get_balance", fa1_2, f'"{recipient}"'),
        "40",
        "recipient FA1.2 balance after rescue",
    )
    check_eq(
        client.view("get_balance", fa1_2, f'"{vault}"'),
        "0",
        "vault FA1.2 balance after rescue",
    )
    ok("admin rescues FA1.2 tokens to a recipient")

    # --- fail-closed guard against hand-crafted invalid storage ------------
    # compile.py and the SmartPy constructor both validate, but octez-client
    # accepts any well-typed storage literal; the withdraw config guard is
    # the last line of defense.
    with open(os.path.join(work, "build", "storage.tz")) as fh:
        good_storage = fh.read()
    good_limits = "Pair 5 (Pair 600 3)"
    check_eq(good_storage.count(good_limits), 1, "limits literal in storage.tz")
    bad_path = os.path.join(work, "build", "storage_bad.tz")
    with open(bad_path, "w") as fh:
        # batch cap 999 > HARD_MAX_ITEMS_PER_BATCH (50)
        fh.write(good_storage.replace(good_limits, "Pair 5 (Pair 600 999)"))
    bad_vault = client.originate(
        "vault_bad", os.path.join(work, "build", "vault.tz"), bad_path, "bootstrap1"
    )
    client.call(
        bad_vault,
        "withdraw",
        withdraw_arg([(fa2, 0, 1, recipient)]),
        "bootstrap2",
        expect_failure="VAULT_BAD_LIMITS",
    )
    ok("out-of-cap hand-crafted storage cannot withdraw (fails closed)")

    out = client.call(bad_vault, "set_limits", "Pair 5 (Pair 600 3)", "bootstrap1")
    check_in(out, "limits_changed", "limits_changed event tag in receipt")
    client.call(
        bad_vault, "withdraw", "{}", "bootstrap2", expect_failure="VAULT_EMPTY_BATCH"
    )
    ok("admin repairs out-of-cap limit *values* on-chain; guard passes again")

    # --- hand-crafted oversized sets ----------------------------------------
    # All addresses are tz1, so lexicographic base58 order matches Michelson
    # set element order (same prefix + ascending base58 alphabet).
    extra = []
    for i in range(6):
        client.run("gen", "keys", f"extra_{i}")
        extra.append(client.address_of(f"extra_{i}"))
    eleven = sorted([admin, manager, locker, new_admin, recipient] + extra)
    eleven_literal = "{ " + " ; ".join(f'"{a}"' for a in eleven) + " }"

    manager_set = f'{{"{manager}"}}'  # SmartPy prints sets without spaces
    check_eq(good_storage.count(manager_set), 1, "manager set literal in storage.tz")
    bad_mgr_path = os.path.join(work, "build", "storage_bad_managers.tz")
    with open(bad_mgr_path, "w") as fh:
        fh.write(good_storage.replace(manager_set, eleven_literal))
    bad_mgr_vault = client.originate(
        "vault_bad_managers",
        os.path.join(work, "build", "vault.tz"),
        bad_mgr_path,
        "bootstrap1",
    )
    client.call(
        bad_mgr_vault,
        "withdraw",
        "{}",
        "bootstrap2",
        expect_failure="VAULT_TOO_MANY_MANAGERS",
    )
    ok("oversized hand-crafted manager set cannot withdraw (fails closed)")

    out = client.call(bad_mgr_vault, "set_managers", manager_set, "bootstrap1")
    check_in(out, "managers_changed", "managers_changed event tag in receipt")
    client.call(
        bad_mgr_vault,
        "withdraw",
        "{}",
        "bootstrap2",
        expect_failure="VAULT_EMPTY_BATCH",
    )
    ok("admin repairs the oversized manager set; guard passes again")

    # Lockers are deliberately NOT in the withdraw guard (no withdrawal
    # authority; see README "Malformed origination") — pin that decision.
    locker_set = f'{{"{locker}"}}'
    check_eq(good_storage.count(locker_set), 1, "locker set literal in storage.tz")
    bad_lkr_path = os.path.join(work, "build", "storage_bad_lockers.tz")
    with open(bad_lkr_path, "w") as fh:
        fh.write(good_storage.replace(locker_set, eleven_literal))
    bad_lkr_vault = client.originate(
        "vault_bad_lockers",
        os.path.join(work, "build", "vault.tz"),
        bad_lkr_path,
        "bootstrap1",
    )
    client.call(
        bad_lkr_vault,
        "withdraw",
        "{}",
        "bootstrap2",
        expect_failure="VAULT_EMPTY_BATCH",
    )
    ok("oversized locker set does not block withdraw (intentionally unguarded)")

    # --- two-step admin transfer -------------------------------------------
    client.call(vault, "set_pending_admin", f'"{new_admin}"', "bootstrap1")
    client.call(
        vault,
        "accept_admin",
        "Unit",
        "bootstrap5",
        expect_failure="VAULT_NOT_PENDING_ADMIN",
    )
    out = client.call(vault, "accept_admin", "Unit", "bootstrap4")
    check_in(out, "admin_accepted", "admin_accepted event tag in receipt")
    check_eq(
        client.view("get_admin", vault), f'"{new_admin}"', "get_admin after accept"
    )
    ok("two-step admin transfer")

    client.call(
        vault,
        "set_managers",
        f'{{ "{recipient}" }}',
        "bootstrap1",
        expect_failure="VAULT_NOT_ADMIN",
    )
    client.call(vault, "set_managers", f'{{ "{recipient}" }}', "bootstrap4")
    check_eq(
        client.view("is_manager", vault, f'"{recipient}"'),
        "True",
        "is_manager(new manager) after rotation",
    )
    check_eq(
        client.view("is_manager", vault, f'"{manager}"'),
        "False",
        "is_manager(old manager) after rotation",
    )
    ok("old admin lost rights; new admin rotates the manager set")
    ok("critical event tags appear in operation receipts")

    print(f"\nAll {passed} integration tests passed.")
    if args.keep:
        print(f"work dir kept: {work}")
    else:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
