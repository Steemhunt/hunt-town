import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const BuilderGrantModule = buildModule("BuilderGrant", (m) => {
  const mcv2Bond = m.getParameter("mcv2Bond", "");
  const huntBase = m.getParameter("huntBase", "");
  const miniBuilding = m.getParameter("miniBuilding", "");

  const builderGrant = m.contract("BuilderGrant", [mcv2Bond, huntBase, miniBuilding]);

  return { builderGrant };
});

export default BuilderGrantModule;
