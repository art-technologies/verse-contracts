# Vendored: Limit Break Creator Token Standards

These files are copied **unmodified** from
[limitbreakinc/creator-token-standards](https://github.com/limitbreakinc/creator-token-standards)
at tag `v5.0.0` (commit `980a63b33591d568b6e04b45f37deba05a55f787`), under the MIT license in
`LICENSE`.

| File | Upstream path |
|---|---|
| `access/OwnablePermissions.sol` | `src/access/OwnablePermissions.sol` |
| `interfaces/ICreatorToken.sol` | `src/interfaces/ICreatorToken.sol` |
| `interfaces/ICreatorTokenLegacy.sol` | `src/interfaces/ICreatorTokenLegacy.sol` |
| `interfaces/ITransferValidator.sol` | `src/interfaces/ITransferValidator.sol` |
| `interfaces/ITransferValidatorSetTokenType.sol` | `src/interfaces/ITransferValidatorSetTokenType.sol` |
| `utils/CreatorTokenBase.sol` | `src/utils/CreatorTokenBase.sol` |
| `utils/TransferValidation.sol` | `src/utils/TransferValidation.sol` |

`utils/AutomaticValidatorTransferApproval.sol` is deliberately **not** vendored. LondonTokenC does not
auto-approve the transfer validator, because the collection owner chooses the validator; see
the project [README](../../../../README.md).

Why vendor instead of a submodule: upstream pins OpenZeppelin 4.x. Mixing its remappings with this
repo's OpenZeppelin 5.x would give two `Context` bases in one inheritance tree. The vendored files
import only `@openzeppelin/contracts/utils/Context.sol`, which has the same path and API in OZ 5.

The files keep their upstream formatting; `foundry.toml` excludes this directory from `forge fmt`,
and `slither.config.json` from analysis. Do not edit them. To upgrade, re-copy from a newer upstream
tag, update this table, and re-run the full test suite including the Ethereum fork tests.
