import { BaseContract } from "ethers";

import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

import {
  ACL__factory,
  DAOFactory__factory,
  EIP712StETH__factory,
  EVMScriptRegistryFactory__factory,
  Kernel,
  Kernel__factory,
  Lido__factory,
  LidoLocator,
} from "typechain-types";

import { dummyLocator } from "./dummy";
import { findEvents } from "./event";
import { streccak } from "./keccak";
import { ether } from "./units";

export async function createAragonDao(rootAccount: HardhatEthersSigner) {
  const kernelBase = await new Kernel__factory(rootAccount).deploy(true);
  const aclBase = await new ACL__factory(rootAccount).deploy();
  const EvmScriptRegistryFactory = await new EVMScriptRegistryFactory__factory(rootAccount).deploy();
  const daoFactory = await new DAOFactory__factory(rootAccount).deploy(kernelBase, aclBase, EvmScriptRegistryFactory);

  const tx = await daoFactory.newDAO(rootAccount);
  const txReceipt = await tx.wait();
  const daoAddress = findEvents(txReceipt!, "DeployDAO")[0].args[0];

  const dao = Kernel__factory.connect(daoAddress, rootAccount);
  const acl = ACL__factory.connect(await dao.acl(), rootAccount);
  const APP_MANAGER_ROLE = await kernelBase.APP_MANAGER_ROLE();
  await acl.createPermission(rootAccount, await dao.getAddress(), APP_MANAGER_ROLE, rootAccount);

  return { dao, acl };
}

interface CreateAddAppArgs {
  dao: Kernel;
  name: string;
  impl: BaseContract;
  rootAccount: HardhatEthersSigner;
}

export async function addAragonApp({ dao, name, impl, rootAccount }: CreateAddAppArgs): Promise<string> {
  const tx = await dao["newAppInstance(bytes32,address,bytes,bool)"](
    streccak(`${name}.aragonpm.test`),
    await impl.getAddress(),
    "0x",
    false,
    { from: rootAccount },
  );

  const receipt = await tx.wait();
  const proxyAddress = findEvents(receipt!, "NewAppProxy")[0].args[0];

  return proxyAddress;
}

interface DeployLidoDaoArgs {
  rootAccount: HardhatEthersSigner;
  initialized: boolean;
  locatorConfig?: Partial<LidoLocator.ConfigStruct>;
}

export async function deployLidoDao({ rootAccount, initialized, locatorConfig = {} }: DeployLidoDaoArgs) {
  const { dao, acl } = await createAragonDao(rootAccount);

  const impl = await new Lido__factory(rootAccount).deploy();

  const lidoProxyAddress = await addAragonApp({
    dao,
    name: "lido",
    impl,
    rootAccount,
  });

  const lido = Lido__factory.connect(lidoProxyAddress, rootAccount);

  if (initialized) {
    const locator = await dummyLocator({ lido, ...locatorConfig }, rootAccount);
    const eip712steth = await new EIP712StETH__factory(rootAccount).deploy(lido);
    await lido.initialize(locator, eip712steth, { value: ether("1.0") });
  }

  return { lido, dao, acl };
}
