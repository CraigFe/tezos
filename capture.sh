#!/bin/bash
set -euo pipefail

dune build @src/bin_node/install

BOOTSTRAPPED_STORE=~/data/tezos/stores/full_store_BLAktkWruUqXNgHAiR7kLh4dMP96mGmQANDGagdHAsTXfqgvfiR_933914/
SOURCE_BLOCK=BLAktkWruUqXNgHAiR7kLh4dMP96mGmQANDGagdHAsTXfqgvfiR
SNAPSHOT_FILE=~/data/tezos/snapshots/full_10

rm -rf "$SNAPSHOT_FILE"
rm -rf /tmp/time-out

# Timed

/usr/bin/time --format='%S,%M,%x' \
	-- _build/install/default/bin/tezos-node snapshot export \
	--data-dir "$BOOTSTRAPPED_STORE" --block=$SOURCE_BLOCK "$SNAPSHOT_FILE"

# Perf

# perf record --call-graph dwarf -g -- _build/install/default/bin/tezos-node snapshot export \
#     --data-dir "$BOOTSTRAPPED_STORE" --block=$SOURCE_BLOCK "$SNAPSHOT_FILE"

# Valgrind

# valgrind --tool=massif -- _build/install/default/bin/tezos-node snapshot export \
#     --data-dir "$BOOTSTRAPPED_STORE" --block=$SOURCE_BLOCK "$SNAPSHOT_FILE"

