import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("Mintpad", (m) => {
  // Use deployer address as default signer if no parameter provided
  const signerAddress = m.getParameter("signerAddress", m.getAccount(0));
  // dailyHuntReward in Wei (TEST: 10 HUNT per day)
  const dailyHuntReward = m.getParameter("dailyHuntReward", 10n * 10n ** 18n);

  const mintpad = m.contract("Mintpad", [signerAddress, dailyHuntReward]);

  return { mintpad };
});
