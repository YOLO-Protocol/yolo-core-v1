Instructions:
- I need you to create a comprehensive guideline for another AI to develop a fully functional web3 frontend for the YOLO Coreve V1


References:
- For references wise, you can loosely refer to the 2 early frontends which I have created
- ```references/yolo-ui```: An very early srage UI where we develop for Hackathon purpose, pre-mature, just to let you know what pages shall be there (also on the navbar - But the new owder should be Swap, Trade, Synthetic RWAs, Loop Strategies, Earn, Dashboard) - Don't mimic this repo's way to fetch the price wss though... coz it's pre-mature
- ```references/compare-intent-trade```: Just to demonstrade how to use hermes-client to subsribe and display the live prices, as well as use tradingview graph and pyth as provider, dont learn other things


Requirement:
- The frontend codebase must be VERY VERY MODULAR and elegant, dont clunk all in a single page or something
- Actually carefully plan the architecture before you execute it
- make sure it's expandable in future

Tech Stack:
- It needs to use create rainbowkit app to scaffold the entire app
- Chain needs to to configure wagmi - and chain supports base sepolia preconf

Design:
- Needs to be modernly, simplistically professional, as well as fun and a bit funky (our protocol's is YOLO Protocol. YOLO stands for yield-oriented leverage optimization, and the url is yolo.wtf... a bit let you get the vibe) - Fun but elegant


Chains:
- So the frontend codebase must be inherently supporting multichain, and the react's configuration management must be at 1 place (think about aave v3 frontend where you can plug in additional changes on it and it will automatically be supported)
- By now we only supports Base Sepolia, but future we can supoort multiple chains
- There should be a toggle on top right where we can toggle to allow testnet or not. But right now the button is toggeld to testnet, and grey-out and cannot be selected - but should make it toggle-able in future - keep it extensible

Languages
- The codebase should be inherently multilinggual supported at day 1
- And at day1 the codebase should support English, Simplified Chinese, Traditional Chinese, and the is a dropdown bar to select the language and it will immediately change the language (Please make it modular and translation configurable)

State fetching
- So we fetches many things at once... there are many state I supposed... If possible make the fetching painless at the beginning so that when we switch around pages it wont be painful

Logos:
- Multiple palces needs to be have logo (Project LOGO, coin logos etc)
- But when logo not available you can put a place holder
- Like Aave styles tokens can be put in a single assets directory, and then I can create and place it there it can directly be displayed (learn from Aave V3's frontend)

Pages:
- These are the pages needed - should appear on the navbar
- you should look at the ```references/yolo-ui``` for the rough idea
    - ```swap```: Page to swap between assets... must support usdc, usy and all created synthetic assets
    - Must support exact in or exact out
    - Needs to be able to fetch the price by the stream hermes client if possible to estimate the input and output, with slippage (must consider fee and correctly display it, using what you learn from this codebase)
    - It should also correctly construct the swap argument and passed to the universal router - learn from ```script/DeployTask_TestSwap.sol``` but should support 2 ways and also exact input and exact output, and should be able to do the math and calculate the output correctly together with input box to indicate slippage
    - ```Perp Trades```: can learn from ```references/yolo-ui```'s trade page for the rough idea, however it should be correctly subsribe price from hermes client and correctly pass the price into opening positions... learn from ```references/compare-trade-intent/full-transaction``` on how to fetch pyth price and passes it to the contract, but insyead of passing it to the pyth contract, pass to TradeOrchestrator instead. The upper of the trading view chart bar there should show pyth live price of the said asset, (no need to show the passive price as showed in compare-trade-intent), and should properly display all trade configuration including borrowing intertest, funding factor etc.... and when we long or short it should properly show the long price - spread, and then below there should correctly show user's all opening positions and parse and display it correctly
    - ```Synthetic RWAs```: learn from ```references/yolo-ui```: should display and categorize all synthetic assets together with its supported collaterals, the mint and repay should actually works and sign the message to blockchain. The synthetic assets are at ```script/Deploy02_ConfigureProtocol``` and ```deployments/ConfiguredProtocol_84532.json```
    - ```Strategies```: This page only appear when we plug in yolo looper into the market configurations.... can leave this blank first but place holder must be there
    - ```Earn```: similar to ```references/yolo-ui```'s earn page, let user chip in their assets into sUSY and also YLP and correctly explain it
    - ```testnet faucet```: page that allow people to mind MockUSDC, MockETH, MockWBTC sUSDe and other mock collaterals where we created

