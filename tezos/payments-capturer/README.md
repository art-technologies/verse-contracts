# Tezos Payments Capturer

## Toolchain (Docker)

The toolchain (Node 16 + completium-cli 0.4.74, the versions this contract was
originally deployed with) is baked into a Docker image. Build it once:

```
docker build -t payments-capturer-dev .
```

Start an interactive shell with the sources mounted and the completium config
(endpoint, imported accounts) persisted in a named volume:

```
docker run -it --rm \
  -v "$PWD:/contracts" \
  -v payments-capturer-completium:/root/.completium \
  payments-capturer-dev
```

## Compile

Inside the container shell:

```
completium-cli generate michelson ./PaymentsCapturer.arl
```

## Deploy

Inside the container shell (default endpoint is a testnet; for mainnet run
`completium-cli switch endpoint` and import a funded account first):

```
completium-cli deploy ./PaymentsCapturer.arl --parameters '{ "admin": "x", "treasury": "y", "refund_manager": "z" }'
```

## Notes

- Do not upgrade completium-cli: 1.0.x is broken for any contract with
  parameters (`i is not defined` — undeclared loop variable, fatal in strict
  mode ESM), and 0.4.x installed with a modern npm resolution is missing
  hoisted deps (`bn.js`, `glob`). The Dockerfile pins Node 16 and resolves the
  dependency tree as of 2023-03-01 (`npm --before`), matching the environment
  the contract was originally deployed from.
- If deploying to current mainnet fails in the deploy step (2023-era Taquito
  vs. a newer Tezos protocol), compile with `generate michelson` here and
  originate the emitted Michelson with a current `octez-client` instead.
