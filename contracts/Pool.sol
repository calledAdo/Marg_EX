//SPDX-License-Identifier:MIT

pragma solidity ^0.8.9;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract Shares is ERC1155Supply {
    address owner;

    constructor() ERC1155("") {
        owner = msg.sender;
    }

    function mint(address to, uint256 id, uint256 value) external {
        require(msg.sender == owner);
        _mint(to, id, value, "");
    }

    function burn(address to, uint256 id, uint256 value) external {
        require(msg.sender == owner);
        _burn(to, id, value);
    }
}

contract Vault {
    address s_dex;

    IERC20 s_poolToken;

    Shares s_shares;

    address poolTokenOracle;

    uint immutable i_minBootstrapAmount;

    struct tokenDetails {
        bool isStable;
        address priceOracle;
        uint debtOnToken;
    }

    mapping(uint => tokenDetails) public m_tokenDetails;
    mapping(uint tokenID => bool) public m_isStable;
    mapping(uint => address) public m_tokenPriceOracles;
    mapping(address => bool) public m_isCollateral;
    mapping(uint => address) public m_tokenWithID;
    mapping(uint tokenId => uint debt) public m_debtOnToken;

    enum BootStrap {
        Ongoing,
        Ended
    }

    BootStrap immutable i_bootstrapAmount;

    event AddedLiquidity(uint tokenID, address from, uint amount);
    event RemovedLiquidity(uint tokenID, address to, uint amount);

    constructor(
        string memory symbol,
        uint _minBootstrapAmount,
        address _poolToken
    ) {
        s_shares = new Shares();
        s_dex = msg.sender;
        s_poolToken = IERC20(_poolToken);
        m_tokenWithID[1] = _poolToken;
        i_bootstrapAmount = BootStrap.Ongoing;
        i_minBootstrapAmount = _minBootstrapAmount;
    }

    function poolToken() external view returns (address) {
        return m_tokenWithID[1];
    }

    function getTokenDetails(
        uint tokenID
    )
        external
        view
        returns (bool isCollateral, bool isStable, address tokenAddress)
    {
        tokenAddress = m_tokenWithID[tokenID];
        tokenAddress = m_tokenWithID[tokenID];
        isCollateral = m_isCollateral[tokenAddress];
    }

    function depositPoolToken(uint amount) external {
        depositToken(1, amount);
    }

    function depositToken(uint tokenID, uint amount) public {
        address token = m_tokenWithID[tokenID];
        require(m_isCollateral[token]);

        uint sharesSupply = s_shares.totalSupply(tokenID);
        uint virtualBalance = s_poolToken.balanceOf(address(this)) +
            m_debtOnToken[tokenID];
        uint amount_to_mint = (amount * sharesSupply) / virtualBalance;
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        s_shares.mint(msg.sender, tokenID, amount_to_mint);
    }

    function withdrawPoolToken(uint amountOfShares) external {
        withdrawToken(1, amountOfShares);
    }

    function withdrawToken(uint tokenID, uint amountOfShares) public {
        s_shares.burn(msg.sender, tokenID, amountOfShares);
        address token = m_tokenWithID[tokenID];
        uint sharesSupply = s_shares.totalSupply(tokenID);
        uint virtualBalance = s_poolToken.balanceOf(address(this)) +
            m_debtOnToken[tokenID];
        uint amount_to_send = (amountOfShares * virtualBalance) / sharesSupply;
        IERC20(token).transfer(msg.sender, amount_to_send);
    }

    function transferPoolToken(address to, uint amount) external {
        transferToken(1, to, amount);
    }

    function transferToken(uint tokenID, address to, uint amount) public {
        require(i_bootstrapAmount == BootStrap.Ended);
        require(msg.sender == s_dex);
        address token = m_tokenWithID[tokenID];
        IERC20(token).transfer(to, amount);
    }

    function longWithStable(
        uint amount
    ) external view returns (uint equivalent) {
        address poolTokenOracle = m_tokenPriceOracles[1];
        equivalent = convertUSDToToken(poolTokenOracle, amount);
    }

    function longWithToken(
        uint tokenID,
        uint amount,
        uint collateral
    ) external view returns (uint equivalent, uint collateralValue) {
        address collateralOracle = m_tokenPriceOracles[tokenID];
        collateralValue = convertTokenToUSD(collateralOracle, collateral);
        uint amountInUSD = convertTokenToUSD(collateralOracle, amount);
        equivalent = equivalent = convertUSDToToken(
            poolTokenOracle,
            amountInUSD
        );
    }

    function shortWithStable(
        uint amount
    ) external view returns (uint equivalent) {
        address poolTokenOracle = m_tokenPriceOracles[1];
        equivalent = convertTokenToUSD(poolTokenOracle, amount);
    }

    function shortWithToken(
        uint tokenID,
        uint amount,
        uint collateral
    ) external view returns (uint equivalent, uint collateralValue) {
        address collateralOracle = m_tokenPriceOracles[tokenID];
        collateralValue = convertTokenToUSD(collateralOracle, collateral);
        uint valueInUSD = convertTokenToUSD(poolTokenOracle, amount);
        equivalent = convertUSDToToken(collateralOracle, valueInUSD);
    }

    function increaseDebt(uint tokenId, uint amount) external {
        require(msg.sender == s_dex);
        m_debtOnToken[tokenId] += amount;
    }

    function decreaseDebt(uint tokenID, uint amount) external {
        require(msg.sender == s_dex);
        m_debtOnToken[tokenID] -= amount;
    }

    function getMaxDebt(uint tokenId) external view returns (uint) {
        address token = m_tokenWithID[tokenId];
        uint vaultBalance = IERC20(token).balanceOf(address(this));
        return (2 * vaultBalance) / 3;
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
}
