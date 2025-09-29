import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("Mintpad", (m) => {
  // Use deployer address as default signer if no parameter provided
  const signerAddress = m.getParameter("signerAddress", m.getAccount(0));
  const bondAddress = m.getParameter("bondAddress", "0xc5a076cad94176c2996B32d8466Be1cE757FAa27");

  const mintpad = m.contract("Mintpad", [signerAddress, bondAddress]);

  return { mintpad };
});
