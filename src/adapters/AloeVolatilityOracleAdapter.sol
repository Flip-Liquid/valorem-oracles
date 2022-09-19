// SPDX-License-Identifier: BUSL 1.1
pragma solidity 0.8.13;

import "../interfaces/IAloeVolatilityOracleAdapter.sol";

import "../libraries/aloe/interfaces/IVolatilityOracle.sol";
import "../libraries/aloe/VolatilityOracle.sol";

import "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import "../utils/Keep3rV2Job.sol";

/**
 * @notice This contract adapts the Aloe capital volatility oracle
 * contract from https://github.com/aloelabs/aloe-blend.
 */
contract AloeVolatilityOracleAdapter is IAloeVolatilityOracleAdapter, Keep3rV2Job {
    /**
     * /////////// CONSTANTS ////////////
     */
    uint24 private constant POINT_ZERO_ONE_PCT_FEE = 1 * 100;
    uint24 private constant POINT_THREE_PCT_FEE = 3 * 100 * 10;
    uint24 private constant POINT_ZERO_FIVE_PCT_FEE = 5 * 100;

    /**
     * /////////// STATE ////////////
     */
    IUniswapV3Factory private uniswapV3Factory;
    IVolatilityOracle private aloeVolatilityOracle;

    IAloeVolatilityOracleAdapter.UniswapV3PoolInfo[] private tokenFeeTierList;

    // MultiRolesAuthority inehrited from Keep3rV2Job
    constructor(address v3Factory, address aloeOracle, address _keep3r)
        MultiRolesAuthority(msg.sender, Authority(address(0)))
    {
        setRoleCapability(0, IAloeVolatilityOracleAdapter.setAloeOracle.selector, true);
        setRoleCapability(0, IKeep3rV2Job.setKeep3r.selector, true);

        uniswapV3Factory = IUniswapV3Factory(v3Factory);
        aloeVolatilityOracle = IVolatilityOracle(aloeOracle);
        keep3r = _keep3r;
    }

    /**
     * /////////// IVolatilityOracleAdapter //////////
     */

    /// @inheritdoc IVolatilityOracleAdapter
    function getHistoricalVolatility(address) external pure returns (uint256) {
        revert("not implemented");
    }

    /// @inheritdoc IVolatilityOracleAdapter
    function getImpliedVolatility(address tokenA, address tokenB, UniswapV3FeeTier tier)
        external
        view
        returns (uint256 impliedVolatility)
    {
        uint24 fee = getUniswapV3FeeInHundredthsOfBip(tier);
        IUniswapV3Pool pool = getV3PoolForTokensAndFee(tokenA, tokenB, fee);
        uint256[25] memory lens = aloeVolatilityOracle.lens(pool);
        (, uint8 idx) = aloeVolatilityOracle.feeGrowthGlobalsIndices(pool);
        return lens[idx];
    }

    /// @inheritdoc IVolatilityOracleAdapter
    function scale() external pure returns (uint16) {
        return 18;
    }

    /// @inheritdoc IAloeVolatilityOracleAdapter
    function getV3PoolForTokensAndFee(address tokenA, address tokenB, uint24 fee)
        public
        view
        returns (IUniswapV3Pool pool)
    {
        pool = IUniswapV3Pool(uniswapV3Factory.getPool(tokenA, tokenB, fee));
    }

    /// @inheritdoc IAloeVolatilityOracleAdapter
    function refreshVolatilityCache() public returns (uint256) {
        return _refreshVolatilityCache();
    }

    /// @inheritdoc IAloeVolatilityOracleAdapter
    function refreshVolatilityCacheAndMetadataForPool(UniswapV3PoolInfo calldata info) public returns (uint256) {
        _refreshPoolMetadata(info);
        (, uint256 timestamp) = _refreshTokenVolatility(info.tokenA, info.tokenB, info.feeTier);
        return timestamp;
    }

    /**
     * ////////////// KEEP3R ///////////////
     */

    function work() external validateAndPayKeeper(msg.sender) {
        _refreshVolatilityCache();
    }

    /**
     * ////////////// TOKEN REFRESH LIST ///////////////
     */

    /// @inheritdoc IAloeVolatilityOracleAdapter
    function setTokenFeeTierRefreshList(UniswapV3PoolInfo[] calldata list)
        external
        returns (UniswapV3PoolInfo[] memory)
    {
        delete tokenFeeTierList;
        for (uint256 i = 0; i < list.length; i++) {
            UniswapV3PoolInfo memory info = UniswapV3PoolInfo(list[i].tokenA, list[i].tokenB, list[i].feeTier);
            // refresh pool metadata cache on first add
            _refreshPoolMetadata(info);
            tokenFeeTierList.push(info);
        }
        emit TokenRefreshListSet();
        return list;
    }

    /// @inheritdoc IAloeVolatilityOracleAdapter
    function getTokenFeeTierRefreshList() public view returns (UniswapV3PoolInfo[] memory) {
        return tokenFeeTierList;
    }

    /**
     * /////////////// ADMIN FUNCTIONS ///////////////
     */

    /// @inheritdoc IAloeVolatilityOracleAdapter
    function setAloeOracle(address oracle) external requiresAuth returns (address) {
        aloeVolatilityOracle = IVolatilityOracle(oracle);
        emit AloeOracleSet(oracle);
        return oracle;
    }

    /// @inheritdoc IAloeVolatilityOracleAdapter
    function setV3Factory(address factory) external requiresAuth returns (address) {
        uniswapV3Factory = IUniswapV3Factory(factory);
        emit UniswapV3FactorySet(factory);
        return factory;
    }

    /// @inheritdoc IAloeVolatilityOracleAdapter
    function getUniswapV3FeeInHundredthsOfBip(UniswapV3FeeTier tier) public pure returns (uint24) {
        if (tier == UniswapV3FeeTier.PCT_POINT_01) {
            return 1 * 100;
        }
        if (tier == UniswapV3FeeTier.PCT_POINT_05) {
            return 5 * 100;
        }
        if (tier == UniswapV3FeeTier.PCT_POINT_3) {
            return 3 * 100 * 10;
        }
        if (tier == UniswapV3FeeTier.PCT_1) {
            return 100 * 100;
        }
    }

    /**
     * ///////// INTERNAL ///////////
     */
    function _refreshVolatilityCache() internal returns (uint256) {
        for (uint256 i = 0; i < tokenFeeTierList.length; i++) {
            address tokenA = tokenFeeTierList[i].tokenA;
            address tokenB = tokenFeeTierList[i].tokenB;
            UniswapV3FeeTier feeTier = tokenFeeTierList[i].feeTier;
            _refreshTokenVolatility(tokenA, tokenB, feeTier);
        }

        emit AloeVolatilityOracleCacheUpdated(block.timestamp);
        return block.timestamp;
    }

    function _refreshTokenVolatility(address tokenA, address tokenB, UniswapV3FeeTier feeTier)
        internal
        returns (uint256 volatility, uint256 timestamp)
    {
        uint24 fee = getUniswapV3FeeInHundredthsOfBip(feeTier);
        IUniswapV3Pool pool = getV3PoolForTokensAndFee(tokenA, tokenB, fee);

        // refresh metadata only if observation is older than xx
        // in certain cases, aloe won't have sufficient data to run estimate24h, since
        // the oldest observation for the pool oracle is under an hour. for now,
        // we're only refreshing the pool metadata cache when the token is added to the
        // refresh list, and when a manual call to refresh a token is made.
        // aloeVolatilityOracle.cacheMetadataFor(pool);
        uint256 impliedVolatility = aloeVolatilityOracle.estimate24H(pool);
        emit TokenVolatilityUpdated(tokenA, tokenB, fee, impliedVolatility, block.timestamp);
        return (impliedVolatility, block.timestamp);
    }

    function _refreshPoolMetadata(UniswapV3PoolInfo memory info) internal {
        uint24 fee = getUniswapV3FeeInHundredthsOfBip(info.feeTier);
        IUniswapV3Pool pool = getV3PoolForTokensAndFee(info.tokenA, info.tokenB, fee);
        aloeVolatilityOracle.cacheMetadataFor(pool);
    }
}
