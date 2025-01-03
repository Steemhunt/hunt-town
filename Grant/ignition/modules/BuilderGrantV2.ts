import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const BuilderGrantV2Module = buildModule("BuilderGrantV2", (m) => {
  const mcv2Bond = m.getParameter("mcv2Bond", "");
  const huntBase = m.getParameter("huntBase", "");
  const miniBuilding = m.getParameter("miniBuilding", "");

  const builderGrantV2 = m.contract("BuilderGrantV2", [mcv2Bond, huntBase, miniBuilding]);

  return { builderGrantV2 };
});

export default BuilderGrantV2Module;
