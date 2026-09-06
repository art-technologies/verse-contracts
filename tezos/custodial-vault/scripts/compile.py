"""Compile the vault to Michelson and produce initial storage.

Usage:
    python scripts/compile.py \
        [--admin ADDR] [--manager ADDR ...] [--locker ADDR ...] \
        [--max-tokens N] [--period-seconds N] [--max-items-per-batch N] \
        [--metadata-uri URI] [--out DIR]

Writes:
    build/vault.tz        contract code (independent of the addresses given)
    build/vault.json      contract code, JSON Michelson (for Taquito)
    build/storage.tz      initial storage for origination
    build/storage.json    initial storage, JSON Michelson

The contract *code* is identical whatever addresses/limits are passed; only
the storage output depends on them. The committed build/ uses placeholder
addresses — regenerate storage with production values before origination.
"""

import argparse
import glob
import os
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

PLACEHOLDER = "tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb"


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--admin", default=PLACEHOLDER)
    p.add_argument(
        "--manager",
        action="append",
        default=None,
        help="withdrawal manager address (repeatable)",
    )
    p.add_argument(
        "--locker",
        action="append",
        default=None,
        help="emergency locker address (repeatable)",
    )
    p.add_argument("--max-tokens", type=int, default=10)
    p.add_argument("--period-seconds", type=int, default=600)
    p.add_argument("--max-items-per-batch", type=int, default=10)
    p.add_argument(
        "--metadata-uri",
        default=None,
        help="TZIP-16 metadata URI stored under the empty key",
    )
    p.add_argument("--out", default=os.path.join(ROOT, "build"))
    return p.parse_args()


def validate(args, managers, lockers):
    """Mirror the contract's hard caps (check_limits_ / set_emergency_lockers /
    set_managers).

    Initial storage is written directly and never passes through the on-chain
    validation entrypoints, so a bad value here would deploy a vault with
    weaker-than-documented limits. Fail fast before compiling.
    """
    errors = []
    if not 0 < args.max_tokens <= 2_000:
        errors.append("--max-tokens must be in 1..2000 (HARD_MAX_TOKENS_PER_PERIOD)")
    if not 1 <= args.period_seconds <= 2_592_000:
        errors.append(
            "--period-seconds must be in 1..2592000 "
            "(MIN_PERIOD_SECONDS..HARD_MAX_PERIOD_SECONDS)"
        )
    if not 0 < args.max_items_per_batch <= 50:
        errors.append(
            "--max-items-per-batch must be in 1..50 (HARD_MAX_ITEMS_PER_BATCH)"
        )
    if not 0 < len(set(managers)) <= 10:
        errors.append("--manager count must be in 1..10 (HARD_MAX_MANAGERS)")
    if not 0 < len(set(lockers)) <= 10:
        errors.append("--locker count must be in 1..10 (HARD_MAX_EMERGENCY_LOCKERS)")
    if errors:
        raise SystemExit("invalid deployment parameters:\n  " + "\n  ".join(errors))


def main():
    args = parse_args()
    managers = args.manager or [PLACEHOLDER]
    lockers = args.locker or [PLACEHOLDER]
    validate(args, managers, lockers)
    args.out = os.path.abspath(args.out)

    # chdir before importing smartpy: the compiler backend writes scenario
    # output relative to the working directory it was started in.
    scenario_dir = tempfile.mkdtemp(prefix="vault_compile_")
    os.chdir(scenario_dir)

    import smartpy as sp  # noqa: E402

    from contracts.vault import t, vault_module  # noqa: E402

    metadata = {}
    if args.metadata_uri is not None:
        metadata[""] = sp.bytes("0x" + args.metadata_uri.encode().hex())

    sc = sp.test_scenario("VaultCompilation", [t, vault_module])
    vault = vault_module.Vault(
        admin=sp.address(args.admin),
        managers=sp.set([sp.address(a) for a in managers]),
        emergency_lockers=sp.set([sp.address(a) for a in lockers]),
        limits=sp.record(
            max_tokens=args.max_tokens,
            period_seconds=args.period_seconds,
            max_items_per_batch=args.max_items_per_batch,
        ),
        metadata=sp.big_map(metadata),
    )
    sc += vault

    produced = os.path.join(scenario_dir, "VaultCompilation")

    def pick(pattern):
        matches = sorted(glob.glob(os.path.join(produced, pattern)))
        if not matches:
            raise SystemExit(f"no artifact matching {pattern} in {produced}")
        return matches[-1]

    os.makedirs(args.out, exist_ok=True)
    targets = {
        "step_*_cont_0_contract.tz": "vault.tz",
        "step_*_cont_0_contract.json": "vault.json",
        "step_*_cont_0_storage.tz": "storage.tz",
        "step_*_cont_0_storage.json": "storage.json",
    }
    for pattern, name in targets.items():
        dst = os.path.join(args.out, name)
        shutil.copyfile(pick(pattern), dst)
        print(f"wrote {os.path.relpath(dst, ROOT)}")

    shutil.rmtree(scenario_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
