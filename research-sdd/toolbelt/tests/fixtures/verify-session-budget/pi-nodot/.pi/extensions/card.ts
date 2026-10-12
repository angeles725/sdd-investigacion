// Fixture target extension: one 2,500-char system-prompt section on before_agent_start (like niagara-protocol.ts's card).
export default function (pi: any) {
  pi.on("before_agent_start", async (event: any) => {
    event.systemPromptOptions.sections["card-section"] = "c".repeat(2500);
  });
}
