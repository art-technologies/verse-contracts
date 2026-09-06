# Integration tests

`run_sandbox_tests.py` exercises the compiled Michelson against a **real Tezos
protocol** using `octez-client` mockup mode (protocol application, gas,
on-chain views, events — no node required). This is the recommended local
step between SmartPy scenario tests and Ghostnet.

```sh
# requires octez-client on PATH and SmartPy (uv sync)
make integration
# or directly:
python integration/run_sandbox_tests.py [--protocol HASH] [--keep]
```

The driver:

1. creates a fresh mockup chain (default protocol: Rio `PsRiotuma…`),
2. compiles the vault (admin/manager/locker = bootstrap1/2/3, `max_nfts=5`,
   `period_seconds=600`, `max_items_per_batch=3`) and the FA2 fixtures,
3. originates vault + mock FA2 + rejecting FA2,
4. runs 20 checks: deposit via plain FA2 transfer, single/batch/edition
   withdrawals, view outputs, role rejections, **over-limit auto-lock without
   failure**, locked-state behavior, unlock keeping the rate-limit window,
   emergency lock, whole-operation rollback on failing FA2, FA1.2 rescue
   (admin-only, cannot target FA2), two-step admin transfer and manager
   rotation.

## Ghostnet

Before mainnet, replay the same flow on Ghostnet (proposal §20.1):

```sh
octez-client --endpoint https://rpc.ghostnet.teztnets.com config update
# fund a key via https://faucet.ghostnet.teztnets.com, then:
python scripts/compile.py --admin <admin> --manager <manager> --locker <locker>
octez-client originate contract nft_vault transferring 0 from <key> \
  running build/vault.tz --init "$(cat build/storage.tz)" --burn-cap 2
```

Then repeat the driver's steps manually or adapt the driver (the
`octez-client` calls are identical; drop `--mode mockup`, add waiting for
inclusion). Run the emergency lock/unlock drill and the rate-limit auto-lock
drill with a low-value NFT before any production use.
