"""Compile FA2 fixtures for the integration tests.

Usage:
    python integration/compile_fixtures.py --owner tz1... --out DIR

Writes:
    DIR/simple_fa2.tz + DIR/simple_fa2_storage.tz
        Minimal FA2 where `owner` holds token 0 (x1), token 1 (x1) and
        edition token 2 (x10).
    DIR/rejecting_fa2.tz + DIR/rejecting_fa2_storage.tz
        FA2 whose transfer always fails.
    DIR/simple_fa1_2.tz + DIR/simple_fa1_2_storage.tz
        Minimal FA1.2 (TZIP-7) token where `owner` holds 100 units.
"""

import argparse
import glob
import os
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--owner", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    out = os.path.abspath(args.out)

    # chdir before importing smartpy: the compiler backend writes scenario
    # output relative to the working directory it was started in.
    scenario_dir = tempfile.mkdtemp(prefix="fixtures_compile_")
    os.chdir(scenario_dir)

    import smartpy as sp  # noqa: E402

    from tests.mocks import mocks, t  # noqa: E402

    sc = sp.test_scenario("Fixtures", [t, mocks])
    owner = sp.address(args.owner)
    simple = mocks.SimpleFA2(
        ledger=sp.big_map(
            {
                (owner, 0): 1,
                (owner, 1): 1,
                (owner, 2): 10,
            }
        )
    )
    sc += simple
    rejecting = mocks.RejectingFA2()
    sc += rejecting
    fa1_2 = mocks.SimpleFA1_2(ledger=sp.big_map({owner: 100}))
    sc += fa1_2

    produced = os.path.join(scenario_dir, "Fixtures")

    def pick(pattern):
        matches = sorted(glob.glob(os.path.join(produced, pattern)))
        if not matches:
            raise SystemExit(f"no artifact matching {pattern} in {produced}")
        return matches[-1]

    os.makedirs(out, exist_ok=True)
    # contract 0 = SimpleFA2, 1 = RejectingFA2, 2 = SimpleFA1_2 (origination order)
    for pattern, name in {
        "step_*_cont_0_contract.tz": "simple_fa2.tz",
        "step_*_cont_0_storage.tz": "simple_fa2_storage.tz",
        "step_*_cont_1_contract.tz": "rejecting_fa2.tz",
        "step_*_cont_1_storage.tz": "rejecting_fa2_storage.tz",
        "step_*_cont_2_contract.tz": "simple_fa1_2.tz",
        "step_*_cont_2_storage.tz": "simple_fa1_2_storage.tz",
    }.items():
        shutil.copyfile(pick(pattern), os.path.join(out, name))
        print(f"wrote {os.path.join(out, name)}")

    shutil.rmtree(scenario_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
