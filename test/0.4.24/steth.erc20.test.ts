import { ethers } from "hardhat";

import { Steth__MinimalMock__factory } from "typechain-types";

import { ether } from "lib/units";

import { testERC20Compliance } from "../common/erc20.test";

testERC20Compliance({
  tokenName: "stETH",
  deploy,
});

testERC20Compliance({
  tokenName: "stETH (after positive rebase)",
  deploy: () => deploy(105n), // +5%
});

testERC20Compliance({
  tokenName: "stETH (after negative rebase)",
  deploy: () => deploy(95n), // -5%
});

async function deploy(rebaseFactor: bigint = 100n) {
  const signers = await ethers.getSigners();
  const [deployer, holder, recipient, spender] = signers;
  const holderBalance = ether("10.0");

  const factory = new Steth__MinimalMock__factory(deployer);
  const steth = await factory.deploy(holder, { value: holderBalance });

  const totalSupply = (holderBalance * rebaseFactor) / 100n;
  await steth.setTotalPooledEther(totalSupply);

  return {
    token: steth.connect(holder),
    name: "Liquid staked Ether 2.0",
    symbol: "stETH",
    decimals: 18n,
    totalSupply,
    holder,
    recipient,
    spender,
  };
}
