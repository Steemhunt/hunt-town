import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const TipperGrantModule = buildModule("TipperGrant", (m) => {
  const huntBase = m.getParameter("huntBase", "");

  const tipperGrant = m.contract("TipperGrant", [huntBase]);

  return { tipperGrant };
});

export default TipperGrantModule;
