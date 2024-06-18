import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { TOWN_HALL_ADDRESS } from "../../test/utils";

const HuntGrantModule = buildModule("HuntGrant", (m) => {
  const townhall = m.getParameter("townHall", TOWN_HALL_ADDRESS);

  const huntGrant = m.contract("HuntGrant", [townhall]);

  return { huntGrant };
});

export default HuntGrantModule;
