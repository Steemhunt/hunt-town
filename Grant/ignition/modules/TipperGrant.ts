import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { HUNT_BASE_ADDRESS } from "../../test/utils";

const TipperGrantModule = buildModule("TipperGrant", (m) => {
  const huntBase = m.getParameter("huntBase", HUNT_BASE_ADDRESS);

  const tipperGrant = m.contract("TipperGrant", [huntBase]);

  return { tipperGrant };
});

export default TipperGrantModule;
