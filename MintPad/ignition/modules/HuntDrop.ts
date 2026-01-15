import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("HuntDrop", (m) => {
  // Mintpad Signer
  const signerAddress = "0xCEa252F91e5Cc3559f781090Fc53f2ac0000B3eb";

  const huntDrop = m.contract("HuntDrop", [signerAddress]);

  return { huntDrop };
});
