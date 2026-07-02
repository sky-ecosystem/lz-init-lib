#!/usr/bin/env bash
#
# deliver.sh — poll + (if the LZ executor stalls) permissionlessly force-deliver a LayerZero
# message on the destination chain, for the AVAX-migration clone experiment.
#
# LayerZero's real executor normally delivers a message a few minutes after the source tx.
# Occasionally it lags (as happened during the real experiment run). Delivery is permissionless
# once the DVNs have verified the payload, so this script reconstructs the packet from the source
# tx's PacketSent log and calls endpoint.lzReceive(...) directly.
#
# Usage:
#   ./script/deliver.sh <SOURCE_TX_HASH> <SRC> <DST> [POLL_SECONDS]
#     SRC / DST : one of  eth | avax   (source and destination chains)
#     POLL_SECONDS (optional): how long to wait for the real executor before force-delivering.
#                              Default 900 (15 min). Set 0 to force-deliver immediately.
#
# Env required:
#   MAINNET_RPC_URL, AVALANCHE_RPC_URL   (archive not required for delivery, just current state)
#   PRIVATE_KEY  (or set CAST_KEYSTORE / pass --account via CAST_WALLET_ARGS) — only needed if a
#                force-delivery send is actually performed. Polling is read-only.
#
# Notes:
#   * The LZ endpoint (0x1a44...728c) is the same address on Ethereum and Avalanche.
#   * If verification hasn't completed yet, the endpoint.lzReceive call will revert; the script
#     prints the exact `cast send` command so the operator can retry manually once verified.
#   * This delivers ONE message (the first matching PacketSent for the destination eid). The
#     migration and each round-trip leg emit exactly one such packet.

set -euo pipefail

ENDPOINT="0x1a44076050125825900e736c501f859c50fE728c"
ETH_EID=30101
AVAX_EID=30106

TX="${1:?source tx hash required}"
SRC="${2:?source chain (eth|avax) required}"
DST="${3:?destination chain (eth|avax) required}"
POLL_SECONDS="${4:-900}"

rpc_for() {
  case "$1" in
    eth)  echo "${MAINNET_RPC_URL:?MAINNET_RPC_URL not set}";;
    avax) echo "${AVALANCHE_RPC_URL:?AVALANCHE_RPC_URL not set}";;
    *) echo "unknown chain: $1" >&2; exit 1;;
  esac
}
eid_for() {
  case "$1" in eth) echo $ETH_EID;; avax) echo $AVAX_EID;; *) exit 1;; esac
}

SRC_RPC="$(rpc_for "$SRC")"
DST_RPC="$(rpc_for "$DST")"
DST_EID="$(eid_for "$DST")"

# PacketSent(bytes encodedPayload, bytes options, address sendLibrary)
PACKET_SENT_TOPIC="$(cast keccak 'PacketSent(bytes,bytes,address)')"

echo ">> Fetching source receipt: $TX (on $SRC)"
RECEIPT="$(cast receipt "$TX" --rpc-url "$SRC_RPC" --json)"

# Find the PacketSent log emitted by the endpoint and pull its ABI-encoded data blob.
LOG_DATA="$(echo "$RECEIPT" | jq -r --arg topic "$PACKET_SENT_TOPIC" --arg ep "$(echo "$ENDPOINT" | tr 'A-F' 'a-f')" '
  .logs[] | select((.topics[0]|ascii_downcase)==($topic|ascii_downcase)) | select((.address|ascii_downcase)==$ep) | .data' | head -1)"

if [ -z "$LOG_DATA" ] || [ "$LOG_DATA" = "null" ]; then
  echo "ERROR: no PacketSent log from the endpoint found in tx $TX" >&2
  exit 1
fi

# data = abi.encode(bytes encodedPayload, bytes options, address sendLibrary)
# Decode the first bytes arg (the encoded packet). cast abi-decode wants the 0x blob.
ENCODED_PACKET="$(cast abi-decode 'x(bytes,bytes,address)' "$LOG_DATA" --input | head -1)"
PKT="${ENCODED_PACKET#0x}"

# PacketV1Codec fixed offsets (bytes -> hex nibble ranges, *2):
#   nonce   [1:9]    srcEid  [9:13]   sender  [13:45]
#   dstEid  [45:49]  receiver[49:81]  guid    [81:113]  message [113:]
hexslice() { echo "${PKT:$(($1*2)):$((($2-$1)*2))}"; }

NONCE_HEX="$(hexslice 1 9)"
SRC_EID_HEX="$(hexslice 9 13)"
SENDER_HEX="$(hexslice 13 45)"      # bytes32
PKT_DST_EID_HEX="$(hexslice 45 49)"
RECEIVER_HEX="$(hexslice 49 81)"    # bytes32
GUID_HEX="$(hexslice 81 113)"       # bytes32
MESSAGE_HEX="${PKT:$((113*2))}"

NONCE=$((16#$NONCE_HEX))
SRC_EID=$((16#$SRC_EID_HEX))
PKT_DST_EID=$((16#$PKT_DST_EID_HEX))
RECEIVER_ADDR="0x${RECEIVER_HEX: -40}"    # low 20 bytes of the bytes32
SENDER_B32="0x${SENDER_HEX}"
GUID="0x${GUID_HEX}"
MESSAGE="0x${MESSAGE_HEX}"

echo ">> Parsed packet:"
echo "     srcEid=$SRC_EID  dstEid=$PKT_DST_EID  nonce=$NONCE"
echo "     sender(b32)=$SENDER_B32"
echo "     receiver=$RECEIVER_ADDR"
echo "     guid=$GUID"

if [ "$PKT_DST_EID" != "$DST_EID" ]; then
  echo "ERROR: packet dstEid ($PKT_DST_EID) != requested destination eid ($DST_EID)." >&2
  echo "       Did you swap SRC/DST?" >&2
  exit 1
fi

# Origin tuple for endpoint calls: (uint32 srcEid, bytes32 sender, uint64 nonce)
ORIGIN="($SRC_EID,$SENDER_B32,$NONCE)"

delivered() {
  # Use lazyInboundNonce (advances when lzReceive EXECUTES), NOT inboundNonce (which advances on
  # COMMIT/verification and would report "delivered" for a committed-but-unexecuted packet — the packet
  # would then never run and any dependent exec reverts). This is the FINDINGS #6 fix.
  local n
  n="$(cast call "$ENDPOINT" 'lazyInboundNonce(address,uint32,bytes32)(uint64)' \
        "$RECEIVER_ADDR" "$SRC_EID" "$SENDER_B32" --rpc-url "$DST_RPC" 2>/dev/null || echo 0)"
  [ "$n" -ge "$NONCE" ] 2>/dev/null
}

echo ">> Polling destination ($DST) for delivery, up to ${POLL_SECONDS}s ..."
elapsed=0
while [ "$elapsed" -lt "$POLL_SECONDS" ]; do
  if delivered; then
    echo ">> DELIVERED by the LZ executor (inboundNonce >= $NONCE). Done."
    exit 0
  fi
  sleep 30
  elapsed=$((elapsed+30))
  echo "   ...waited ${elapsed}s (inboundNonce still < $NONCE)"
done

echo ">> Executor did not deliver within ${POLL_SECONDS}s. Attempting permissionless force-delivery."

LZRECEIVE_SIG='lzReceive((uint32,bytes32,uint64),address,bytes32,bytes,bytes)'
CMD=(cast send "$ENDPOINT" "$LZRECEIVE_SIG" "$ORIGIN" "$RECEIVER_ADDR" "$GUID" "$MESSAGE" "0x" --rpc-url "$DST_RPC")
if [ -n "${PRIVATE_KEY:-}" ]; then
  CMD+=(--private-key "$PRIVATE_KEY")
fi

echo ">> Exact command:"
printf '   %q ' "${CMD[@]}"; echo

if [ -z "${PRIVATE_KEY:-}" ]; then
  echo ">> PRIVATE_KEY not set — not sending. Run the command above (add your --account/keystore)."
  echo "   (It only succeeds once the DVNs have verified the payload; retry if it reverts.)"
  exit 2
fi

if "${CMD[@]}"; then
  echo ">> Force-delivery submitted. Re-checking ..."
  sleep 10
  if delivered; then echo ">> DELIVERED (manual). Done."; exit 0; fi
  echo ">> Sent but inboundNonce not yet advanced; check the dest tx / re-run to confirm."
  exit 0
else
  echo ">> Force-delivery reverted. Most likely the payload isn't DVN-verified yet."
  echo "   Wait a few minutes and re-run this script (or the printed command)."
  exit 3
fi
