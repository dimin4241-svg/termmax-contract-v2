#!/usr/bin/env bash
set -euo pipefail

TARGET_COMMIT="e314f3f849577dfecd4614f148c4df81fdf8c72d"
CURRENT_COMMIT="$(git rev-parse main 2>/dev/null || git rev-parse HEAD~4 2>/dev/null || true)"

printf 'Target vulnerable commit: %s\n' "$TARGET_COMMIT"
printf 'Current base commit:      %s\n' "$CURRENT_COMMIT"

forge soldeer install

# Required by the reviewed revision on case-sensitive filesystems.
if [[ -f contracts/v2/factory/TermMaxPriceFeedFactoryV2.sol ]] && \
   [[ ! -f contracts/v2/factory/TermMaxPricefeedFactoryV2.sol ]]; then
  cp contracts/v2/factory/TermMaxPriceFeedFactoryV2.sol \
     contracts/v2/factory/TermMaxPricefeedFactoryV2.sol
fi

python3 audit/bad-debt-capture/verify_source_path.py | tee audit/bad-debt-capture/source-verification.log

forge test --isolate \
  --match-contract VaultBadDebtPostDefaultDepositPoC \
  --match-test test_PostDefaultDepositAtomicallyCapturesPreDefaultRecoveryCollateral \
  -vvv | tee audit/bad-debt-capture/foundry-poc.log
