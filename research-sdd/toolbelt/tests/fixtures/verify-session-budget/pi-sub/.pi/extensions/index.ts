export default function (pi: any) { pi.on("before_agent_start", async (e: any) => { e.systemPromptOptions.sections["idx-root"] = "r".repeat(10); }); }
