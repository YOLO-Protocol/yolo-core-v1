// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {IYoloHook} from "@yolo/core-v1/interfaces/IYoloHook.sol";
import {YoloHookViews} from "@yolo/core-v1/core/YoloHookViews.sol";

contract DeployTask_AddLendingPairs is Script {
    address constant YOLO_HOOK_PROXY = 0x033ea50dEaa8b064958fC40E34F994C154D27FFf;
    address constant WETH = 0x119000192D6C783d355aC50320670F8140D051d0;
    address constant WBTC = 0x47A94537Cd5169dD0D7E8B86B65372794C9Ff8e8;

    struct LendingPairInput {
        string syntheticSymbol;
        address synthetic;
        address collateral;
        string collateralSymbol;
        uint256 ltvBps;
        uint256 liqThresholdBps;
        uint256 liqBonusBps;
        uint256 liqPenaltyBps;
        uint256 borrowRateBps;
        uint256 minBorrow;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        LendingPairInput[] memory pairs = _getPairs();
        require(pairs.length > 0, "No pairs configured");

        console2.log("=================================");
        console2.log("YOLO Protocol V1 - Add Lending Pairs");
        console2.log("=================================");
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);
        console2.log("Pairs:", pairs.length);
        console2.log("");

        IYoloHook hook = IYoloHook(YOLO_HOOK_PROXY);
        YoloHookViews views = YoloHookViews(YOLO_HOOK_PROXY);

        vm.startBroadcast(deployerPrivateKey);
        for (uint256 i = 0; i < pairs.length; i++) {
            _configurePair(hook, views, pairs[i]);
        }
        vm.stopBroadcast();

        console2.log("");
        console2.log("All pairs configured!");
        console2.log("=================================");
    }

    function _configurePair(IYoloHook hook, YoloHookViews views, LendingPairInput memory input) internal {
        console2.log("> Configuring", input.syntheticSymbol, "with", input.collateralSymbol);
        require(input.synthetic != address(0), "Synthetic missing");

        uint256 mintCap = views.getAssetConfiguration(input.synthetic).maxSupply;
        require(mintCap > 0, "Synthetic cap must be > 0");

        uint256 maxMintable = mintCap / 2; // allow up to 50% via this collateral
        uint256 supplyCap = mintCap / 2;

        hook.configureLendingPair(
            input.synthetic,
            input.collateral,
            address(0),
            address(0),
            input.ltvBps,
            input.liqThresholdBps,
            input.liqBonusBps,
            input.liqPenaltyBps,
            input.borrowRateBps,
            maxMintable,
            supplyCap,
            input.minBorrow,
            false,
            0
        );
    }

    function _getPairs() internal pure returns (LendingPairInput[] memory pairs) {
        LendingPairInput[40] memory array = [
            _pair("yAMD", 0x733b737320F0bd3fE347F02257F77E7A7807bC3E, WETH, "WETH"),
            _pair("yAMD", 0x733b737320F0bd3fE347F02257F77E7A7807bC3E, WBTC, "WBTC"),
            _pair("yNFLX", 0xa185A6f1Dc798a57D42c9CD13b93e72718682321, WETH, "WETH"),
            _pair("yNFLX", 0xa185A6f1Dc798a57D42c9CD13b93e72718682321, WBTC, "WBTC"),
            _pair("yINTC", 0x8Db4f2aD2c4B07a6c5D5bBe0784Df5DB0E072706, WETH, "WETH"),
            _pair("yINTC", 0x8Db4f2aD2c4B07a6c5D5bBe0784Df5DB0E072706, WBTC, "WBTC"),
            _pair("yPLTR", 0x57d086092eCD0F5653a9956019C0E0fA584A246A, WETH, "WETH"),
            _pair("yPLTR", 0x57d086092eCD0F5653a9956019C0E0fA584A246A, WBTC, "WBTC"),
            _pair("yCOIN", 0xbA9aa9fDBAE1040D9D74612A899dF2455957aA22, WETH, "WETH"),
            _pair("yCOIN", 0xbA9aa9fDBAE1040D9D74612A899dF2455957aA22, WBTC, "WBTC"),
            _pair("yHOOD", 0x84D82024e8B7D504Ca33f237C64B7f218eee607f, WETH, "WETH"),
            _pair("yHOOD", 0x84D82024e8B7D504Ca33f237C64B7f218eee607f, WBTC, "WBTC"),
            _pair("yJPM", 0x1317BD6371749e911c96F01d0305A9E23Ef3ABfe, WETH, "WETH"),
            _pair("yJPM", 0x1317BD6371749e911c96F01d0305A9E23Ef3ABfe, WBTC, "WBTC"),
            _pair("yBAC", 0xDef987Ab8663288e4D50124781Bf2aD12681db50, WETH, "WETH"),
            _pair("yBAC", 0xDef987Ab8663288e4D50124781Bf2aD12681db50, WBTC, "WBTC"),
            _pair("yGS", 0x5fe0Ed58e69A16A897943ebad7C88C3aA65D6bFc, WETH, "WETH"),
            _pair("yGS", 0x5fe0Ed58e69A16A897943ebad7C88C3aA65D6bFc, WBTC, "WBTC"),
            _pair("yV", 0xA8411Ea314e74AFCB6e2B990e7c708E28Ad585Ea, WETH, "WETH"),
            _pair("yV", 0xA8411Ea314e74AFCB6e2B990e7c708E28Ad585Ea, WBTC, "WBTC"),
            _pair("yDIS", 0x556edf4dE518210219d6c978f30aaFb55eb6906D, WETH, "WETH"),
            _pair("yDIS", 0x556edf4dE518210219d6c978f30aaFb55eb6906D, WBTC, "WBTC"),
            _pair("yBA", 0xDaBD1E1E6A6b772Fa424f5F72E49Cb89aA47DD14, WETH, "WETH"),
            _pair("yBA", 0xDaBD1E1E6A6b772Fa424f5F72E49Cb89aA47DD14, WBTC, "WBTC"),
            _pair("yBABA", 0x6f6BA9a74160BB02F2EA43F58A24bD90CCd30f2F, WETH, "WETH"),
            _pair("yBABA", 0x6f6BA9a74160BB02F2EA43F58A24bD90CCd30f2F, WBTC, "WBTC"),
            _pair("yDIA", 0x058aB338562B32A6bcc40641208C487Bb323B570, WETH, "WETH"),
            _pair("yDIA", 0x058aB338562B32A6bcc40641208C487Bb323B570, WBTC, "WBTC"),
            _pair("yIWM", 0x06d9c5F15433934810b8632F034b66Fe823B9d75, WETH, "WETH"),
            _pair("yIWM", 0x06d9c5F15433934810b8632F034b66Fe823B9d75, WBTC, "WBTC"),
            _pair("yBRENT", 0x37d32890F63D6aeC1F6C2Bfc4885A1B905C147D0, WETH, "WETH"),
            _pair("yBRENT", 0x37d32890F63D6aeC1F6C2Bfc4885A1B905C147D0, WBTC, "WBTC"),
            _pair("yWTI", 0x3D5f5004ef3Bd1bcB03F578784757a5a67795F29, WETH, "WETH"),
            _pair("yWTI", 0x3D5f5004ef3Bd1bcB03F578784757a5a67795F29, WBTC, "WBTC"),
            _pair("yXAG", 0x27fAA3E80f9D791eE3dA9D6A8F5407Fa1BD2D28f, WETH, "WETH"),
            _pair("yXAG", 0x27fAA3E80f9D791eE3dA9D6A8F5407Fa1BD2D28f, WBTC, "WBTC"),
            _pair("yXPT", 0x2bA7c85A45767443f44274331f20299755B17C2f, WETH, "WETH"),
            _pair("yXPT", 0x2bA7c85A45767443f44274331f20299755B17C2f, WBTC, "WBTC"),
            _pair("yXPD", 0xb9936ac3eE6b30C82587dAf7F2fF417758aaCe78, WETH, "WETH"),
            _pair("yXPD", 0xb9936ac3eE6b30C82587dAf7F2fF417758aaCe78, WBTC, "WBTC")
        ];

        pairs = new LendingPairInput[](40);
        for (uint256 j = 0; j < array.length; j++) {
            pairs[j] = array[j];
        }
    }

    function _pair(string memory symbol, address synth, address collateral, string memory collateralSymbol)
        internal
        pure
        returns (LendingPairInput memory)
    {
        return LendingPairInput({
            syntheticSymbol: symbol,
            synthetic: synth,
            collateral: collateral,
            collateralSymbol: collateralSymbol,
            ltvBps: collateral == WETH ? 7_500 : 7_000,
            liqThresholdBps: collateral == WETH ? 8_000 : 7_500,
            liqBonusBps: 500,
            liqPenaltyBps: 500,
            borrowRateBps: collateral == WETH ? 350 : 400,
            minBorrow: collateral == WETH ? 1e18 : 0.01e18
        });
    }
}
