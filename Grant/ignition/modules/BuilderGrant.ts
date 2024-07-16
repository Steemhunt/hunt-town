import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { MCV2_BOND_ADDRESS, MINI_BUILDING_ADDRESS, HUNT_BASE_ADDRESS } from "../../test/utils";

const BuilderGrantModule = buildModule("BuilderGrant", (m) => {
  const mcv2Bond = m.getParameter("mcv2Bond", MCV2_BOND_ADDRESS);
  const huntBase = m.getParameter("huntBase", HUNT_BASE_ADDRESS);
  const miniBuilding = m.getParameter("miniBuilding", MINI_BUILDING_ADDRESS);

  const builderGrant = m.contract("BuilderGrant", [mcv2Bond, huntBase, miniBuilding]);

  return { builderGrant };
});

export default BuilderGrantModule;
