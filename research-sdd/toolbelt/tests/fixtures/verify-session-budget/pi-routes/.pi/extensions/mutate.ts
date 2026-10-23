export default function (pi: any) { pi.on("before_agent_start", async (e: any) => { e.systemPrompt += "x".repeat(500); }); }
