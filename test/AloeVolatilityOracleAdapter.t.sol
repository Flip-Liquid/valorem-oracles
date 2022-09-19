// SPDX-License-Identifier: BUSL 1.1
pragma solidity 0.8.13;

import "forge-std/Test.sol";
import "v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";

import "../src/libraries/aloe/VolatilityOracle.sol";
import "../src/adapters/AloeVolatilityOracleAdapter.sol";

import "../src/interfaces/IVolatilityOracleAdapter.sol";

/// for writeBalance
interface IERC20 {
    function balanceOf(address) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);
}

contract AloeVolatilityOracleAdapterTest is Test, IUniswapV3SwapCallback{
    using stdStorage for StdStorage;

    event LogString(string topic);
    event LogAddress(string topic, address info);
    event LogUint(string topic, uint info);
    event LogInt(string topic, int info);

    VolatilityOracle public volatilityOracle;
    address private constant UNISWAP_FACTORY_ADDRESS = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address private constant KEEP3R_ADDRESS = 0xeb02addCfD8B773A5FFA6B9d1FE99c566f8c44CC;

    address private constant DAI_ADDRESS = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant FUN_ADDRESS = 0x419D0d8BdD9aF5e606Ae2232ed285Aff190E711b;
    address private constant LUSD_ADDRESS = 0x5f98805A4E8be255a32880FDeC7F6728C6568bA0;
    address private constant LINK_ADDRESS = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address private constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant SNX_ADDRESS = 0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F;

    uint24 private constant POINT_ZERO_ONE_PCT_FEE = 1 * 100;
    uint24 private constant POINT_ZERO_FIVE_PCT_FEE = 5 * 100;
    uint24 private constant POINT_THREE_PCT_FEE = 3 * 100 * 10;

    /// @dev The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    /// @dev The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;


    AloeVolatilityOracleAdapter public aloeAdapter;

    IAloeVolatilityOracleAdapter.UniswapV3PoolInfo[] private defaultTokenRefreshList;

    function setUp() public {
        volatilityOracle = new VolatilityOracle();

        aloeAdapter = new AloeVolatilityOracleAdapter(
            UNISWAP_FACTORY_ADDRESS, 
            address(volatilityOracle),
            KEEP3R_ADDRESS);

        vm.makePersistent(address(volatilityOracle), address(aloeAdapter));

        delete defaultTokenRefreshList;
        defaultTokenRefreshList.push(
            IAloeVolatilityOracleAdapter.UniswapV3PoolInfo(
                USDC_ADDRESS, DAI_ADDRESS, IVolatilityOracleAdapter.UniswapV3FeeTier.PCT_POINT_01
            )
        );
        defaultTokenRefreshList.push(
            IAloeVolatilityOracleAdapter.UniswapV3PoolInfo(
                FUN_ADDRESS, DAI_ADDRESS, IVolatilityOracleAdapter.UniswapV3FeeTier.PCT_POINT_01
            )
        );
        defaultTokenRefreshList.push(
            IAloeVolatilityOracleAdapter.UniswapV3PoolInfo(
                WETH_ADDRESS, DAI_ADDRESS, IVolatilityOracleAdapter.UniswapV3FeeTier.PCT_POINT_3
            )
        );
        defaultTokenRefreshList.push(
            IAloeVolatilityOracleAdapter.UniswapV3PoolInfo(
                LUSD_ADDRESS, DAI_ADDRESS, IVolatilityOracleAdapter.UniswapV3FeeTier.PCT_POINT_01
            )
        );
    }

    function testSetUniswapV3Pool() public {
        IUniswapV3Pool pool = aloeAdapter.getV3PoolForTokensAndFee(USDC_ADDRESS, DAI_ADDRESS, POINT_ZERO_ONE_PCT_FEE);
        // USDC / DAI @ .01 pct
        assertEq(address(pool), 0x5777d92f208679DB4b9778590Fa3CAB3aC9e2168);

        pool = aloeAdapter.getV3PoolForTokensAndFee(USDC_ADDRESS, DAI_ADDRESS, POINT_ZERO_FIVE_PCT_FEE);
        // USDC / DAI @ .05 pct
        assertEq(address(pool), 0x6c6Bc977E13Df9b0de53b251522280BB72383700);
    }

    function testSetRefreshTokenList() public {
        // TODO: assert event emission
        aloeAdapter.setTokenFeeTierRefreshList(defaultTokenRefreshList);

        IAloeVolatilityOracleAdapter.UniswapV3PoolInfo[] memory returnedRefreshList =
            aloeAdapter.getTokenFeeTierRefreshList();
        assertEq(defaultTokenRefreshList, returnedRefreshList);
    }

    function testTokenVolatilityRefresh() public {
        // TODO: Add error if v3 pool not set
        // move forward 1 hour to allow for aloe data requirement
        vm.warp(block.timestamp + 1 hours + 1);
        aloeAdapter.setTokenFeeTierRefreshList(defaultTokenRefreshList);
        uint256 ts = aloeAdapter.refreshVolatilityCache();
        assertEq(ts, block.timestamp);
    }

    function testGetImpliedVolatility() public {
        // move forward 1 hour to allow for aloe data requirement
        vm.warp(block.timestamp + 1 hours + 1);
        aloeAdapter.setTokenFeeTierRefreshList(defaultTokenRefreshList);
        _cache1d();
        emit LogString("cached one day");
        for (uint256 i = 0; i < defaultTokenRefreshList.length; i++) {
            IAloeVolatilityOracleAdapter.UniswapV3PoolInfo storage poolInfo = defaultTokenRefreshList[i];
            _validateCachedVolatilityForPool(poolInfo);
        }
    }

    /** 
     * /////////// IUniswapV3SwapCallback /////////////
     */

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) public 
    {
        emit LogInt("uniswap swap callback, amount0", amount0Delta);
        emit LogInt("uniswap swap callback, amount1", amount1Delta);
        // only ever transferring DAI to the pool, extend this via data
        int256 amountToTransfer = amount0Delta > 0 ? amount0Delta : amount1Delta;
        emit LogUint("uniswap swap callback, amountToTransfer", uint256(amountToTransfer));
        address poolAddr = _bytesToAddress(data);
        IERC20(DAI_ADDRESS).transfer(poolAddr, uint256(amountToTransfer));
    }

    /**
     * ///////// HELPERS //////////
     */
    function assertEq(
        IAloeVolatilityOracleAdapter.UniswapV3PoolInfo[] memory a,
        IAloeVolatilityOracleAdapter.UniswapV3PoolInfo[] memory b
    )
        internal
    {
        // from forg-std/src/Test.sol
        if (keccak256(abi.encode(a)) != keccak256(abi.encode(b))) {
            emit log("Error: a == b not satisfied [UniswapV3PoolInfo[]]");
            fail();
        }
    }

    function _validateCachedVolatilityForPool(IAloeVolatilityOracleAdapter.UniswapV3PoolInfo storage poolInfo)
        internal
    {
        address tokenA = poolInfo.tokenA;
        address tokenB = poolInfo.tokenB;
        IVolatilityOracleAdapter.UniswapV3FeeTier feeTier = poolInfo.feeTier;
        uint256 iv = aloeAdapter.getImpliedVolatility(tokenA, tokenB, feeTier);
        // assertFalse(iv == 0, "Volatility is expected to have been refreshed");
    }

    function _cache1d() internal {
        // get 24 hours
        for (uint i = 0; i < 24; i++) {
            aloeAdapter.refreshVolatilityCache();
            emit LogUint("cached hour", i);
            // fuzz trades
            _simulateUniswapMovements();
            // refresh the pool metadata
            vm.warp(block.timestamp + 2 hours + 1);
            aloeAdapter.setTokenFeeTierRefreshList(defaultTokenRefreshList);
        }
        aloeAdapter.refreshVolatilityCache();
    }

    function _simulateUniswapMovements() internal {
        // add tokens to this contract
        _writeTokenBalance(address(this), address(DAI_ADDRESS), 1_000_000_000 ether);

        // iterate pools
        for (uint i = 0; i < defaultTokenRefreshList.length; i++) {
            IAloeVolatilityOracleAdapter.UniswapV3PoolInfo memory poolInfo = defaultTokenRefreshList[i];
            uint24 fee = aloeAdapter.getUniswapV3FeeInHundredthsOfBip(poolInfo.feeTier);
            IUniswapV3Pool pool = aloeAdapter.getV3PoolForTokensAndFee(
                poolInfo.tokenA, poolInfo.tokenB, fee);
            bool zeroForOne = pool.token0() == DAI_ADDRESS; 
            // swap 10 tokens on each pool
            pool.swap(
                address(this),
                zeroForOne,
                10 ether,
                zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
                abi.encodePacked(address(pool)));
        }
    }

    function _writeTokenBalance(address who, address token, uint256 amt) internal {
        stdstore
            .target(token)
            .sig(IERC20(token).balanceOf.selector)
            .with_key(who)
            .checked_write(amt);
    }

    function _bytesToAddress(bytes memory bys) internal pure returns (address addr) {
        assembly {
            addr := mload(add(bys, 0x14))
        } 
    }
    // TODO: Keep3r tests
}
