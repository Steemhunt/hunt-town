import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("ProjectUpdates", (m) => {
  const projectUpdates = m.contract("ProjectUpdates", [1n * 10n ** 18n]); // 1 HUNT per update initially

  return { projectUpdates };
});
