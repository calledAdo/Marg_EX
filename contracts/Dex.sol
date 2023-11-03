//SPDX-License-Identifier:MIT

pragma solidity ^0.8.9;
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {Vault, IERC20} from "./Pool.sol";

library SigVerify {
    function getMessageHash(
        uint vaultId,
        bool islong,
        uint maxtimeStamp
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(vaultId, islong, maxtimeStamp));
    }

    function getEthMesssageHash(
        bytes32 messageHash
    ) public pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    "\x19Ethereum Signed Message : \n32",
                    messageHash
                )
            );
    }

    function verify(
        bytes memory signature,
        uint vaultID,
        bool isLong,
        address signer,
        uint maxtimeStamp
    ) external pure returns (bool) {
        bytes32 ethMesssageHash = getEthMesssageHash(
            getMessageHash(vaultID, isLong, maxtimeStamp)
        );

        return signer == recoverSigner(ethMesssageHash, signature);
    }

    function recoverSigner(
        bytes32 EthMesssageHash,
        bytes memory signature
    ) public pure returns (address) {
        (bytes32 r, bytes32 s, uint8 v) = splitSignature(signature);

        return ecrecover(EthMesssageHash, v, r, s);
    }

    function splitSignature(
        bytes memory sig
    ) public pure returns (bytes32 r, bytes32 s, uint8 v) {
        require(sig.length == 65, "invalid Signature Length");

        assembly {
            r := mload(add(sig, 32))

            s := mload(add(sig, 64))

            v := byte(0, mload(add(sig, 96)))
        }
    }
}

contract Dex {
    using SigVerify for bytes;
    address admin;
    IERC20 collateralToken;

    mapping(address => uint) m_getUserBalance;
    mapping(uint => VaultDetails) m_getVaultByID;

    mapping(bytes32 => Order) m_getOrderByKey;

    event openedPosition(bytes32 key, bool islong, uint debt);
    event closedPosition(bytes32 key, bool islong, uint debt);

    struct Order {
        address owner;
        uint vaultID;
        bool isLong;
        uint collateralAmount;
        uint debt;
        uint orderSize;
        uint timestamp;
    }

    ///@dev Vaults data type representing any pool
    /// it comprises of
    /// vault address => the address of the vault contract
    /// token => the token of the vault
    /// oracleAddress => the price oracle address
    /// minCollateral => min collateralAmount needed for a margined Position
    /// liquidityBalance => amount of collateralAmount tokens available for that vault
    // marginFees => margin fee in percentage paid every 1 hour
    struct VaultDetails {
        address vaultAddress;
        address vaultBaseToken;
        uint minMaintainanceMargin;
        uint marginFees;
    }

    ///@dev vaultLiquidityShares data type representing the available collateralAmount liquidity for any pool
    //it comprises of
    //liquidityBalance =>  amount of collateralAmount tokens available for that vault
    //userPoolShares => a mapping of userBalances of poolShares
    // totalSHares => totalShares of the vault liquidity

    struct OrderProvider {
        address signer;
        bytes signature;
        uint premium;
        uint maxTimestamp;
    }

    function openPosition(
        bool isLong,
        uint vaultID,
        uint collateralTokenID,
        uint collateralAmount,
        uint debt,
        OrderProvider memory provider
    ) external {
        VaultDetails memory _vaultDetails = m_getVaultByID[vaultID];
        Vault vault = Vault(_vaultDetails.vaultAddress);
        (bool isCollateral, bool isStable, address tokenAddress) = vault
            .getTokenDetails(collateralTokenID);
        require(isCollateral);

        uint amountIn;
        uint amountOut;
        if (isLong) {
            openLong(
                vault,
                collateralTokenID,
                tokenAddress,
                collateralAmount,
                debt + collateralAmount,
                isStable,
                provider
            );
        } else {
            openShort(
                vault,
                collateralTokenID,
                tokenAddress,
                collateralAmount,
                debt + collateralAmount,
                isStable,
                provider
            );
        }
    }

    function openLong(
        Vault _vault,
        uint collateralTokenID,
        address collateralAddress,
        uint collateralAmount,
        uint orderValue,
        bool isStable,
        OrderProvider memory provider
    ) internal {
        address owner = msg.sender;
        uint collateralValue = collateralAmount;
        uint amountIn;
        uint amountOut;
        if (isStable) {
            uint equivalent = _vault.longWithStable(orderValue);
            amountIn = equivalent - percentage(equivalent, provider.premium);
        } else {
            (uint equivalent, uint _collateralValue) = _vault.longWithToken(
                collateralTokenID,
                orderValue,
                collateralAmount
            );
            amountIn = equivalent - percentage(equivalent, provider.premium);
            collateralValue = _collateralValue;
        }
        IERC20(collateralAddress).transferFrom(
            owner,
            address(_vault),
            collateralAmount
        );
        IERC20(_vault.poolToken()).transferFrom(
            provider.signer,
            address(this),
            amountIn
        );
        _vault.transferToken(collateralTokenID, provider.signer, orderValue);
    }

    function openShort(
        Vault _vault,
        uint collateralTokenID,
        address collateralAddress,
        uint collateralAmount,
        uint orderValue,
        bool isStable,
        OrderProvider memory provider
    ) internal {
        address owner = msg.sender;
        uint collateralValue = collateralAmount;
        uint amountIn;
        uint amountOut;
        if (isStable) {
            uint equivalent = _vault.shortWithStable(orderValue);
            amountIn = equivalent - percentage(equivalent, provider.premium);
        } else {
            (uint equivalent, uint _collateralValue) = _vault.shortWithToken(
                collateralTokenID,
                orderValue,
                collateralAmount
            );
            amountIn = equivalent - percentage(equivalent, provider.premium);
            collateralValue = _collateralValue;
        }

        IERC20(collateralAddress).transferFrom(
            owner,
            address(this),
            collateralAmount
        );
        IERC20(collateralAddress).transferFrom(
            provider.signer,
            address(this),
            amountIn
        );
        _vault.transferPoolToken(provider.signer, orderValue);
    }

    function cummulativeMarginFees(
        uint amount,
        uint marginFee,
        uint startTime,
        uint duration
    ) private view returns (uint) {
        uint numOfTimes = (block.timestamp - startTime) / duration;
        uint fee;
        for (uint i = 1; i <= numOfTimes; i++) {
            fee += percentage(amount, marginFee);
        }
        return fee;
    }

    function percentage(uint amount, uint percent) private pure returns (uint) {
        return (amount * percent) / 100000;
    }
}
