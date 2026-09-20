let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { input += chunk; });
process.stdin.on("end", () => {
  const request = JSON.parse(input.trim());
  const { commandID, query } = request.params;
  process.stdout.write(`${JSON.stringify({
    jsonrpc: "2.0",
    id: request.id,
    result: `Web: ${commandID} / ${query}`,
  })}\n`);
});
