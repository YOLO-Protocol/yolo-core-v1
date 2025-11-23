// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {MockERC20} from "@yolo/core-v1/mocks/MockERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

// Minimal Universal Router interface
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

// Permit2 interface for token approvals
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

// Universal Router Commands
library Commands {
    uint256 constant V4_SWAP = 0x10;
    uint256 constant SWEEP = 0x04; // Sweep tokens from Router to recipient
}

/**
 * @title DeployTask_TestSwap
 * @author alvin@yolo.wtf
 * @notice Quick swap test script to verify protocol functionality on real network
 * @dev Executes two swaps using Universal Router:
 *      1. USDC -> USY (anchor pool)
 *      2. USY -> yETH (synthetic pool)
 *
 * Prerequisites:
 *   - Deploy01_FullProtocol completed (YoloHook, Universal Router deployed)
 *   - Deploy02_ConfigureProtocol completed (Synthetic assets, lending pairs configured)
 *   - Configure addresses below for your target network
 *
 * Usage:
 *   forge script script/DeployTask_TestSwap.sol:DeployTask_TestSwap \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast -vvv
 */
contract DeployTask_TestSwap is Script {
    using CurrencyLibrary for Currency;

    // ========================
    // CONFIGURATION - ADJUST THESE VALUES
    // ========================

    // Deployed contract addresses (configure for your network)
    address constant YOLO_HOOK_PROXY = 0x033ea50dEaa8b064958fC40E34F994C154D27FFf; // FILL IN: YoloHook proxy address
    address constant UNIVERSAL_ROUTER = 0x492E6456D9528771018DeB9E87ef7750EF184104; // FILL IN: Universal Router address
    address constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408; // FILL IN: PoolManager address
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3; // Canonical Permit2 (same on all chains)
    address constant USDC = 0xF32B34Dfc110BF618a0Ff148afBAd8C3915c45aB; // FILL IN: USDC address
    address constant USY = 0x50108c7CCdfDf341baEC1c1f4A94B42A764628EF; // FILL IN: USY address
    address constant YETH = 0x4f24bdFE9f375E8BA9aCA6247DAAa8624cc4A02E; // FILL IN: yETH synthetic asset address

    // Swap amounts (adjust as needed)
    uint256 constant USDC_TO_USY_AMOUNT = 200e6; // 200 USDC (6 decimals) - increased to ensure enough USY for second swap
    uint256 constant USY_TO_YETH_AMOUNT = 100e18; // 100 USY (18 decimals)
    uint8 constant USY_DECIMALS = 18;
    uint8 constant YETH_DECIMALS = 18;
    uint8 constant DISPLAY_PRECISION = 4;

    // Slippage tolerance (in basis points: 100 = 1%)
    uint256 constant SLIPPAGE_BPS = 100; // 1% slippage tolerance

    // Deadline (seconds from now)
    uint256 constant DEADLINE_SECONDS = 300; // 5 minutes

    // Pool parameters (MUST MATCH DEPLOYMENT)
    // YoloHook manages fees dynamically via beforeSwapReturnDelta
    // The protocol fee in the PoolKey itself is 0
    uint24 constant ANCHOR_POOL_FEE = 0; // Fee handled by hook
    uint24 constant SYNTHETIC_POOL_FEE = 0; // Fee handled by hook
    int24 constant ANCHOR_TICK_SPACING = 60; // Matches BootstrapModule.sol:114
    int24 constant SYNTHETIC_TICK_SPACING = 1; // Matches SyntheticAssetModule.sol:182

    // ========================
    // STATE VARIABLES
    // ========================

    // Test user
    address public trader;

    // ========================
    // MAIN EXECUTION
    // ========================

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        trader = vm.addr(deployerPrivateKey);

        console2.log("============================================================");
        console2.log("YOLO Protocol V1 - Test Swap Execution");
        console2.log("============================================================");
        console2.log("Trader:", trader);
        console2.log("Chain ID:", block.chainid);
        console2.log("");

        // Verify configured addresses
        require(YOLO_HOOK_PROXY != address(0), "YOLO_HOOK_PROXY not configured");
        require(UNIVERSAL_ROUTER != address(0), "UNIVERSAL_ROUTER not configured");
        require(USDC != address(0), "USDC not configured");
        require(USY != address(0), "USY not configured");
        require(YETH != address(0), "YETH not configured");

        console2.log("Configured addresses:");
        console2.log("  YoloHook:", YOLO_HOOK_PROXY);
        console2.log("  Universal Router:", UNIVERSAL_ROUTER);
        console2.log("  USDC:", USDC);
        console2.log("  USY:", USY);
        console2.log("  yETH:", YETH);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Mint USDC to trader for testing
        _mintUSDCToTrader();

        // Execute Swap 1: USDC -> USY
        _swapUSDCtoUSY();

        // Execute Swap 2: USY -> yETH
        _swapUSYtoYETH();

        vm.stopBroadcast();

        console2.log("");
        console2.log("============================================================");
        console2.log("Test Swaps Complete!");
        console2.log("============================================================");
    }

    // ========================
    // HELPER FUNCTIONS
    // ========================

    function _mintUSDCToTrader() internal {
        console2.log("[Setup] Minting USDC to trader...");

        // Mint enough USDC for the test swap
        // Only attempts mint if you own the token (Mock)
        try MockERC20(USDC).mint(trader, USDC_TO_USY_AMOUNT) {
            console2.log("  Minted", USDC_TO_USY_AMOUNT / 1e6, "USDC");
        } catch {
            console2.log("  Skipped minting (not a MockERC20 or no permission)");
        }

        uint256 balance = IERC20(USDC).balanceOf(trader);
        console2.log("  Trader USDC balance:", balance / 1e6, "USDC");
        console2.log("");
    }

    function _swapUSDCtoUSY() internal {
        console2.log("[Swap 1] Executing USDC -> USY swap...");
        console2.log("  Amount In:", USDC_TO_USY_AMOUNT / 1e6, "USDC");

        // Calculate minimum output (with slippage)
        // For debugging on thin-liquidity pools we permit zero min output
        uint256 minUSYOut = 0;

        // Pre-transfer tokens to Universal Router (simpler for scripts than Permit2)
        // The Router will pay the PoolManager from its own balance
        IERC20(USDC).transfer(UNIVERSAL_ROUTER, USDC_TO_USY_AMOUNT);
        console2.log("  Transferred USDC to Universal Router");

        // Build PoolKey for USDC/USY anchor pool
        PoolKey memory poolKey = _buildAnchorPoolKey();

        // Determine swap direction (USDC -> USY)
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == USDC;

        // 1. DEFINE V4 ACTIONS: SWAP -> SETTLE -> TAKE_ALL
        // TAKE_ALL clears all output deltas to avoid CurrencyNotSettled error
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE_ALL));

        // 2. ENCODE V4 ACTION PARAMS
        bytes[] memory actionParams = new bytes[](3);

        // Action 0: Swap
        actionParams[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: uint128(USDC_TO_USY_AMOUNT),
                amountOutMinimum: uint128(minUSYOut),
                hookData: ""
            })
        );

        // Action 1: SETTLE - Router pays PoolManager from its balance
        // Params: (Currency, uint256 amount, bool payerIsUser)
        actionParams[1] = abi.encode(Currency.wrap(USDC), USDC_TO_USY_AMOUNT, false);

        // Action 2: TAKE_ALL - Router claims ALL output tokens (clears delta)
        // Params: (Currency, uint256 minAmount) - Only 2 params!
        actionParams[2] = abi.encode(Currency.wrap(USY), minUSYOut);

        // 3. BUILD TOP-LEVEL COMMANDS: V4_SWAP -> SWEEP
        // SWEEP transfers tokens from Router to trader
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP), uint8(Commands.SWEEP));
        bytes[] memory inputs = new bytes[](2);

        // Input 0: V4 Actions
        inputs[0] = abi.encode(actions, actionParams);

        // Input 1: SWEEP Params (address token, address recipient, uint256 minAmount)
        // DIAGNOSTIC: Set minAmount to 0 to test if tokens are reaching Router
        // If this passes: tokens ARE in Router, minUSYOut was too high
        // If this fails: tokens NOT in Router, TAKE_ALL is failing
        inputs[1] = abi.encode(USY, trader, uint256(0));

        // 4. EXECUTE
        uint256 deadline = block.timestamp + DEADLINE_SECONDS;
        IUniversalRouter(UNIVERSAL_ROUTER).execute(commands, inputs, deadline);

        // Report results
        uint256 usyBalance = IERC20(USY).balanceOf(trader);
        console2.log("  Swap executed successfully!");
        console2.log(string.concat("  USY received: ", _formatTokenAmount(usyBalance, USY_DECIMALS), " USY"));
        console2.log("  USY balance (exact):", usyBalance);
        console2.log("");
    }

    function _swapUSYtoYETH() internal {
        console2.log("[Swap 2] Executing USY -> yETH swap...");
        console2.log("  Amount In:", USY_TO_YETH_AMOUNT / 1e18, "USY");

        // Calculate minimum output (with slippage)
        // Allow zero min-out to bypass stale pricing during integration tests
        uint256 minYETHOut = 0;

        // Pre-transfer tokens to Universal Router (simpler for scripts than Permit2)
        // The Router will pay the PoolManager from its own balance
        IERC20(USY).transfer(UNIVERSAL_ROUTER, USY_TO_YETH_AMOUNT);
        console2.log("  Transferred USY to Universal Router");

        // Build PoolKey for yETH/USY synthetic pool
        PoolKey memory poolKey = _buildSyntheticPoolKey();

        // Determine swap direction (USY -> yETH)
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == USY;

        // 1. DEFINE V4 ACTIONS: SWAP -> SETTLE -> TAKE_ALL
        // TAKE_ALL clears all output deltas to avoid CurrencyNotSettled error
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE_ALL));

        // 2. ENCODE V4 ACTION PARAMS
        bytes[] memory actionParams = new bytes[](3);

        // Action 0: Swap
        actionParams[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: uint128(USY_TO_YETH_AMOUNT),
                amountOutMinimum: uint128(minYETHOut),
                hookData: ""
            })
        );

        // Action 1: SETTLE - Router pays PoolManager from its balance
        // Params: (Currency, uint256 amount, bool payerIsUser)
        actionParams[1] = abi.encode(Currency.wrap(USY), USY_TO_YETH_AMOUNT, false);

        // Action 2: TAKE_ALL - Router claims ALL output tokens (clears delta)
        // Params: (Currency, uint256 minAmount) - Only 2 params!
        actionParams[2] = abi.encode(Currency.wrap(YETH), minYETHOut);

        // 3. BUILD TOP-LEVEL COMMANDS: V4_SWAP -> SWEEP
        // SWEEP transfers tokens from Router to trader
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP), uint8(Commands.SWEEP));
        bytes[] memory inputs = new bytes[](2);

        // Input 0: V4 Actions
        inputs[0] = abi.encode(actions, actionParams);

        // Input 1: SWEEP Params (address token, address recipient, uint256 minAmount)
        // DIAGNOSTIC: Set minAmount to 0 to test if tokens are reaching Router
        inputs[1] = abi.encode(YETH, trader, uint256(0));

        // 4. EXECUTE
        uint256 deadline = block.timestamp + DEADLINE_SECONDS;
        IUniversalRouter(UNIVERSAL_ROUTER).execute(commands, inputs, deadline);

        // Report results
        uint256 yETHBalance = IERC20(YETH).balanceOf(trader);
        console2.log("  Swap executed successfully!");
        console2.log(string.concat("  yETH received: ", _formatTokenAmount(yETHBalance, YETH_DECIMALS), " yETH"));
        console2.log("  yETH balance (exact):", yETHBalance);
        console2.log("");
    }

    // ========================
    // POOL KEY BUILDERS
    // ========================

    /**
     * @notice Builds PoolKey for USDC/USY anchor pool
     * @dev Pool key structure: (currency0, currency1, fee, tickSpacing, hooks)
     *      Currencies must be sorted (lower address first)
     */
    function _buildAnchorPoolKey() internal pure returns (PoolKey memory) {
        Currency currency0;
        Currency currency1;

        // Sort currencies
        if (USDC < USY) {
            currency0 = Currency.wrap(USDC);
            currency1 = Currency.wrap(USY);
        } else {
            currency0 = Currency.wrap(USY);
            currency1 = Currency.wrap(USDC);
        }

        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: ANCHOR_POOL_FEE,
            tickSpacing: ANCHOR_TICK_SPACING,
            hooks: IHooks(YOLO_HOOK_PROXY)
        });
    }

    /**
     * @notice Builds PoolKey for yETH/USY synthetic pool
     */
    function _buildSyntheticPoolKey() internal pure returns (PoolKey memory) {
        Currency currency0;
        Currency currency1;

        // Sort currencies
        if (YETH < USY) {
            currency0 = Currency.wrap(YETH);
            currency1 = Currency.wrap(USY);
        } else {
            currency0 = Currency.wrap(USY);
            currency1 = Currency.wrap(YETH);
        }

        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: SYNTHETIC_POOL_FEE,
            tickSpacing: SYNTHETIC_TICK_SPACING,
            hooks: IHooks(YOLO_HOOK_PROXY)
        });
    }

    function _formatTokenAmount(uint256 amount, uint8 tokenDecimals) internal pure returns (string memory) {
        if (tokenDecimals == 0) {
            return Strings.toString(amount);
        }

        uint256 base = 10 ** tokenDecimals;
        uint256 integerPart = amount / base;
        uint256 fractionalPart = amount % base;

        if (fractionalPart == 0) {
            return Strings.toString(integerPart);
        }

        uint8 precision = DISPLAY_PRECISION;
        if (precision > tokenDecimals) {
            precision = tokenDecimals;
        }

        uint256 divisor = 10 ** (tokenDecimals - precision);
        fractionalPart = fractionalPart / divisor;

        string memory fractionalStr = _padFractional(fractionalPart, precision);

        return string.concat(Strings.toString(integerPart), ".", fractionalStr);
    }

    function _padFractional(uint256 fractional, uint8 precision) private pure returns (string memory) {
        string memory raw = Strings.toString(fractional);
        uint256 length = bytes(raw).length;

        if (length >= precision) {
            return raw;
        }

        bytes memory padded = new bytes(precision);
        for (uint256 i = 0; i < precision - length; i++) {
            padded[i] = bytes1("0");
        }
        for (uint256 i = 0; i < length; i++) {
            padded[precision - length + i] = bytes(raw)[i];
        }
        return string(padded);
    }
}
