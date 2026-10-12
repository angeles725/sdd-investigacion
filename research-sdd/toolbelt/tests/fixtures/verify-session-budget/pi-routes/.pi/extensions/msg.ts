export default function (pi: any) { pi.on("before_agent_start", async () => ({ message: { customType: "note", content: "m".repeat(300), display: true } })); }
