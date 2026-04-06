// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {DataTypes} from "@yolo/core-v1/libraries/DataTypes.sol";
import {YoloHookViews} from "@yolo/core-v1/core/YoloHookViews.sol";

interface IYoloHookMaxSupply {
    function updateAssetMaxSupply(address syntheticToken, uint256 newMaxSupply) external;
}

contract DeployTask_UpdateSyntheticCaps is Script {
    address constant YOLO_HOOK_PROXY = 0x033ea50dEaa8b064958fC40E34F994C154D27FFf;
    address constant YOLO_HOOK_VIEWS = 0xf3C29D0284836bC7B7F1E6847ac83E0e139C5f21;

    struct CapUpdate {
        string symbol;
        address synthetic;
        uint256 newMaxSupply;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        CapUpdate[] memory updates = _loadUpdates();
        require(updates.length > 0, "No cap updates configured");

        console2.log("=================================");
        console2.log("YOLO Protocol V1 - Update Synthetic Caps");
        console2.log("=================================");
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);
        console2.log("Assets:", updates.length);
        console2.log("");

        IYoloHookMaxSupply hook = IYoloHookMaxSupply(YOLO_HOOK_PROXY);
        YoloHookViews views = YoloHookViews(YOLO_HOOK_VIEWS);

        uint256[] memory previousCaps = new uint256[](updates.length);
        for (uint256 i = 0; i < updates.length; i++) {
            DataTypes.AssetConfiguration memory cfg = views.getAssetConfiguration(updates[i].synthetic);
            previousCaps[i] = cfg.maxSupply;
        }

        vm.startBroadcast(deployerPrivateKey);
        for (uint256 i = 0; i < updates.length; i++) {
            console2.log("[", updates[i].symbol, "] Updating max supply...");
            console2.log("  Old cap:", previousCaps[i]);
            console2.log("  New cap:", updates[i].newMaxSupply);
            hook.updateAssetMaxSupply(updates[i].synthetic, updates[i].newMaxSupply);
        }
        vm.stopBroadcast();

        _saveDeployment(updates, previousCaps);

        console2.log("");
        console2.log("Update Complete!");
        console2.log("=================================");
    }

    function _loadUpdates() internal pure returns (CapUpdate[] memory updates) {
        updates = new CapUpdate[](35);
        uint256 i;
        updates[i++] = CapUpdate("yBTC", 0x430Ad0BF065d3c677D833646e629d69EB99b7AfA, 50 * 1e18);
        updates[i++] = CapUpdate("yETH", 0x4f24bdFE9f375E8BA9aCA6247DAAa8624cc4A02E, 1_500 * 1e18);
        updates[i++] = CapUpdate("ySOL", 0x6bDe934737AbD8E5cbBF37d2aDb726CeF6cd7a22, 31_000 * 1e18);
        updates[i++] = CapUpdate("yAAPL", 0x24Aab2A5c9aB642162E230f29b2057f66a24C03a, 15_000 * 1e18);
        updates[i++] = CapUpdate("yGOOGL", 0x4972567d733dC15419FDe35c81a2a6cbbA21436d, 14_000 * 1e18);
        updates[i++] = CapUpdate("yNVDA", 0x9093Fb36F7f9d29D295a2E83CCC113AA5065a52F, 3_400 * 1e18);
        updates[i++] = CapUpdate("yMETA", 0x21743096381b0469e9Ed414F1fBb71014e122145, 8000 * 1e18);
        updates[i++] = CapUpdate("yMSFT", 0xce8b6EBe3636BAEb14e4d0295C8Cd0C21e84685B, 9_600 * 1e18);
        updates[i++] = CapUpdate("yAMZN", 0x39D9D2593f8Bb52Bfe12Bd3733c87e4978F242Be, 23_000 * 1e18);
        updates[i++] = CapUpdate("yTSLA", 0x2f677b84AebE104D5F559e3f2A4D6463C4A14B36, 23_000 * 1e18);
        updates[i++] = CapUpdate("yAMD", 0x733b737320F0bd3fE347F02257F77E7A7807bC3E, 24_000 * 1e18);
        updates[i++] = CapUpdate("yNFLX", 0xa185A6f1Dc798a57D42c9CD13b93e72718682321, 6_400 * 1e18);
        updates[i++] = CapUpdate("yINTC", 0x8Db4f2aD2c4B07a6c5D5bBe0784Df5DB0E072706, 89_000 * 1e18);
        updates[i++] = CapUpdate("yPLTR", 0x57d086092eCD0F5653a9956019C0E0fA584A246A, 160_000 * 1e18);
        updates[i++] = CapUpdate("yCOIN", 0xbA9aa9fDBAE1040D9D74612A899dF2455957aA22, 16_000 * 1e18);
        updates[i++] = CapUpdate("yHOOD", 0x84D82024e8B7D504Ca33f237C64B7f218eee607f, 200_000 * 1e18);
        updates[i++] = CapUpdate("yJPM", 0x1317BD6371749e911c96F01d0305A9E23Ef3ABfe, 20_000 * 1e18);
        updates[i++] = CapUpdate("yBAC", 0xDef987Ab8663288e4D50124781Bf2aD12681db50, 100_000 * 1e18);
        updates[i++] = CapUpdate("yGS", 0x5fe0Ed58e69A16A897943ebad7C88C3aA65D6bFc, 8_600 * 1e18);
        updates[i++] = CapUpdate("yV", 0xA8411Ea314e74AFCB6e2B990e7c708E28Ad585Ea, 16_000 * 1e18);
        updates[i++] = CapUpdate("yDIS", 0x556edf4dE518210219d6c978f30aaFb55eb6906D, 40_000 * 1e18);
        updates[i++] = CapUpdate("yBA", 0xDaBD1E1E6A6b772Fa424f5F72E49Cb89aA47DD14, 20_000 * 1e18);
        updates[i++] = CapUpdate("yBABA", 0x6f6BA9a74160BB02F2EA43F58A24bD90CCd30f2F, 50_000 * 1e18);
        updates[i++] = CapUpdate("ySPY", 0x57475ec3590A24A0B791372545280252610f254B, 7_700 * 1e18);
        updates[i++] = CapUpdate("yQQQ", 0x36ee8B10Caed9AfC24654b8a082A8A8Eb081F8B4, 9_100 * 1e18);
        updates[i++] = CapUpdate("yDIA", 0x058aB338562B32A6bcc40641208C487Bb323B570, 11_000 * 1e18);
        updates[i++] = CapUpdate("yIWM", 0x06d9c5F15433934810b8632F034b66Fe823B9d75, 20_000 * 1e18);
        updates[i++] = CapUpdate("yUVXY", 0x8013f8c8dC7b73CC49eA5D36A45FCAacAd42a634, 445_000 * 1e18);
        updates[i++] = CapUpdate("yEUR", 0x3C335e06063f6c02f31132b1f8a651C0bDE8218D, 3_740_000 * 1e18);
        updates[i++] = CapUpdate("yBRENT", 0x37d32890F63D6aeC1F6C2Bfc4885A1B905C147D0, 50_000 * 1e18);
        updates[i++] = CapUpdate("yWTI", 0x3D5f5004ef3Bd1bcB03F578784757a5a67795F29, 54_000 * 1e18);
        updates[i++] = CapUpdate("yXAU", 0x114ED53a68230fFf4F1F4277e3d946eef90A0334, 1_800 * 1e18);
        updates[i++] = CapUpdate("yXAG", 0x27fAA3E80f9D791eE3dA9D6A8F5407Fa1BD2D28f, 135_000 * 1e18);
        updates[i++] = CapUpdate("yXPT", 0x2bA7c85A45767443f44274331f20299755B17C2f, 4_400 * 1e18);
        updates[i++] = CapUpdate("yXPD", 0xb9936ac3eE6b30C82587dAf7F2fF417758aaCe78, 3_900 * 1e18);
    }

    function _saveDeployment(CapUpdate[] memory updates, uint256[] memory previousCaps) internal {
        string memory root = "syntheticCaps";
        vm.serializeUint(root, "chainId", block.chainid);

        for (uint256 i = 0; i < updates.length; i++) {
            string memory key = string.concat("cap_", updates[i].symbol);
            string memory entry = vm.serializeString(key, "symbol", updates[i].symbol);
            entry = vm.serializeAddress(key, "synthetic", updates[i].synthetic);
            entry = vm.serializeUint(key, "oldMaxSupply", previousCaps[i]);
            entry = vm.serializeUint(key, "newMaxSupply", updates[i].newMaxSupply);
            vm.serializeString(root, key, entry);
        }

        string memory finalJson = vm.serializeUint(root, "timestamp", block.timestamp);
        string memory dir = "deployments";
        if (!vm.exists(dir)) {
            vm.createDir(dir, true);
        }
        string memory fileName = string.concat(dir, "/SyntheticCapsUpdate_", vm.toString(block.chainid), ".json");
        vm.writeJson(finalJson, fileName);
        console2.log("Saved summary to:", fileName);
    }
}
