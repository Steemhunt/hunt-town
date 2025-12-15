import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("ZapUniV4MCV2", (m) => {
  const zapUniV4MCV2 = m.contract("ZapUniV4MCV2");

  return { zapUniV4MCV2 };
});
