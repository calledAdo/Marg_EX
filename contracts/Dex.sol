//SPDX-License-Identifier:MIT

pragma solidity ^0.8.9;
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IPool, ERC20} from "./Pool.sol";

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
    ERC20 collateralToken;

    mapping(address => uint) getUserBalance;
    mapping(uint => Vault) getVaultByID;
    mapping(uint => vaultLiquidityShares) getVaultSharesByID;
    mapping(bytes32 => Order) getOrderByKey;

    event openedPosition(bytes32 key, bool islong, uint debt);
    event closedPosition(bytes32 key, bool islong, uint debt);

    struct Order {
        address owner;
        uint vaultID;
        bool isLong;
        uint collateral;
        uint debt;
        uint orderSize;
        uint timestamp;
    }

    ///@dev Vaults data type representing any pool
    /// it comprises of
    /// vault address => the address of the vault contract
    /// token => the token of the vault
    /// oracleAddress => the price oracle address
    /// minCollateral => min collateral needed for a margined Position
    /// liquidityBalance => amount of collateral tokens available for that vault
    // marginFees => margin fee in percentage paid every 1 hour
    struct Vault {
        address poolAddress;
        ERC20 token;
        address oracleAddress;
        uint minCollateral;
        uint minMaintainanceMargin;
        uint liquiditylBalance;
        uint totalDebt;
        uint marginFees;
    }

    ///@dev vaultLiquidityShares data type representing the available collateral liquidity for any pool
    //it comprises of
    //liquidityBalance =>  amount of collateral tokens available for that vault
    //userPoolShares => a mapping of userBalances of poolShares
    // totalSHares => totalShares of the vault liquidity
    struct vaultLiquidityShares {
        uint liquiditylBalance;
        mapping(address => uint) userPoolShares;
        uint totallShares;
        uint totalDebt;
    }

    ///@dev OrderProvider data type representing liquidity provider for a trade
    //it comprises of
    //owner => the address of the liquidity provider and the address to recieve funds
    // signature => the signature to validate the provision of liquidity,providers should have approved this contract address to spend this much
    //takerPremium => the discount in percentage given to the liquidity provider;
    struct OrderProvider {
        address owner;
        bytes signature;
        uint takerPremium;
        uint maxTimestamp;
    }

    /// @dev function for depositing collateral into into the dex;
    //NOTE:This ia different from depositing into pools
    //the deposited amount will be used to deposit to preferred pools;
    function depositCollateral(uint amount) external {
        collateralToken.transferFrom(msg.sender, address(this), amount);
        getUserBalance[msg.sender] += amount;
    }

    function addCollateralAsLiquidity(uint vaultId, uint amount) external {
        require(getUserBalance[msg.sender] >= amount);
        vaultLiquidityShares storage vaultShares = getVaultSharesByID[vaultId];
        uint sharesToMint = (vaultShares.totallShares * amount) /
            vaultShares.liquiditylBalance;

        vaultShares.userPoolShares[msg.sender] += sharesToMint;
        vaultShares.liquiditylBalance += amount;
        getUserBalance[msg.sender] -= amount;
        vaultShares.totallShares += sharesToMint;
        getVaultByID[vaultId].liquiditylBalance += amount;
    }

    function withdrawCollateralLiquidity(
        uint vaultID,
        uint amountOfShares
    ) external {
        vaultLiquidityShares storage vaultShares = getVaultSharesByID[vaultID];
        require(vaultShares.userPoolShares[msg.sender] >= amountOfShares);
        uint amountToSend = (amountOfShares *
            (vaultShares.liquiditylBalance + vaultShares.totalDebt)) /
            vaultShares.totallShares;
        vaultShares.userPoolShares[msg.sender] -= amountOfShares;
        vaultShares.liquiditylBalance -= amountToSend;
        vaultShares.totallShares -= amountOfShares;
        getUserBalance[msg.sender] += amountToSend;
        getVaultByID[vaultID].liquiditylBalance -= amountToSend;
    }

    function openPosition(
        uint vaultID,
        bool isLong,
        uint collateral,
        uint debt,
        OrderProvider memory LP
    ) external {
        require(
            block.timestamp <= LP.maxTimestamp &&
                LP.signature.verify(vaultID, isLong, LP.owner, LP.maxTimestamp)
        );

        bytes32 orderKey = keccak256(abi.encodePacked(msg.sender, vaultID));

        require(getOrderByKey[orderKey].owner == address(0));

        Vault memory vault = getVaultByID[vaultID];

        require(collateral >= vault.minCollateral);

        uint amountIn;
        if (isLong) {
            amountIn = openLong(vault, collateral, debt, LP);
        } else {
            amountIn = openShort(vault, collateral, debt, LP);
        }

        getOrderByKey[orderKey] = Order(
            msg.sender,
            vaultID,
            isLong,
            collateral,
            debt,
            amountIn,
            block.timestamp
        );

        emit openedPosition(orderKey, isLong, debt);
    }

    function openLong(
        Vault memory vault,
        uint collateral,
        uint debt,
        OrderProvider memory LP
    ) private returns (uint) {
        uint poolmaxDebt = (2 * vault.liquiditylBalance) / 3;

        require(debt <= poolmaxDebt);

        uint orderValue = convertUSDToToken(
            vault.oracleAddress,
            debt + collateral
        );

        uint amountIn = orderValue - percentage(orderValue, LP.takerPremium);

        collateralToken.transferFrom(msg.sender, address(this), collateral);

        vault.token.transferFrom(LP.owner, address(this), amountIn);

        collateralToken.transfer(LP.owner, debt + collateral);

        vault.liquiditylBalance -= debt;

        vault.totalDebt += debt;

        return amountIn;
    }

    function openShort(
        Vault memory vault,
        uint collateral,
        uint debt,
        OrderProvider memory LP
    ) private returns (uint) {
        IPool pool = IPool(vault.poolAddress);

        require(debt <= pool.getMaxDebt());

        uint orderValue = convertTokenToUSD(vault.oracleAddress, debt);

        uint amountIn = orderValue - percentage(orderValue, LP.takerPremium);

        collateralToken.transferFrom(msg.sender, address(this), collateral);

        collateralToken.transferFrom(LP.owner, address(this), amountIn);

        pool._transfer(LP.owner, debt);

        pool.increaseDebt(debt);

        return amountIn;
    }

    /// @dev used for closing long positions

    function closePosition(bytes32 orderKey, OrderProvider memory LP) external {
        Order memory order = getOrderByKey[orderKey];
        require(msg.sender == order.owner);
        Vault memory vault = getVaultByID[order.vaultID];
        if (order.isLong) {
            closeLong(vault, order, LP);
        } else {
            closeShort(vault, order, LP);
        }

        delete getOrderByKey[orderKey];
    }

    function closeLong(
        Vault memory vault,
        Order memory order,
        OrderProvider memory LP
    ) internal {
        uint orderValue = convertTokenToUSD(
            vault.oracleAddress,
            order.orderSize
        );

        uint amountIn = orderValue - percentage(orderValue, LP.takerPremium);

        uint totalDebt = order.debt +
            cummulativeMarginFees(
                order.debt,
                vault.marginFees,
                order.timestamp,
                1 hours
            );

        uint pnl = amountIn - totalDebt;

        collateralToken.transferFrom(LP.owner, address(this), amountIn);

        vault.token.transfer(LP.owner, order.orderSize);

        collateralToken.transfer(order.owner, pnl);

        vault.totalDebt -= totalDebt;
        vault.liquiditylBalance += totalDebt;
    }

    function closeShort(
        Vault memory vault,
        Order memory order,
        OrderProvider memory LP
    ) internal {
        IPool pool = IPool(vault.poolAddress);
        uint totalDebt = order.debt +
            cummulativeMarginFees(
                order.debt,
                vault.marginFees,
                order.timestamp,
                1 hours
            );
        uint debtValue = convertUSDToToken(vault.oracleAddress, totalDebt);

        uint orderSize = debtValue + percentage(debtValue, LP.takerPremium);

        uint pnl = order.collateral + order.orderSize - orderSize;

        vault.token.transferFrom(LP.owner, vault.poolAddress, totalDebt);

        collateralToken.transfer(LP.owner, orderSize);

        collateralToken.transfer(order.owner, pnl);

        pool.decreaseDebt(order.debt);
    }

    ///@dev function used to liquidate

    function liquidatePosition(
        bytes32 orderKey,
        OrderProvider memory LP
    ) external {
        Order memory order = getOrderByKey[orderKey];

        Vault memory vault = getVaultByID[order.vaultID];

        if (order.isLong) {
            uint positionValue = convertTokenToUSD(
                vault.oracleAddress,
                order.orderSize
            );
            uint maintainanceMargin = positionValue - order.debt;
            require(maintainanceMargin < vault.minMaintainanceMargin);
            closeLong(vault, order, LP);
        } else {
            uint debtValue = convertTokenToUSD(vault.oracleAddress, order.debt);
            uint maintainanceMargin = order.collateral +
                order.orderSize -
                debtValue;
            require(maintainanceMargin < vault.minMaintainanceMargin);
            closeShort(vault, order, LP);
        }
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

    function convertTokenToUSD(
        address oracleAddress,
        uint amount
    ) public view returns (uint equivalent) {
        AggregatorV3Interface oracle = AggregatorV3Interface(oracleAddress);
        uint8 decimals = oracle.decimals();
        (, int256 price, , , ) = oracle.latestRoundData();
        equivalent = (uint256(price) * amount) / decimals;
    }

    function convertUSDToToken(
        address oracleAddress,
        uint amount
    ) public view returns (uint equivalent) {
        AggregatorV3Interface oracle = AggregatorV3Interface(oracleAddress);
        uint8 decimals = oracle.decimals();
        (, int256 price, , , ) = oracle.latestRoundData();
        equivalent = (amount * decimals) / uint256(price);
    }

    function percentage(uint amount, uint percent) private pure returns (uint) {
        return (amount * percent) / 100000;
    }
}
