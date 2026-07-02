# ============================================================================================
#  AVAX-migration clone experiment — one-command runner.
#
#  Stands up an independent CLONE of the Sky LZ gov-bridge + OFT setup on REAL mainnet + real
#  Avalanche, runs the Avalanche hardening migration against it, and (optionally) bridges USDS
#  round-trip through the migrated adapters — all with YOUR OWN funded deployer.
#
#  See script/README.md for prerequisites, funding, and the full walkthrough.
#
#  Every target broadcasts REAL transactions with your key. `make -n all` dry-runs (prints the
#  ordered command list) without sending anything.
#
#  Required env (export or use a .env + `set -a; . ./.env; set +a`):
#    DEPLOYER            your deployer EOA (MUST match PRIVATE_KEY / your keystore)
#    PRIVATE_KEY         the broadcasting key (or override WALLET=--account <name> for a keystore)
#    MAINNET_RPC_URL     an Ethereum RPC (archive not required for broadcasting)
#    AVALANCHE_RPC_URL   an Avalanche C-chain RPC
# ============================================================================================

SHELL := /bin/bash

# Wallet args passed to forge/cast. Defaults to --private-key $PRIVATE_KEY; override for a keystore:
#   make deploy-bridge WALLET="--account mydeployer"
WALLET ?= --private-key $(PRIVATE_KEY)

# Common forge script flags. --slow lands txs one at a time (safer for partial re-runs); the scripts
# themselves are idempotent (skip already-done work) so re-running a target is safe.
FORGE_FLAGS := --broadcast --slow -vv $(WALLET)

BRIDGE := script/CloneAvaxBridge.s.sol
OFT    := script/CloneAvaxOft.s.sol
DVN    := script/CloneAvaxDvnBroadcaster.s.sol
# This file holds two contracts (the L2 spell + the driver), so name the target explicitly.
MIG    := script/CloneAvaxRunMigration.s.sol:CloneAvaxRunMigration

ETH_JSON  := script/clone.eth.json
AVAX_JSON := script/clone.avax.json

# Poll window (seconds) for deliver.sh before force-delivering. Override: make deliver-migration DELIVER_POLL=0
DELIVER_POLL ?= 900

.PHONY: help check clean-state \
        deploy-bridge wire-bridge deploy-oft-avax deploy-dvn-broadcaster deploy-oft-eth wire-oft \
        deploy-l2spell migrate \
        deliver-migration exec-migration verify \
        roundtrip send-to-avax deliver-to-avax send-back deliver-to-eth \
        gov-message reclaim all

help:
	@echo "Targets (see script/README.md):"
	@echo "  check              verify env + foundry + deployer balances on both chains"
	@echo "  clean-state        wipe clone.*.json for a FRESH clone (your own addresses)"
	@echo "  deploy-bridge      deploy gov bridge + fake tokens + FakeChainlog (both chains)"
	@echo "  wire-bridge        wire the gov bridge send/recv sides (both chains)"
	@echo "  deploy-oft-eth     deploy the 4 L1 lockboxes + mainnet CCIP DVN adapter BARE (mainnet; run BEFORE the broadcaster)"
	@echo "  deploy-oft-avax    deploy the 4 Avalanche OFT adapters (Avalanche)"
	@echo "  deploy-dvn-broadcaster  deploy Avax CCIP adapter + CCIP/msig broadcasters + 8 replicas via RecvSideDeployer (needs mainnet adapter first)"
	@echo "  wire-oft           wire the OFT adapters, seed backing, configure+handoff the CCIP send adapter (both chains)"
	@echo "  deploy-l2spell     deploy the L2 clone migration spell (Avalanche)"
	@echo "  migrate            run migrateAvax on mainnet (relays the L2 spell)"
	@echo "  deliver-migration  poll + force-deliver the relayed L2 spell (Eth->Avax)"
	@echo "  exec-migration     exec the queued L2 migration action on the OLD relay (Avalanche)"
	@echo "  verify             cast-assert the L1 + L2 migration outcome"
	@echo "  roundtrip          send USDS Eth->Avax, deliver, send back, deliver, verify"
	@echo "  gov-message        post-migration 8-of-15 gov message via the multisig wing (see script/README.md)"
	@echo "  reclaim            recover leftover LZ-fee ETH from the clone L1 relay (mainnet)"
	@echo "  all                run the whole ordered sequence end-to-end"
	@echo ""
	@echo "Dry run (prints commands, sends nothing):  make -n all"

# --------------------------------------------------------------------------------------------
#  check: fail fast if the environment isn't ready.
# --------------------------------------------------------------------------------------------
check:
	@echo ">> Checking environment ..."
	@command -v forge >/dev/null || { echo "ERROR: foundry (forge) not found"; exit 1; }
	@command -v cast  >/dev/null || { echo "ERROR: foundry (cast) not found"; exit 1; }
	@command -v jq    >/dev/null || { echo "ERROR: jq not found (needed by deliver.sh)"; exit 1; }
	@test -n "$(DEPLOYER)"          || { echo "ERROR: DEPLOYER not set"; exit 1; }
	@test -n "$(MAINNET_RPC_URL)"   || { echo "ERROR: MAINNET_RPC_URL not set"; exit 1; }
	@test -n "$(AVALANCHE_RPC_URL)" || { echo "ERROR: AVALANCHE_RPC_URL not set"; exit 1; }
	@test -n "$(PRIVATE_KEY)" || echo "note: PRIVATE_KEY empty — assuming WALLET override ($(WALLET))"
	@echo "   deployer: $(DEPLOYER)"
	@echo -n "   mainnet balance (ETH):  "; cast to-unit $$(cast balance $(DEPLOYER) --rpc-url $(MAINNET_RPC_URL)) ether
	@echo -n "   avalanche balance (AVAX): "; cast to-unit $$(cast balance $(DEPLOYER) --rpc-url $(AVALANCHE_RPC_URL)) ether
	@echo -n "   mainnet chainid: ";   cast chain-id --rpc-url $(MAINNET_RPC_URL)
	@echo -n "   avalanche chainid: "; cast chain-id --rpc-url $(AVALANCHE_RPC_URL)
	@echo ">> OK. (need ~0.1 ETH on mainnet, ~2 AVAX on Avalanche)"

# --------------------------------------------------------------------------------------------
#  clean-state: start a fresh clone. The committed clone.*.json hold a PREVIOUS run's addresses
#  (idempotency sentinels); wiping them makes the next deploy mint your own contracts.
# --------------------------------------------------------------------------------------------
clean-state:
	@echo ">> Wiping $(ETH_JSON) and $(AVAX_JSON) for a fresh clone ..."
	@echo '{}' > $(ETH_JSON)
	@echo '{}' > $(AVAX_JSON)
	@echo ">> Done. The next deploy will create your own clone."

# --------------------------------------------------------------------------------------------
#  Deploy + wire (each script auto-selects behaviour by chainid; we point --rpc-url at the chain).
#  Adapters on both chains cross-reference each other, so DEPLOY both sides before WIRING.
# --------------------------------------------------------------------------------------------
deploy-bridge: check
	@echo ">> [1/8] Deploy gov bridge + fake tokens + FakeChainlog (mainnet, then Avalanche)"
	forge script $(BRIDGE) --sig "deploy()" --rpc-url $(MAINNET_RPC_URL)   $(FORGE_FLAGS)
	forge script $(BRIDGE) --sig "deploy()" --rpc-url $(AVALANCHE_RPC_URL) $(FORGE_FLAGS)

# --- OFT deploy is SPLIT + ORDERED around the DVN broadcaster ---------------------------------
#  Both CCIP DVN adapters set their peer via setDstConfig ONCE per chainSelector, and the peer is the
#  REMOTE adapter's address — a mutual dependency. The real Send/RecvSideDeployer split this cleanly:
#    - deploy-oft-eth: deploys the mainnet CCIP adapter BARE via CloneSendSideDeployer's constructor
#      (roles + allowlist, NO peer). Peer wiring is deferred to wire-oft (below).
#    - deploy-dvn-broadcaster: RecvSideDeployer deploys the Avax adapter and bakes the REAL mainnet
#      adapter as its source peer — so it MUST run AFTER deploy-oft-eth. (This is the fix for the
#      set-once 0xdead placeholder bug that silently killed the CCIP recv path in the earlier run.)
#    - wire-oft (mainnet): CloneSendSideDeployer.configure() sets the mainnet adapter's peer to the
#      REAL Avax adapter + broadcaster, then handOff() moves admin to the clone pause proxy (EOA).
#  Correct order:  deploy-oft-eth  ->  deploy-oft-avax  ->  deploy-dvn-broadcaster  ->  wire-oft
deploy-oft-eth: check
	@echo ">> [3/8] Deploy the 4 L1 lockboxes + mainnet CCIP DVN adapter BARE (mainnet)"
	@echo "   (CloneSendSideDeployer ctor: adapter + roles, NO peer yet — peer wired in wire-oft)"
	forge script $(OFT) --sig "deployOft()" --rpc-url $(MAINNET_RPC_URL) $(FORGE_FLAGS)

deploy-oft-avax: check
	@echo ">> [4/8] Deploy the 4 Avalanche OFT adapters (Avalanche)"
	forge script $(OFT) --sig "deployOft()" --rpc-url $(AVALANCHE_RPC_URL) $(FORGE_FLAGS)

deploy-dvn-broadcaster: check
	@echo ">> [5/8] Deploy Avax CCIP DVN adapter + CCIP/msig broadcasters + 8 replicas via RecvSideDeployer (Avalanche)"
	@echo "   (must run AFTER deploy-oft-eth: RecvSideDeployer bakes the REAL mainnet CCIP adapter as its set-once source peer)"
	@ETHCCIP=$$(jq -r '.ccipAdapter // empty' $(ETH_JSON)); \
	 test -n "$$ETHCCIP" || { echo "ERROR: ccipAdapter not in $(ETH_JSON) — run deploy-oft-eth first (need the real mainnet adapter, no placeholder)"; exit 1; }
	forge script $(DVN) --sig "deploy()" --rpc-url $(AVALANCHE_RPC_URL) $(FORGE_FLAGS)

wire-bridge: check
	@echo ">> [3/8] Wire gov bridge SEND (mainnet) + RECV (Avalanche)"
	forge script $(BRIDGE) --sig "wire()" --rpc-url $(MAINNET_RPC_URL)   $(FORGE_FLAGS)
	forge script $(BRIDGE) --sig "wire()" --rpc-url $(AVALANCHE_RPC_URL) $(FORGE_FLAGS)

wire-oft: check
	@echo ">> [4/8] Wire OFT adapters (mainnet), then Avalanche (relies tokens, pauses old, hands off)"
	forge script $(OFT) --sig "wireOft()" --rpc-url $(MAINNET_RPC_URL)   $(FORGE_FLAGS)
	forge script $(OFT) --sig "wireOft()" --rpc-url $(AVALANCHE_RPC_URL) $(FORGE_FLAGS)

deploy-l2spell: check
	@echo ">> [5/8] Deploy the L2 clone migration spell (Avalanche)"check
	forge script $(MIG) --sig "deployL2Spell()" --rpc-url $(AVALANCHE_RPC_URL) $(FORGE_FLAGS)

migrate: check
	@echo ">> [6/8] Run migrateAvax on mainnet (funds the L1 relay + relays the L2 spell)"
	forge script $(MIG) --sig "run()" --rpc-url $(MAINNET_RPC_URL) $(FORGE_FLAGS)

deliver-migration: check
	@echo ">> [7/8] Deliver the relayed L2 migration spell (Eth->Avax). Provide MIGRATE_TX or paste when prompted."
	@test -n "$(MIGRATE_TX)" || { echo "Set MIGRATE_TX=<the migrate() tx hash from step 6> (or run deliver.sh manually)"; exit 1; }
	MAINNET_RPC_URL=$(MAINNET_RPC_URL) AVALANCHE_RPC_URL=$(AVALANCHE_RPC_URL) PRIVATE_KEY=$(PRIVATE_KEY) \
	  ./script/deliver.sh $(MIGRATE_TX) eth avax $(DELIVER_POLL)

exec-migration: check
	@echo ">> [8/8] Exec the queued L2 migration action on the OLD relay (Avalanche)"
	forge script $(MIG) --sig "execQueued()" --rpc-url $(AVALANCHE_RPC_URL) $(FORGE_FLAGS)

# --------------------------------------------------------------------------------------------
#  verify: read-only cast assertions of the migration outcome on both chains.
# --------------------------------------------------------------------------------------------
verify: check
	@echo ">> Verifying migration outcome ..."
	@ETH=$(ETH_JSON); AVAX=$(AVAX_JSON); \
	 NEWL1USDS=$$(jq -r .newUsdsOft $$ETH); OLDL1USDS=$$(jq -r .oldUsdsOft $$ETH); CL=$$(jq -r .chainlog $$ETH); L1USDS=$$(jq -r .usds $$ETH); \
	 NEWAVUSDS=$$(jq -r .newUsdsOft $$AVAX); NEWRELAY=$$(jq -r .newRelay $$AVAX); AVUSDS=$$(jq -r .usds $$AVAX); OLDAVUSDS=$$(jq -r .oldUsdsOft $$AVAX); \
	 echo "   [L1] chainlog USDS_OFT -> new lockbox:"; \
	 echo "        got  $$(cast call $$CL 'getAddress(bytes32)(address)' $$(cast format-bytes32-string USDS_OFT) --rpc-url $(MAINNET_RPC_URL))  expect $$NEWL1USDS"; \
	 echo "   [L1] old USDS lockbox peer[AVAX] cleared (expect 0x0..0):"; \
	 echo "        $$(cast call $$OLDL1USDS 'peers(uint32)(bytes32)' 30106 --rpc-url $(MAINNET_RPC_URL))"; \
	 echo "   [L1] USDS backing held by the NEW lockbox (expect 10000e18 = 1e22, + any in-flight bridged):"; \
	 echo "        $$(cast call $$L1USDS 'balanceOf(address)(uint256)' $$NEWL1USDS --rpc-url $(MAINNET_RPC_URL))"; \
	 echo "   [L2] avax USDS token ward: new adapter=1, old adapter=0:"; \
	 echo "        new $$(cast call $$AVUSDS 'wards(address)(uint256)' $$NEWAVUSDS --rpc-url $(AVALANCHE_RPC_URL))  old $$(cast call $$AVUSDS 'wards(address)(uint256)' $$OLDAVUSDS --rpc-url $(AVALANCHE_RPC_URL))"; \
	 echo "   [L2] new avax USDS adapter owner (expect new relay $$NEWRELAY):"; \
	 echo "        $$(cast call $$NEWAVUSDS 'owner()(address)' --rpc-url $(AVALANCHE_RPC_URL))"; \
	 echo ">> Review the values above against the expectations."

# --------------------------------------------------------------------------------------------
#  Token round-trip. Each send emits one LZ packet that must be delivered before the next leg.
#  send-to-avax prints its tx hash; capture it and pass as SEND_TX to deliver-to-avax (same for back).
# --------------------------------------------------------------------------------------------
send-to-avax: check
	@echo ">> Round-trip 1/4: send 1000 USDS Eth->Avax (locks on the new L1 lockbox)"
	forge script $(MIG) --sig "sendUsdsToAvax()" --rpc-url $(MAINNET_RPC_URL) $(FORGE_FLAGS)

deliver-to-avax: check
	@echo ">> Round-trip 2/4: deliver the Eth->Avax token packet"
	@test -n "$(SEND_TX)" || { echo "Set SEND_TX=<the sendUsdsToAvax() tx hash>"; exit 1; }
	MAINNET_RPC_URL=$(MAINNET_RPC_URL) AVALANCHE_RPC_URL=$(AVALANCHE_RPC_URL) PRIVATE_KEY=$(PRIVATE_KEY) \
	  ./script/deliver.sh $(SEND_TX) eth avax $(DELIVER_POLL)

send-back: check
	@echo ">> Round-trip 3/4: send 1000 USDS Avax->Eth (burns on Avax)"
	forge script $(MIG) --sig "sendUsdsBack()" --rpc-url $(AVALANCHE_RPC_URL) $(FORGE_FLAGS)

deliver-to-eth: check
	@echo ">> Round-trip 4/4: deliver the Avax->Eth token packet (unlocks on L1)"
	@test -n "$(BACK_TX)" || { echo "Set BACK_TX=<the sendUsdsBack() tx hash>"; exit 1; }
	MAINNET_RPC_URL=$(MAINNET_RPC_URL) AVALANCHE_RPC_URL=$(AVALANCHE_RPC_URL) PRIVATE_KEY=$(PRIVATE_KEY) \
	  ./script/deliver.sh $(BACK_TX) avax eth $(DELIVER_POLL)

roundtrip:
	@echo ">> Full round-trip is interactive because each leg's tx hash feeds the next deliver step."
	@echo "   Run in order, capturing tx hashes from the forge output:"
	@echo "     make send-to-avax"
	@echo "     make deliver-to-avax SEND_TX=<hash from send-to-avax>"
	@echo "     make send-back"
	@echo "     make deliver-to-eth  BACK_TX=<hash from send-back>"
	@echo "   Then confirm the deployer's USDS balance returned on mainnet."

# --------------------------------------------------------------------------------------------
#  gov-message: the headline post-migration demonstration — send a gov message through the NEW
#  relay under the real hardened 8-of-15 recv topology, delivered via the MULTISIG WING.
#  There is no forge --sig for this; it is a documented cast recipe (see script/README.md
#  "Post-migration gov message (8-of-15, multisig wing)"). This target just prints the steps,
#  because each step's output (send tx hash, packet header/payloadHash) feeds the next.
# --------------------------------------------------------------------------------------------
gov-message: check
	@echo ">> Post-migration 8-of-15 gov message via the multisig wing — see script/README.md."
	@echo "   The full cast recipe (prefund CCIP adapter, relayEVM through the new relay, attest the"
	@echo "   msig broadcaster, then permissionless lzReceive) is documented there; it is a sequence of"
	@echo "   cast commands (not a forge --sig) because each step's output feeds the next."
	@echo "   Summary:"
	@echo "     1. cast send <ethCcipAdapter> --value 0.001ether            # prefund CCIP assignJob"
	@echo "     2. cast send <l1Relay> 'relayEVM(...)' with the quoted fee   # send through the new relay"
	@echo "     3. ./script/deliver.sh <sendTx> eth avax 0                   # parse the PacketSent packet"
	@echo "     4. cast send <msigBroadcaster> 'verify(bytes,bytes32,uint64)' <hdr81> <payloadHash> <conf>"
	@echo "     5. cast send <endpoint> 'lzReceive(...)'                     # permissionless, once >=8 attested"

reclaim: check
	@echo ">> Reclaim leftover LZ-fee ETH from the clone L1 gov relay to the deployer (mainnet)"
	forge script $(MIG) --sig "reclaim()" --rpc-url $(MAINNET_RPC_URL) $(FORGE_FLAGS)

# --------------------------------------------------------------------------------------------
#  all: the whole ordered sequence, in the DEPENDENCY-CORRECT order. The mainnet CCIP adapter is
#  deployed BARE first (deploy-oft-eth), THEN the Avax recv side (deploy-dvn-broadcaster) which bakes
#  the real mainnet adapter as its set-once source peer, THEN wire-oft configures the mainnet peer +
#  hands off. deliver-migration + exec-migration need the migrate() tx hash; because that hash is only
#  known after `migrate` broadcasts, `all` stops after it and prints the remaining commands.
# --------------------------------------------------------------------------------------------
all: deploy-bridge wire-bridge deploy-oft-eth deploy-oft-avax deploy-dvn-broadcaster wire-oft deploy-l2spell migrate
	@echo ""
	@echo ">> Deploy + wire + migrate broadcast complete."
	@echo ">> Finish the migration (needs the migrate() tx hash printed above):"
	@echo "     make deliver-migration MIGRATE_TX=<migrate tx hash>"
	@echo "     make exec-migration"
	@echo "     make verify"
	@echo ">> Optional token round-trip: make roundtrip"
	@echo ">> Cleanup: make reclaim"
