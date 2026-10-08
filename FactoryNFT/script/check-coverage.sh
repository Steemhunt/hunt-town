#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
: "${MAINNET_RPC_URL:?Set MAINNET_RPC_URL to an Ethereum archive RPC endpoint}"
: "${BASE_RPC_URL:?Set BASE_RPC_URL to a Base archive RPC endpoint}"
export MAINNET_FORK_BLOCK="${MAINNET_FORK_BLOCK:-26039501}"

if [[ -n "${FORGE_BIN:-}" ]]; then
    forge_bin="$FORGE_BIN"
elif [[ -x ./.tools/forge ]]; then
    forge_bin=./.tools/forge
else
    forge_bin=forge
fi

mkdir -p coverage
"$forge_bin" coverage \
    --exclude-tests \
    --no-match-coverage '^(lib|test)/' \
    --report summary \
    --report lcov \
    --report-file coverage/lcov.info \
    | tee coverage/summary.txt

# Require every authored contract and deployment script to reach 100% in all
# four metrics. Dependencies and test fixtures are outside the coverage scope.
awk -F '|' '
    BEGIN {
        required["src/FactoryNFT.sol"] = 1
        required["src/FactoryDonation.sol"] = 1
        required["src/BuildingMigrator.sol"] = 1
        required["src/MiniBuildingCollector.sol"] = 1
        required["src/periphery/FactoryZapRouter.sol"] = 1
        required["script/DeployFactory.s.sol"] = 1
        required["script/DeployFactoryDonation.s.sol"] = 1
        required["script/DeployBuildingMigrator.s.sol"] = 1
        required["script/DeployMiniBuildingCollector.s.sol"] = 1
    }
    /^\|[[:space:]]*(src\/|script\/)/ {
        path = $2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", path)
        seen[path] = 1
        for (metric = 3; metric <= 6; metric++) {
            split($metric, counts, /[()\/]/)
            if ($metric !~ /^[[:space:]]*100[.]00%/ || counts[2] != counts[3]) {
                print "Coverage below 100%:" $2 $metric > "/dev/stderr"
                failed = 1
            }
        }
    }
    END {
        for (path in required) {
            if (!(path in seen)) {
                print "Coverage report is missing:" path > "/dev/stderr"
                failed = 1
            }
        }
        exit failed
    }
' coverage/summary.txt
