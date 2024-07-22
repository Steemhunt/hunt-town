import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { HUNT_BASE_ADDRESS } from "../../test/utils";

const TipperGrantModule = buildModule("TipperGrant", (m) => {
  const huntToken = m.getParameter("huntToken", HUNT_BASE_ADDRESS);

  const tipperGrant = m.contract("TipperGrant", [huntToken]);

  return { tipperGrant };
});

export default TipperGrantModule;
