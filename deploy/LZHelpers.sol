// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.22;

interface ChainlogLike {
    function getAddress(bytes32) external view returns (address);
}

struct TxParams {
    uint32  dstEid;
    bytes32 dstTarget;
    bytes   dstCallData;
    bytes   extraOptions;
}

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

interface GovOAppSenderLike {
    function quoteTx(TxParams calldata params, bool payInLzToken) external view returns (MessagingFee memory);
}

interface L2GovernanceRelayLike {
    function relay(address target, bytes calldata data) external;
}

interface L2UpdateOFTRateLimitsSpellLike {
    function execute(
        uint32  dstEid,
        address oftAdapter,
        uint48  inboundWindow,
        uint256 inboundLimit,
        uint48  outboundWindow,
        uint256 outboundLimit
    ) external;
}

interface L1GovernanceRelayLike {
    function relayEVM(
        uint32 dstEid,
        address l2GovernanceRelay,
        address target,
        bytes calldata targetData,
        bytes calldata extraOptions,
        MessagingFee calldata fee,
        address refundAddress
    ) external payable;
}

library LZHelpers {

    ChainlogLike internal constant chainlog = ChainlogLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    function relayUpdateOFTRateLimits(
        uint32 dstEid,
        address l2GovernanceRelay,
        address l2Spell,
        uint128 l2GasAmount,
        address oftAdapter,
        uint32 rateLimitDstEid,
        uint48 inboundWindow,
        uint256 inboundLimit,
        uint48 outboundWindow,
        uint256 outboundLimit
    ) internal {
        require(l2GasAmount > 0, "RelayUpdateOFTRateLimits/L2-gas-amount-0");

        bytes memory spellData = abi.encodeCall(
            L2UpdateOFTRateLimitsSpellLike.execute,
            (rateLimitDstEid, oftAdapter, inboundWindow, inboundLimit, outboundWindow, outboundLimit)
        );

        // Equivalent to OptionsBuilder.newOptions().addExecutorLzReceiveOption(optionsGas, 0)
        // source: https://github.com/LayerZero-Labs/LayerZero-v2/blob/9c741e7f9790639537b1710a203bcdfd73b0b9ac/packages/layerzero-v2/evm/oapp/contracts/oapp/libs/OptionsBuilder.sol#L139-L145
        bytes memory extraOptions =  abi.encodePacked(
            hex"0003",      // OPTIONS_TYPE_3
            uint8(1),       // WORKER_ID (executor)
            uint16(16 + 1), // uint128 gas amount (16 bytes) + uint8 option type (1 byte)
            uint8(1),       // OPTION_TYPE_LZRECEIVE
            l2GasAmount
        );

        TxParams memory txParams = TxParams({
            dstEid:       dstEid,
            dstTarget:    bytes32(uint256(uint160(address(l2GovernanceRelay)))),
            dstCallData:  abi.encodeCall(L2GovernanceRelayLike.relay, (address(l2Spell), spellData)),
            extraOptions: extraOptions
        });

        MessagingFee memory fee = GovOAppSenderLike(chainlog.getAddress("LZ_GOV_SENDER")).quoteTx(txParams, false);

        require(address(this).balance >= fee.nativeFee, "RelayUpdateOFTRateLimits/Insufficient-ETH");
        L1GovernanceRelayLike(chainlog.getAddress("LZ_GOV_RELAY")).relayEVM{value: fee.nativeFee}(
            dstEid,
            l2GovernanceRelay,
            address(l2Spell),
            spellData,
            extraOptions,
            fee,
            address(this)
        );
    }
}
