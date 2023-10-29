//SPDX-License-Identifier:MIT

pragma solidity ^0.8.9;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract erc20 is ERC20 {
    address immutable adminPool;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        adminPool = msg.sender;
    }

    function mint(address to, uint amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint amount) external {
        _burn(from, amount);
    }
}

interface IPool {
    function bootstrapDeposit(uint amount) external;

    function deposit(uint amount) external;

    function withdraw(uint amount) external;

    function _transfer(address to, uint amount) external;

    function increaseDebt(uint amount) external;

    function decreaseDebt(uint amount) external;

    function getMaxDebt() external view returns (uint);
}

contract Pool is IPool {
    address dex;
    ERC20 poolToken; /* /// @notice Explain to an end user what this does
    /// @dev Explain to a developer any extra details
    /// @param Documents a parameter just like in doxygen (must be followed by parameter name) */

    uint debt;

    erc20 poolShare;

    enum BootStrap {
        Ongoing,
        Ended
    }

    uint immutable minBootstrapAmount;

    BootStrap immutable _bootStrapPhase;

    constructor(
        string memory symbol,
        uint _minBootstrapAmount,
        address _poolToken
    ) {
        dex = msg.sender;
        poolToken = ERC20(_poolToken);

        poolShare = new erc20(symbol, symbol);
        _bootStrapPhase = BootStrap.Ongoing;
        minBootstrapAmount = _minBootstrapAmount;
    }

    function bootstrapDeposit(uint amount) external {
        require(
            amount >= minBootstrapAmount && _bootStrapPhase == BootStrap.Ongoing
        );
        ERC20(poolToken).transferFrom(msg.sender, address(this), amount);

        emit AddedLiquidity(msg.sender, amount);

        uint totalShareSupply = poolShare.totalSupply();
        uint virtualAmount = poolToken.balanceOf(address(this)) + debt;
        uint amount_to_mint = (totalShareSupply * amount) / virtualAmount;
        poolShare.mint(msg.sender, amount_to_mint);
    }

    function deposit(uint amount) external {
        poolToken.transferFrom(msg.sender, address(this), amount);

        uint totalShareSupply = poolShare.totalSupply();
        uint virtualBalance = poolToken.balanceOf(address(this)) + debt;
        uint amount_to_mint = (totalShareSupply * amount) / virtualBalance;
        poolShare.mint(msg.sender, amount_to_mint);

        emit AddedLiquidity(msg.sender, amount);
    }

    function withdraw(uint amount) external {
        poolShare.burn(msg.sender, amount);
        uint totalShareSupply = poolShare.totalSupply();
        uint virtualBalance = poolToken.balanceOf(address(this)) + debt;
        uint amount_to_send = (virtualBalance * amount) / totalShareSupply;
        poolToken.transfer(msg.sender, amount_to_send);
    }

    function _transfer(address to, uint amount) external {
        require(_bootStrapPhase == BootStrap.Ended);
        require(msg.sender == dex);
        poolToken.transfer(to, amount);
    }

    function increaseDebt(uint amount) external {
        require(msg.sender == dex);
        debt += amount;
    }

    function decreaseDebt(uint amount) external {
        require(msg.sender == dex);
        debt -= amount;
    }

    ///@notice at anytime you can only use two third of the amount of token in the pool
    function getMaxDebt() external view returns (uint) {
        return (2 * poolToken.balanceOf(address(this))) / 3;
    }

    event AddedLiquidity(address depositor, uint amount);
}
