// Fixture target extension: one 6,000-char section, enough with the kit's sweep section to cross 8,000.
export default function (pi: any) {
  pi.on("before_agent_start", async (event: any) => {
    event.systemPromptOptions.sections["big-section"] = "b".repeat(6000);
  });
}
