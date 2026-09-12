import { test, expect } from "bun:test";
import { createServer, type Socket } from "node:net";
import { RCONClient, encodePacket } from "../src/rcon/client";

async function fixture(handler: (socket: Socket, id: number, type: number, text: string) => void) {
  const sockets = new Set<Socket>();
  const server = createServer((socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    let buffer: Buffer = Buffer.alloc(0);
    socket.on("data", (data: Buffer) => {
      buffer = Buffer.concat([buffer, data]);
      while (buffer.length >= 4 && buffer.length >= buffer.readInt32LE(0) + 4) {
        const size = buffer.readInt32LE(0) + 4,
          packet = buffer.subarray(0, size);
        buffer = buffer.subarray(size);
        handler(
          socket,
          packet.readInt32LE(4),
          packet.readInt32LE(8),
          packet.subarray(12, -2).toString(),
        );
      }
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const client = new RCONClient(
    { host: "127.0.0.1", port: (server.address() as { port: number }).port, password: "test" },
    150,
  );
  return {
    client,
    close: async () => {
      await client.disconnect();
      for (const socket of sockets) socket.destroy();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

test("RCON handles split headers, coalesced packets, UTF-8 and serialized commands", async () => {
  const commands: string[] = [];
  const f = await fixture((socket, id, type, text) => {
    if (type === 3) {
      socket.write(Buffer.concat([encodePacket(id, 0, ""), encodePacket(id, 2, "")]));
      return;
    }
    if (text === "/version") {
      socket.write(encodePacket(id, 0, "2.0.77"));
      return;
    }
    commands.push(text);
    const packet = encodePacket(id, 0, `${text}: áéí Ñ 🚂 ${"x".repeat(15000)}`);
    for (const [start, end] of [
      [0, 2],
      [2, 10],
      [10, 23],
      [23, packet.length],
    ])
      socket.write(packet.subarray(start, end));
  });
  try {
    const results = await Promise.all([f.client.sendCommand("one"), f.client.sendCommand("two")]);
    expect(commands).toEqual(["one", "two"]);
    for (let i = 0; i < 2; i++)
      expect(results[i]).toEqual({
        success: true,
        data: `${commands[i]}: áéí Ñ 🚂 ${"x".repeat(15000)}`,
      });
    await Bun.sleep(180);
    expect(f.client.isConnected()).toBe(true);
    await f.client.disconnect();
    expect((await f.client.sendCommand("after shutdown")).error).toContain("stopped");
    expect(commands).toEqual(["one", "two"]);
  } finally {
    await f.close();
  }
});

test("RCON rejects authentication failures and malformed packets", async () => {
  for (const malformed of [false, true]) {
    const f = await fixture((socket, _id) =>
      socket.write(malformed ? Buffer.from([1, 0, 0, 0]) : encodePacket(-1, 2, "")),
    );
    try {
      const result = await f.client.sendCommand("test");
      expect(result.success).toBe(false);
      expect(result.error).toContain(malformed ? "packet length" : "authentication failed");
    } finally {
      await f.close();
    }
  }
});

test("an uncertain timed-out mutation is never retried; next command reconnects", async () => {
  let mutations = 0;
  let recovering = false;
  const f = await fixture((socket, id, type, text) => {
    if (type === 3) socket.write(encodePacket(id, 2, ""));
    else if (text === "mutate") mutations++;
    else if (recovering) socket.write(encodePacket(id, 0, text === "read" ? "ok" : "2.0.77"));
  });
  try {
    expect((await f.client.sendCommand("mutate")).error).toContain("outcome unknown");
    expect(mutations).toBe(1);
    recovering = true;
    expect(await f.client.sendCommand("read")).toEqual({ success: true, data: "ok" });
    expect((await f.client.sendCommand("bad\ncommand")).success).toBe(false);
  } finally {
    await f.close();
  }
});
