export default function (pi: any) { pi.on("before_agent_start", async () => { process.exit(0); }); }
